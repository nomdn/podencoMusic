import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import '../static_cache.dart';

/// 桌面端封面 Provider：磁盘缓存命中 → FileImage；
/// 未命中 → 网络下载 → 落盘 → 用落盘文件构造（字节不攥在内存里）。
/// 仅在 dart:io 可用的平台被导入（见 cover_provider.dart 门面）。
Future<ImageProvider?> coverProvider(String url) async {
  final cached = await StaticCache.fileFor('cover:$url');
  if (cached != null) return FileImage(cached);

  try {
    final res = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      return null;
    }
    final file = await StaticCache.saveBytes('cover:$url', res.bodyBytes);
    return FileImage(file);
  } catch (_) {
    return null;
  }
}
