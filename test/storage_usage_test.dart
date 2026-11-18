import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/storage_usage.dart';

void main() {
  group('StorageUsage.format', () {
    test('小于 1KB 用字节', () {
      expect(StorageUsage.format(0), '0 B');
      expect(StorageUsage.format(1023), '1023 B');
    });

    test('逐级换算', () {
      expect(StorageUsage.format(1024), '1.0 KB');
      expect(StorageUsage.format(74 * 1024 * 1024), '74.0 MB');
      expect(StorageUsage.format(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('超过 100 不带小数，免得一行太长', () {
      expect(StorageUsage.format(178 * 1024 * 1024), '178 MB');
    });

    test('负数表示统计不到', () {
      expect(StorageUsage.format(-1), '未知');
    });
  });
}
