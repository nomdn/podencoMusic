import 'package:material_ui/material_ui.dart';

import '../models.dart';

/// 新建 / 重命名共用的歌单名输入框。
///
/// 点确定返回输入的名字（可能是空串，调用方自己兜），点取消或
/// 点遮罩关掉返回 null。
Future<String?> showPlaylistNameDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String actionLabel = '确定',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, initial: initial, actionLabel: actionLabel),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.actionLabel,
  });

  final String title;
  final String initial;
  final String actionLabel;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

/// 删除确认。歌曲本身不受影响，删掉的只是这份歌单记录。
Future<bool> showPlaylistDeleteDialog(
  BuildContext context,
  Playlist playlist,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('删除歌单'),
        content: Text(
          '「${playlist.name}」里的 ${playlist.tracks.length} 首歌的记录会一起删掉，'
          '歌曲本身和下载的文件不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
