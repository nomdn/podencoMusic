import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../bili_api.dart';
import '../bili_models.dart';
import '../favorites_model.dart';
import '../player_model.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/bili_video_tile.dart';
import '../widgets/cover_image.dart';
import '../widgets/download_button.dart';
import '../widgets/error_view.dart';
import '../widgets/favorite_button.dart';
import '../widgets/mini_player.dart';
import 'bili_video_page.dart';

/// UP 主页。
///
/// 视频列表走「搜索接口 + 按 mid 过滤」（原因见 [BiliApi.upVideos]），
/// 所以这里天然带一个站内搜索框 —— 同一个接口，多传一个关键词而已。
class UpPage extends StatefulWidget {
  const UpPage({super.key, required this.up, this.initialVideos});

  final BiliUp up;

  /// 从搜索结果点进来时已经有几条视频了，先拿来占位，省一次白屏
  final List<BiliVideo>? initialVideos;

  @override
  State<UpPage> createState() => _UpPageState();
}

class _UpPageState extends State<UpPage> {
  final _controller = TextEditingController();
  Timer? _debounce;

  String _keyword = '';
  List<BiliVideo> _videos = const [];
  bool _loading = true;
  String? _error;

  /// 连打关键词时会有多个请求在飞，只认最新那次
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialVideos;
    if (initial != null && initial.isNotEmpty) {
      _videos = initial;
      _loading = false;
      // 先显示手上这几条，后台再补全
      unawaited(_load());
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final list = await BiliApi.upVideos(
        widget.up.mid,
        widget.up.name,
        keyword: _keyword,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _videos = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e is BiliException ? e.message : '读取失败：$e';
        _loading = false;
      });
    }
  }

  void _onQueryChanged(String value) {
    final next = value.trim();
    // 让输入框尾巴上的「清空」按钮跟着输入出现 / 消失
    setState(() {});
    _debounce?.cancel();
    // 每敲一个字都请求会一直在「加载中」里闪，停手 400ms 再发
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || next == _keyword) return;
      _keyword = next;
      unawaited(_load());
    });
  }

  void _play(List<BiliVideo> videos, int index) {
    if (videos.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    playerModel.playQueue(
      videos.map((video) => video.toTrack()).toList(),
      start: index,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.up.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          FavoriteButton(item: favoriteOfUp(widget.up)),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _UpHeader(up: widget.up),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              onSubmitted: (value) {
                _debounce?.cancel();
                final next = value.trim();
                if (next == _keyword) return;
                _keyword = next;
                unawaited(_load());
              },
              decoration: InputDecoration(
                hintText: '在 ${widget.up.name} 的影像中检索',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _controller.clear();
                          _debounce?.cancel();
                          if (_keyword.isEmpty) {
                            setState(() {});
                            return;
                          }
                          _keyword = '';
                          setState(() {});
                          unawaited(_load());
                        },
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  _loading && _videos.isEmpty
                      ? '正在找这个 UP 主的视频…'
                      : _keyword.isEmpty
                      ? '共 ${_videos.length} 个视频'
                      : '找到 ${_videos.length} 个「$_keyword」相关视频',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (_videos.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _play(_videos, 0),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('播放全部'),
                  ),
              ],
            ),
          ),
          if (_loading && _videos.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body()),
        ],
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }

  Widget _body() {
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _load);
    }
    if (_loading && _videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_videos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _keyword.isEmpty
                ? '该 UP 主暂无公开投稿，或接口暂时失联。\n可下拉重试，或改查其他 UP 主。'
                : '在 ${widget.up.name} 的影像里未检索到「$_keyword」。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
        return BiliVideoTile(
          video: video,
          showAuthor: false,
          onTap: () => _play(_videos, index),
          onWatch: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BiliVideoPage(
                  bvid: video.bvid,
                  title: video.title,
                  cover: video.cover,
                ),
              ),
            );
          },
          onAddToPlaylist: () =>
              showAddToPlaylistSheet(context, [video.toTrack()]),
          trailing: DownloadButton(track: video.toTrack(), iconSize: 20),
        );
      },
    );
  }
}

class _UpHeader extends StatelessWidget {
  const _UpHeader({required this.up});

  final BiliUp up;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          ClipOval(
            child: SizedBox(
              width: 56,
              height: 56,
              child: CoverImage(url: up.face),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  up.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                if (up.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    up.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
