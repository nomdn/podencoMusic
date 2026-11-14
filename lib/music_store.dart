import 'dart:io';

import 'package:flutter/services.dart';

/// Android 系统 Music 目录的读写，走原生 MethodChannel。
///
/// 为什么非得走原生：Android 10 之后往公共目录写文件不能直接用 dart:io 写路径，
/// 必须通过 MediaStore 插入媒体条目，而 MediaStore 是纯 Java API。
///
/// 非 Android 平台上所有方法都返回空，调用方自己按 Platform 分支处理。
class MusicStore {
  static const _channel = MethodChannel('com.mint.podencomusic/storage');

  static bool get isSupported => Platform.isAndroid;

  /// 把临时文件存进系统 Music/PodencoMusic 目录。
  ///
  /// 成功返回 content:// URI（Android 10+）或绝对路径（9 及以下）。
  /// 权限被拒会抛 PlatformException，code 是 permission_denied。
  static Future<String?> save({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    if (!isSupported) return null;
    return _channel.invokeMethod<String>('saveToMusic', {
      'path': sourcePath,
      'fileName': fileName,
      'mimeType': mimeType,
    });
  }

  /// 已经存在 Music/PodencoMusic 里的文件名列表。
  /// 冷启动时用它把「已下载」标记恢复出来，不用请求网络。
  static Future<List<String>> list() async {
    if (!isSupported) return const [];
    final names = await _channel.invokeListMethod<String>('listMusic');
    return names ?? const [];
  }

  /// 是否已具备写公共目录的权限。Android 10+ 恒为 true。
  static Future<bool> hasPermission() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('hasPermission') ?? false;
  }

  /// Music 目录所在卷的剩余空间（字节），批量下载前查磁盘用。
  /// 拿不到（老系统没权限、StatFs 失败）返回 null，调用方跳过检查。
  static Future<int?> getFreeSpace() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<int>('getFreeSpace');
    } catch (_) {
      return null;
    }
  }

  /// 用系统文件管理器打开 Music/PodencoMusic 目录。
  /// 设备上没有能打开目录的应用时返回 false。
  static Future<bool> openFolder() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('openMusicFolder') ?? false;
    } catch (_) {
      return false;
    }
  }
}
