import 'package:flutter/painting.dart';

import '../cover_provider_data.dart';

/// Web 端封面 Provider：本地 base64 → MemoryImage，普通链接 → NetworkImage
/// （浏览器自己的 HTTP 缓存接管重复加载，磁盘缓存层在 Web 上不适用）。
/// 仅在 Web 上被导入（见 cover_provider.dart 门面）。
Future<ImageProvider?> coverProvider(String url) async {
  if (url.startsWith('data:image/')) return dataUriProvider(url);
  return NetworkImage(url);
}
