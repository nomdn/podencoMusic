import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// 弹系统文件选择器挑一张图，只负责把字节读出来。
/// 压缩/裁剪/编码留给裁剪确认页处理 —— 选完不能悄悄落库。
/// 返回 null 表示用户取消 —— 调用方安静收场，别弹失败提示。
Future<Uint8List?> pickCoverBytes() async {
  final group = Platform.isAndroid || Platform.isIOS
      // 移动端 SAF 按扩展名筛不靠谱，只认 MIME
      ? const XTypeGroup(label: '图片', mimeTypes: <String>['image/*'])
      : const XTypeGroup(
          label: '图片',
          extensions: <String>['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
        );

  final file = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
  if (file == null) return null;
  return file.readAsBytes();
}
