import 'package:material_ui/material_ui.dart';

import '../bili_models.dart';
import 'cover_image.dart';

/// B站视频列表里的一行。
///
/// 没用 ListTile：那个的 leading 高度被压在 56 左右，放 16:9 缩略图会
/// 挤成一条。自己写一行 Row，缩略图 112×63，和 B站网页的比例一致。
class BiliVideoTile extends StatelessWidget {
  const BiliVideoTile({
    super.key,
    required this.video,
    required this.onTap,
    this.onAddToPlaylist,
    this.onWatch,
    this.trailing,
    this.showAuthor = true,
  });

  final BiliVideo video;
  final VoidCallback onTap;

  /// 传了就显示「加入歌单」按钮
  final VoidCallback? onAddToPlaylist;

  /// 传了缩略图就变成「看视频」的入口 —— 点画面看视频、点文字听声音，
  /// 这个分工跟视频网站一致，不用额外解释
  final VoidCallback? onWatch;
  final Widget? trailing;
  final bool showAuthor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = <String>[
      if (video.play > 0) '${formatBiliCount(video.play)} 播放',
      if (video.durationMs > 0) _duration(video.durationMs),
    ].join(' · ');

    Widget thumb = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 112,
        height: 63,
        child: CoverImage(url: video.cover),
      ),
    );

    final watch = onWatch;
    if (watch != null) {
      thumb = Stack(
        children: [
          thumb,
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: watch,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: Container(
                    margin: const EdgeInsets.all(4),
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(
                      Icons.smart_display,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 8, onAddToPlaylist != null ? 0 : 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            thumb,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    showAuthor && video.author.isNotEmpty
                        ? '${video.author} · $meta'
                        : meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onAddToPlaylist != null)
              IconButton(
                onPressed: onAddToPlaylist,
                icon: const Icon(Icons.playlist_add),
                tooltip: '编入歌单',
              ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 毫秒 → `13:36` / `1:02:03`
String _duration(int ms) {
  final total = ms ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
