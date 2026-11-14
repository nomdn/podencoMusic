import 'package:flutter/painting.dart';

/// Web 端封面 Provider：直接 NetworkImage —— 浏览器自己的 HTTP 缓存
/// 会接管重复加载（hycdn 响应带缓存头），磁盘缓存层在 Web 上不适用。
/// 仅在 Web 上被导入（见 cover_provider.dart 门面）。
Future<ImageProvider?> coverProvider(String url) async => NetworkImage(url);
