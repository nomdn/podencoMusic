import 'package:flutter/services.dart';

/// 一次导出的落点。Web 没有文件系统，只能退化成剪贴板。
class WrittenFile {
  const WrittenFile.file(this.path) : copied = false;

  const WrittenFile.clipboard()
    : path = null,
      copied = true;

  final String? path;
  final bool copied;
}

/// Web 上「导出」= 复制到剪贴板，用户自己粘到别处。
///
/// 不用 a[download] + Blob 那套：它只能下载不能选目录，而且这里
/// 已经在 File System Access 那条路上（见 web_download_impl），
/// 为一个文本文件再引一条路径不划算。
Future<WrittenFile> writeExportFile({
  required String fileName,
  required String content,
}) async {
  await Clipboard.setData(ClipboardData(text: content));
  return const WrittenFile.clipboard();
}

/// Web 上打不开本地文件夹。
Future<bool> openExportFolder() async => false;
