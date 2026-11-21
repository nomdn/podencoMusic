package com.mint.podencomusic

import android.Manifest
import android.annotation.TargetApi
import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.io.File

/**
 * 把下载好的音频放进系统 Music 目录。
 *
 * 分两条路：
 *   Android 10（API 29）及以上 —— 走 MediaStore.Audio，写自己插入的条目不需要任何权限。
 *   Android 9 及以下        —— 老的公共目录直接写文件，必须先拿到 WRITE_EXTERNAL_STORAGE。
 *
 * 为什么不存 app 私有目录：那样系统音乐播放器里根本看不到，文件管理器也要翻好几层。
 * 用户要的是「下载完就能在系统里直接听」。
 *
 * 基类是 AudioServiceActivity（FlutterActivity 的子类）：audio_service
 * 要靠它在引擎就绪前接管 MediaButton / 服务生命周期，播放时才能拉起
 * 带媒体通知的前台服务。
 */
class MainActivity : AudioServiceActivity() {

    private data class PendingSave(
        val sourcePath: String,
        val fileName: String,
        val mimeType: String,
        val result: MethodChannel.Result,
    )

    /** 等用户点完权限弹窗后要继续的保存任务 */
    private var pendingSave: PendingSave? = null

    /** 等用户在 Shizuku 授权框点完后要回话的通道结果 */
    private var pendingShizukuResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToMusic" -> handleSave(call, result)
                    "saveText" -> handleSaveText(call, result)
                    "listMusic" -> result.success(listMusic())
                    "hasPermission" -> result.success(hasStoragePermission())
                    "getFreeSpace" -> result.success(getFreeSpace())
                    "openMusicFolder" -> result.success(openMusicFolder())
                    "openExportFolder" -> result.success(openFolderIn(Environment.DIRECTORY_DOWNLOADS))
                    "ensureNotificationPermission" -> {
                        ensureNotificationPermission()
                        result.success(true)
                    }
                    "getVivoWhitelist" -> result.success(getVivoWhitelist())
                    "setVivoWhitelist" -> {
                        val json = call.argument<String>("json")
                        if (json.isNullOrEmpty()) {
                            result.error("bad_args", "json 不能为空", null)
                        } else {
                            result.success(setVivoWhitelist(json))
                        }
                    }
                    "vivoWhitelistEnv" -> result.success(
                        mapOf(
                            "shizukuAlive" to shizukuAlive(),
                            "shizukuGranted" to shizukuGranted(),
                            "canWriteSettings" to Settings.System.canWrite(this),
                        ),
                    )
                    "vivoShizukuRequestPermission" -> {
                        // Shizuku 的授权框是异步的：先挂起通道结果，
                        // 用户点完在 onRequestPermissionResult 里回话
                        pendingShizukuResult = result
                        Shizuku.requestPermission(REQUEST_SHIZUKU)
                    }
                    "openVivoWriteSettings" -> result.success(openVivoWriteSettings())
                    else -> result.notImplemented()
                }
            }

        Shizuku.addRequestPermissionResultListener(shizukuPermissionListener)
    }

    // ── 保存 ─────────────────────────────────────────────────

    private fun handleSave(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("path")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType") ?: "audio/mpeg"

        if (sourcePath.isNullOrEmpty() || fileName.isNullOrEmpty()) {
            result.error("bad_args", "path 和 fileName 不能为空", null)
            return
        }
        if (!File(sourcePath).exists()) {
            result.error("source_missing", "临时文件不存在：$sourcePath", null)
            return
        }

        val job = PendingSave(sourcePath, fileName, mimeType, result)

        // Android 10 起，往 MediaStore 插入自己的媒体条目不需要权限
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q || hasStoragePermission()) {
            runSave(job)
            return
        }

        // 老系统：先把任务挂起，弹权限框，用户点完在 onRequestPermissionsResult 里接着做
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingSave = job
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQUEST_WRITE,
            )
        } else {
            // API 23 以下是安装时授权，直接写
            runSave(job)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_WRITE) return

        val job = pendingSave ?: return
        pendingSave = null

        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            runSave(job)
        } else {
            job.result.error(
                "permission_denied",
                "没有存储权限，无法保存到 Music 目录",
                null,
            )
        }
    }

    private fun runSave(job: PendingSave) {
        try {
            val location = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveWithMediaStore(job.sourcePath, job.fileName, job.mimeType)
            } else {
                saveWithFile(job.sourcePath, job.fileName)
            }
            job.result.success(location)
        } catch (e: Exception) {
            job.result.error("save_failed", e.message ?: "保存失败", null)
        }
    }

    /**
     * Android 10+ 的正路。IS_PENDING 先占位、写完再置 0，
     * 这样正在写的文件不会被音乐 App 扫到半截内容。
     *
     * 不写 TITLE / ARTIST：这两列会在媒体扫描时被文件内嵌标签覆盖，
     * 写了也留不住，属于做无用功。
     */
    @TargetApi(Build.VERSION_CODES.Q)
    private fun saveWithMediaStore(
        sourcePath: String,
        fileName: String,
        mimeType: String,
    ): String {
        val collection = MediaStore.Audio.Media.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY,
        )
        val relativePath = "${Environment.DIRECTORY_MUSIC}/$FOLDER"

        // 同名条目先删掉，否则重复下载会在音乐库里堆出一串同名的「幽灵歌曲」
        contentResolver.query(
            collection,
            arrayOf(MediaStore.Audio.Media._ID),
            "${MediaStore.Audio.Media.RELATIVE_PATH}=? AND ${MediaStore.Audio.Media.DISPLAY_NAME}=?",
            arrayOf("$relativePath/", fileName),
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                contentResolver.delete(
                    ContentUris.withAppendedId(collection, id),
                    null,
                    null,
                )
            }
        }

        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Audio.Media.MIME_TYPE, mimeType)
            put(MediaStore.Audio.Media.RELATIVE_PATH, relativePath)
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }

        val uri = contentResolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore 插入失败")

        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                File(sourcePath).inputStream().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("无法打开输出流")
        } catch (e: Exception) {
            // 写失败就把占位条目删掉，别留一个 0 字节的空壳
            contentResolver.delete(uri, null, null)
            throw e
        }

        values.clear()
        values.put(MediaStore.Audio.Media.IS_PENDING, 0)
        contentResolver.update(uri, values, null, null)

        return uri.toString()
    }

    /**
     * 把一段文本写进「下载/PodencoMusic」。歌单导出走这里。
     *
     * 为什么不复用 saveToMusic：那条路进的是 MediaStore.Audio，
     * 文本文件会被系统音乐 App 当成一首歌扫出来。文本属于 Downloads。
     */
    private fun handleSaveText(call: MethodCall, result: MethodChannel.Result) {
        val fileName = call.argument<String>("fileName")
        val content = call.argument<String>("content")
        if (fileName.isNullOrEmpty() || content == null) {
            result.error("bad_args", "fileName 和 content 不能为空", null)
            return
        }

        // Android 10 起写自己的 Downloads 条目免权限；9 及以下要先有存储权限
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && !hasStoragePermission()) {
            result.error("permission_denied", "导出需要存储权限", null)
            return
        }

        try {
            result.success(saveTextToDownloads(fileName, content))
        } catch (e: Exception) {
            result.error("save_failed", e.message ?: "导出失败", null)
        }
    }

    private fun saveTextToDownloads(fileName: String, content: String): String {
        val mimeType =
            if (fileName.endsWith(".json", ignoreCase = true)) {
                "application/json"
            } else {
                "audio/x-mpegurl"
            }
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER"
        val bytes = content.toByteArray(Charsets.UTF_8)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = MediaStore.Downloads.getContentUri(
                MediaStore.VOLUME_EXTERNAL_PRIMARY,
            )

            // 同名条目先删：反复导出同一个歌单不该在下载目录里堆一串副本
            contentResolver.query(
                collection,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.RELATIVE_PATH}=? AND ${MediaStore.Downloads.DISPLAY_NAME}=?",
                arrayOf("$relativePath/", fileName),
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    contentResolver.delete(
                        ContentUris.withAppendedId(collection, id),
                        null,
                        null,
                    )
                }
            }

            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }

            val uri = contentResolver.insert(collection, values)
                ?: throw IllegalStateException("MediaStore 插入失败")

            try {
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IllegalStateException("无法打开输出流")
            } catch (e: Exception) {
                // 写失败删掉占位，别留 0 字节空壳
                contentResolver.delete(uri, null, null)
                throw e
            }

            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)

            return uri.toString()
        }

        // Android 9 及以下：直接写公共下载目录，写完通知媒体库
        @Suppress("DEPRECATION")
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            FOLDER,
        )
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, fileName)
        file.writeText(content, Charsets.UTF_8)
        MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf(mimeType), null)
        return file.absolutePath
    }

    /** Android 9 及以下：直接往公共目录写文件，写完通知媒体库扫描 */    @Suppress("DEPRECATION")
    private fun saveWithFile(sourcePath: String, fileName: String): String {
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
            FOLDER,
        )
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("无法创建目录：${dir.absolutePath}")
        }

        val target = File(dir, fileName)
        File(sourcePath).copyTo(target, overwrite = true)

        // 不扫的话音乐 App 要等下次开机才看得到
        MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), null, null)

        return target.absolutePath
    }

    // ── 通知权限 ─────────────────────────────────────────────

    /**
     * Android 13（API 33）起，通知要运行时授权才会显示。媒体通知是
     * 「灵动岛」类胶囊、锁屏控制和线控的载体，启动时尽力申请一次；
     * 被拒不阻塞任何功能，用户随时可以在系统设置里补开。
     */
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) return
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATIONS,
        )
    }

    // ── vivo 原子随身听白名单 ─────────────────────────────────

    /**
     * vivo / iQOO（OriginOS 4）原子随身听的音源白名单存在 system settings
     * 表里，key 是 musicwidget_list_pkg_type_key。两条写入通道自动选路：
     *
     *   Shizuku 在线  → 以 shell 身份执行 settings put（与社区 ADB 教程
     *                   完全等效，保真度最高）；
     *   否则          → Settings API 直写（需用户授予「修改系统设置」）。
     *
     * key 不存在（非 vivo 设备 / 新版 OriginOS 换了实现）返回 null。
     */
    private fun getVivoWhitelist(): String? = runCatching {
        // Shizuku 优先（shell 身份，与社区 ADB 教程完全等效）；
        // 执行失败（反射不可用 / 命令报错）时退回 Settings API 直读
        if (shizukuReady()) shizukuGet() ?: fallbackRead() else fallbackRead()
    }.getOrNull()

    private fun setVivoWhitelist(json: String): Boolean {
        // Shizuku 优先，失败（未授权 / 反射不可用）时退回 WRITE_SETTINGS
        if (shizukuReady() && shizukuPut(json)) return true
        return runCatching {
            Settings.System.putString(contentResolver, VIVO_WHITELIST_KEY, json)
        }.getOrDefault(false)
    }

    /**
     * Shizuku 以 shell 身份执行命令，返回 (stdout, 退出码)。
     *
     * 为什么反射：API 13 的 Shizuku.newProcess 是 private 的（官方只推
     * bindUserService 的 AIDL 服务路线），但一次性 settings 命令不值得
     * 背一套服务生命周期。签名哪天变了 runCatching 会兜住，自动退回
     * 「修改系统设置」通道，无副作用。
     */
    private fun shizukuExec(command: String): Pair<String, Int>? = runCatching {
        val method = Shizuku::class.java.getDeclaredMethod(
            "newProcess",
            Array<String>::class.java,
            Array<String>::class.java,
            String::class.java,
        )
        method.isAccessible = true
        val proc = method.invoke(
            null,
            arrayOf("sh", "-c", command),
            null,
            null,
        ) as Process
        try {
            val out = proc.inputStream.bufferedReader().readText().trim()
            val code = proc.waitFor()
            out to code
        } finally {
            proc.destroy()
        }
    }.getOrNull()

    private fun shizukuGet(): String? {
        val result =
            shizukuExec("settings get system $VIVO_WHITELIST_KEY") ?: return null
        if (result.second != 0) return null
        val out = result.first
        return if (out.isEmpty() || out == "null") null else out
    }

    private fun shizukuPut(json: String): Boolean {
        // json 里只有双引号，shell 单引号包裹不会冲突
        val result =
            shizukuExec("settings put system $VIVO_WHITELIST_KEY '$json'")
                ?: return false
        return result.second == 0
    }

    private fun shizukuAlive(): Boolean = runCatching { Shizuku.pingBinder() }.getOrDefault(false)

    private fun shizukuGranted(): Boolean = runCatching {
        Shizuku.pingBinder() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    private fun shizukuReady(): Boolean = shizukuAlive() && shizukuGranted()

    /** 不经 Shizuku 的兜底读法：Settings API（需已授予「修改系统设置」才能写） */
    private fun fallbackRead(): String? =
        Settings.System.getString(contentResolver, VIVO_WHITELIST_KEY)

    private val shizukuPermissionListener =
        Shizuku.OnRequestPermissionResultListener { _, grantResult ->
            pendingShizukuResult?.success(
                grantResult == PackageManager.PERMISSION_GRANTED,
            )
            pendingShizukuResult = null
        }

    /** 跳到系统的「修改系统设置」授权页，让用户手动打开开关 */
    private fun openVivoWriteSettings(): Boolean = try {
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_WRITE_SETTINGS,
                Uri.parse("package:$packageName"),
            ),
        )
        true
    } catch (e: Exception) {
        false
    }

    // ── 查询已下载 ───────────────────────────────────────────

    /** 列出 Music/PodencoMusic 下已有的文件名，Dart 侧用它判断哪些歌已经下过 */
    private fun listMusic(): List<String> {
        val names = mutableListOf<String>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = MediaStore.Audio.Media.getContentUri(
                MediaStore.VOLUME_EXTERNAL_PRIMARY,
            )
            contentResolver.query(
                collection,
                arrayOf(MediaStore.Audio.Media.DISPLAY_NAME),
                "${MediaStore.Audio.Media.RELATIVE_PATH} LIKE ?",
                arrayOf("${Environment.DIRECTORY_MUSIC}/$FOLDER/%"),
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    cursor.getString(0)?.let { names.add(it) }
                }
            }
        } else if (hasStoragePermission()) {
            // 老系统没权限时读不到，返回空列表即可，不影响下载
            @Suppress("DEPRECATION")
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
                FOLDER,
            )
            dir.listFiles()?.forEach { names.add(it.name) }
        }

        return names
    }

    private fun hasStoragePermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
    }

    // ── 磁盘空间与打开目录 ───────────────────────────────────

    /**
     * Music 目录所在卷的剩余字节数，批量下载前 Dart 侧拿来检查磁盘。
     * 老系统没权限时 StatFs 也会抛异常，统一吞掉返回 null —— 检查是尽力而为。
     */
    private fun getFreeSpace(): Long? = try {
        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
        StatFs(dir.path).availableBytes
    } catch (e: Exception) {
        null
    }

    /**
     * 用系统文件管理器打开 Music/PodencoMusic。
     *
     * 目录没有直接「打开」的 API，走 DocumentsUI 的目录浏览 intent ——
     * buildDocumentUri 指到 primary:Music/PodencoMusic，各家文件管理器
     * （DocumentsUI、小米文件管理等）都认这个格式。打不开返回 false，
     * Dart 侧提示用户去系统音乐 App 找。
     */
    private fun openMusicFolder(): Boolean = openFolderIn(Environment.DIRECTORY_MUSIC)

    /** 用 DocumentsUI 打开公共目录（Music / Download）下的 PodencoMusic 子目录 */
    private fun openFolderIn(parent: String): Boolean = try {
        val uri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            "primary:$parent/$FOLDER",
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "vnd.android.document/directory")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        true
    } catch (e: ActivityNotFoundException) {
        false
    }

    companion object {
        private const val CHANNEL = "com.mint.podencomusic/storage"
        private const val REQUEST_WRITE = 4001
        private const val REQUEST_NOTIFICATIONS = 4002
        private const val REQUEST_SHIZUKU = 4003
        private const val FOLDER = "PodencoMusic"

        /** OriginOS 原子随身听音源白名单的 settings key（system 表） */
        private const val VIVO_WHITELIST_KEY = "musicwidget_list_pkg_type_key"
    }
}
