import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import '../cover_provider_data.dart';
import '../static_cache.dart';

/// 桌面端封面 Provider：本地 base64 → MemoryImage；
/// 普通链接走磁盘缓存命中 → FileImage，未命中 → 网络下载 → 落盘。
/// 仅在 dart:io 可用的平台被导入（见 cover_provider.dart 门面）。
Future<ImageProvider?> coverProvider(String url) async {
  // 用户自己选的图压缩后以 data URI 存在 coverUrl 里，不走缓存和网络
  if (url.startsWith('data:image/')) return dataUriProvider(url);

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
