import 'package:material_ui/material_ui.dart';

import '../history_model.dart';
import '../library.dart';
import '../player_model.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/cover_image.dart';
import '../widgets/mini_player.dart';

/// 播放历史：最近播过的歌，最新的在最上面。
/// 点哪首就从哪首开始播，队列就是整份历史。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('清空播放历史'),
          content: const Text('历史只是个记录，删除不影响歌曲和歌单。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('清空'),
            ),
          ],
        );
      },
    );
    if (confirmed ?? false) historyModel.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放历史'),
        actions: [
          ListenableBuilder(
            listenable: historyModel,
            builder: (context, _) {
              if (historyModel.tracks.isEmpty) {
                return const SizedBox.shrink();
              }
              return IconButton(
                onPressed: _clear,
                icon: const Icon(Icons.delete_sweep),
                tooltip: '清空历史',
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        // 封面走 library 反查：冷启动直接进这页时专辑列表可能还没到
        listenable: Listenable.merge([historyModel, library]),
        builder: (context, _) {
          final tracks = historyModel.tracks;
          if (tracks.isEmpty) {
            return Center(
              child: Text(
                '还没有播放记录',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return ListTile(
                leading: SizedBox(
                  width: 48,
                  height: 48,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: CoverImage(url: library.coverOf(track.albumCid)),
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
                onTap: () => playerModel.playQueue(tracks, start: index),
                onLongPress: () => showAddToPlaylistSheet(context, [track]),
              );
            },
          );
        },
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }
}
