import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'static_cache.dart';

/// 接口出错时抛这个，页面里 catch 住直接显示 message 即可。
class SirenException implements Exception {
  const SirenException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 塞壬唱片的公开接口封装。
///
/// 全部是 GET，不需要鉴权、不需要 cookie。用一组静态方法，
/// 没有实例状态 —— 只有一个单曲详情的内存缓存。
class SirenApi {
  static const _host = 'https://monster-siren.hypergryph.com/api';
  static final _client = http.Client();

  /// 单曲详情缓存：cid → 详情。
  /// 一首歌的音频直链在一次会话里不会变，重复点同一首不用再请求。
  static final Map<String, SongDetail> _songCache = {};

  /// 单个请求的超时。没有它，一次挂起的连接会让播放页永久转圈 ——
  /// 播放流程里每一步都在 await 接口，超时是「能报错」的前提。
  static const _requestTimeout = Duration(seconds: 15);

  static Future<dynamic> _getData(String path) async {
    final http.Response res;
    try {
      res = await _client
          .get(Uri.parse('$_host$path'))
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw SirenException('请求超时，请检查网络');
    }
    if (res.statusCode != 200) {
      throw SirenException('网络错误：HTTP ${res.statusCode}');
    }

    // 接口带的是 `application/json; charset=utf-8`，用 res.body 其实也能正确解码。
    // 但这里刻意走 bodyBytes + utf8.decode：不依赖服务端有没有声明 charset，
    // 哪天 CDN 把 charset 弄丢，res.body 会回退成 latin1，中文就全变乱码了。
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;

    if (body['code'] != 0) {
      throw SirenException(body['msg'] as String? ?? '接口返回异常');
    }
    return body['data'];
  }

  /// 全部专辑，约 300 张，一次拿完。
  static Future<List<Album>> albums() async {
    final data = await _getData('/albums') as List;
    return data
        .map((e) => Album.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 全站单曲，约 900+ 首。搜索页靠它做本地过滤。
  static Future<List<Track>> allSongs() async {
    final data = await _getData('/songs') as Map<String, dynamic>;
    final list = data['list'] as List;
    return list.map((e) => Track.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 专辑详情 + 曲目列表。会话级内存缓存：本次运行里打开过的专辑
  /// 不再重复请求。专辑列表是动态内容（塞壬可能更新），所以只做
  /// 内存去重，不落盘。
  static final Map<String, AlbumDetail> _albumDetailCache = {};

  /// 会话内已拉过详情的专辑（托盘「专辑」子菜单的数据源）。
  static List<AlbumDetail> get sessionAlbumDetails =>
      _albumDetailCache.values.toList();

  static Future<AlbumDetail> albumDetail(String cid) async {
    final cached = _albumDetailCache[cid];
    if (cached != null) return cached;

    final data = await _getData('/album/$cid/detail') as Map<String, dynamic>;
    final detail = AlbumDetail.fromJson(data);
    _albumDetailCache[cid] = detail;
    return detail;
  }

  /// 歌词内存缓存：同一次会话里重复播放同一首不再请求。
  static final Map<String, List<LyricLine>> _lyricCache = {};

  /// 拉 lrc 并解析。歌词是静态内容 —— 内存 + 磁盘双层缓存
  /// （StaticCache），第二次播放同一首歌零网络。
  static Future<List<LyricLine>> lyric(String url) async {
    final memory = _lyricCache[url];
    if (memory != null) return memory;

    final cachedText = await StaticCache.textFor('lyric:$url');
    if (cachedText != null) {
      final lines = parseLrc(cachedText);
      _lyricCache[url] = lines;
      return lines;
    }

    final http.Response res;
    try {
      res = await _client.get(Uri.parse(url)).timeout(_requestTimeout);
    } on TimeoutException {
      throw SirenException('歌词下载超时');
    }
    if (res.statusCode != 200) {
      throw SirenException('歌词下载失败：HTTP ${res.statusCode}');
    }
    final text = utf8.decode(res.bodyBytes);
    unawaited(StaticCache.saveText('lyric:$url', text));
    final lines = parseLrc(text);
    _lyricCache[url] = lines;
    return lines;
  }

  /// 单曲详情。带缓存，重复调用只请求一次。
  static Future<SongDetail> songDetail(String cid) async {
    final cached = _songCache[cid];
    if (cached != null) return cached;

    final data = await _getData('/song/$cid') as Map<String, dynamic>;
    final detail = SongDetail.fromJson(data);
    _songCache[cid] = detail;
    return detail;
  }

  /// LRC 解析。格式就一行一句：`[00:14.89]歌词正文`。
  ///
  /// 有的文件是 `[00:20.89]` 后面什么都没有（用来隔开段落），
  /// 这种直接丢掉 —— 界面上留空行反而难看。
  static List<LyricLine> parseLrc(String raw) {
    final pattern = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
    final lines = <LyricLine>[];

    for (final rawLine in raw.split('\n')) {
      final match = pattern.firstMatch(rawLine);
      if (match == null) continue;

      final text = rawLine.substring(match.end).trim();
      if (text.isEmpty) continue;

      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      // 毫秒可能是 ".89" 两位，也可能是 ".890" 三位，补齐成三位再解析
      final millis = int.parse((match.group(3) ?? '0').padRight(3, '0'));

      lines.add(
        LyricLine(
          Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
          text,
        ),
      );
    }

    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}
