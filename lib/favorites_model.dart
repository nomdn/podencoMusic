import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bili_models.dart';
import 'models.dart';

/// 收藏的四种东西。塞壬的专辑/单曲和 B站的视频/UP 主混在一个列表里，
/// 靠这个字段区分点击后该跳哪儿、该不该播放。
enum FavoriteKind {
  sirenAlbum('塞壬专辑'),
  sirenSong('塞壬单曲'),
  biliVideo('B站视频'),
  biliUp('B站UP主');

  const FavoriteKind(this.label);

  final String label;
}

/// 一条收藏。
///
/// 刻意**存全展示字段**（名字、封面、副标题）而不是只存一个 id：
/// 收藏页要能离线打开、快速滚动，不能每行都回去请求接口；
/// 何况塞壬的条目只靠 id 是还原不出封面和名字的。
class FavoriteItem {
  const FavoriteItem({
    required this.kind,
    required this.id,
    required this.name,
    this.subtitle = '',
    this.coverUrl = '',
    this.albumCid = '',
    this.artists = const [],
    this.addedAt = 0,
  });

  final FavoriteKind kind;

  /// 专辑 cid / 单曲 cid / BV 号 / UP 主的 mid（存成字符串，统一处理）
  final String id;
  final String name;

  /// 副标题：艺人、UP 名、粉丝数之类，纯展示
  final String subtitle;
  final String coverUrl;

  /// 塞壬单曲才有的所属专辑，用来在播放时回填封面
  final String albumCid;
  final List<String> artists;

  /// 收藏时间，倒序排列
  final int addedAt;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'id': id,
    'name': name,
    'subtitle': subtitle,
    'coverUrl': coverUrl,
    'albumCid': albumCid,
    'artists': artists,
    'addedAt': addedAt,
  };

  factory FavoriteItem.fromJson(Map<String, dynamic> json) => FavoriteItem(
    kind: FavoriteKind.values.firstWhere(
      (k) => k.name == json['kind'],
      // 存档里出现不认识的类型（降级安装）时别整份丢掉，当单曲处理
      orElse: () => FavoriteKind.sirenSong,
    ),
    id: json['id']?.toString() ?? '',
    name: json['name'] as String? ?? '',
    subtitle: json['subtitle'] as String? ?? '',
    coverUrl: json['coverUrl'] as String? ?? '',
    albumCid: json['albumCid'] as String? ?? '',
    artists: (json['artists'] as List? ?? const [])
        .map((e) => e.toString())
        .toList(),
    addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
  );

  /// 塞壬单曲 / B站视频可以还原成播放器认识的 Track。
  Track toTrack() => Track(
    cid: id,
    name: name,
    albumCid: albumCid,
    artists: artists,
    source: kind == FavoriteKind.biliVideo
        ? TrackSource.bilibili
        : TrackSource.siren,
    coverUrl: coverUrl,
  );
}

/// 全局收藏库。和歌单一样：先改内存、notify、再异步落盘。
class FavoriteModel extends ChangeNotifier {
  static const _key = 'favorites_v1';

  List<FavoriteItem> _items = const [];
  bool _loaded = false;

  List<FavoriteItem> get items => List.unmodifiable(_items);
  bool get loaded => _loaded;

  List<FavoriteItem> of(FavoriteKind kind) =>
      _items.where((item) => item.kind == kind).toList();

  int countOf(FavoriteKind kind) =>
      _items.where((item) => item.kind == kind).length;

  bool contains(FavoriteKind kind, String id) =>
      _items.any((item) => item.kind == kind && item.id == id);

  /// 某首歌/某个视频是不是被收藏了 —— 播放页和列表的收藏按钮用它取状态
  bool containsTrack(Track track) => contains(
    track.isBili ? FavoriteKind.biliVideo : FavoriteKind.sirenSong,
    track.cid,
  );

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _items = list
            .whereType<Map<String, dynamic>>()
            .map(FavoriteItem.fromJson)
            .where((item) => item.id.isNotEmpty)
            .toList();
      } catch (_) {
        // 存档坏了当空收藏，别为它崩启动
        _items = const [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 收藏 / 取消收藏，返回操作后的状态（true = 现在已收藏）。
  bool toggle(FavoriteItem item) {
    final exists = contains(item.kind, item.id);
    if (exists) {
      _items = _items
          .where((old) => !(old.kind == item.kind && old.id == item.id))
          .toList();
    } else {
      _items = [
        FavoriteItem(
          kind: item.kind,
          id: item.id,
          name: item.name,
          subtitle: item.subtitle,
          coverUrl: item.coverUrl,
          albumCid: item.albumCid,
          artists: item.artists,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        ..._items,
      ];
    }
    notifyListeners();
    _persist();
    return !exists;
  }

  void remove(FavoriteKind kind, String id) {
    final next = _items
        .where((item) => !(item.kind == kind && item.id == id))
        .toList();
    if (next.length == _items.length) return;
    _items = next;
    notifyListeners();
    _persist();
  }

  void _persist() {
    unawaited(_save());
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_items.map((item) => item.toJson()).toList()),
    );
  }
}

/// 全局单例。
final favoritesModel = FavoriteModel();

// ── 从各种数据对象造收藏条目 ──────────────────────────────
//
// 界面上的收藏按钮只需要「一个 FavoriteItem」，至于它是从专辑、
// 曲目还是 B站视频来的，在各自的入口处转好再传进去。

FavoriteItem favoriteOfAlbum(Album album) => FavoriteItem(
  kind: FavoriteKind.sirenAlbum,
  id: album.cid,
  name: album.name,
  subtitle: album.artistes.join(' / '),
  coverUrl: album.coverUrl,
  artists: album.artistes,
);

FavoriteItem favoriteOfTrack(
  Track track, {
  String coverUrl = '',
  String albumName = '',
}) => FavoriteItem(
  kind: track.isBili ? FavoriteKind.biliVideo : FavoriteKind.sirenSong,
  id: track.cid,
  name: track.name,
  subtitle: track.artists.join(' / '),
  // 塞壬曲目自己没有封面，由界面把反查到的封面传进来
  coverUrl: track.coverUrl.isNotEmpty ? track.coverUrl : coverUrl,
  albumCid: track.albumCid,
  artists: track.artists,
);

FavoriteItem favoriteOfVideo(BiliVideo video) => FavoriteItem(
  kind: FavoriteKind.biliVideo,
  id: video.bvid,
  name: video.title,
  subtitle: video.author,
  coverUrl: video.cover,
  artists: video.author.isEmpty ? const [] : [video.author],
);

FavoriteItem favoriteOfUp(BiliUp up) => FavoriteItem(
  kind: FavoriteKind.biliUp,
  id: '${up.mid}',
  name: up.name,
  subtitle: up.subtitle,
  coverUrl: up.face,
);
