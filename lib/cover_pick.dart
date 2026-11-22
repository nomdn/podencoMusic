/// 本地选图的平台入口，按编译目标选择：
///   原生 → cover_pick_io.dart（系统文件选择器，移动端按 MIME 收）
///   Web  → cover_pick_web.dart（`<input type="file">`，只读字节不碰路径）
///
/// 两份实现的 API 必须一致，否则条件导入在某一边编译不过。
library;

export 'cover_pick_web.dart' if (dart.library.io) 'cover_pick_io.dart';
