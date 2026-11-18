import 'package:material_ui/material_ui.dart';

import '../library.dart';
import '../models.dart';
import '../playlist_model.dart';
import 'cover_image.dart';
import 'playlist_dialogs.dart';

/// 「把歌加进歌单」的底部弹层。支持单曲也支持整张专辑 ——
/// [tracks] 传一首就是单曲加歌（长按曲目、播放页按钮），
/// 传整张就是批量（专辑详情页的「加入歌单」）。
///
/// 勾选语义按「整个歌单是否已包含全部曲目」：没加全 = 点一下补齐
/// 缺的；已加全 = 点一下全部移出。弹层开着可以操作多个歌单，
/// 加完想退出就点遮罩或下拉关掉，不用多做「完成」按钮。
Future<void> showAddToPlaylistSheet(BuildContext context, List<Track> tracks) {
  assert(tracks.isNotEmpty);
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      return ListenableBuilder(
        listenable: playlistsModel,
        builder: (context, _) {
          final playlists = playlistsModel.playlists;
          final title = tracks.length == 1
              ? '加入歌单 · ${tracks.first.name}'
              : '加入歌单 · ${tracks.length} 首';

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 4),
                    children: [
                      if (playlists.isEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: Text('还没有歌单，在下面建一个吧'),
                        ),
                      for (final playlist in playlists)
                        _SheetRow(playlist: playlist, tracks: tracks),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text(
                    tracks.length == 1 ? '新建歌单并加入' : '新建歌单并加入整张',
                  ),
                  onTap: () => _createAndAdd(sheetContext, tracks),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

/// 弹层里的一行歌单：封面 + 名字 + N 首 + 勾选态。
class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.playlist, required this.tracks});

  final Playlist playlist;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contained = tracks
        .where((t) => playlistsModel.containsTrack(playlist.id, t.cid))
        .length;
    final allIn = contained == tracks.length;
    final coverUrl = playlist.tracks.isEmpty
        ? ''
        : library.coverOfTrack(playlist.tracks.first);

    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: coverUrl.isEmpty
              ? ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.library_music,
                    size: 20,
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
      subtitle: Text(
        contained == 0 || allIn
            ? '${playlist.tracks.length} 首'
            : '${playlist.tracks.length} 首（已有 $contained/${tracks.length}）',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: allIn
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : null,
      onTap: () {
        // 加了再点一遍 = 整批移出，配合勾选图标就是标准的选单交互
        if (allIn) {
          playlistsModel.removeTracks(
            playlist.id,
            tracks.map((t) => t.cid).toList(),
          );
        } else {
          final missing = tracks
              .where((t) => !playlistsModel.containsTrack(playlist.id, t.cid))
              .toList();
          playlistsModel.addTracks(playlist.id, missing);
        }
      },
    );
  }
}

Future<void> _createAndAdd(BuildContext sheetContext, List<Track> tracks) async {
  final name = await showPlaylistNameDialog(
    sheetContext,
    title: '新建歌单',
    actionLabel: '创建',
  );
  if (name == null || name.trim().isEmpty) return;

  final playlist = playlistsModel.create(name);
  playlistsModel.addTracks(playlist.id, tracks);

  // 一条龙做完就收摊。sheetContext 是弹层的 context，
  // 在它 pop 自己之前一直有效（对话框已经先关了）。
  // 弹层可能在这期间被点遮罩关掉，所以先查 mounted。
  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
}
