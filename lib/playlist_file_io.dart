import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'music_store.dart';

/// 一次导出的落点。原生平台一定写文件（[path] 非空），
/// Web 没有文件系统，退化成复制到剪贴板（[copied] = true）。
class WrittenFile {
  const WrittenFile.file(this.path) : copied = false;
  const WrittenFile.clipboard()
    : path = null,
      copied = true;

  final String? path;
  final bool copied;
}

/// 把导出内容写出去。
///
/// 存哪儿：
///   Android → 系统「下载/PodencoMusic/」，走 MediaStore，文件管理器直接能看到
///   桌面     → 系统下载目录下的 PodencoMusic/（和音乐下载同一个文件夹）
///
/// 用 UTF-8 写，且**不加 BOM**：JSON 规范不允许 BOM，M3U 播放器对 BOM 也各
/// 有各的脾气（有的把它当成第一行内容）。
Future<WrittenFile> writeExportFile({
  required String fileName,
  required String content,
}) async {
  if (Platform.isAndroid && MusicStore.isSupported) {
    final saved = await MusicStore.saveText(
      fileName: fileName,
      content: content,
    );
    if (saved != null) return WrittenFile.file(saved);
    // 原生侧失败（老系统没给存储权限之类）就掉到下面走应用目录，
    // 至少别让用户点了导出什么也没发生
  }

  final dir = await _exportDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsString(content, flush: true);
  return WrittenFile.file(file.path);
}

/// 桌面走系统下载目录；安卓的兜底走应用自己的外部目录（免权限）。
Future<Directory> _exportDirectory() async {
  Directory? base;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    base = await getDownloadsDirectory();
  }
  base ??= await getExternalStorageDirectory();
  base ??= await getApplicationDocumentsDirectory();

  final dir = Directory('${base.path}${Platform.pathSeparator}PodencoMusic');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// 打开导出所在的文件夹。安卓复用媒体库那个（Downloads 根），
/// 桌面调系统文件管理器。
Future<bool> openExportFolder() async {
  if (kIsWeb) return false;
  if (Platform.isAndroid) return MusicStore.openExportFolder();

  final dir = await _exportDirectory();
  try {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', [dir.path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [dir.path]);
    } else {
      await Process.run('xdg-open', [dir.path]);
    }
    return true;
  } catch (_) {
    return false;
  }
}
