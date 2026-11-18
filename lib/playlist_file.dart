/// 导出文件的平台实现入口，按编译目标选择：
///   原生（Windows / Android / macOS / Linux）→ playlist_file_io.dart
///   Web → playlist_file_stub.dart（没有文件系统，退回剪贴板）
///
/// 两份实现的 API 必须完全一致，否则条件导入在某一边编译不过。
library;

export 'playlist_file_stub.dart'
    if (dart.library.io) 'playlist_file_io.dart';
