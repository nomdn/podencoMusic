import 'package:material_ui/material_ui.dart';

import '../library.dart';
import '../models.dart';
import '../playlist_model.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/playlist_dialogs.dart';
import '../widgets/playlist_export_sheet.dart';
import '../widgets/playlist_import_sheet.dart';
import 'playlist_detail_page.dart';

/// 歌单列表页。数据全在本地（playlistsModel），不需要 FutureBuilder，
/// 但封面要走 library 反查，所以两个 notifier 一起订阅 ——
/// 冷启动直接进这页时专辑列表可能还没回来。
class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  // 多歌单合并：选中态只在页面内活着，不落盘、不跟着歌单走
  bool _selecting = false;
  final Set<String> _selected = {};

  void _startSelecting() {
    setState(() {
      _selecting = true;
      _selected.clear();
    });
  }

  void _stopSelecting() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  void _toggleAll() {
    final all = playlistsModel.playlists;
    setState(() {
      if (_selected.length == all.length && all.isNotEmpty) {
        _selected.clear();
      } else {
        _selected.addAll(all.map((playlist) => playlist.id));
      }
    });
  }

  Future<void> _mergeSelected() async {
    if (_selected.length < 2) return;
    final name = await showPlaylistNameDialog(
      context,
      title: '合并歌单',
      initial: '合并歌单 ${playlistsModel.playlists.length + 1}',
      actionLabel: '合并',
    );
    if (name == null || name.trim().isEmpty) return;

    // 按界面上的顺序合并，不是按点选顺序 —— 合并结果要能预期
    final ids = playlistsModel.playlists
        .where((playlist) => _selected.contains(playlist.id))
        .map((playlist) => playlist.id)
        .toList();
    final merged = playlistsModel.merge(ids, name);
    if (!mounted) return;
    _stopSelecting();
    if (merged != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已合并 ${merged.tracks.length} 首到「${merged.name}」'),
        ),
      );
    }
  }

  Future<void> _create() async {
    final name = await showPlaylistNameDialog(
      context,
      title: '新建歌单',
      initial: '新建歌单 ${playlistsModel.playlists.length + 1}',
      actionLabel: '创建',
    );
    // 取消（null）或空串都不建
    if (name == null || name.trim().isEmpty) return;
    playlistsModel.create(name);
  }

  Future<void> _rename(Playlist playlist) async {
    final name = await showPlaylistNameDialog(
      context,
      title: '重命名歌单',
      initial: playlist.name,
      actionLabel: '重命名',
    );
    if (name == null || name.trim().isEmpty) return;
    playlistsModel.rename(playlist.id, name);
  }

  Future<void> _delete(Playlist playlist) async {
    if (!await showPlaylistDeleteDialog(context, playlist)) return;
    playlistsModel.remove(playlist.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 选择态下首页没有系统返回键，自己给个关闭入口
        leading: _selecting
            ? IconButton(
                onPressed: _stopSelecting,
                icon: const Icon(Icons.close),
                tooltip: '取消选择',
              )
            : null,
        title: Text(_selecting ? '选择要合并的歌单' : '歌单'),
        actions: _selecting
            ? [
                IconButton(
                  onPressed: _toggleAll,
                  icon: const Icon(Icons.select_all),
                  tooltip: '全选 / 取消全选',
                ),
              ]
            : [
                IconButton(
                  onPressed: () => showPlaylistImportSheet(context),
                  icon: const Icon(Icons.file_download),
                  tooltip: '恢复备份',
                ),
                IconButton(
                  onPressed: _startSelecting,
                  icon: const Icon(Icons.merge_type),
                  tooltip: '合并歌单',
                ),
                IconButton(
                  onPressed: _create,
                  icon: const Icon(Icons.add),
                  tooltip: '新建歌单',
                ),
                const SizedBox(width: 8),
              ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([playlistsModel, library]),
        builder: (context, _) {
          final playlists = playlistsModel.playlists;
          if (playlists.isEmpty) {
            return _EmptyState(
              onCreate: _create,
              onImport: () => showPlaylistImportSheet(context),
            );
          }
          return ListView.builder(
            itemCount: playlists.length,
            itemBuilder: (context, index) {
              return _PlaylistRow(
                playlist: playlists[index],
                selectionMode: _selecting,
                selected: _selected.contains(playlists[index].id),
                onToggle: () => _toggle(playlists[index].id),
                onOpen: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        PlaylistDetailPage(playlistId: playlists[index].id),
                  ),
                ),
                onExport: () =>
                    showPlaylistExportSheet(context, playlists[index]),
                onRename: () => _rename(playlists[index]),
                onDelete: () => _delete(playlists[index]),
              );
            },
          );
        },
      ),
      bottomNavigationBar: _selecting
          ? _MergeBar(count: _selected.length, onMerge: _mergeSelected)
          : const MiniPlayerBar(),
    );
  }
}

/// 选择态底部的合并条。不足两个歌单时按钮置灰 —— 一个歌单没东西可合。
class _MergeBar extends StatelessWidget {
  const _MergeBar({required this.count, required this.onMerge});

  final int count;
  final VoidCallback onMerge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Text('已选 $count 个', style: theme.textTheme.bodyMedium),
          const Spacer(),
          FilledButton.icon(
            onPressed: count >= 2 ? onMerge : null,
            icon: const Icon(Icons.merge_type),
            label: const Text('合并'),
          ),
        ],
      ),
    );
  }
}

/// 一行歌单。封面走 [PlaylistCover]：自定义链接优先，没设过才用首曲封面。
/// 选择态下整行变成勾选开关，菜单藏起来，免得误触进详情页。
class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.selectionMode,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
    required this.onExport,
    required this.onRename,
    required this.onDelete,
  });

  final Playlist playlist;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onExport;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: PlaylistCover(playlist: playlist),
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('${playlist.tracks.length} 首'),
      selected: selectionMode && selected,
      trailing: selectionMode
          ? Checkbox(value: selected, onChanged: (_) => onToggle())
          : PopupMenuButton<String>(
              tooltip: '更多操作',
              onSelected: (action) {
                if (action == 'export') onExport();
                if (action == 'rename') onRename();
                if (action == 'delete') onDelete();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'export', child: Text('导出备份')),
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
      onTap: selectionMode ? onToggle : onOpen,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate, required this.onImport});

  final VoidCallback onCreate;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.library_music,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '档案室尚无歌单',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add),
            label: const Text('建立新歌单'),
          ),
          const SizedBox(height: 8),
          // 换了设备 / 重装之后第一个动作往往是「把备份拿回来」
          TextButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.file_download),
            label: const Text('从备份恢复档案'),
          ),
        ],
      ),
    );
  }
}
