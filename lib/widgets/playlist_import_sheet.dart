import 'package:material_ui/material_ui.dart';

import '../playlist_import.dart';
import '../playlist_model.dart';
import '../playlist_pick.dart';

/// 「导入歌单」：选文件 → 解析（M3U 还要联网补全）→ 预览 → 落库。
///
/// 中间隔一层预览而不是选完直接导入，是因为选错文件比想象的常见
/// （安卓的文件选择器什么都能选），先让人看清「要进来的是哪个歌单、
/// 多少首」，比导完再删省事。
Future<void> showPlaylistImportSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _ImportSheet(),
  );
}

enum _Stage { idle, working, preview, failed }

class _ImportSheet extends StatefulWidget {
  const _ImportSheet();

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  _Stage _stage = _Stage.idle;
  String _progress = '';
  String _error = '';
  String _fileName = '';
  List<ImportedPlaylist> _parsed = const [];

  Future<void> _pickAndParse() async {
    setState(() {
      _stage = _Stage.working;
      _progress = '等待选择档案文件…';
      _error = '';
    });

    try {
      final picked = await pickPlaylistFile();
      if (!mounted) return;
      if (picked == null) {
        // 用户点了取消，回到初始态，别当成失败
        setState(() {
          _stage = _Stage.idle;
          _progress = '';
        });
        return;
      }

      setState(() {
        _fileName = picked.name;
        _progress = '正在解析档案…';
      });

      final List<ImportedPlaylist> parsed;
      if (looksLikeJson(picked.content)) {
        parsed = parsePlaylistJson(picked.content);
      } else {
        setState(() => _progress = '正在从塞壬补全音轨…');
        parsed = [
          await restoreM3uPlaylist(
            picked.content,
            fallbackName: _nameWithoutExtension(picked.name),
            onProgress: (done, total) {
              if (!mounted) return;
              setState(() => _progress = '正在从塞壬补全音轨 $done/$total');
            },
          ),
        ];
      }

      if (!mounted) return;
      setState(() {
        _parsed = parsed;
        _stage = _Stage.preview;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = e is PlaylistImportException ? e.message : '无法读取该档案：$e';
      });
    }
  }

  void _commit() {
    final messenger = ScaffoldMessenger.of(context);
    var count = 0;
    for (final playlist in _parsed) {
      playlistsModel.importPlaylist(
        playlist.name,
        playlist.tracks,
        coverUrl: playlist.coverUrl,
      );
      count += playlist.tracks.length;
    }

    Navigator.of(context).pop();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _parsed.length == 1
              ? '已收录「${_parsed.single.name}」· $count 首'
              : '已收录 ${_parsed.length} 个歌单 · 共 $count 首',
        ),
      ),
    );
  }

  /// `我的歌单.json` → `我的歌单`
  String _nameWithoutExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    return base.trim().isEmpty ? '导入的歌单' : base.trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.file_download, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('导入歌单', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 12),
              ..._body(theme),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(ThemeData theme) {
    switch (_stage) {
      case _Stage.idle:
        return [
          Text(
            '读一个 Podenco Music 导出的 .json 备份，或者一个 M3U 播放列表。'
            '导入是新建歌单，不会覆盖现有的。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'JSON 是完整备份，歌名、艺人、专辑都在；'
            'M3U 仅存曲目 id，导入时需联网逐首补全，耗时稍长。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: canPickPlaylistFile ? _pickAndParse : null,
            icon: const Icon(Icons.folder_open),
            label: Text(canPickPlaylistFile ? '选择文件' : '网页端暂不支持导入'),
          ),
        ];

      case _Stage.working:
        return [
          const SizedBox(height: 8),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Center(
            child: Text(
              _progress,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ];

      case _Stage.failed:
        return [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _error,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: _pickAndParse,
            icon: const Icon(Icons.folder_open),
            label: const Text('重选档案'),
          ),
        ];

      case _Stage.preview:
        final total = _parsed.fold<int>(
          0,
          (sum, playlist) => sum + playlist.tracks.length,
        );
        final notes = _parsed
            .map((playlist) => playlist.note)
            .whereType<String>()
            .toSet();

        return [
          Text(
            _fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          for (final playlist in _parsed)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.queue_music),
              title: Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text('${playlist.tracks.length} 首'),
            ),
          if (notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                notes.join('；'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _commit,
                  icon: const Icon(Icons.add),
                  label: Text('导入 $total 首'),
                ),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: _pickAndParse, child: const Text('重选')),
            ],
          ),
        ];
    }
  }
}
