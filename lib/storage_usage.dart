import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import 'downloader.dart';
import 'static_cache.dart';

/// 设置页「存储」分区的数据来源。
///
/// 把目录扫描、清理这些 dart:io 的活全关在这里，页面只负责展示 ——
/// 以后想加「清理下载」之类的功能也不用再往页面里塞文件系统代码。
class StorageUsage {
  const StorageUsage({
    required this.cacheBytes,
    required this.cacheCount,
    required this.downloadBytes,
    required this.downloadCount,
    required this.downloadPath,
  });

  /// 封面 + 歌词缓存（可重建）
  final int cacheBytes;
  final int cacheCount;

  /// 已下载的音乐。安卓是经 MediaStore 存进系统音乐库的，
  /// path_provider 拿到的不是那个目录，所以固定 -1 表示「统计不到」。
  final int downloadBytes;
  final int downloadCount;

  /// 下载目录的真实路径（安卓为空）
  final String downloadPath;

  bool get downloadKnown => downloadBytes >= 0;

  static Future<StorageUsage> read() async {
    final cache = await StaticCache.stats();

    var dlBytes = -1;
    var dlCount = 0;
    var dlPath = '';
    // 只有桌面能直接数目录：
    //   Web  → 下载走 File System Access，写进用户选的目录，应用读不到；
    //   安卓 → 成品进了系统媒体库（Music/PodencoMusic），path_provider
    //          拿到的不是那个目录。
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      try {
        final dir = await downloader.targetDirectory();
        dlPath = dir.path;
        final stats = await _scan(dir);
        dlBytes = stats.$1;
        dlCount = stats.$2;
      } catch (_) {
        // 拿不到就按「不可统计」显示，不影响其他两行
      }
    }

    return StorageUsage(
      cacheBytes: cache.$1,
      cacheCount: cache.$2,
      downloadBytes: dlBytes,
      downloadCount: dlCount,
      downloadPath: dlPath,
    );
  }

  /// 清空封面/歌词缓存，返回删掉的文件数
  static Future<int> clearCache() => StaticCache.clear();

  static Future<(int, int)> _scan(Directory dir) async {
    if (!await dir.exists()) return (0, 0);
    var bytes = 0;
    var count = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          bytes += await entity.length();
          count++;
        } catch (_) {
          // 正在写的文件取不到大小，跳过
        }
      }
    } catch (_) {
      // 目录被删/权限不足，能统计多少算多少
    }
    return (bytes, count);
  }

  /// 人类可读的大小。超过 100 就不显示小数了，免得一行太长。
  static String format(int bytes) {
    if (bytes < 0) return '未知';
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }
}
