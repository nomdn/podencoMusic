import 'package:flutter/foundation.dart';

import 'models.dart';
import 'siren_api.dart';

/// 全站数据的内存缓存。
///
/// 为什么需要它：接口给的 Track 只带 `albumCid`，不带封面和专辑名。
/// 迷你播放条、搜索页要显示封面，就得按 albumCid 反查专辑。
/// 与其每个页面各拉一遍 /api/albums，不如在这里存一份。
///
/// 做成 ChangeNotifier 是因为有个时序问题：app 冷启动时会先从本地恢复
/// 上次的播放队列，那时专辑列表还没拉回来，迷你条上的封面是空的。
/// 等专辑到了 notify 一下，界面自己补上。
class Library extends ChangeNotifier {
  final List<Album> _albums = [];
  final Map<String, Album> _albumByCid = {};
  List<Track> _songs = const [];

  Future<List<Album>>? _albumsRequest;
  Future<List<Track>>? _songsRequest;

  List<Album> get albums => List.unmodifiable(_albums);
  List<Track> get songs => _songs;

  String coverOf(String cid) => _albumByCid[cid]?.coverUrl ?? '';
  String albumNameOf(String cid) => _albumByCid[cid]?.name ?? '';

  /// 一首歌的封面。
  ///
  /// B站的曲目自带封面直链（`coverUrl`），塞壬的要按 albumCid 反查专辑。
  /// 界面统一走这个方法，就不用到处判断来源了。
  String coverOfTrack(Track track) =>
      track.coverUrl.isNotEmpty ? track.coverUrl : coverOf(track.albumCid);

  /// 拉全部专辑。并发调用只会发一次请求。
  Future<List<Album>> ensureAlbums() async {
    final pending = _albumsRequest;
    if (pending != null) return pending;

    final request = _fetchAlbums();
    _albumsRequest = request;

    try {
      return await request;
    } catch (_) {
      // 失败了要把缓存的 future 清掉，否则以后永远拿到同一个失败的 future
      _albumsRequest = null;
      rethrow;
    }
  }

  /// 拉全站单曲，搜索用。
  Future<List<Track>> ensureSongs() async {
    final pending = _songsRequest;
    if (pending != null) return pending;

    final request = _fetchSongs();
    _songsRequest = request;

    try {
      return await request;
    } catch (_) {
      _songsRequest = null;
      rethrow;
    }
  }

  Future<List<Album>> _fetchAlbums() async {
    final list = await SirenApi.albums();
    _albums
      ..clear()
      ..addAll(list);
    for (final album in list) {
      _albumByCid[album.cid] = album;
    }
    // 通知在等封面的界面（主要是从本地恢复出来的迷你播放条）
    notifyListeners();
    return list;
  }

  Future<List<Track>> _fetchSongs() async {
    _songs = await SirenApi.allSongs();
    return _songs;
  }
}

/// 全局单例。
final library = Library();
