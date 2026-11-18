import 'dart:io' show Directory, Platform;

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

/// 用户选中的文件。只读文本 —— 歌单备份就是纯文本（JSON / M3U8）。
class PickedTextFile {
  const PickedTextFile({required this.name, required this.content});

  /// 文件名（不含路径），用来兜底歌单名和猜格式
  final String name;
  final String content;
}

/// 原生平台都能弹系统文件选择器。
bool get canPickPlaylistFile => true;

/// 弹系统文件选择器读一个歌单备份。
///
/// 返回 null 表示用户取消了 —— 调用方安静收场，别弹「导入失败」。
Future<PickedTextFile?> pickPlaylistFile() async {
  final groups = <XTypeGroup>[
    if (Platform.isAndroid || Platform.isIOS)
      // 移动端的 SAF 只认 MIME。.json 被各家文件管理器标成 application/json、
      // text/plain，甚至 octet-stream，猜不准就干脆全放开：
      // 选错了文件，解析那一步会给出明确报错。
      const XTypeGroup(label: '歌单备份', mimeTypes: <String>['*/*'])
    else
      const XTypeGroup(
        label: '歌单备份',
        extensions: <String>['json', 'm3u', 'm3u8'],
      ),
  ];

  final file = await openFile(
    acceptedTypeGroups: groups,
    // 从导出目录起步：刚导出的备份就在那儿，省一趟翻目录
    initialDirectory: await _exportDirIfExists(),
  );
  if (file == null) return null;

  return PickedTextFile(name: file.name, content: await file.readAsString());
}

/// 导出目录存在才给选择器当起点；不存在返回 null（走系统默认位置）。
Future<String?> _exportDirIfExists() async {
  if (Platform.isAndroid) return null; // SAF 的起点由系统管，传了也没用
  try {
    final base = await getDownloadsDirectory();
    if (base == null) return null;
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}PodencoMusic',
    );
    if (!await dir.exists()) return null;
    return dir.path;
  } catch (_) {
    return null;
  }
}
