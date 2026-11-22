import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'storage.dart';

/// 全局唯一的歌单库。跟 [PlayerModel] / [Library] 一样是顶层单例，
/// 界面用 ListenableBuilder 订阅，增删歌单、加歌之后界面自己重建。
///
/// 所有操作都是「先改内存、notify、再异步写盘」—— 写盘失败只丢下次
/// 启动的记忆，不影响当前界面。歌单操作低频（不像进度条 200ms 一次），
/// 所以不做防抖，直接写。
class PlaylistModel extends ChangeNotifier {
  List<Playlist> _playlists = const [];
  bool _loaded = false;

  // ── 对外只读状态 ─────────────────────────────────────────

  /// 全部歌单，新建的排最前 —— 刚建完就能看到。
  List<Playlist> get playlists => List.unmodifiable(_playlists);

  /// 冷启动的 load() 跑完没有。界面在它完成前不该当作「没有歌单」。
  bool get loaded => _loaded;

  /// 按 id 查。详情页从导航栈进来时拿的是歌单对象的旧引用，
  /// 后续增删曲目会换新对象，页面要用这个方法取最新状态。
  Playlist? byId(String id) {
    for (final playlist in _playlists) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  /// 这首歌在不在某个歌单里（按 cid 判断）。加歌弹层的勾选态用。
  bool containsTrack(String playlistId, String trackCid) {
    final playlist = byId(playlistId);
    return playlist?.tracks.any((t) => t.cid == trackCid) ?? false;
  }

  // ── 操作 ─────────────────────────────────────────────────

  /// 启动时读一次。坏存档在 PlaylistStorage 里已经兜住了。
  Future<void> load() async {
    _playlists = await PlaylistStorage.load();
    _loaded = true;
    notifyListeners();
  }

  /// 建歌单，返回新建的对象，调用方可以直接 push 详情页。
  Playlist create(String name) {
    final clean = name.trim();
    final playlist = Playlist(
      // 加当前数量兜底：同一微秒连建两个不会撞 id，否则后一个会把前一个
      // 的操作全接走（byId 按字符串查，命中排在最前的那个）
      id: '${DateTime.now().microsecondsSinceEpoch}-${_playlists.length}',
      name: clean.isEmpty ? '未命名歌单' : clean,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      tracks: const [],
    );
    _playlists = [playlist, ..._playlists];
    notifyListeners();
    _persist();
    return playlist;
  }

  /// 从备份导入。永远是新建，不覆盖本地歌单 —— 导入的内容和现有的
  /// 哪个「更该留」没有客观答案，让用户自己删多余的那个更安全。
  ///
  /// 名字撞了自动加序号（「我的歌单 (2)」），因为界面上靠名字认歌单。
  Playlist importPlaylist(
    String name,
    List<Track> tracks, {
    String coverUrl = '',
  }) {
    final base = name.trim().isEmpty ? '导入的歌单' : name.trim();
    final playlist = Playlist(
      // 加下标兜底：一批导入里两次调用可能落在同一微秒
      id: '${DateTime.now().microsecondsSinceEpoch}-${_playlists.length}',
      name: _uniqueName(base),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      tracks: tracks,
      // 备份里可能带自定义封面；老备份没这字段就是空串，走默认封面
      coverUrl: coverUrl,
    );
    _playlists = [playlist, ..._playlists];
    notifyListeners();
    _persist();
    return playlist;
  }

  /// 把多个歌单合成一份新的。源歌单保留不动 —— 合并是不可逆的整理动作，
  /// 先留住原件，用户确认结果没问题再自己删。
  ///
  /// 曲目按传入的歌单顺序拼接，按 cid 去重（同一个 cid 在不同歌单里
  /// 可能是不同时间加进去的，留第一次出现的那份）。少于两个有效歌单
  /// 就不用合并，返回 null 让调用方别弹成功提示。
  Playlist? merge(List<String> ids, String name) {
    final sources = ids
        .map(byId)
        .whereType<Playlist>()
        .toList();
    if (sources.length < 2) return null;

    final seen = <String>{};
    final tracks = <Track>[];
    for (final source in sources) {
      for (final track in source.tracks) {
        if (seen.add(track.cid)) tracks.add(track);
      }
    }

    final base = name.trim().isEmpty ? '合并歌单' : name.trim();
    final playlist = Playlist(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_playlists.length}',
      name: _uniqueName(base),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      tracks: tracks,
    );
    _playlists = [playlist, ..._playlists];
    notifyListeners();
    _persist();
    return playlist;
  }

  /// 换封面。传空串 = 恢复默认的「第一首歌专辑封面」。
  void setCover(String id, String url) {
    final playlist = byId(id);
    final clean = url.trim();
    // 内容没变就别写盘了，封面对话框里点确定不会白动一次存档
    if (playlist == null || playlist.coverUrl == clean) return;
    _replace(id, (p) => p.copyWith(coverUrl: clean));
  }

  /// 首个空位名字。上限只是防止极端情况下死循环。
  String _uniqueName(String base) {
    final taken = _playlists.map((playlist) => playlist.name).toSet();
    if (!taken.contains(base)) return base;
    for (var i = 2; i < 1000; i++) {
      final candidate = '$base ($i)';
      if (!taken.contains(candidate)) return candidate;
    }
    return base;
  }

  void rename(String id, String name) {
    final clean = name.trim();
    if (clean.isEmpty) return;
    _replace(
      id,
      (playlist) => playlist.copyWith(name: clean),
    );
  }

  void remove(String id) {
    final next = _playlists.where((playlist) => playlist.id != id).toList();
    if (next.length == _playlists.length) return;
    _playlists = next;
    notifyListeners();
    _persist();
  }

  /// 加歌。已经在里面就不动（弹层靠 [containsTrack] 决定加还是移除）。
  void addTrack(String id, Track track) {
    _replace(id, (playlist) {
      if (playlist.tracks.any((t) => t.cid == track.cid)) return playlist;
      return playlist.copyWith(tracks: [...playlist.tracks, track]);
    });
  }

  /// 批量加歌（整张专辑进歌单用）。已在歌单里的跳过，
  /// 全程只 notify / 落盘一次，不按曲目数刷屏。
  void addTracks(String id, List<Track> tracks) {
    _replace(id, (playlist) {
      final existing = playlist.tracks.map((t) => t.cid).toSet();
      final fresh = tracks
          .where((t) => !existing.contains(t.cid))
          .toList();
      if (fresh.isEmpty) return playlist;
      return playlist.copyWith(tracks: [...playlist.tracks, ...fresh]);
    });
  }

  /// 按 cid 批量移歌（整张专辑从歌单移除用）。没有的 cid 忽略。
  void removeTracks(String id, List<String> trackCids) {
    final gone = trackCids.toSet();
    _replace(id, (playlist) {
      final tracks = playlist.tracks
          .where((t) => !gone.contains(t.cid))
          .toList();
      if (tracks.length == playlist.tracks.length) return playlist;
      return playlist.copyWith(tracks: tracks);
    });
  }

  /// 移一首歌（歌单详情页每行的移除按钮用）。
  void removeTrack(String id, String trackCid) {
    removeTracks(id, [trackCid]);
  }

  // ── 内部 ─────────────────────────────────────────────────

  /// 换掉某个歌单再通知。找不到 id 时静默返回（歌单可能在别的
  /// 窗口被删了，操作落空就好，别抛异常打断界面）。
  void _replace(String id, Playlist Function(Playlist) transform) {
    final index = _playlists.indexWhere((playlist) => playlist.id == id);
    if (index < 0) return;

    final updated = transform(_playlists[index]);
    // transform 可能判断无需变化而原样返回，这时不用打扰界面
    if (identical(updated, _playlists[index])) return;

    final next = [..._playlists];
    next[index] = updated;
    _playlists = next;
    notifyListeners();
    _persist();
  }

  void _persist() {
    unawaited(PlaylistStorage.save(_playlists));
  }
}

/// 全局单例。
final playlistsModel = PlaylistModel();
