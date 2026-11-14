import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// 需要跨启动保留的东西：队列、播到第几首、模式、音量。
///
/// 故意不存播放进度 —— 音频直链带签名会过期，恢复时得重新换源，
/// 存一个 seek 位置也用不上，还容易让人以为「一开 app 就自动放」。
class PlayerSnapshot {
  const PlayerSnapshot({
    required this.queue,
    required this.index,
    required this.mode,
    required this.volume,
  });

  final List<Track> queue;
  final int index;
  final PlayMode mode;
  final double volume;
}

/// 把快照写进系统级的 key-value 存储。
///
/// Windows 落在注册表（shared_preferences_windows 的实现），
/// 安卓走 SharedPreferences。都只有几 KB，不用上数据库。
class PlayerStorage {
  static const _key = 'player_state_v1';

  /// 队列上限。正常用不到，防一手「有人把 900 首全塞进队列」时
  /// 每次写盘都序列化一大坨 JSON。
  static const _maxQueue = 300;

  static Future<PlayerSnapshot?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;

      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;

      final queue = (json['queue'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Track.fromJson)
          .toList();

      final modeIndex = (json['mode'] as num?)?.toInt() ?? 0;
      final volume = (json['volume'] as num?)?.toDouble() ?? 1.0;

      return PlayerSnapshot(
        queue: queue,
        index: (json['index'] as num?)?.toInt() ?? -1,
        mode: modeIndex >= 0 && modeIndex < PlayMode.values.length
            ? PlayMode.values[modeIndex]
            : PlayMode.listLoop,
        volume: volume.clamp(0.0, 1.0),
      );
    } catch (_) {
      // 存档格式对不上就当没存过。绝不能因为一个坏文件让 app 起不来。
      return null;
    }
  }

  static Future<void> save(PlayerSnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({
          'queue': snapshot.queue
              .take(_maxQueue)
              .map((track) => track.toJson())
              .toList(),
          'index': snapshot.index,
          'mode': snapshot.mode.index,
          'volume': snapshot.volume,
        }),
      );
    } catch (_) {
      // 写失败只影响下次启动的记忆，不影响当前播放
    }
  }
}

/// 用户歌单的本地读写。模式跟 [PlayerStorage] 一样：
/// 一个 key 存整份 JSON，坏存档当没存过。
class PlaylistStorage {
  static const _key = 'playlists_v1';

  static Future<List<Playlist>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const [];

      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return const [];

      return (json['playlists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Playlist.fromJson)
          .toList();
    } catch (_) {
      // 存档格式对不上就当没存过。绝不能因为一个坏文件让 app 起不来。
      return const [];
    }
  }

  static Future<void> save(List<Playlist> playlists) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({
          'playlists': playlists.map((playlist) => playlist.toJson()).toList(),
        }),
      );
    } catch (_) {
      // 写失败只影响下次启动的记忆，不影响当前操作
    }
  }
}

/// 播放历史的本地读写。和歌单同理：只存 Track 的坐标信息。
class HistoryStorage {
  static const _key = 'history_v1';

  static Future<List<Track>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const [];

      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return const [];

      return (json['tracks'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Track.fromJson)
          .toList();
    } catch (_) {
      // 存档格式对不上就当没存过。绝不能因为一个坏文件让 app 起不来。
      return const [];
    }
  }

  static Future<void> save(List<Track> tracks) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({'tracks': tracks.map((t) => t.toJson()).toList()}),
      );
    } catch (_) {
      // 写失败只影响下次启动的记忆，不影响当前操作
    }
  }
}

/// 首页专辑排序偏好。就一个开关，不值得为它建 ChangeNotifier。
class UiStorage {
  static const _sortKey = 'albums_sort_by_name';

  static Future<bool> loadSortByName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_sortKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveSortByName(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_sortKey, value);
    } catch (_) {
      // 写失败只影响下次启动的记忆
    }
  }
}

