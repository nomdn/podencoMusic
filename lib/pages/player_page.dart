import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../library.dart';
import '../models.dart';
import '../player_model.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/cover_image.dart';
import '../widgets/download_button.dart';
import '../widgets/volume_button.dart';

/// 播放页。宽屏左右分栏（左封面右歌词），窄屏上下堆叠。
///
/// 整页订阅 playerModel：进度、高亮歌词、按钮状态全靠它，
/// 所以这里用 ListenableBuilder 把整棵树包起来，简单直接。
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: playerModel,
      builder: (context, _) {
        final track = playerModel.current;

        if (track == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('正在播放')),
            body: const Center(child: Text('还没有在播的歌曲')),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(
              library.albumNameOf(track.albumCid).isEmpty
                  ? '正在播放'
                  : library.albumNameOf(track.albumCid),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                onPressed: () => showAddToPlaylistSheet(context, [track]),
                icon: const Icon(Icons.playlist_add),
                tooltip: '加入歌单',
              ),
              DownloadButton(track: track),
              const SizedBox(width: 8),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, box) {
              // 800 是 M3 官方的「展开宽度」断点，跟平板/桌面分栏对得上
              final wide = box.maxWidth >= 800;
              return wide ? _wide(context, track) : _narrow(context, track);
            },
          ),
        );
      },
    );
  }

  Widget _wide(BuildContext context, Track track) {
    return LayoutBuilder(
      builder: (context, box) {
        // 封面尺寸按「可用高度」算，不写死：
        // 横屏（高 600 左右）时左栏塞不下 360 见方的封面，
        // 写死会把标题和控制条顶出屏幕，底部就出现黄黑报错条。
        // 230 是歌名区 + 控制条 + 间距的大致高度。
        final available = box.maxHeight - 56; // 上下各 28 的内边距
        final cover = math.min(math.max(available - 230, 0.0), 360.0);

        return Padding(
          padding: const EdgeInsets.all(28),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 360,
                child: Column(
                  children: [
                    SizedBox.square(
                      dimension: cover,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CoverImage(
                          url: library.coverOf(track.albumCid),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _TrackInfo(track: track),
                    // Spacer 会把剩下的高度全吃掉，控制条才能贴住底边
                    const Spacer(),
                    // 注意这里不能加 const：_Controls 整棵子树直接读
                    // playerModel 的状态，加了 const 就永远不会重建 ——
                    // 进度条冻结、按钮不翻面就是它（迷你条没这问题）。
                    _Controls(),
                  ],
                ),
              ),
              const SizedBox(width: 32),
              Expanded(child: _LyricsPanel()),
            ],
          ),
        );
      },
    );
  }

  Widget _narrow(BuildContext context, Track track) {
    return LayoutBuilder(
      builder: (context, box) {
        // 同上：封面只吃「可用高度减掉固定部分」剩下的量，
        // 不用 MediaQuery.height —— 那是整块屏幕（含 AppBar），算出来偏大，
        // 矮窗时反而会把控制条挤出屏幕。
        final cover = math.min(math.max(box.maxHeight - 230, 0.0), 320.0);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 12),
              SizedBox.square(
                dimension: cover,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CoverImage(url: library.coverOf(track.albumCid)),
                ),
              ),
              const SizedBox(height: 16),
              _TrackInfo(track: track),
              const SizedBox(height: 8),
              // Expanded 吃掉剩余高度，歌词区不会在底部留空
              Expanded(child: _LyricsPanel()),
              // 同上，不能加 const —— 加了整个控制区都不会刷新
              _Controls(),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// 标题 + 艺人 + 出错提示。
class _TrackInfo extends StatelessWidget {
  const _TrackInfo({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = playerModel.error;

    return Column(
      children: [
        Text(
          track.name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(
          track.artists.isEmpty ? '未知艺人' : track.artists.join(' / '),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(
            error,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

/// 进度条 + 时间 + 上一首/播放/下一首。
class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 这两处同理不能加 const：_ProgressBar/_ModeButton 的 State
        // 直接读 playerModel，const 会让它们在页面打开后永远冻结。
        _ProgressBar(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ModeButton(),
            IconButton(
              onPressed: playerModel.previous,
              icon: const Icon(Icons.skip_previous),
              iconSize: 34,
              tooltip: '上一首',
            ),
            const SizedBox(width: 8),
            // 主播放键用填充圆钮，视觉上应该是整页最重的元素
            if (playerModel.loading)
              const SizedBox(
                width: 64,
                height: 64,
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            else
              IconButton.filled(
                onPressed: playerModel.toggle,
                iconSize: 34,
                padding: const EdgeInsets.all(14),
                style: IconButton.styleFrom(backgroundColor: scheme.primary),
                icon: Icon(
                  playerModel.playing ? Icons.pause : Icons.play_arrow,
                  color: scheme.onPrimary,
                ),
              ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: playerModel.next,
              icon: const Icon(Icons.skip_next),
              iconSize: 34,
              tooltip: '下一首',
            ),
            const VolumeButton(),
          ],
        ),
      ],
    );
  }
}

/// 进度条。拖动时需要临时接管数值，松手才真正 seek，
/// 否则播放进度会跟手指抢着改 value，滑块会跳。
class _ProgressBar extends StatefulWidget {
  const _ProgressBar();

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = playerModel.duration.inMilliseconds;
    // Slider 的 max 必须大于 0，音频还没加载完时给个 1 兜住
    final max = total > 0 ? total.toDouble() : 1.0;
    final value = (_dragValue ?? playerModel.position.inMilliseconds.toDouble())
        .clamp(0.0, max);

    final current = Duration(milliseconds: value.round());

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Slider(
          value: value,
          max: max,
          onChanged: total > 0
              ? (v) => setState(() => _dragValue = v)
              : null,
          onChangeEnd: (v) {
            playerModel.seek(Duration(milliseconds: v.round()));
            setState(() => _dragValue = null);
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_format(current), style: theme.textTheme.bodySmall),
              Text(_format(playerModel.duration), style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

/// 歌词面板：固定行高，靠 ScrollController 把当前行滚到中间。
class _LyricsPanel extends StatefulWidget {
  const _LyricsPanel();

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  final _controller = ScrollController();

  /// 固定行高让滚动位置可以精确算出来，不用去问渲染树每行多高
  static const _lineHeight = 44.0;

  /// 上一次滚到的行号。切歌时要重置，所以放在 State 里而不是 widget 属性里。
  int _lastIndex = -1;

  @override
  void initState() {
    super.initState();
    _followLyric();
  }

  @override
  void didUpdateWidget(covariant _LyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _followLyric();
  }

  /// 当前行变了就滚过去。
  /// didUpdateWidget 跑在 build 之前，所以滚动得推到这一帧布局完成之后，
  /// 否则 maxScrollExtent 还是旧值，滚不到正确位置。
  void _followLyric() {
    final index = playerModel.lyricIndex;
    if (index == _lastIndex) return;
    _lastIndex = index;
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollTo(index);
    });
  }

  void _scrollTo(int index) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (index * _lineHeight).clamp(0.0, position.maxScrollExtent);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = playerModel.lyrics;
    final theme = Theme.of(context);

    if (lines.isEmpty) {
      return Center(
        child: Text(
          '暂无歌词',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final active = playerModel.lyricIndex;

    return LayoutBuilder(
      builder: (context, box) {
        // 上下各留半屏，第一行和最后一行才可能滚到正中间
        final pad = ((box.maxHeight - _lineHeight) / 2).clamp(0.0, 400.0);

        return ListView.builder(
          controller: _controller,
          itemExtent: _lineHeight,
          padding: EdgeInsets.symmetric(vertical: pad),
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final isActive = index == active;
            return Center(
              child: Text(
                lines[index].text,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: isActive ? 17 : 14,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 播放模式按钮。点一下换一种：列表循环 → 单曲循环 → 随机 → 回到列表循环。
class _ModeButton extends StatelessWidget {
  const _ModeButton();

  @override
  Widget build(BuildContext context) {
    final mode = playerModel.mode;

    // 用 if/else 而不是 switch 表达式，读起来更直白
    final IconData icon;
    final String label;
    if (mode == PlayMode.listLoop) {
      icon = Icons.repeat;
      label = '列表循环';
    } else if (mode == PlayMode.singleLoop) {
      icon = Icons.repeat_one;
      label = '单曲循环';
    } else {
      icon = Icons.shuffle;
      label = '随机播放';
    }

    return IconButton(
      onPressed: playerModel.cycleMode,
      icon: Icon(icon),
      tooltip: label,
      // 非默认模式用主色标出来，否则三个图标长得太像，看不出当前是哪个
      color: mode == PlayMode.listLoop
          ? null
          : Theme.of(context).colorScheme.primary,
    );
  }
}

/// mm:ss
String _format(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
