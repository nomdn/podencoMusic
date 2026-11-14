import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// x64/arm64 桌面实现（dart:ffi）。由 disk_space.dart 条件导出。
///
/// 拿不到（平台不支持、调用失败）就返回 null，调用方跳过检查 ——
/// 检查是尽力而为的保险，不该挡住能正常下载的场景。
/// 安卓走 MusicStore 的原生通道（StatFs），这里只管桌面。
class DiskSpace {
  /// 批量下载的最低剩余空间门槛。一张 wav 专辑轻松 500MB 往上，
  /// 少于这个数说明盘已经很满，直接拦下来比下到一半失败友好。
  static const minFreeBytes = 1 << 30; // 1 GiB

  /// [path] 所在卷的剩余空间（字节）。Windows 走 FFI，其它平台返回 null。
  static int? freeBytesAt(String path) {
    if (Platform.isWindows) return _freeBytesWindows(path);
    return null;
  }

  /// 调 Win32 的 GetDiskFreeSpaceExW。
  /// ULARGE_INTEGER 在 ABI 上就是 64 位无符号整数，用 `Pointer<Uint64>` 接。
  /// DynamicLibrary 打开后就驻留进程，不需要也不会释放。
  static int? _freeBytesWindows(String path) {
    Pointer<Uint16>? dirPtr;
    Pointer<Uint64>? availablePtr;
    Pointer<Uint64>? totalPtr;
    Pointer<Uint64>? freePtr;

    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getDiskFreeSpaceExW = kernel32.lookupFunction<
          Int32 Function(
            Pointer<Uint16>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
          ),
          int Function(
            Pointer<Uint16>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
          )>('GetDiskFreeSpaceExW');

      dirPtr = path.toNativeUtf16().cast();
      availablePtr = malloc<Uint64>();
      totalPtr = malloc<Uint64>();
      freePtr = malloc<Uint64>();

      // 返回 0 = 调用失败（路径不存在等）
      if (getDiskFreeSpaceExW(dirPtr, availablePtr, totalPtr, freePtr) == 0) {
        return null;
      }
      return availablePtr.value;
    } catch (_) {
      return null;
    } finally {
      for (final ptr in [dirPtr, availablePtr, totalPtr, freePtr]) {
        if (ptr != null) {
          try {
            malloc.free(ptr);
          } catch (_) {}
        }
      }
    }
  }
}
