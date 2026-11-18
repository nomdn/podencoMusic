import 'dart:math' as math;

import 'package:material_ui/material_ui.dart' show Matrix4, Offset, Size;

/// 高级弹幕的 3D 透视投影（B站 Flash 模型，danmaku2ass / CommentCoreLibrary
/// 两方逆向一致）。
///
/// 文字是 z=0 平面上的一块板，绕自身中心先 RotZ 再 RotY，然后经透视投影
/// 落到屏幕上。透视的消失点是屏幕中心，焦距 = 宽 · tan40° / 2（Flash 的
/// 视场角公式）。
///
/// 参考：
/// - `[5]` = 绕 Z 轴旋转（度），`[6]` = 绕 Y 轴旋转（度）
/// - 「超小杯」rotY=90：文字立起来与屏幕垂直，投影成从屏幕中心指向锚点
///   的斜条，近端大远端小。
class BiliDanmaku3D {
  const BiliDanmaku3D._();

  /// 构造「模型 → 屏幕」的 4×4 投影矩阵。返回的是已经含透视除法的矩阵，
  /// 直接 `canvas.transform(m.storage)` 后以局部原点画文字即可。
  static Matrix4 transform({
    required Size canvas,
    required Offset anchor,
    required double textWidth,
    required double textHeight,
    required double rotZDeg,
    required double rotYDeg,
  }) {
    final focal = canvas.width * math.tan(2 * math.pi / 9) / 2;
    final cx = canvas.width / 2;
    final cy = canvas.height / 2;

    // 模型变换：把文字中心平移到锚点，再绕锚点中心做 RotY · RotZ。
    final model = Matrix4.identity()
      ..translateByDouble(anchor.dx, anchor.dy, 0, 1)
      ..rotateY(rotYDeg * math.pi / 180)
      ..rotateZ(rotZDeg * math.pi / 180)
      ..translateByDouble(-textWidth / 2, -textHeight / 2, 0, 1);

    // 透视投影矩阵（Flash 视角）：x_s = (f·x − cx·z) / (f − z)，
    // 即矩阵的行构造，最后一行 (0,0,−1,f) 产生 w' = f − z 做透视除法。
    final proj = Matrix4.identity()
      ..setEntry(0, 0, focal)
      ..setEntry(0, 2, -cx)
      ..setEntry(1, 1, focal)
      ..setEntry(1, 2, -cy)
      ..setEntry(2, 2, -1)
      ..setEntry(3, 2, -1)
      ..setEntry(3, 3, focal);

    return proj.clone()..multiply(model);
  }
}
