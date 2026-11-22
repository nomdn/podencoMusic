import 'package:flutter/painting.dart';

import 'cover_codec.dart';

/// data URI 封面直接解码成 MemoryImage，不落磁盘也不发网络请求。
/// 两个平台实现共用这段，避免一边支持 base64 另一边不支持。
ImageProvider? dataUriProvider(String url) {
  if (!url.startsWith('data:image/')) return null;
  final bytes = decodeCoverDataUri(url);
  // 存档被改坏时当没封面，别把损坏串丢给 NetworkImage
  return bytes == null ? null : MemoryImage(bytes);
}
