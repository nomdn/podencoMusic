/// 剩余磁盘空间查询的条件导出门面。
///
/// 桌面（dart:io + dart:ffi 可用）→ FFI 实现；
/// Web（dart:ffi 不存在）→ 存根，返回 null，调用方跳过空间检查。
library;

export 'disk_space_stub.dart'
    if (dart.library.io) 'disk_space_impl.dart';
