import 'package:material_ui/material_ui.dart';

import '../library.dart';
import '../models.dart';
import '../playlist_model.dart';
import '../widgets/cover_image.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_dialogs.dart';
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
        title: const Text('歌单'),
        actions: [
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
            return _EmptyState(onCreate: _create);
          }
          return ListView.builder(
            itemCount: playlists.length,
            itemBuilder: (context, index) {
              return _PlaylistRow(
                playlist: playlists[index],
                onRename: () => _rename(playlists[index]),
                onDelete: () => _delete(playlists[index]),
              );
            },
          );
        },
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }
}

/// 一行歌单。封面取歌单里第一首歌的专辑封面，空歌单显示占位图标。
class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.onRename,
    required this.onDelete,
  });

  final Playlist playlist;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverUrl = playlist.tracks.isEmpty
        ? ''
        : library.coverOf(playlist.tracks.first.albumCid);

    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: coverUrl.isEmpty
              ? ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.library_music,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              : CoverImage(url: coverUrl),
        ),
      ),
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('${playlist.tracks.length} 首'),
      // 入口菜单放行尾：桌面端长按不好按，按钮两端平台都顺手
      trailing: PopupMenuButton<String>(
        tooltip: '更多操作',
        onSelected: (action) {
          if (action == 'rename') onRename();
          if (action == 'delete') onDelete();
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'rename', child: Text('重命名')),
          PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlaylistDetailPage(playlistId: playlist.id),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});

  final VoidCallback onCreate;

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
            '还没有歌单',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add),
            label: const Text('新建歌单'),
          ),
        ],
      ),
    );
  }
}
