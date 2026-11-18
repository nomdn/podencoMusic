import 'package:file_selector/file_selector.dart';

/// 用户选中的文件。只读文本 —— 歌单备份就是纯文本（JSON / M3U8）。
class PickedTextFile {
  const PickedTextFile({required this.name, required this.content});

  /// 文件名（不含路径），用来兜底歌单名和猜格式
  final String name;
  final String content;
}

/// Web 也能弹文件选择器。
///
/// 之前这里是 stub，理由是"浏览器没有可读的本地路径"。这个判断错了：
/// 拿不到**路径**不等于拿不到**内容** —— file_selector 的 Web 实现
/// 底层就是 `<input type="file">`，产出的 XFile 可以直接 readAsString
/// 把字节读进内存，根本不需要路径。
bool get canPickPlaylistFile => true;

/// 弹浏览器文件选择框，读一个歌单备份。
///
/// 返回 null 表示用户关掉了对话框 —— 调用方安静收场，不该报「导入失败」。
Future<PickedTextFile?> pickPlaylistFile() async {
  // 浏览器里 MIME 判断不可靠（.json 常被报成空串或 octet-stream），
  // 所以只按扩展名收窄；真选错了文件，解析那一步会给出明确报错。
  const group = XTypeGroup(
    label: '歌单备份',
    extensions: <String>['json', 'm3u', 'm3u8'],
  );

  final file = await openFile(acceptedTypeGroups: const <XTypeGroup>[group]);
  if (file == null) return null;

  return PickedTextFile(name: file.name, content: await file.readAsString());
}
