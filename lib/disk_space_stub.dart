/// Web 存根：dart:ffi 在 Web 上不存在，磁盘空间查询直接返回 null
/// （调用方拿到 null 会跳过空间检查 —— 缓存缺失的后果只是慢，不是错）。
class DiskSpace {
  static const minFreeBytes = 1 << 30; // 1 GiB

  static int? freeBytesAt(String path) => null;
}
