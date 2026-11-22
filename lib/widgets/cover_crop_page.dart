import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:image/image.dart' as img;

import '../cover_codec.dart';

/// 打开裁剪页。传图片字节，返回裁剪压缩后的 data URI；
/// 用户取消或按返回键返回 null。
Future<String?> showCoverCropPage(BuildContext context, Uint8List bytes) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(builder: (_) => CoverCropPage(imageBytes: bytes)),
  );
}

/// 封面裁剪确认页。固定正方形裁剪框，图片可拖动和缩放 —— 选完本地图
/// 不能悄悄落库，得让用户先看一眼裁掉的是什么。
class CoverCropPage extends StatefulWidget {
  const CoverCropPage({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<CoverCropPage> createState() => _CoverCropPageState();
}

class _CoverCropPageState extends State<CoverCropPage> {
  img.Image? _source;
  String? _decodeError;

  double _scale = 1;
  double _offsetX = 0;
  double _offsetY = 0;

  double _startScale = 1;
  double _startOffsetX = 0;
  double _startOffsetY = 0;
  Offset? _startFocal;

  @override
  void initState() {
    super.initState();
    try {
      _source = img.decodeImage(widget.imageBytes);
    } catch (_) {
      _source = null;
    }
    if (_source == null) {
      _decodeError = '这张图片读不出来，换一张 JPG / PNG 试试';
    }
  }

  /// 裁剪框边长。取屏幕短边的八成，四周留出手势空间。
  double _viewSizeOf(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return math.min(screen.width, screen.height) * 0.8;
  }

  CoverCropLayout _layoutOf(BuildContext context) {
    final source = _source!;
    return CoverCropLayout(
      imageWidth: source.width,
      imageHeight: source.height,
      viewSize: _viewSizeOf(context),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startOffsetX = _offsetX;
    _startOffsetY = _offsetY;
    _startFocal = details.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, CoverCropLayout layout) {
    final focal = _startFocal ?? details.focalPoint;
    setState(() {
      _scale = (_startScale * details.scale).clamp(1.0, 4.0);
      _offsetX = _startOffsetX + details.focalPoint.dx - focal.dx;
      _offsetY = _startOffsetY + details.focalPoint.dy - focal.dy;

      // 别让图片被拖出裁剪框，否则会切到边框外的空白
      final maxX = (layout.baseWidth * _scale - layout.viewSize) / 2;
      final maxY = (layout.baseHeight * _scale - layout.viewSize) / 2;
      _offsetX = maxX <= 0 ? 0 : _offsetX.clamp(-maxX, maxX);
      _offsetY = maxY <= 0 ? 0 : _offsetY.clamp(-maxY, maxY);
    });
  }

  void _confirm() {
    final layout = _layoutOf(context);
    final rect = layout.cropRectFor(
      scale: _scale,
      offsetX: _offsetX,
      offsetY: _offsetY,
    );
    try {
      final uri = encodeCoverCropped(
        widget.imageBytes,
        x: rect.x,
        y: rect.y,
        size: rect.size,
      );
      Navigator.of(context).pop(uri);
    } on CoverCodecException catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_decodeError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('裁剪封面')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_decodeError!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('返回'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final layout = _layoutOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('裁剪封面'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _confirm,
            child: const Text('完成'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: _onScaleStart,
              onScaleUpdate: (details) => _onScaleUpdate(details, layout),
              child: Center(
                child: Transform.translate(
                  offset: Offset(_offsetX, _offsetY),
                  child: Transform.scale(
                    scale: _scale,
                    child: Image.memory(
                      widget.imageBytes,
                      width: layout.baseWidth,
                      height: layout.baseHeight,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 框外压暗 + 四角标记，纯绘制不拦手势
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _CropMaskPainter(size: layout.viewSize),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Text(
              '拖动和缩放图片，把要用的部分放进方框',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CropMaskPainter extends CustomPainter {
  const _CropMaskPainter({required this.size});

  final double size;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final rect = Rect.fromCenter(
      center: Offset(canvasSize.width / 2, canvasSize.height / 2),
      width: size,
      height: size,
    );

    final mask = Path()
      ..addRect(Offset.zero & canvasSize)
      ..addRect(rect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 四角的 L 形标记：一眼看出裁剪边界，比细线框好认
    final corner = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    const length = 18.0;
    canvas
      ..drawLine(rect.topLeft, rect.topLeft + const Offset(length, 0), corner)
      ..drawLine(rect.topLeft, rect.topLeft + const Offset(0, length), corner)
      ..drawLine(rect.topRight, rect.topRight + const Offset(-length, 0), corner)
      ..drawLine(rect.topRight, rect.topRight + const Offset(0, length), corner)
      ..drawLine(
        rect.bottomLeft,
        rect.bottomLeft + const Offset(length, 0),
        corner,
      )
      ..drawLine(
        rect.bottomLeft,
        rect.bottomLeft + const Offset(0, -length),
        corner,
      )
      ..drawLine(
        rect.bottomRight,
        rect.bottomRight + const Offset(-length, 0),
        corner,
      )
      ..drawLine(
        rect.bottomRight,
        rect.bottomRight + const Offset(0, -length),
        corner,
      );
  }

  @override
  bool shouldRepaint(covariant _CropMaskPainter oldDelegate) =>
      oldDelegate.size != size;
}
