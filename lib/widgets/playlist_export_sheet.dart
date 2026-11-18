import 'package:material_ui/material_ui.dart';

import '../models.dart';
import '../playlist_export.dart';
import '../playlist_file.dart';

/// 「导出歌单」：选格式 → 写文件 → 报结果。
///
/// 两种格式对应两种用途，弹层里把差别写清楚，不让人猜：
///   JSON  —— 完整备份，歌名/艺人/专辑 cid 都在，将来能再导回来
///   M3U8  —— 通用播放列表，每首带一条塞壬页面链接，别的播放器能读
Future<void> showPlaylistExportSheet(
  BuildContext context,
  Playlist playlist,
) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final empty = playlist.tracks.isEmpty;

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '导出档案「${playlist.name}」· ${playlist.tracks.length} 首',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (empty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Text('该歌单尚无音轨，先收录几首再导出'),
              ),
            ListTile(
              enabled: !empty,
              leading: const Icon(Icons.data_object),
              title: const Text('JSON 备份'),
              subtitle: const Text('完整档案，含 cid 与专辑，可作备份'),
              onTap: () => _run(sheetContext, playlist, PlaylistFormat.json),
            ),
            ListTile(
              enabled: !empty,
              leading: const Icon(Icons.queue_music),
              title: const Text('M3U 播放列表'),
              subtitle: const Text('通用格式，每首附一条塞壬页面链接'),
              onTap: () => _run(sheetContext, playlist, PlaylistFormat.m3u),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

Future<void> _run(
  BuildContext sheetContext,
  Playlist playlist,
  PlaylistFormat format,
) async {
  // 先关弹层再干活：写文件在 Android 上要跳一次 MediaStore，弹层挂着很别扭
  final messenger = ScaffoldMessenger.of(sheetContext);
  Navigator.of(sheetContext).pop();

  try {
    final result = await exportPlaylist(playlist, format);
    messenger.hideCurrentSnackBar();

    if (result.copiedToClipboard) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('已复制 ${result.trackCount} 首到剪贴板，粘贴到任意文本即可'),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text('已导出 ${result.trackCount} 首 → ${result.path}'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: '打开文件夹',
          onPressed: () => openExportFolder(),
        ),
      ),
    );
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
  }
}
