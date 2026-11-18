// 弹幕数据重复度检查（真实网络）。
// 手动跑：flutter test test/bili_dm_dup_check.dart
//
// 背景：用户看到普通弹幕「同一句话重复成墙」。之前的实证是手动 curl 的
// 单个分段文件（无重复），但 app 的 fetchDanmaku 是多段循环合并——
// B站 seg.so 对超界 segment_index 的行为存疑（可能返回已拉过的内容）。
// 本测试直接调用 app 同一条代码路径，统计真实合并结果的重复度。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/bili_api.dart';
import 'package:podenco_music/bili_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  test('fetchDanmaku 合并结果重复度', () async {
    const bvid = 'BV1FrFhejEcB';
    final items = await BiliApi.fetchDanmaku(bvid);
    // ignore: avoid_print
    print('fetchDanmaku($bvid) → ${items.length} 条');

    expect(items, isNotEmpty);

    // 按 (timeMs, mode, text) 统计——同毫秒同模式同文本视为「同一发弹幕」
    final counts = <String, int>{};
    for (final d in items) {
      final key = '${d.timeMs}|${d.mode}|${d.text}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final dupEntries = counts.entries.where((e) => e.value > 1).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // ignore: avoid_print
    print('唯一 (timeMs|mode|text) 组合：${counts.length}');
    // ignore: avoid_print
    print('重复组合数：${dupEntries.length}');
    for (final e in dupEntries.take(15)) {
      // ignore: avoid_print
      print('  ×${e.value}  ${e.key}');
    }

    // 用户截图里重复成墙的那条
    const probe = '前奏像林俊杰的杀手';
    final probeHits = items.where((d) => d.text == probe).toList();
    // ignore: avoid_print
    print('「$probe」出现 ${probeHits.length} 次：'
        '${probeHits.map((d) => d.timeMs).take(20).toList()}');

    // 按 timeMs 分桶：同一毫秒上有几条弹幕（B站官方同毫秒也可能多条，
    // 但应该文本不同）
    final byMs = <int, List<BiliDanmaku>>{};
    for (final d in items) {
      byMs.putIfAbsent(d.timeMs, () => []).add(d);
    }
    final worstMs = byMs.entries
        .where((e) => e.value.length > 1)
        .toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    // ignore: avoid_print
    print('同毫秒多条的时间点：${worstMs.length} 个');
    for (final e in worstMs.take(10)) {
      // ignore: avoid_print
      print('  ${e.key}ms → ${e.value.map((d) => d.text).take(6).toList()}');
    }
  });
}
