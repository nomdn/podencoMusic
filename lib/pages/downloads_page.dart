import 'package:material_ui/material_ui.dart';

import '../downloader.dart';
import '../library.dart';
import '../models.dart';
import '../widgets/cover_image.dart';
import '../widgets/mini_player.dart';

/// 下载管理页：正在下载 / 排队中 / 已完成 / 失败，四个区按顺序排。
/// 数据全在 downloader 单例里，ListenableBuilder 订阅就行。
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  void _openFolder(BuildContext context) async {
    final ok = await downloader.openFolder();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已交给系统打开' : '没有找到能打开文件夹的应用'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          ListenableBuilder(
            listenable: downloader,
            builder: (context, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (downloader.pendingTracks.isNotEmpty)
                    IconButton(
                      onPressed: () => downloader.clearQueue(),
                      icon: const Icon(Icons.clear_all),
                      tooltip: '清空队列',
                    ),
                  IconButton(
                    onPressed: () => _openFolder(context),
                    icon: const Icon(Icons.folder_open),
                    tooltip: '打开文件夹',
                  ),
                ],
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([downloader, library]),
        builder: (context, _) {
          // 正在下载直接从状态表推导 —— 单曲直下的任务也要显示，
          // 之前只看队列的 activeTrack，单曲下载时页面永远是空的
          final running = downloader.runningTracks;
          final pending = downloader.pendingTracks;
          final done = downloader.doneTracks;
          final failed = downloader.failedTracks;

          if (running.isEmpty && pending.isEmpty && done.isEmpty && failed.isEmpty) {
            return Center(
              child: Text(
                '没有下载任务',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              if (running.isNotEmpty) ...[
                _SectionTitle(
                  running.length > 1 ? '正在下载 · ${running.length}' : '正在下载',
                ),
                for (final track in running) _ActiveCard(track: track),
              ],
              if (pending.isNotEmpty) ...[
                _SectionTitle('排队中 · ${pending.length}'),
                for (final track in pending)
                  _PendingRow(key: ValueKey('pending-${track.cid}'), track: track),
              ],
              if (failed.isNotEmpty) ...[
                _SectionTitle('失败 · ${failed.length}'),
                for (final track in failed)
                  _FailedRow(key: ValueKey('failed-${track.cid}'), track: track),
              ],
              if (done.isNotEmpty) ...[
                _SectionTitle('已完成 · ${done.length}'),
                for (final track in done)
                  _DoneRow(key: ValueKey('done-${track.cid}'), track: track),
              ],
            ],
          );
        },
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }
}

/// 区块小标题，样式抄搜索页的。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// 行首封面。跟列表页的 48×48 规格保持一致。
class _Thumb extends StatelessWidget {
  const _Thumb({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CoverImage(url: library.coverOf(track.albumCid)),
      ),
    );
  }
}

class _ActiveCard extends StatelessWidget {
  const _ActiveCard({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListenableBuilder(
          listenable: downloader,
          builder: (context, _) {
            final state = downloader.stateOf(track.cid);
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: CoverImage(url: library.coverOf(track.albumCid)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          track.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      Text(
                        state.progress > 0
                            ? '${(state.progress * 100).round()}%'
                            : '准备中',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        onPressed: () => downloader.cancel(track.cid),
                        icon: const Icon(Icons.close),
                        iconSize: 20,
                        tooltip: '取消下载',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: state.progress > 0 ? state.progress : null,
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 排队中的一行。加 ValueKey 让取消移除时动画/状态对得上号。
class _PendingRow extends StatelessWidget {
  const _PendingRow({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _Thumb(track: track),
      title: Text(
        track.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        library.albumNameOf(track.albumCid),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        onPressed: () => downloader.cancel(track.cid),
        icon: const Icon(Icons.close),
        iconSize: 20,
        tooltip: '移出队列',
      ),
    );
  }
}

class _FailedRow extends StatelessWidget {
  const _FailedRow({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = downloader.stateOf(track.cid).error ?? '下载失败';

    return ListTile(
      leading: _Thumb(track: track),
      title: Text(
        track.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        error,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.error),
      ),
      trailing: IconButton(
        onPressed: () => downloader.download(track),
        icon: const Icon(Icons.refresh),
        tooltip: '重试',
      ),
    );
  }
}

class _DoneRow extends StatelessWidget {
  const _DoneRow({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = downloader.stateOf(track.cid).path ?? '';

    return ListTile(
      leading: _Thumb(track: track),
      title: Text(
        track.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        path.startsWith('content://') ? '已存入系统音乐库' : path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
