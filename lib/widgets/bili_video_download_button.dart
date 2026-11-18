import 'package:material_ui/material_ui.dart';

import '../bili_video_download.dart';

/// 视频下载按钮：显示当前下载状态 / 进度，点一下开始，进行中可取消。
///
/// 画质策略全在 [BiliVideoDownloader] 里（桌面有 ffmpeg 就 4K，否则
/// 720P），这里只负责展示结果和把错误说清楚。
class BiliVideoDownloadButton extends StatefulWidget {
  const BiliVideoDownloadButton({
    super.key,
    required this.bvid,
    this.title = '',
    this.author = '',
  });

  final String bvid;
  final String title;
  final String author;

  @override
  State<BiliVideoDownloadButton> createState() =>
      _BiliVideoDownloadButtonState();
}

class _BiliVideoDownloadButtonState extends State<BiliVideoDownloadButton> {
  Future<void> _download() async {
    final path = await biliVideoDownloader.download(
      widget.bvid,
      title: widget.title,
      author: widget.author,
    );
    if (!mounted) return;
    final state = biliVideoDownloader.stateOf(widget.bvid);
    final messenger = ScaffoldMessenger.of(context);
    if (path != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('视频已归档（${state.qualityLabel}）：$path'),
          duration: const Duration(seconds: 5),
        ),
      );
    } else if (state.error != null) {
      messenger.showSnackBar(SnackBar(content: Text(state.error!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: biliVideoDownloader,
      builder: (context, _) {
        final state = biliVideoDownloader.stateOf(widget.bvid);
        final running = state.status == BiliVideoDownloadStatus.running;

        if (running) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    value: state.progress > 0 ? state.progress : null,
                    strokeWidth: 2,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '视频归档中 ${(state.progress * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => biliVideoDownloader.cancel(widget.bvid),
                  child: const Text('取消'),
                ),
              ],
            ),
          );
        }

        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _download,
            icon: const Icon(Icons.video_file_outlined, size: 18),
            label: Text(
              state.status == BiliVideoDownloadStatus.done
                  ? '重新下载视频（上次 ${state.qualityLabel}）'
                  : '下载视频',
            ),
          ),
        );
      },
    );
  }
}
