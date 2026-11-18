// 真机验证「存储」分区的数据来源能不能读到真实目录。
//
// `flutter test` 里 path_provider 没有平台通道，各目录都拿不到，
// 数字全是 0 —— 那种「通过」没有意义。所以在真窗口里跑一遍，
// 把实际字节数打出来核对。
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:podenco_music/storage_usage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('存储统计读到的是真实占用', (tester) async {
    final usage = await StorageUsage.read();

    // ignore: avoid_print
    print(
      '封面+歌词：${StorageUsage.format(usage.cacheBytes)} '
      '(${usage.cacheBytes} B / ${usage.cacheCount} 个)\n'
      '已下载：${StorageUsage.format(usage.downloadBytes)} '
      '(${usage.downloadCount} 个) @ ${usage.downloadPath}',
    );

    expect(usage.cacheCount, greaterThan(0), reason: '封面缓存一个都没扫到');
    expect(usage.cacheBytes, greaterThan(0));
    expect(usage.downloadKnown, isTrue, reason: '桌面上应该能统计下载目录');
    expect(usage.downloadPath, contains('PodencoMusic'));
  });
}
