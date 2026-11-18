// 端到端验证：B站曲目能不能走完整条下载链路（换地址 → 带 Referer 取流 →
// 落盘成 .m4a）。
//
// 只测纯逻辑没意义 —— 这条链路的每一步都可能是安静的失败（403 却返回 200
// 的壳、文件名规则不匹配、.part 改名失败）。真窗口里跑一遍、量文件大小，
// 才能确定下下来的确实是音频。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:podenco_music/downloader.dart';
import 'package:podenco_music/models.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('B站曲目下载成 m4a', (tester) async {
    const track = Track(
      cid: 'BV1ZVsn6nEMn',
      name: '冒烟下载用例',
      albumCid: '',
      artists: ['测试UP'],
      source: TrackSource.bilibili,
    );

    final path = await downloader.download(track);
    expect(path, isNotNull, reason: '下载没返回路径');

    final file = File(path!);
    final size = await file.length();
    // ignore: avoid_print
    print('下载结果：$path（$size 字节）');

    expect(await file.exists(), isTrue);
    expect(size, greaterThan(500 * 1024), reason: '文件太小，多半只下到了错误页');
    expect(path.endsWith('.m4a'), isTrue, reason: '扩展名应该是 .m4a');

    // 测试产物不留在用户的下载目录里
    await file.delete();
  });
}
