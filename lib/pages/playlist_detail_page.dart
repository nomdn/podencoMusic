import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../downloader.dart';
import '../library.dart';
import '../models.dart';
import '../player_model.dart';
import '../playlist_model.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/playlist_cover_sheet.dart';
import '../widgets/playlist_dialogs.dart';
import '../widgets/playlist_export_sheet.dart';
import 'downloads_page.dart';
import 'player_page.dart';

/// 歌单详情：头部 + 曲目列表。骨架抄 album_page，数据是本地的，
/// 没有加载过程 —— 直接订阅 playlistsModel，增删曲目界面自己刷新。
///
/// 构造传的是 id 而不是歌单对象：歌单每次增删曲目都会换成新对象，
/// 页面里每帧都得用 id 取最新状态，不然显示的是进页时的旧快照。
class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
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
    // 歌单没了，这页也别留了
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          ListenableBuilder(
            listenable: playlistsModel,
            builder: (context, _) {
              final playlist = playlistsModel.byId(widget.playlistId);
              if (playlist == null) return const SizedBox.shrink();
              return PopupMenuButton<String>(
                tooltip: '更多操作',
                onSelected: (action) {
                  if (action == 'rename') _rename(playlist);
                  if (action == 'cover') showPlaylistCoverSheet(context, playlist.id);
                  if (action == 'export') showPlaylistExportSheet(context, playlist);
                  if (action == 'delete') _delete(playlist);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'cover', child: Text('设置封面')),
                  PopupMenuItem(value: 'export', child: Text('导出备份')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        // 封面走 library 反查，行高亮跟着 playerModel 走
        listenable: Listenable.merge([playlistsModel, playerModel, library]),
        builder: (context, _) {
          final playlist = playlistsModel.byId(widget.playlistId);
          // 歌单被删了会走到这；正常流程删除后直接 pop，一般看不到
          if (playlist == null) {
            return const Center(child: Text('该歌单档案不存在或已被清除'));
          }
          return ListView.builder(
            itemCount: playlist.tracks.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return _Header(playlist: playlist);
              return _TrackRow(playlist: playlist, index: index - 1);
            },
          );
        },
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.playlist});

  final Playlist playlist;

  /// 把歌单里所有歌排进下载队列。已下载的自动跳过，磁盘不够时整批拦下。
  Future<void> _downloadAll(BuildContext context, List<Track> songs) async {
    final result = await downloader.queueAll(songs);
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    if (result.blocked) {
      messenger.showSnackBar(
        SnackBar(content: Text(result.blockedReason!)),
      );
      return;
    }
    if (result.added == 0) {
      messenger.showSnackBar(const SnackBar(content: Text('所有音轨均已归档')));
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '已编入下载队列（${result.added} 首'
          '${result.skipped > 0 ? '，跳过已下载 ${result.skipped} 首' : ''}）',
        ),
        action: SnackBarAction(
          label: '查看队列',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DownloadsPage()),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlaylistCover(
            playlist: playlist,
            size: 132,
            radius: 8,
            onTap: () => showPlaylistCoverSheet(context, playlist.id),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  playlist.name,
                  style: theme.textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  '${playlist.tracks.length} 首',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                // Wrap 而不是 Row：窄窗口塞不下两个按钮时会自动换行
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      // 空歌单没有可播的东西，按钮置灰
                      onPressed: playlist.tracks.isEmpty
                          ? null
                          : () {
                              playerModel.playQueue(playlist.tracks);
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const PlayerPage(),
                                ),
                              );
                            },
                      icon: const Icon(Icons.play_arrow),
                      label: Text('播放全部（${playlist.tracks.length}）'),
                    ),
                    // 空歌单置灰；Web 端没有文件下载能力，整体隐藏
                    if (!kIsWeb)
                      OutlinedButton.icon(
                        onPressed: playlist.tracks.isEmpty
                            ? null
                            : () => _downloadAll(context, playlist.tracks),
                        icon: const Icon(Icons.download),
                        label: const Text('归档全部'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.playlist, required this.index});

  final Playlist playlist;
  final int index;

  void _remove() {
    playlistsModel.removeTrack(playlist.id, playlist.tracks[index].cid);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = playlist.tracks[index];
    final isCurrent = playerModel.current?.cid == track.cid;
    final playing = isCurrent && playerModel.playing;

    return ListTile(
      selected: isCurrent,
      leading: SizedBox(
        width: 28,
        child: Center(
          child: isCurrent
              ? Icon(playing ? Icons.volume_up : Icons.pause, size: 20)
              : Text(
                  '${index + 1}',
                  style: theme.textTheme.bodyMedium,
                ),
        ),
      ),
      title: Text(
        track.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          library.albumNameOf(track.albumCid),
          if (track.artists.isNotEmpty) track.artists.join(' / '),
        ].where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        onPressed: _remove,
        icon: const Icon(Icons.close),
        iconSize: 20,
        tooltip: '移出歌单',
      ),
      onTap: () => playerModel.playQueue(playlist.tracks, start: index),
    );
  }
}
