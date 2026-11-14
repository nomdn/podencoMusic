import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../downloader.dart';
import '../models.dart';
import '../music_store.dart';

/// 单曲下载按钮。四种状态：未下载 / 排队（时钟）/ 下载中（进度环）/ 已下载（对勾）。
class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key, required this.track, this.iconSize = 20});

  final Track track;
  final double iconSize;

  bool get _canOpenFolder =>
      MusicStore.isSupported ||
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: downloader,
      builder: (context, _) {
        final state = downloader.stateOf(track.cid);

        if (state.isRunning) {
          return SizedBox(
            width: iconSize + 16,
            height: iconSize + 16,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  // progress 为 0 说明服务端没给 Content-Length，转成不确定进度
                  value: state.progress > 0 ? state.progress : null,
                  strokeWidth: 2,
                ),
              ),
            ),
          );
        }

        final done = state.isDone || downloader.isDownloaded(track);
        final queued = state.isQueued;

        return IconButton(
          // 排队中的歌点了没反应（download 会拒绝重入），干脆禁用
          onPressed: queued ? null : () => _start(context),
          iconSize: iconSize,
          icon: Icon(
            done
                ? Icons.download_done
                : queued
                    ? Icons.schedule
                    : Icons.download_outlined,
          ),
          color: done ? scheme.primary : null,
          tooltip: done
              ? '已在本地'
              : queued
                  ? '排队中'
                  : '下载',
        );
      },
    );
  }

  Future<void> _start(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);

    // 已经下过了，点一下就只是把路径再报一遍
    if (downloader.stateOf(track.cid).isDone) {
      final path = downloader.stateOf(track.cid).path;
      _toastSaved(messenger, path ?? '');
      return;
    }

    final path = await downloader.download(track);
    if (path == null) {
      final error = downloader.stateOf(track.cid).error ?? '下载失败';
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    _toastSaved(messenger, path);
  }

  void _toastSaved(ScaffoldMessengerState messenger, String path) {
    // 安卓返回的是 content:// URI，直接甩给用户看不懂，换成说明性文案
    final isContentUri = path.startsWith('content://');
    final message = isContentUri
        ? '已保存到系统音乐库 · Music/PodencoMusic'
        : '已保存：$path';

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        action: _canOpenFolder
            ? SnackBarAction(
                label: '打开文件夹',
                onPressed: () => downloader.openFolder(),
              )
            : null,
      ),
    );
  }
}
