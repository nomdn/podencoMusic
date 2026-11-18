/// 选文件的平台入口，按编译目标选择：
///   原生 → playlist_pick_io.dart（系统文件选择器 + 起始目录）
///   Web  → playlist_pick_web.dart（`<input type="file">`，只读内容、不碰路径）
///
/// 两份实现的 API 必须完全一致，否则条件导入在某一边编译不过。
library;

export 'playlist_pick_web.dart' if (dart.library.io) 'playlist_pick_io.dart';
