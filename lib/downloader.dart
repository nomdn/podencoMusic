import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'audio_tags.dart';
import 'bili_api.dart';
import 'disk_space.dart';
import 'fmp4_remux.dart';
import 'library.dart';
import 'models.dart';
import 'static_cache.dart';
import 'music_store.dart';
import 'siren_api.dart';
import 'web_download.dart';

/// 一首歌的下载状态。五个字段描述完整生命周期，别加中间态。
enum DownloadStatus { idle, queued, running, done, failed }

@immutable
class DownloadState {
  const DownloadState({
    this.status = DownloadStatus.idle,
    this.progress = 0,
    this.path,
    this.error,
  });

  final DownloadStatus status;

  /// 0~1。服务端不给 Content-Length 时恒为 0，界面就显示不确定进度。
  final double progress;
  final String? path;
  final String? error;

  bool get isQueued => status == DownloadStatus.queued;
  bool get isRunning => status == DownloadStatus.running;
  bool get isDone => status == DownloadStatus.done;
}

/// queueAll 的结果：加了几首、跳了几首、有没有被磁盘检查拦下。
@immutable
class QueueResult {
  const QueueResult({
    required this.added,
    required this.skipped,
    this.blockedReason,
  });

  final int added;
  final int skipped;

  /// 非 null = 整批被拦（磁盘空间不足），一首都没入队。
  final String? blockedReason;

  bool get blocked => blockedReason != null;
}

/// 下载器。全局一个实例，因为「哪些歌已经下过」是全局状态。
///
/// 存哪儿：
///   Android         → 系统 Music/PodencoMusic/，走 MediaStore，系统音乐 App 能直接扫到
///   Windows / macOS → 系统下载目录下的 PodencoMusic/
///   其它            → 应用文档目录
///
/// 单曲点击走 [download]，立刻开始；批量走 [queueAll] 进串行队列
/// —— 一首下一首，几十 MB 的 wav 并发只会互相抢带宽。
class Downloader extends ChangeNotifier {
  final Map<String, DownloadState> _states = {};
  final Set<String> _downloadedStems = {};

  /// 批量下载的等待队列，先进先出，[_drain] 从头取。
  final List<Track> _pending = [];

  /// 见过的每首歌，管理页按 cid 找回 Track 来显示。
  final Map<String, Track> _known = {};

  /// 正在下载的流客户端，取消时掐断它，流会报错然后按取消处理。
  /// 单曲直下和队列任务都会挂在这里，管理页按 cid 取消。
  final Map<String, http.Client> _activeClients = {};

  /// Web 端下载的取消句柄（AbortController），与 _activeClients 同责。
  final Map<String, WebDownloadHandle> _webHandles = {};

  /// 用户点了取消、但流还没抛错之前的标记
  final Set<String> _cancelRequested = {};

  bool _draining = false;

  Directory? _cachedDir;

  /// 节流用：上次通知时的进度，避免每个数据块都触发一次重建
  final Map<String, double> _lastNotified = {};

  DownloadState stateOf(String cid) => _states[cid] ?? const DownloadState();

  /// 等待队列（不含正在下载的那首）。
  List<Track> get pendingTracks => List.unmodifiable(_pending);

  /// 正在下载的歌（单曲直下 + 队列里跑着的都算），新的在前。
  /// 直接从状态表推导，别用单个「当前任务」字段 —— 那样单曲
  /// 直下的任务在管理页上永远显示不出来。
  List<Track> get runningTracks => _byStatus(DownloadStatus.running);

  /// 已完成 / 失败的歌，新的在前。管理页的两个静态区用。
  List<Track> get doneTracks => _byStatus(DownloadStatus.done);
  List<Track> get failedTracks => _byStatus(DownloadStatus.failed);

  List<Track> _byStatus(DownloadStatus status) {
    final result = <Track>[];
    for (final entry in _states.entries) {
      if (entry.value.status != status) continue;
      final track = _known[entry.key];
      if (track != null) result.add(track);
    }
    return result.reversed.toList();
  }

  /// 启动时把已有的下载记录恢复出来。
  /// Android 查 MediaStore，桌面直接扫目录 —— 都不需要请求网络。
  Future<void> scanExisting() async {
    if (kIsWeb) {
      // 恢复上次授权的目录（只查权，绝不弹框），扫一遍文件名把
      // 「已下载」标记恢复出来 —— 浏览器把权限收回了就当没下过
      await webFs.querySavedAccess();
      final names = await webFs.listSavedDirectory();
      for (final name in names) {
        final stem = _stemOfFileName(name);
        if (stem != null) _downloadedStems.add(stem);
      }
      notifyListeners();
      return;
    }
    try {
      if (MusicStore.isSupported) {
        final names = await MusicStore.list();
        for (final name in names) {
          final stem = _stemOfFileName(name);
          if (stem != null) _downloadedStems.add(stem);
        }
        notifyListeners();
        return;
      }

      final dir = await targetDirectory();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final stem = _stemOfFileName(entity.uri.pathSegments.last);
        if (stem != null) _downloadedStems.add(stem);
      }
      notifyListeners();
    } catch (_) {
      // 扫不到就算了，不影响下载
    }
  }

  /// 这首歌是不是已经在本地了（判断依据是文件名，不请求网络）。
  /// 兼容老版本生成的「艺人 - 曲名」文件名，否则改名后已下载的老歌
  /// 会被误判成没下载，用户一刷新就重复下一份。
  bool isDownloaded(Track track) {
    final stem = _stemFor(track);
    if (_downloadedStems.contains(stem)) return true;
    if (track.artists.isEmpty) return false;
    return _downloadedStems.contains(
      _sanitizeStem('${track.artists.first} - ${track.name}'),
    );
  }

  /// 这首歌要不要下。拆成纯函数是为了单测不用碰实例状态和网络。
  static bool needsDownload(
    Track track, {
    required bool downloaded,
    required DownloadState? state,
  }) =>
      !downloaded &&
      !(state?.isRunning ?? false) &&
      !(state?.isQueued ?? false) &&
      !(state?.isDone ?? false);

  /// 批量入队时真正需要下载的歌。跳过已下载 / 已完成 / 进行中 / 已排队的。
  List<Track> pickNew(List<Track> tracks) => tracks
      .where(
        (t) => needsDownload(
          t,
          downloaded: isDownloaded(t),
          state: _states[t.cid],
        ),
      )
      .toList();

  /// 把一批歌排进队列，串行逐首下。返回结果给 UI 弹提示用。
  Future<QueueResult> queueAll(List<Track> tracks) async {
    if (kIsWeb) {
      if (!webFsSupported) {
        return QueueResult(
          added: 0,
          skipped: tracks.length,
          blockedReason: '当前浏览器不支持归档（需 Chrome / Edge）',
        );
      }
      // 目录授权要趁用户手势还在（弹选择框 / 续权）：批量任务的第一首
      // 下载隔着好几层 await，到那时手势早就过期了
      if (!await webFs.ensureDirectoryAccess()) {
        return QueueResult(
          added: 0,
          skipped: tracks.length,
          blockedReason: '未选择 / 未授权归档目录',
        );
      }
    }
    final fresh = pickNew(tracks);

    if (fresh.isNotEmpty) {
      final blockedReason = await _checkDiskSpace();
      if (blockedReason != null) {
        return QueueResult(
          added: 0,
          skipped: tracks.length,
          blockedReason: blockedReason,
        );
      }
      for (final track in fresh) {
        _known[track.cid] = track;
        _pending.add(track);
        _publish(track.cid, const DownloadState(status: DownloadStatus.queued));
      }
      unawaited(_drain());
    }

    return QueueResult(added: fresh.length, skipped: tracks.length - fresh.length);
  }

  /// 下载一首歌，返回最终位置的路径 / URI；失败返回 null。
  Future<String?> download(Track track) async {
    final existing = _states[track.cid];
    // 进行中或已排队都拒绝重入 —— 排队中的歌在管理页取消后再点即可
    if (existing != null && (existing.isRunning || existing.isQueued)) {
      return null;
    }
    _known[track.cid] = track;
    // Web：目录授权必须趁用户手势还在（弹选择框 / 续权），赶在任何
    // 网络请求之前做；被拒就按失败收尾，SnackBar 会给出原因
    if (kIsWeb) {
      if (!webFsSupported) {
        _publish(
          track.cid,
          const DownloadState(
            status: DownloadStatus.failed,
            error: '当前浏览器不支持归档（需 Chrome / Edge）',
          ),
        );
        return null;
      }
      if (!await webFs.ensureDirectoryAccess()) {
        _publish(
          track.cid,
          const DownloadState(
            status: DownloadStatus.failed,
            error: '未选择 / 未授权归档目录',
          ),
        );
        return null;
      }
    }
    return _downloadNow(track);
  }

  /// 取消下载：排队中的直接移出，正在下的掐断传输流。
  /// 取消后回到「未下载」态，随时可以再点。
  void cancel(String cid) {
    final index = _pending.indexWhere((t) => t.cid == cid);
    if (index >= 0) {
      _pending.removeAt(index);
      _publish(cid, const DownloadState());
      return;
    }
    // Web 下载：掐断 fetch 的 AbortController，效果与掐流一致
    if (_webHandles.containsKey(cid)) {
      _cancelRequested.add(cid);
      _webHandles[cid]!.abort();
      return;
    }
    // 单曲直下的任务不在队列里，看它有没有挂着的流客户端
    if (_activeClients.containsKey(cid)) {
      _cancelRequested.add(cid);
      // 掐断流。正在写的那份临时文件 / .part 由各自的失败清理逻辑删掉
      _activeClients[cid]?.close();
    }
  }

  /// 清空等待队列（不影响正在下载的那首）。
  void clearQueue() {
    if (_pending.isEmpty) return;
    for (final track in _pending) {
      _publish(track.cid, const DownloadState());
    }
    _pending.clear();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final track = _pending.removeAt(0);
        if (_cancelRequested.remove(track.cid)) {
          // 入队到出队之间被取消了
          _publish(track.cid, const DownloadState());
          continue;
        }
        await _downloadNow(track);
      }
    } finally {
      _draining = false;
    }
  }

  /// 批量前的磁盘检查。拦下时返回原因，放行返回 null。
  Future<String?> _checkDiskSpace() async {
    int? freeBytes;
    if (MusicStore.isSupported) {
      freeBytes = await MusicStore.getFreeSpace();
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final dir = await targetDirectory();
      freeBytes = DiskSpace.freeBytesAt(dir.path);
    }
    if (freeBytes == null) return null;
    if (freeBytes >= DiskSpace.minFreeBytes) return null;
    return '磁盘剩余空间不足（${_formatBytes(freeBytes)}），请先清理缓存';
  }

  static String _formatBytes(int bytes) {
    final gb = bytes / (1 << 30);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    return '${(bytes / (1 << 20)).round()} MB';
  }

  Future<String?> _downloadNow(Track track) async {
    final cid = track.cid;
    _publish(cid, const DownloadState(status: DownloadStatus.running));

    try {
      // 还是要先换直链 —— 列表里的 Track 没有地址。
      // 两个源取地址的方式不同：塞壬走 /api/song，B站走 playurl；
      // B站的地址还额外要求带请求头，所以把它一起往下传。
      final String sourceUrl;
      final String extension;
      final Map<String, String>? headers;
      if (track.isBili) {
        sourceUrl = await BiliApi.audioUrl(track.cid);
        // dash 音轨是 fragmented mp4，容器里只有音频轨。
        // 用 .m4a 命名最贴切，MediaStore 那边也认 audio/mp4。
        extension = '.m4a';
        headers = BiliApi.streamHeaders(track.cid);
      } else {
        final detail = await SirenApi.songDetail(cid);
        sourceUrl = detail.sourceUrl;
        extension = _extensionOf(detail.sourceUrl);
        headers = null;
      }
      final fileName = '${_stemFor(track)}$extension';
      // B站 DASH 音轨是 fragmented MP4，落盘前必须重封装成标准 M4A，
      // 否则系统媒体库读不到时长，华为手表同步/解码都会失败。
      final needsRemux = track.isBili;

      // 元数据组装失败就给 null，下载照常进行。
      // B站走 ilst（remux 时写 ©nam/©ART），只需要标题和艺人，不下封面；
      // 塞壬走 ID3/WAV，专辑/封面由 _tagFor 补全。
      AudioTag? tag;
      if (track.isBili) {
        tag = AudioTag(
          title: track.name,
          artist: track.artists.isEmpty ? 'B站' : track.artists.join(' / '),
        );
      } else if (extension == '.mp3' || extension == '.wav') {
        try {
          tag = await _tagFor(track);
        } catch (e) {
          debugPrint('[download] 元数据组装失败：$e');
        }
      }

      String location;
      if (kIsWeb) {
        // Web：fetch 流式读 + File System Access 流式写。
        // B站的 ilst 在 remux 那一并写入字节，不需要单独嵌标签。
        location = await _saveToWeb(
          sourceUrl: sourceUrl,
          fileName: fileName,
          cid: cid,
          needsRemux: needsRemux,
          headers: headers,
          tag: tag,
        );
      } else {
        location = MusicStore.isSupported
            ? await _saveToAndroidMusic(
                sourceUrl: sourceUrl,
                fileName: fileName,
                mimeType: _mimeOf(extension),
                cid: cid,
                tag: tag,
                headers: headers,
                needsRemux: needsRemux,
              )
            : await _saveToFolder(
                sourceUrl: sourceUrl,
                fileName: fileName,
                cid: cid,
                tag: tag,
                headers: headers,
                needsRemux: needsRemux,
              );
      }

      _downloadedStems.add(_stemFor(track));
      _publish(
        cid,
        DownloadState(
          status: DownloadStatus.done,
          progress: 1,
          path: location,
        ),
      );
      return location;
    } on PlatformException catch (e) {
      // 原生抛回来的：权限被拒、MediaStore 插入失败等
      debugPrint('[download] ${track.name} 原生保存失败：${e.code} ${e.message}');
      _failOrCancel(cid, e.message ?? '归档至音乐库失败');
      return null;
    } catch (e, stack) {
      debugPrint('[download] ${track.name} 失败：$e');
      debugPrint('$stack');
      _failOrCancel(cid, '$e');
      return null;
    }
  }

  /// 下载失败收尾。要是这场失败其实是用户取消的，就回到待下载态而不是报错。
  void _failOrCancel(String cid, String error) {
    if (_cancelRequested.remove(cid)) {
      _publish(cid, const DownloadState());
      return;
    }
    _publish(cid, DownloadState(status: DownloadStatus.failed, error: error));
  }

  /// 在系统文件管理器里打开下载目录。安卓用 DocumentsUI 打开
  /// Music/PodencoMusic；打不开返回 false。
  Future<bool> openFolder() async {
    if (kIsWeb) return false;
    if (MusicStore.isSupported) return MusicStore.openFolder();
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return false;
    }
    final dir = await targetDirectory();
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir.path]);
      } else {
        await Process.run('xdg-open', [dir.path]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Directory> targetDirectory() async {
    final cached = _cachedDir;
    if (cached != null) return cached;

    Directory? base;
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      base = await getDownloadsDirectory();
    }
    base ??= await getApplicationDocumentsDirectory();

    final dir = Directory('${base.path}${Platform.pathSeparator}PodencoMusic');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cachedDir = dir;
    return dir;
  }

  // ── 三个落盘实现 ─────────────────────────────────────────

  /// Web：fetch 流式读 + File System Access 流式写。目录权限已在
  /// download() / queueAll() 的用户手势里确认过，这里只管写。
  /// 取消走 AbortController（见 cancel），失败删半截文件（见实现）。
  Future<String> _saveToWeb({
    required String sourceUrl,
    required String fileName,
    required String cid,
    required bool needsRemux,
    Map<String, String>? headers,
    AudioTag? tag,
  }) async {
    if (!needsRemux) {
      final handle = webFs.createDownloadHandle();
      _webHandles[cid] = handle;
      try {
        return await webFs.writeFileFromUrl(
          url: sourceUrl,
          fileName: fileName,
          handle: handle,
          onProgress: (progress) => _publishProgress(cid, progress),
        );
      } finally {
        _webHandles.remove(cid);
      }
    }

    // B站音轨：浏览器里没法流式 remux，先把字节读进来，转成标准 M4A 再写。
    // 挂在 _activeClients 上，取消时 close() 会掐断请求。
    final client = http.Client();
    _activeClients[cid] = client;
    try {
      final request = http.Request('GET', Uri.parse(sourceUrl));
      if (headers != null) request.headers.addAll(headers);
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw SirenException('归档失败：HTTP ${response.statusCode}');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        buffer.add(chunk);
        received += chunk.length;
        _publishProgress(cid, total > 0 ? received / total : 0);
      }
      final bytes = buffer.takeBytes();
      final normalized = _normalizeBiliBytes(bytes, tag: tag);
      return await webFs.writeBytes(fileName: fileName, bytes: normalized);
    } finally {
      _activeClients.remove(cid);
      client.close();
    }
  }

  /// Android：先下到缓存目录，再交给原生存进 MediaStore。
  ///
  /// 为什么不边下边写进 MediaStore：MediaStore 的输出流中途断了不好清理，
  /// 而先落临时文件再一次性拷贝，失败时只要删掉临时文件就够了。
  /// 代价是多一次磁盘拷贝，几十 MB 的 wav 也就是一瞬间。
  Future<String> _saveToAndroidMusic({
    required String sourceUrl,
    required String fileName,
    required String mimeType,
    required String cid,
    AudioTag? tag,
    Map<String, String>? headers,
    required bool needsRemux,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final temp = File('${tempDir.path}${Platform.pathSeparator}$fileName');

    try {
      await _streamTo(sourceUrl, temp, cid, headers: headers);
      if (needsRemux) await _normalizeBiliFile(temp, tag: tag);
      // MediaStore 拷贝前把标签写进临时文件，入库的才是带元数据的版本。
      // B站 M4A 的 ilst 已在 remux 时写入，_embedTags 对它不做任何事。
      //
      // 标签只写进文件，不写 MediaStore 的 TITLE / ARTIST：那两列会在
      // 媒体扫描时被文件标签回填覆盖，插入时写的值留不住。设备最终
      // 看到什么，取决于文件里有什么标签。
      //
      // MP3 的 ID3v2 能被系统解析；WAV 的 LIST/INFO 与 id3 块不能，
      // 所以 WAV 在音乐库里只有文件名兜底成曲名、歌手为空。
      await _embedTags(temp, tag, fileName);

      final location = await MusicStore.save(
        sourcePath: temp.path,
        fileName: fileName,
        mimeType: mimeType,
      );
      if (location == null) {
        throw const SirenException('归档至音乐库失败');
      }
      return location;
    } finally {
      // 成败都清掉，不然缓存目录会越攒越大
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  /// 桌面：直接写目标目录。先写 .part 再改名，
  /// 中途断网不会留下一个看着正常其实残缺的文件。
  Future<String> _saveToFolder({
    required String sourceUrl,
    required String fileName,
    required String cid,
    AudioTag? tag,
    Map<String, String>? headers,
    required bool needsRemux,
  }) async {
    final dir = await targetDirectory();
    final target = File('${dir.path}${Platform.pathSeparator}$fileName');

    // 已经存在而且不是个空壳，直接当成成功
    if (await target.exists() && await target.length() > 64 * 1024) {
      return target.path;
    }

    final part = File('${target.path}.part');
    try {
      await _streamTo(sourceUrl, part, cid, headers: headers);
      if (await part.length() < 64 * 1024) {
        throw const SirenException('归档失败：文件不完整');
      }
      if (needsRemux) await _normalizeBiliFile(part, tag: tag);
      await part.rename(target.path);
      // 改完名再写元数据：标签嵌入失败时，删掉的应该是原音频而不是标签
      await _embedTags(target, tag, fileName);
      return target.path;
    } catch (e) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// 组装一首歌的元数据。专辑名 / 封面走内存专辑库 + StaticCache，
  /// 曲目号在专辑详情还在会话缓存里时能算出来，拿不到就留空。
  Future<AudioTag?> _tagFor(Track track) async {
    final album = library.albumNameOf(track.albumCid);
    final coverUrl = library.coverOfTrack(track);

    Uint8List? cover;
    var mime = 'image/jpeg';
    if (coverUrl.isNotEmpty) {
      try {
        final cached = await StaticCache.fileFor('cover:$coverUrl');
        if (cached != null) {
          cover = await cached.readAsBytes();
        } else {
          final res = await http
              .get(Uri.parse(coverUrl))
              .timeout(const Duration(seconds: 15));
          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            cover = res.bodyBytes;
            unawaited(StaticCache.saveBytes('cover:$coverUrl', cover));
          }
        }
        if (cover != null && cover.length >= 4) {
          // PNG 魔数 0x89 0x50，其余按 JPEG 处理
          mime = (cover[0] == 0x89 && cover[1] == 0x50)
              ? 'image/png'
              : 'image/jpeg';
        }
      } catch (_) {
        // 封面拿不到就不写 APIC，其他标签照填
      }
    }

    String? trackNo;
    for (final detail in SirenApi.sessionAlbumDetails) {
      if (detail.cid != track.albumCid) continue;
      final index = detail.songs.indexWhere((t) => t.cid == track.cid);
      if (index >= 0) trackNo = '${index + 1}/${detail.songs.length}';
      break;
    }

    return AudioTag(
      title: track.name,
      artist: track.artists.isEmpty ? '塞壬唱片-MSR' : track.artists.join(' / '),
      album: album.isEmpty ? null : album,
      trackNumberText: trackNo,
      coverBytes: cover,
      coverMime: mime,
    );
  }

  /// 按扩展名把标签写进音频文件。任何失败都只丢标签、不丢文件。
  Future<void> _embedTags(File file, AudioTag? tag, String fileName) async {
    if (tag == null) return;
    try {
      if (fileName.endsWith('.mp3')) {
        await writeMp3Tags(file, tag);
      } else if (fileName.endsWith('.wav')) {
        await writeWavTags(file, tag);
      }
    } catch (e) {
      debugPrint('[download] 元数据写入失败（文件本身不受影响）：$e');
    }
  }

  /// 流式下载到指定文件，边下边报进度。
  /// 绝不把整首歌读进内存 —— wav 一首能有几十 MB。
  /// 客户端挂在 _activeClients 上，取消时从外面掐断。
  Future<void> _streamTo(
    String url,
    File target,
    String cid, {
    Map<String, String>? headers,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    // B站音轨的 CDN 要 Referer，不带就是 403
    if (headers != null) request.headers.addAll(headers);
    final client = http.Client();
    _activeClients[cid] = client;

    final sink = target.openWrite();
    try {
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw SirenException('归档失败：HTTP ${response.statusCode}');
      }

      final total = response.contentLength ?? 0;
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        _publishProgress(cid, total > 0 ? received / total : 0);
      }
      await sink.flush();
    } finally {
      await sink.close();
      _activeClients.remove(cid);
    }
  }

  /// B站 DASH 音轨重封装。失败只丢「标准容器」这个收益，不丢音频本身：
  /// 原样返回让下载照常完成，旧设备至少还能在 App 内播。
  Uint8List _normalizeBiliBytes(Uint8List bytes, {AudioTag? tag}) {
    try {
      return remuxFragmentedMp4(
        bytes,
        title: tag?.title,
        artist: tag?.artist,
      );
    } catch (e, stack) {
      debugPrint('[download] fMP4 remux 失败，保留原始音频：$e');
      debugPrint('$stack');
      return bytes;
    }
  }

  Future<void> _normalizeBiliFile(File file, {AudioTag? tag}) async {
    try {
      final bytes = await file.readAsBytes();
      final normalized = _normalizeBiliBytes(bytes, tag: tag);
      if (!identical(normalized, bytes)) {
        await file.writeAsBytes(normalized);
      }
    } catch (e, stack) {
      debugPrint('[download] 文件 remux 失败，保留原始音频：$e');
      debugPrint('$stack');
    }
  }

  // ── 内部 ────────────────────────────────────────────────

  /// 文件名主干的纯函数，方便单测锁定「只保留曲名」这个约定。
  static String fileStemFor(Track track) => _sanitizeStem(track.name);

  /// 文件名主干：只保留曲名 / 视频标题，不加艺人或 UP 主前缀。
  /// 只依赖 Track，不依赖音频地址，所以扫目录时能直接比对。
  String _stemFor(Track track) => fileStemFor(track);

  /// 文件名清洗：去掉 Windows 不允许的字符，过长截断。
  static String _sanitizeStem(String raw) {
    final safe = raw
        // Windows 下这九个字符不能出现在文件名里
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        // 控制字符也清掉
        .replaceAll(RegExp(r'[\x00-\x1F]'), '')
        .trim();
    // 太长的名字截断，避免超过文件系统限制
    return safe.length > 120 ? safe.substring(0, 120) : safe;
  }

  /// 从文件名反推主干，`.part` 这种中间产物直接返回 null
  String? _stemOfFileName(String name) {
    if (name.endsWith('.part')) return null;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 音频扩展名。塞壬混用 mp3 和 wav，从直链上取，取不到就按 mp3。
  String _extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '.mp3';
    final ext = path.substring(dot).toLowerCase();
    const allowed = {'.mp3', '.wav', '.flac', '.m4a', '.ogg'};
    return allowed.contains(ext) ? ext : '.mp3';
  }

  /// MediaStore 要 MIME type 才认得出这是音频，写错的话
  /// 系统音乐 App 里不会出现这首歌。
  String _mimeOf(String extension) {
    switch (extension) {
      case '.mp3':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/x-wav';
      case '.flac':
        return 'audio/flac';
      case '.m4a':
        return 'audio/mp4';
      case '.ogg':
        return 'audio/ogg';
      default:
        return 'audio/mpeg';
    }
  }

  void _publish(String cid, DownloadState state) {
    _states[cid] = state;
    _lastNotified[cid] = state.progress;
    notifyListeners();
  }

  /// 进度变化小于 2% 就不通知，否则几百次重建没意义
  void _publishProgress(String cid, double progress) {
    final last = _lastNotified[cid] ?? -1;
    if (progress - last < 0.02 && progress < 1) return;
    _states[cid] = DownloadState(
      status: DownloadStatus.running,
      progress: progress,
    );
    _lastNotified[cid] = progress;
    notifyListeners();
  }
}

/// 全局单例
final downloader = Downloader();
