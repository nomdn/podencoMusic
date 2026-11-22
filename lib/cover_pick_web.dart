import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// 浏览器里选一张图，只读字节，裁剪和压缩交给确认页。
/// Web 的 file_selector 底层就是 `<input type="file">`，XFile.readAsBytes()
/// 直接拿到字节，不需要路径。返回 null 表示用户关掉了对话框。
Future<Uint8List?> pickCoverBytes() async {
  // 浏览器给的 MIME 经常是空串或 octet-stream，只按扩展名收窄
  const group = XTypeGroup(
    label: '图片',
    extensions: <String>['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
  );

  final file = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
  if (file == null) return null;
  return file.readAsBytes();
}
