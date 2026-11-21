// 临时探针：BV18t421n7cq 的 mode 分布 + 目标弹幕的原始字段。
// 文件名不带 _test 后缀，flutter test 不会自动收它；需要时手动跑：
//   flutter test test/dm_probe_check.dart
// 它发真实网络请求且无超时，放在自动套件里会在网络差时把整个 job 挂住。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/bili_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  test('mode 分布 + 目标弹幕字段', () async {
    final items = await BiliApi.fetchDanmaku('BV18t421n7cq');
    final byMode = <int, int>{};
    for (final d in items) {
      byMode[d.mode] = (byMode[d.mode] ?? 0) + 1;
    }
    // ignore: avoid_print
    print('mode 分布: $byMode  总数 ${items.length}');

    final hits = items.where((d) => d.text.contains('想看翻译')).toList();
    for (final d in hits) {
      // ignore: avoid_print
      print('t=${d.timeMs}ms mode=${d.mode} fs=${d.fontSize} '
          'color=${d.color} text="${d.text}"');
    }
    if (hits.isEmpty) {
      // ignore: avoid_print
      print('未找到「想看翻译」，列出前 8 条 mode 5 的弹幕：');
      for (final d in items.where((d) => d.mode == 5).take(8)) {
        // ignore: avoid_print
        print('t=${d.timeMs}ms fs=${d.fontSize} text="${d.text}"');
      }
    }
  });
}
