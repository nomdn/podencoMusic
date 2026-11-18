import 'dart:convert';

import 'models.dart';
import 'siren_api.dart';

/// 从备份文件里读回来的一个歌单。
///
/// 还没有 id —— id 由 [PlaylistModel.importPlaylist] 生成，
/// 导入永远是「新建一个」，不会覆盖本地已有歌单。
class ImportedPlaylist {
  const ImportedPlaylist({required this.name, required this.tracks, this.note});

  final String name;
  final List<Track> tracks;

  /// 解析时值得告诉用户的一句话（跳过了几首、名字是兜底之类）。
  /// 正常情况下是 null。
  final String? note;
}

/// 导入失败。message 写成中文整句，界面直接显示，不再二次加工。
class PlaylistImportException implements Exception {
  const PlaylistImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

// ── JSON ───────────────────────────────────────────────────

/// 解析 `buildExportContent` 产出的 JSON。
///
/// 认这几种形状，宽松一点，别人手工整理的也能进：
///   {app, version, exportedAt, playlist: {...}}   本应用导出的
///   {playlists: [ {...}, {...} ]}                 一文件多歌单
///   {name, tracks: [...]}                          裸歌单
///   [ {...}, {...} ]                               裸数组
List<ImportedPlaylist> parsePlaylistJson(String raw) {
  final dynamic root;
  try {
    root = jsonDecode(raw);
  } on FormatException {
    throw const PlaylistImportException('不是合法的 JSON，文件可能损坏或选错了');
  }

  final maps = _gatherPlaylistMaps(root);
  if (maps.isEmpty) {
    throw const PlaylistImportException('这个 JSON 里找不到歌单（没有 tracks 字段）');
  }

  final result = <ImportedPlaylist>[];
  for (final map in maps) {
    final playlist = _toImported(map);
    // 一首有效的都没有的歌单不进结果：导出一个空壳回来没有意义，
    // 全部为空时下面会当成「文件里没有歌单」报错。
    if (playlist != null && playlist.tracks.isNotEmpty) result.add(playlist);
  }

  if (result.isEmpty) {
    throw const PlaylistImportException('歌单是空的，或者里面的曲子都没有 cid');
  }
  return result;
}

/// 从各种包装层里把「长得像歌单的 Map」挑出来。
List<Map<String, dynamic>> _gatherPlaylistMaps(dynamic root) {
  if (root is List) {
    return root.whereType<Map<String, dynamic>>().toList();
  }
  if (root is! Map<String, dynamic>) return const [];

  // 本应用的导出格式：真正的歌单在 playlist 里，外面的 app/version 只是元信息
  final inner = root['playlist'];
  if (inner is Map<String, dynamic>) return [inner];

  final many = root['playlists'];
  if (many is List) {
    return many.whereType<Map<String, dynamic>>().toList();
  }

  // 已经是裸歌单了
  if (root['tracks'] is List) return [root];
  return const [];
}

ImportedPlaylist? _toImported(Map<String, dynamic> map) {
  final rawTracks = map['tracks'];
  if (rawTracks is! List) return null;

  // 同一个 cid 只留一次：手改过的备份里常出现重复行
  final seen = <String>{};
  final tracks = <Track>[];
  for (final item in rawTracks) {
    if (item is! Map<String, dynamic>) continue;
    final cid = item['cid']?.toString().trim() ?? '';
    if (cid.isEmpty || !seen.add(cid)) continue;
    tracks.add(Track.fromJson(item));
  }

  final name = (map['name'] as String?)?.trim() ?? '';
  return ImportedPlaylist(
    name: name.isEmpty ? '导入的歌单' : name,
    tracks: tracks,
    note: rawTracks.length > tracks.length
        ? '跳过 ${rawTracks.length - tracks.length} 条无效或重复的曲目'
        : null,
  );
}

// ── M3U ────────────────────────────────────────────────────

/// M3U 里能还原的只有 cid，歌名和专辑得回头问接口。
///
/// 所以这里分两步：先 [parseM3u] 拿到 cid 列表（纯函数，可测），
/// 再由 [restoreM3uPlaylist] 逐首补全成 [Track]。
({String? name, List<String> cids}) parseM3u(String raw) {
  String? name;
  final cids = <String>[];
  final seen = <String>{};

  for (final line in const LineSplitter().convert(raw)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    if (trimmed.startsWith('#PLAYLIST:')) {
      final value = trimmed.substring('#PLAYLIST:'.length).trim();
      if (value.isNotEmpty) name = value;
      continue;
    }
    // 其余 # 开头的是 #EXTM3U / #EXTINF 之类，不是曲目
    if (trimmed.startsWith('#')) continue;

    final cid = _cidFromLine(trimmed);
    if (cid != null && seen.add(cid)) cids.add(cid);
  }

  return (name: name, cids: cids);
}

/// 一行里抠出 cid。优先认塞壬单曲页链接，其次认「整行就是一个 cid」。
String? _cidFromLine(String line) {
  final fromUrl = RegExp(r'/music/([A-Za-z0-9_-]+)').firstMatch(line);
  if (fromUrl != null) return fromUrl.group(1);

  // 手工整理的 m3u 常常直接写 cid
  if (RegExp(r'^[A-Za-z0-9]{4,}$').hasMatch(line)) return line;
  return null;
}

/// 把 M3U 里的 cid 逐首换成完整曲目。
///
/// 串行请求：一次几十首并发打过去，接口不一定会拒，但慢网下更容易
/// 一半超时。串行 20 首也就几秒，换来的是确定的结果。
///
/// 查不到的单曲不会让整次导入失败 —— 记下数量，其余照常进歌单。
Future<ImportedPlaylist> restoreM3uPlaylist(
  String raw, {
  required String fallbackName,
  void Function(int done, int total)? onProgress,
}) async {
  final parsed = parseM3u(raw);
  if (parsed.cids.isEmpty) {
    throw const PlaylistImportException('M3U 里没找到塞壬的曲目链接');
  }

  final tracks = <Track>[];
  var failed = 0;
  for (var i = 0; i < parsed.cids.length; i++) {
    try {
      tracks.add(Track.fromSongDetail(await SirenApi.songDetail(parsed.cids[i])));
    } catch (_) {
      failed++;
    }
    onProgress?.call(i + 1, parsed.cids.length);
  }

  if (tracks.isEmpty) {
    throw const PlaylistImportException('这首单里的曲子全都查不到了，可能已经下架');
  }

  return ImportedPlaylist(
    name: parsed.name ?? fallbackName,
    tracks: tracks,
    note: failed > 0 ? '$failed 首在塞壬查不到，已跳过' : null,
  );
}

/// 按文件名猜格式。选文件对话框在 Android 上可能不给扩展名，
/// 内容特征更可靠：以 `{` 或 `[` 开头就按 JSON 试。
bool looksLikeJson(String content) {
  final head = content.trimLeft();
  return head.startsWith('{') || head.startsWith('[');
}
