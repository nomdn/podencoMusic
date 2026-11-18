import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'bili_api.dart';
import 'web_download.dart';

/// B站视频下载服务。
///
/// 和音频下载（[Downloader]）刻意分开：视频的目标格式是「能看的 mp4」，
/// 而音频下载要写 ID3 标签、进系统音乐库，两条管线的落盘和元数据完全不同。
///
/// 画质策略：
///   · 桌面端：检测到 ffmpeg 就下 dash 音视频双轨，合成 1080P/4K；
///     检测不到就退回 720P 单段合并流（fnval=1）。
///   · 移动端 / Web：只用 720P 单段 —— dash 双轨在移动端没法合并，
///     Web 的 WASM ffmpeg 又大又慢，都不值得。
/// 一次视频下载的状态。
enum BiliVideoDownloadStatus { idle, running, done, failed }

class BiliVideoDownloadState {
  const BiliVideoDownloadState({
    this.status = BiliVideoDownloadStatus.idle,
    this.progress = 0,
    this.path,
    this.error,
    this.qualityLabel = '',
  });

  final BiliVideoDownloadStatus status;

  /// 0~1
  final double progress;
  final String? path;
  final String? error;

  /// 实际画质文案（"720P" / "1080P" / "4K"），完成后给用户看
  final String qualityLabel;
}

class BiliVideoDownloader extends ChangeNotifier {
  final Map<String, BiliVideoDownloadState> _states = {};
  final Map<String, http.Client> _clients = {};
  final Set<String> _cancelled = {};

  BiliVideoDownloadState stateOf(String bvid) =>
      _states[bvid] ?? const BiliVideoDownloadState();

  /// 系统里有没有 ffmpeg。只探测一次并缓存。
  /// 桌面端才可能为 true（移动端/Web 一律 false）。
  String? _ffmpegPath;
  Future<String?> ffmpegPath() async {
    final cached = _ffmpegPath;
    if (cached != null) return cached.isEmpty ? null : cached;
    String? found;
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      final candidates = Platform.isWindows
          ? ['ffmpeg', r'C:\ffmpeg\bin\ffmpeg.exe', r'C:\Program Files\ffmpeg\bin\ffmpeg.exe']
          : ['ffmpeg', '/usr/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/opt/homebrew/bin/ffmpeg'];
      for (final c in candidates) {
        try {
          final r = await Process.run(
            c,
            ['-version'],
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          if (r.exitCode == 0) {
            found = c;
            break;
          }
        } catch (_) {
          // 这个候选不存在，试下一个
        }
      }
    }
    _ffmpegPath = found ?? '';
    return found;
  }

  void cancel(String bvid) {
    _cancelled.add(bvid);
    _clients[bvid]?.close();
  }

  /// 下载一个视频。返回最终文件路径，失败返回 null。
  Future<String?> download(
    String bvid, {
    String title = '',
    String author = '',
  }) async {
    if (_states[bvid]?.status == BiliVideoDownloadStatus.running) return null;
    _cancelled.remove(bvid);
    _publish(bvid, const BiliVideoDownloadState(status: BiliVideoDownloadStatus.running));

    try {
      final ffmpeg = await ffmpegPath();
      final highQuality = ffmpeg != null;

      String url;
      String label;
      String? audioUrl; // 非 null 表示走 dash 双轨，需要合并
      if (highQuality) {
        final dash = await BiliApi.dashStreams(bvid, preferQn: 120);
        url = dash.videoUrls.first;
        audioUrl = dash.audioUrls.first;
        label = _qualityLabel(dash.quality);
      } else {
        // 720P 合并流：Web 上 videoStream 已包好反代（浏览器设不了 Referer）
        url = (await BiliApi.videoStream(bvid)).url;
        label = '720P';
      }

      // 文件名主干（清理非法字符）
      final stem = _safeName(author.isEmpty ? title : '$author - $title');
      final fileName = '${stem.isEmpty ? bvid : stem}_$label.mp4';

      String location;
      if (kIsWeb) {
        // Web：只能下单段，走 File System Access
        if (!webFsSupported) {
          throw const BiliException('当前浏览器不支持文件下载（需 Chrome / Edge）');
        }
        if (!await webFs.ensureDirectoryAccess()) {
          throw const BiliException('未选择 / 未授权下载目录');
        }
        location = await webFs.writeFileFromUrl(
          url: url,
          fileName: fileName,
          handle: webFs.createDownloadHandle(),
          onProgress: (p) => _publishProgress(bvid, p),
        );
      } else {
        final dir = await _targetDir();
        final target = File('${dir.path}${Platform.pathSeparator}$fileName');
        if (await target.exists() && await target.length() > 64 * 1024) {
          _publish(bvid, BiliVideoDownloadState(
            status: BiliVideoDownloadStatus.done,
            progress: 1,
            path: target.path,
            qualityLabel: label,
          ));
          return target.path;
        }

        final highAudio = audioUrl;
        if (highAudio != null && ffmpeg != null) {
          // 下视频轨和音轨两份临时文件，再用 ffmpeg -c copy 合并（不重编码，快）
          final tempDir = await Directory.systemTemp.createTemp('podenco_vid_');
          try {
            final videoFile = File('${tempDir.path}${Platform.pathSeparator}video.m4s');
            final audioFile = File('${tempDir.path}${Platform.pathSeparator}audio.m4s');
            await _streamToFile(url, videoFile, bvid, 0.5);
            if (_isCancelled(bvid)) return null;
            await _streamToFile(highAudio, audioFile, bvid, 0.5, offset: 0.5);
            if (_isCancelled(bvid)) return null;
            await _mergeWithFfmpeg(
              ffmpeg,
              videoFile.path,
              audioFile.path,
              target.path,
            );
          } finally {
            try {
              await tempDir.delete(recursive: true);
            } catch (_) {}
          }
        } else {
          // 720P 单段：直接流式写
          await _streamToFile(url, target, bvid, 1);
        }
        location = target.path;
      }

      _publish(bvid, BiliVideoDownloadState(
        status: BiliVideoDownloadStatus.done,
        progress: 1,
        path: location,
        qualityLabel: label,
      ));
      return location;
    } on BiliException catch (e) {
      _fail(bvid, e.message);
      return null;
    } catch (e) {
      debugPrint('[bili-video-download] $bvid 失败：$e');
      _fail(bvid, '$e');
      return null;
    } finally {
      _clients.remove(bvid);
    }
  }

  bool _isCancelled(String bvid) {
    if (_cancelled.remove(bvid)) {
      _publish(bvid, const BiliVideoDownloadState());
      return true;
    }
    return false;
  }

  void _fail(String bvid, String error) {
    if (_isCancelled(bvid)) return;
    _publish(bvid, BiliVideoDownloadState(
      status: BiliVideoDownloadStatus.failed,
      error: error,
    ));
  }

  Future<Directory> _targetDir() async {
    Directory? base;
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      base = await getDownloadsDirectory();
    }
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}PodencoMusic');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 流式写文件。 [weight] 是本段占总进度的权重，[offset] 是起始进度。
  Future<void> _streamToFile(
    String url,
    File target,
    String bvid,
    double weight, {
    double offset = 0,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll(BiliApi.streamHeaders(bvid));
    final client = http.Client();
    _clients[bvid] = client;
    final sink = target.openWrite();
    try {
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw BiliException('视频流 HTTP ${response.statusCode}');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _publishProgress(bvid, offset + (received / total) * weight);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
      _clients.remove(bvid);
    }
  }

  /// 用系统 ffmpeg 把视频轨+音轨合成一个 mp4（-c copy 不重编码）。
  Future<void> _mergeWithFfmpeg(
    String ffmpeg,
    String videoPath,
    String audioPath,
    String outputPath,
  ) async {
    final result = await Process.run(ffmpeg, [
      '-y',
      '-i', videoPath,
      '-i', audioPath,
      '-c', 'copy',
      '-movflags', '+faststart',
      outputPath,
    ], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode != 0) {
      throw BiliException('ffmpeg 合并失败：${result.stderr}');
    }
  }

  static String _qualityLabel(int q) {
    if (q >= 120) return '4K';
    if (q >= 112) return '1080P';
    if (q >= 64) return '720P';
    if (q >= 32) return '480P';
    return '360P';
  }

  static String _safeName(String raw) {
    final safe = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'[\x00-\x1F]'), '')
        .trim();
    return safe.length > 100 ? safe.substring(0, 100) : safe;
  }

  void _publish(String bvid, BiliVideoDownloadState state) {
    _states[bvid] = state;
    notifyListeners();
  }

  void _publishProgress(String bvid, double progress) {
    final prev = _states[bvid]?.progress ?? 0;
    if (progress - prev < 0.02 && progress < 1) return;
    _states[bvid] = BiliVideoDownloadState(
      status: BiliVideoDownloadStatus.running,
      progress: progress,
    );
    notifyListeners();
  }

}

/// 全局单例
final biliVideoDownloader = BiliVideoDownloader();
