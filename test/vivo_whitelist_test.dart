import 'package:flutter_test/flutter_test.dart';

import 'package:podenco_music/music_store.dart';

/// vivo 原子随身听音源白名单的 JSON 纯逻辑。
/// settings 表里存的是形如 `["pkgA","pkgB"]` 的字符串（无空格）。
void main() {
  group('vivo 原子随身听白名单 JSON 逻辑', () {
    test('解析标准格式', () {
      final list = MusicStore.parseWhitelist(
        '["com.android.bbkmusic.local","com.foo.bar"]',
      );
      expect(list, ['com.android.bbkmusic.local', 'com.foo.bar']);
    });

    test('空列表能解析成空数组', () {
      expect(MusicStore.parseWhitelist('[]'), isEmpty);
    });

    test('null / 坏格式 / 非 JSON 返回 null', () {
      expect(MusicStore.parseWhitelist(null), isNull);
      expect(MusicStore.parseWhitelist(''), isNull);
      expect(MusicStore.parseWhitelist('不是JSON'), isNull);
      // settings 表偶尔存成对象 / 混入非字符串元素，别让它炸
      expect(MusicStore.parseWhitelist('{"a":1}'), isNull);
    });

    test('序列化无空格、保序', () {
      expect(
        MusicStore.serializeWhitelist(['a', 'b']),
        '["a","b"]',
      );
    });

    test('加入：追加在尾部，已存在则原样返回', () {
      final list = MusicStore.whitelistWith(['bbk'], 'pkg');
      expect(list, ['bbk', 'pkg']);
      final again = MusicStore.whitelistWith(list, 'pkg');
      expect(again, list);
      // 原列表不被修改
      expect(identical(list, again), isFalse);
    });

    test('移除：只删自己，别人不动', () {
      expect(
        MusicStore.whitelistWithout(['bbk', 'pkg', 'other'], 'pkg'),
        ['bbk', 'other'],
      );
      // 本就不在其中，返回等价列表
      expect(MusicStore.whitelistWithout(['bbk'], 'pkg'), ['bbk']);
    });

    test('全流程：读原值 → 加自己 → 移出还原到原值', () {
      const raw = '["com.android.bbkmusic.local"]';
      var list = MusicStore.parseWhitelist(raw)!;
      list = MusicStore.whitelistWith(list, MusicStore.appPackage);
      final written = MusicStore.serializeWhitelist(list);
      expect(written, '["com.android.bbkmusic.local","com.mint.podencomusic"]');

      final restored = MusicStore.serializeWhitelist(
        MusicStore.whitelistWithout(
          MusicStore.parseWhitelist(written)!,
          MusicStore.appPackage,
        ),
      );
      expect(restored, raw);
    });
  });
}
