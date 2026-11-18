import 'package:material_ui/material_ui.dart';

import '../library.dart';
import '../pages/player_page.dart';
import '../player_model.dart';
import 'cover_image.dart';

/// 底部常驻的迷你播放条。
///
/// 用法：放在 Scaffold 的 bottomNavigationBar 位置。没在播任何东西时
/// 返回零尺寸，自动消失，不用外面再判断。
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 同时订阅播放器和专辑缓存：
    // 冷启动时队列先从本地恢复，专辑列表晚一步到，封面要能自己补上
    return ListenableBuilder(
      listenable: Listenable.merge([playerModel, library]),
      builder: (context, _) {
        final track = playerModel.current;
        if (track == null) return const SizedBox.shrink();

        final artistes = track.artists.isEmpty ? '' : track.artists.join(' / ');

        return Material(
          color: scheme.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部一条细进度，比塞一个进度条更省地方
                LinearProgressIndicator(
                  value: playerModel.progress,
                  minHeight: 2,
                ),
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PlayerPage(),
                    ),
                  ),
                  child: SizedBox(
                    height: 62,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 62,
                          height: 62,
                          child: CoverImage(
                            url: library.coverOfTrack(track),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                artistes,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: playerModel.previous,
                          icon: const Icon(Icons.skip_previous),
                          tooltip: '上一首',
                        ),
                        if (playerModel.loading)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        else if (playerModel.error != null)
                          // 加载失败必须在这里看得见 —— 以前错误只显示在
                          // 播放页里，首页上看起来就是「点了没反应」。
                          IconButton(
                            onPressed: () {
                              final messenger = ScaffoldMessenger.of(context);
                              messenger.hideCurrentSnackBar();
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(playerModel.error ?? '音轨部署失败'),
                                  duration: const Duration(seconds: 6),
                                ),
                              );
                            },
                            icon: Icon(
                              Icons.error_outline,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            tooltip: '音轨部署失败，点看详情',
                          )
                        else
                          IconButton(
                            onPressed: playerModel.toggle,
                            icon: Icon(
                              playerModel.playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                            ),
                            tooltip: playerModel.playing ? '暂停' : '播放',
                          ),
                        IconButton(
                          onPressed: playerModel.next,
                          icon: const Icon(Icons.skip_next),
                          tooltip: '下一首',
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
