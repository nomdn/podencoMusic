import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 自定义封面最长边。列表里只显示 48px、详情页 132px，320 已经够清晰，
/// 再大只会把歌单存档撑胖 —— 每次增删歌都要整份 JSON 写盘。
const int coverMaxEdge = 320;

const int _jpegQuality = 80;

class CoverCodecException implements Exception {
  const CoverCodecException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把本地图片字节压成可直接塞进 `coverUrl` 的 data URI。
///
/// 等比缩到最长边 [coverMaxEdge]，JPEG 编码后 base64。一张 320px 的图
/// 压完约 10～20KB，base64 后涨三成，塞进 SharedPreferences 的 JSON 里
/// 还能接受。原图尺寸和格式都不留 —— 封面只需要显示，不需要还原原稿。
String encodeCover(List<int> bytes) => _toDataUri(_fit(_decode(bytes)));

/// 按裁剪页确认的矩形切图再压缩。裁剪区域由 [cropRectFor] 算出，
/// 这里只负责切和编码 —— 坐标越界由调用方 clamp 过，不再兜底。
String encodeCoverCropped(
  List<int> bytes, {
  required int x,
  required int y,
  required int size,
}) {
  final decoded = _decode(bytes);
  final cropped = img.copyCrop(
    decoded,
    x: x,
    y: y,
    width: size,
    height: size,
  );
  return _toDataUri(_fit(cropped));
}

img.Image _decode(List<int> bytes) {
  if (bytes.isEmpty) {
    throw const CoverCodecException('图片是空的，换一张试试');
  }
  final decoded = img.decodeImage(Uint8List.fromList(bytes));
  if (decoded == null) {
    throw const CoverCodecException('这张图片读不出来，换一张 JPG / PNG 试试');
  }
  return decoded;
}

img.Image _fit(img.Image source) {
  final longest = source.width > source.height ? source.width : source.height;
  if (longest <= coverMaxEdge) return source;
  return img.copyResize(
    source,
    width: _scaledEdge(source.width, longest),
    height: _scaledEdge(source.height, longest),
  );
}

String _toDataUri(img.Image image) =>
    'data:image/jpeg;base64,${base64Encode(img.encodeJpg(image, quality: _jpegQuality))}';

int _scaledEdge(int edge, int longest) =>
    (edge * coverMaxEdge / longest).round().clamp(1, coverMaxEdge);

/// 裁剪视图里图片的初始摆法：短边刚好铺满裁剪框，长边溢出。
/// 用户在此基础上缩放、平移，确认时按当前状态反算原图上的裁剪矩形。
class CoverCropLayout {
  const CoverCropLayout({
    required this.imageWidth,
    required this.imageHeight,
    required this.viewSize,
  });

  final int imageWidth;
  final int imageHeight;

  /// 裁剪框边长（逻辑像素）。
  final double viewSize;

  double get _shortEdge => math.min(imageWidth, imageHeight).toDouble();

  /// 缩放为 1 时的显示尺寸，短边 = [viewSize]。
  double get baseWidth => imageWidth * viewSize / _shortEdge;
  double get baseHeight => imageHeight * viewSize / _shortEdge;

  /// 把「图片中心相对裁剪框中心的偏移」和「用户缩放」换算成原图上的
  /// 正方形裁剪区域。偏移超出图片时自动 clamp，保证切出来的始终是正方形
  /// 且不越界 —— 用户把图拖飞了也不会拿到黑边或负坐标。
  ({int x, int y, int size}) cropRectFor({
    required double scale,
    required double offsetX,
    required double offsetY,
  }) {
    final totalScale = _shortEdge == 0 ? 1.0 : viewSize / _shortEdge * scale;
    final displayWidth = imageWidth * totalScale;
    final displayHeight = imageHeight * totalScale;

    // 框左上角在「显示坐标系」里相对图片左上角的位置
    final left = (displayWidth - viewSize) / 2 - offsetX;
    final top = (displayHeight - viewSize) / 2 - offsetY;

    final size = (viewSize / totalScale)
        .round()
        .clamp(1, math.min(imageWidth, imageHeight))
        .toInt();
    final x = (left / totalScale).round().clamp(0, imageWidth - size).toInt();
    final y = (top / totalScale).round().clamp(0, imageHeight - size).toInt();
    return (x: x, y: y, size: size);
  }
}

/// 从 data URI 里取回图片字节。普通 http 链接返回 null，调用方照旧走网络。
Uint8List? decodeCoverDataUri(String url) {
  if (!url.startsWith('data:image/')) return null;
  final comma = url.indexOf(',');
  if (comma < 0) return null;
  try {
    return base64Decode(url.substring(comma + 1));
  } catch (_) {
    // 存档被手改坏 / 截断的 base64 都当没封面，别拖垮启动
    return null;
  }
}
