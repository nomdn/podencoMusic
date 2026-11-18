import 'dart:convert';

import 'models.dart';
import 'playlist_file.dart';

/// 导出格式。
enum PlaylistFormat {
  /// 完整备份：cid / albumCid / 艺人都在，将来能再导入回来
  json,

  /// 通用播放列表：每首带一条塞壬页面链接，别的播放器/编辑器都认
  m3u,
}

/// 导出结果。落盘成功给 [path]，Web 上退化成剪贴板时 [copiedToClipboard]。
class ExportResult {
  const ExportResult({
    required this.trackCount,
    this.path,
    this.copiedToClipboard = false,
  });

  final int trackCount;
  final String? path;
  final bool copiedToClipboard;
}

/// 塞壬官网的单曲页面，M3U 里当 URI 用 —— 播放器点开至少能落到正确页面。
const _songPageBase = 'https://monster-siren.hypergryph.com/music';

/// 把歌单导出去。内容和落盘分开：[buildExportContent] 是纯函数，
/// 方便单测；真正写文件交给按平台条件导入的 [writeExportFile]。
Future<ExportResult> exportPlaylist(
  Playlist playlist,
  PlaylistFormat format,
) async {
  final content = buildExportContent(playlist, format);
  final name = '${sanitizeFileName(playlist.name)}${extensionFor(format)}';

  final path = await writeExportFile(fileName: name, content: content);

  return ExportResult(
    trackCount: playlist.tracks.length,
    path: path.path,
    copiedToClipboard: path.copied,
  );
}

/// 生成文件内容。纯函数，不碰 IO。
String buildExportContent(Playlist playlist, PlaylistFormat format) {
  switch (format) {
    case PlaylistFormat.json:
      return const JsonEncoder.withIndent('  ').convert({
        'app': 'Podenco Music',
        // 版本号留着，以后改结构了能据此判断要不要迁移
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'playlist': playlist.toJson(),
      });
    case PlaylistFormat.m3u:
      final buffer = StringBuffer()
        ..writeln('#EXTM3U')
        ..writeln('#PLAYLIST:${playlist.name}');
      for (final track in playlist.tracks) {
        final artist = track.artists.isEmpty ? '' : track.artists.join(' / ');
        final label = artist.isEmpty ? track.name : '$artist - ${track.name}';
        buffer
          ..writeln('#EXTINF:-1,$label')
          // 没有直链可写：音频地址带签名会过期，写进去第二天就是死链。
          // 换成官网单曲页，播放器点开还能落到正确的地方。
          ..writeln('$_songPageBase/${track.cid}');
      }
      return buffer.toString();
  }
}

/// 扩展名跟着格式走，别让人拿到一个 .txt 里包着 JSON。
String extensionFor(PlaylistFormat format) =>
    format == PlaylistFormat.json ? '.json' : '.m3u8';

/// 歌单名直接当文件名会出事：Windows 不允许 `\/:*?"<>|`，
/// 安卓的 MediaStore 也不喜欢控制字符。
String sanitizeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // 全是非法字符时给个兜底名，别生成 ".json" 这种隐藏文件
  if (cleaned.isEmpty || cleaned.replaceAll('_', '').isEmpty) {
    return '未命名歌单';
  }
  // Windows 上以点结尾的文件名也存不下
  return cleaned.replaceAll(RegExp(r'[. ]+$'), '');
}
