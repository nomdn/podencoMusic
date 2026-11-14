// 播放历史的持久化 + 模型操作测试。和 playlist_test 同一套路。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/history_model.dart';
import 'package:podenco_music/models.dart';
import 'package:podenco_music/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const a = Track(cid: '1', name: 'Your Star', albumCid: '0256', artists: []);
  const b = Track(cid: '2', name: 'Radian', albumCid: '0256', artists: []);
  const c = Track(cid: '3', name: 'Mirari', albumCid: '8913', artists: []);

  group('HistoryStorage', () {
    test('存进去的历史能原样读回来', () async {
      await HistoryStorage.save([a, b]);

      final loaded = await HistoryStorage.load();

      expect(loaded.length, 2);
      expect(loaded.first.cid, '1');
      expect(loaded.last.cid, '2');
    });

    test('没存过时返回空列表，不是抛异常', () async {
      expect(await HistoryStorage.load(), isEmpty);
    });

    test('存档是一段乱码也不会崩', () async {
      SharedPreferences.setMockInitialValues({'history_v1': '这不是 json'});
      expect(await HistoryStorage.load(), isEmpty);
    });
  });

  group('HistoryModel', () {
    test('record 最新在前，重复听同一首只是挪位置不是重复插入', () {
      final model = HistoryModel();
      model.record(a);
      model.record(b);
      model.record(a); // 又听了一遍第一首

      expect(model.tracks.map((t) => t.cid), ['1', '2']);
    });

    test('超过上限时从尾巴上扔', () {
      final model = HistoryModel();
      for (var i = 0; i < HistoryModel.maxEntries + 10; i++) {
        model.record(Track(cid: '$i', name: 't$i', albumCid: '0', artists: []));
      }

      expect(model.tracks.length, HistoryModel.maxEntries);
      // 最新的（编号最大的）在最前面，最旧的 10 首被扔掉
      expect(model.tracks.first.cid, '${HistoryModel.maxEntries + 9}');
      expect(model.tracks.last.cid, '10');
    });

    test('clear 清空并持久化', () async {
      final model = HistoryModel();
      model.record(a);
      model.record(b);

      model.clear();
      expect(model.tracks, isEmpty);

      // 重新加载确认清空落了盘
      final fresh = HistoryModel();
      await fresh.load();
      expect(fresh.tracks, isEmpty);
    });

    test('重启后能恢复顺序', () async {
      final model = HistoryModel();
      model.record(a);
      model.record(b);
      model.record(c);

      final fresh = HistoryModel();
      await fresh.load();
      expect(fresh.tracks.map((t) => t.cid), ['3', '2', '1']);
    });
  });
}
