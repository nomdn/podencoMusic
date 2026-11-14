import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../downloader.dart';
import '../models.dart';
import '../player_model.dart';
import '../siren_api.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/cover_image.dart';
import '../widgets/download_button.dart';
import '../widgets/error_view.dart';
import '../widgets/mini_player.dart';
import 'downloads_page.dart';
import 'player_page.dart';

/// 专辑详情：封面 + 简介 + 曲目列表。
class AlbumPage extends StatefulWidget {
  const AlbumPage({super.key, required this.album});

  /// 从首页点进来时已经拿到 Album 了，先拿它把标题和封面画出来，
  /// 详情接口还在路上时页面不会是一片空白。
  final Album album;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  late Future<AlbumDetail> _request = SirenApi.albumDetail(widget.album.cid);

  void _reload() {
    setState(() => _request = SirenApi.albumDetail(widget.album.cid));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.album.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: FutureBuilder<AlbumDetail>(
        future: _request,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: '${snapshot.error}',
              onRetry: _reload,
            );
          }
          return _AlbumBody(detail: snapshot.data!);
        },
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }
}

class _AlbumBody extends StatelessWidget {
  const _AlbumBody({required this.detail});

  final AlbumDetail detail;

  @override
  Widget build(BuildContext context) {
    // 整页订阅播放器状态：这样「正在播的是哪首」的高亮会自动跟着变
    return ListenableBuilder(
      listenable: playerModel,
      builder: (context, _) {
        return ListView.builder(
          // 第 0 项是头部，后面才是曲目
          itemCount: detail.songs.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return _Header(detail: detail);

            final track = detail.songs[index - 1];
            final isCurrent = playerModel.current?.cid == track.cid;
            final playing = isCurrent && playerModel.playing;

            return ListTile(
              selected: isCurrent,
              leading: SizedBox(
                width: 28,
                child: Center(
                  child: isCurrent
                      ? Icon(
                          playing ? Icons.volume_up : Icons.pause,
                          size: 20,
                        )
                      : Text(
                          '$index',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                ),
              ),
              title: Text(
                track.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: track.artists.isEmpty
                  ? null
                  : Text(
                      track.artists.join(' / '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: DownloadButton(track: track, iconSize: 18),
              // 点哪首就从哪首开始，后面的歌自动进队列
              onTap: () => playerModel.playQueue(
                detail.songs,
                start: index - 1,
              ),
              onLongPress: () => showAddToPlaylistSheet(context, [track]),
            );
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.detail});

  final AlbumDetail detail;

  /// 整张专辑排进下载队列。已下载的会自动跳过，磁盘不够时整批拦下，
  /// 提示都从返回的 QueueResult 来。
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
      messenger.showSnackBar(const SnackBar(content: Text('都已经下载过了')));
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '已加入下载队列（${result.added} 首'
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
    final artistes = detail.songs.isNotEmpty
        ? detail.songs.first.artists.join(' / ')
        : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 132,
                  height: 132,
                  child: CoverImage(url: detail.coverUrl),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.name,
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    if (artistes.isNotEmpty)
                      Text(
                        artistes,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 16),
                    // Wrap 而不是 Row：窄窗口塞不下三个按钮时会自动换行
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () {
                            playerModel.playQueue(detail.songs);
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const PlayerPage(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.play_arrow),
                          label: Text('播放全部（${detail.songs.length}）'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () =>
                              showAddToPlaylistSheet(context, detail.songs),
                          icon: const Icon(Icons.playlist_add),
                          label: const Text('加入歌单'),
                        ),
                        // Web 端没有文件下载能力，按钮整体隐藏
                        if (!kIsWeb)
                          OutlinedButton.icon(
                            onPressed: () => _downloadAll(context, detail.songs),
                            icon: const Icon(Icons.download),
                            label: const Text('下载全部'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (detail.intro.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              detail.intro,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
