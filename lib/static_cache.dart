import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:path_provider/path_provider.dart';

/// 静态资源的磁盘缓存：封面图片、歌词这类「内容永不变化」的东西。
///
/// key 是资源 URL，映射成缓存目录下的文件名。写入失败静默 ——
/// 缓存缺失的后果只是下一次慢一点，不是错误。存的是原始字节，
/// 读的时候调用方自己解析（图片直接 Image.file/memory，歌词按 utf8 文本）。
class StaticCache {
  static Directory? _dir;

  /// Web 上 dart:io 是抛 UnsupportedError 的桩 —— 所有缓存操作
  /// 直接返回空值，封面走浏览器 HTTP 缓存、歌词走内存缓存。
  static bool get _unavailable => kIsWeb;


  /// 缓存目录：应用支持目录下的 static_cache/。懒加载一次。
  static Future<Directory> _cacheDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}static_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  /// key（URL）→ 安全文件名。URL 里能当文件名的字符原样保留，
  /// 其余替换成下划线；超长截尾并拼上整个 key 的长度做区分。
  static String fileNameFor(String key) {
    final sanitized = key.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final capped = sanitized.length > 96
        ? sanitized.substring(sanitized.length - 96)
        : sanitized;
    return '$capped.${key.length}';
  }

  /// 命中返回缓存文件，未命中返回 null。
  static Future<File?> fileFor(String key) async {
    if (_unavailable) return null;
    try {
      final dir = await _cacheDir();
      final file = File('${dir.path}${Platform.pathSeparator}${fileNameFor(key)}');
      return file.existsSync() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// 写入并返回落盘的文件（调用方可以直接拿去构造 FileImage，
  /// 免得把原始字节一直攥在内存里）。
  static Future<File> saveBytes(String key, List<int> bytes) async {
    assert(!_unavailable, 'saveBytes 不应在 Web 上调用');
    if (_unavailable) return File('/dev/null');
    final dir = await _cacheDir();
    final file = File(
      '${dir.path}${Platform.pathSeparator}${fileNameFor(key)}',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<void> saveText(String key, String text) async {
    if (_unavailable) return;
    try {
      await saveBytes(key, text.codeUnits);
    } catch (_) {
      // 缓存写失败不影响本次使用
    }
  }

  /// 命中返回文本内容，未命中返回 null。
  static Future<String?> textFor(String key) async {
    if (_unavailable) return null;
    final file = await fileFor(key);
    if (file == null) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 当前占用：(字节数, 文件数)。Web 上是 (0, 0)。
  static Future<(int, int)> stats() async {
    if (_unavailable) return (0, 0);
    try {
      final dir = await _cacheDir();
      var bytes = 0;
      var count = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        try {
          bytes += entity.lengthSync();
          count++;
        } catch (_) {
          // 正在被读写的文件可能取不到大小，跳过
        }
      }
      return (bytes, count);
    } catch (_) {
      return (0, 0);
    }
  }

  /// 清空缓存。只删文件，目录留着。
  ///
  /// 删完之后封面会从网络重下，歌词同理 —— 都是「慢一点」而不是「坏掉」，
  /// 所以这里不做任何补偿逻辑。
  static Future<int> clear() async {
    if (_unavailable) return 0;
    try {
      final dir = await _cacheDir();
      var removed = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        try {
          await entity.delete();
          removed++;
        } catch (_) {
          // 单个删不掉不影响整体
        }
      }
      return removed;
    } catch (_) {
      return 0;
    }
  }
}
