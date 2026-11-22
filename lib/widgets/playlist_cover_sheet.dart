import 'package:material_ui/material_ui.dart';

import '../cover_pick.dart';
import '../library.dart';
import '../models.dart';
import '../playlist_model.dart';
import 'cover_crop_page.dart';
import 'cover_image.dart';
import 'playlist_cover.dart';

/// 设置歌单封面。传 id 不传对象：跟详情页同理，弹层开着时歌单可能被
/// 别处改过，用 id 现取才是最新状态。
Future<void> showPlaylistCoverSheet(BuildContext context, String playlistId) async {
  if (playlistsModel.byId(playlistId) == null) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CoverSheet(playlistId: playlistId),
  );
}

class _CoverSheet extends StatefulWidget {
  const _CoverSheet({required this.playlistId});

  final String playlistId;

  @override
  State<_CoverSheet> createState() => _CoverSheetState();
}

class _CoverSheetState extends State<_CoverSheet> {
  final _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// 歌单里出现过的专辑封面，按链接去重。空链接跳过 —— 没缓存到的
  /// 封面选了也是占位图，不如不列。
  List<String> _candidateUrls(Playlist playlist) {
    final seen = <String>{};
    final urls = <String>[];
    for (final track in playlist.tracks) {
      final url = library.coverOfTrack(track);
      if (url.isNotEmpty && seen.add(url)) urls.add(url);
    }
    return urls;
  }

  void _setCover(String url) {
    playlistsModel.setCover(widget.playlistId, url);
  }

  void _apply(String url) {
    _setCover(url);
    Navigator.of(context).pop();
  }

  /// 选本地图片 → 裁剪确认 → 才写回封面。任一步取消都不动原封面。
  Future<void> _pickLocal() async {
    final navigator = Navigator.of(context);
    final bytes = await pickCoverBytes().catchError((_) => null);
    if (!mounted || bytes == null) return; // 选图取消

    final uri = await showCoverCropPage(context, bytes);
    if (!mounted || uri == null) return; // 裁剪取消，封面保持原样

    _setCover(uri);
    if (navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playlist = playlistsModel.byId(widget.playlistId);
    if (playlist == null) return const SizedBox.shrink();

    final candidates = _candidateUrls(playlist);

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('设置封面', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '「${playlist.name}」',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: PlaylistCover(playlist: playlist, size: 120, radius: 12),
            ),
            const SizedBox(height: 20),

            FilledButton.icon(
              onPressed: _pickLocal,
              icon: const Icon(Icons.image_outlined),
              label: const Text('从本地选图'),
            ),
            const SizedBox(height: 4),
            Text(
              '图片压到 320px 存进歌单，导出备份也带着走',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),

            if (candidates.isNotEmpty) ...[
              Text('或者用歌单里的专辑封面', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final url in candidates)
                    GestureDetector(
                      onTap: () => _apply(url),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 56,
                          height: 56,
                          child: CoverImage(url: url),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
            ],

            Text('也可以填一张图片链接', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              autofocus: candidates.isEmpty,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'https://example.com/cover.jpg',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) _apply(value);
              },
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                final url = _urlController.text.trim();
                if (url.isEmpty) return;
                _apply(url);
              },
              icon: const Icon(Icons.check),
              label: const Text('使用这个链接'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _apply(''),
              icon: const Icon(Icons.restore),
              label: const Text('恢复默认封面'),
            ),
          ],
        ),
      ),
    );
  }
}
