package com.mint.podencomusic

import android.Manifest
import android.annotation.TargetApi
import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
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
 */
class MainActivity : FlutterActivity() {

    private data class PendingSave(
        val sourcePath: String,
        val fileName: String,
        val mimeType: String,
        val result: MethodChannel.Result,
    )

    /** 等用户点完权限弹窗后要继续的保存任务 */
    private var pendingSave: PendingSave? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToMusic" -> handleSave(call, result)
                    "listMusic" -> result.success(listMusic())
                    "hasPermission" -> result.success(hasStoragePermission())
                    "getFreeSpace" -> result.success(getFreeSpace())
                    "openMusicFolder" -> result.success(openMusicFolder())
                    else -> result.notImplemented()
                }
            }
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

    /** Android 9 及以下：直接往公共目录写文件，写完通知媒体库扫描 */
    @Suppress("DEPRECATION")
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
    private fun openMusicFolder(): Boolean = try {
        val uri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            "primary:${Environment.DIRECTORY_MUSIC}/$FOLDER",
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
        private const val FOLDER = "PodencoMusic"
    }
}
