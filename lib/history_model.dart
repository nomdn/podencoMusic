import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'storage.dart';

/// 播放历史：最近播过什么，最新的排最前。
///
/// 不做日期分组、不做收藏级功能 —— 它回答的只有一个问题：
/// 「那首歌叫什么来着，我前几天听过」。上限 100 首，够翻很远，
/// 也保证 JSON 不会随着使用无限膨胀。
class HistoryModel extends ChangeNotifier {
  /// 持久化上限。超了就从尾巴上扔。
  static const maxEntries = 100;

  List<Track> _tracks = const [];
  bool _loaded = false;

  List<Track> get tracks => List.unmodifiable(_tracks);
  bool get loaded => _loaded;

  Future<void> load() async {
    _tracks = await HistoryStorage.load();
    _loaded = true;
    notifyListeners();
  }

  /// 记一次播放。听过的挪到最前而不是重复插入 ——
  /// 历史是「最近听过什么」的顺序，不是播放次数统计。
  void record(Track track) {
    final rest = _tracks.where((t) => t.cid != track.cid).toList();
    final next = [track, ...rest];
    _tracks = next.length > maxEntries ? next.sublist(0, maxEntries) : next;
    notifyListeners();
    unawaited(HistoryStorage.save(_tracks));
  }

  /// 清空。UI 侧调用前自己弹确认。
  void clear() {
    if (_tracks.isEmpty) return;
    _tracks = const [];
    notifyListeners();
    unawaited(HistoryStorage.save(_tracks));
  }
}

/// 全局单例。
final historyModel = HistoryModel();
