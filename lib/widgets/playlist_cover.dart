import 'package:material_ui/material_ui.dart';

import '../library.dart';
import '../models.dart';
import 'cover_image.dart';

/// 歌单封面。两处显示口径必须一致：优先用户自己设的链接，
/// 没设过才回退到第一首歌的专辑封面，空歌单给占位图标。
///
/// 传 [onTap] 时右下角挂个编辑角标（详情页点封面换图用）；
/// 不传就是纯展示（列表页）。
class PlaylistCover extends StatelessWidget {
  const PlaylistCover({
    super.key,
    required this.playlist,
    this.size = 48,
    this.radius = 4,
    this.onTap,
  });

  final Playlist playlist;
  final double size;
  final double radius;
  final VoidCallback? onTap;

  /// 当前实际生效的封面链接，封面对话框的预览也用它。
  static String urlOf(Playlist playlist) {
    if (playlist.coverUrl.isNotEmpty) return playlist.coverUrl;
    if (playlist.tracks.isEmpty) return '';
    return library.coverOfTrack(playlist.tracks.first);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = urlOf(playlist);

    Widget cover = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.library_music,
                  size: size * 0.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : CoverImage(url: url),
      ),
    );

    if (onTap == null) return cover;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          cover,
          Positioned(
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(radius),
                    bottomRight: Radius.circular(radius),
                  ),
                ),
                child: Icon(
                  Icons.edit,
                  size: size * 0.28,
                  color: theme.colorScheme.onPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
