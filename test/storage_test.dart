// 持久化往返测试。shared_preferences 提供了内存版实现，不用真机也能测。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/models.dart';
import 'package:podenco_music/static_cache.dart';
import 'package:podenco_music/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 每个用例都从空存储开始
    SharedPreferences.setMockInitialValues({});
  });

  group('PlayerStorage', () {
    test('存进去的队列、下标、模式、音量能原样读回来', () async {
      const snapshot = PlayerSnapshot(
        queue: [
          Track(cid: '1', name: 'Your Star', albumCid: '0256', artists: ['塞壬唱片-MSR']),
          Track(cid: '2', name: 'Radian', albumCid: '0256', artists: []),
        ],
        index: 1,
        mode: PlayMode.shuffle,
        volume: 0.42,
      );

      await PlayerStorage.save(snapshot);
      final loaded = await PlayerStorage.load();

      expect(loaded, isNotNull);
      expect(loaded!.queue.length, 2);
      expect(loaded.queue.first.cid, '1');
      expect(loaded.queue.first.name, 'Your Star');
      expect(loaded.index, 1);
      expect(loaded.mode, PlayMode.shuffle);
      expect(loaded.volume, closeTo(0.42, 0.0001));
    });

    test('没存过时返回 null，不是抛异常', () async {
      final loaded = await PlayerStorage.load();
      expect(loaded, isNull);
    });

    test('存档是一段乱码也不会崩', () async {
      SharedPreferences.setMockInitialValues({'player_state_v1': '这不是 json'});
      final loaded = await PlayerStorage.load();
      expect(loaded, isNull);
    });
  });

  // StaticCache 文件名：key（URL）→ 安全文件名，不同 key 不相撞。
  group('StaticCache.fileNameFor', () {
    test('非法字符被替换成下划线', () {
      final name = StaticCache.fileNameFor('https://web.hycdn.cn/lyric/a b.lrc');
      expect(name.contains('/'), isFalse);
      expect(name.contains(':'), isFalse);
      expect(name.contains(' '), isFalse);
    });

    test('不同长度的 key 不会截尾后相撞', () {
      final a = StaticCache.fileNameFor('https://x.com/${'a' * 200}.lrc');
      final b = StaticCache.fileNameFor('https://x.com/${'a' * 300}.lrc');
      expect(a, isNot(b));
    });

    test('同一个 key 的文件名稳定', () {
      final key = 'lyric:https://web.hycdn.cn/siren/lyric/123/abc.lrc';
      expect(StaticCache.fileNameFor(key), StaticCache.fileNameFor(key));
    });
  });
}