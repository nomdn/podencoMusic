import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Android 系统 Music 目录的读写，走原生 MethodChannel。
///
/// 为什么非得走原生：Android 10 之后往公共目录写文件不能直接用 dart:io 写路径，
/// 必须通过 MediaStore 插入媒体条目，而 MediaStore 是纯 Java API。
///
/// 非 Android 平台上所有方法都返回空，调用方自己按 Platform 分支处理。
class MusicStore {
  static const _channel = MethodChannel('com.mint.podencomusic/storage');

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

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

  /// 申请 Android 13+ 的通知运行时权限（媒体通知的显示授权）。
  /// 启动时尽力而为地申请一次：被拒不阻塞任何功能，播放本身不依赖它，
  /// 用户之后仍可在系统设置里补开。
  static Future<void> ensureNotificationPermission() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('ensureNotificationPermission');
    } catch (_) {
      // 通道未就绪 / 低版本等异常一律吞掉，不该影响启动
    }
  }

  // ── vivo 原子随身听白名单 ─────────────────────────────────
  //
  // OriginOS 4 的挖孔播放胶囊只对白名单内应用显示，白名单存在 system
  // settings 表里（JSON 字符串数组）。两条写入通道自动选路：Shizuku
  // 在线走 shell 身份（与社区 ADB 教程完全等效），否则走「修改系统
  // 设置」直写。详见 settings_page 的说明文案。

  /// 应用自身的包名，必须与 build.gradle.kts 的 applicationId 一致。
  static const appPackage = 'com.mint.podencomusic';

  /// 白名单的 settings key，值形如 `["com.android.bbkmusic.local","..."]`。
  static const vivoWhitelistKey = 'musicwidget_list_pkg_type_key';

  /// 读取白名单原值。key 不存在（非 vivo / 新版 OriginOS）返回 null。
  static Future<String?> vivoWhitelist() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('getVivoWhitelist');
    } catch (_) {
      return null;
    }
  }

  /// 写回白名单。失败（未授权 / Shizuku 不在线且未授权等）返回 false。
  static Future<bool> setVivoWhitelist(String json) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('setVivoWhitelist', {'json': json}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 白名单写入通道的环境探测：决定走 Shizuku 还是「修改系统设置」。
  static Future<VivoWhitelistEnv?> vivoWhitelistEnv() async {
    if (!isSupported) return null;
    try {
      final map =
          await _channel.invokeMethod<Map<Object?, Object?>>('vivoWhitelistEnv');
      if (map == null) return null;
      return VivoWhitelistEnv(
        shizukuAlive: map['shizukuAlive'] == true,
        shizukuGranted: map['shizukuGranted'] == true,
        canWriteSettings: map['canWriteSettings'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// 拉起 Shizuku 的授权框（Shizuku 在运行但未授权时调用）。
  /// 返回用户是否点了允许。
  static Future<bool> vivoShizukuRequestPermission() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('vivoShizukuRequestPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 跳到系统「修改系统设置」授权页（WRITE_SETTINGS 通道的授权入口）。
  static Future<bool> openVivoWriteSettings() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('openVivoWriteSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ── 白名单 JSON 纯逻辑（不碰平台通道，单测覆盖）──────────

  /// 解析白名单原值为包名列表。null / 格式非预期返回 null。
  static List<String>? parseWhitelist(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded.map((e) => e.toString()).toList();
    } catch (_) {
      return null;
    }
  }

  /// 序列化回 settings 表要求的格式：无空格的 JSON 数组。
  static String serializeWhitelist(List<String> list) => jsonEncode(list);

  /// 把 [pkg] 加入包名列表（已在其中则原样返回），原列表不被修改。
  static List<String> whitelistWith(List<String> list, String pkg) =>
      list.contains(pkg) ? List.of(list) : [...list, pkg];

  /// 从包名列表移除 [pkg]（只删自己，不动别人的条目）。
  static List<String> whitelistWithout(List<String> list, String pkg) =>
      list.where((e) => e != pkg).toList();

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

/// [MusicStore.vivoWhitelistEnv] 的结果。
class VivoWhitelistEnv {
  const VivoWhitelistEnv({
    required this.shizukuAlive,
    required this.shizukuGranted,
    required this.canWriteSettings,
  });

  /// Shizuku 管理器是否在运行（装了没运行 / 没装都是 false）
  final bool shizukuAlive;

  /// Shizuku 是否已授权本应用
  final bool shizukuGranted;

  /// 是否已授予「修改系统设置」（WRITE_SETTINGS）
  final bool canWriteSettings;

  /// Shizuku 完全就绪：优先走这条通道，shell 身份写入保真度最高
  bool get shizukuReady => shizukuAlive && shizukuGranted;
}
