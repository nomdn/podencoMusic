import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../bili_api.dart';
import '../bili_models.dart';
import '../bili_store.dart';
import '../favorites_model.dart';
import '../library.dart';
import '../models.dart';
import '../player_model.dart';
import '../siren_api.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/bili_video_tile.dart';
import '../widgets/cover_image.dart';
import '../widgets/download_button.dart';
import '../widgets/error_view.dart';
import '../widgets/favorite_button.dart';
import '../widgets/mini_player.dart';
import 'album_page.dart';
import 'bili_video_page.dart';
import 'up_page.dart';

/// 搜索来源。
///
/// 塞壬是本地过滤（900 多首一次拉完，比任何搜索接口都快），
/// B站是网络搜索，两边结果可以同时出现在一屏里 —— 这正是
/// 「两个源共存」的意思：不需要先选一个才能搜另一个。
enum _Source {
  all('全部'),
  siren('塞壬唱片'),
  bili('B站'),
  up('UP主');

  const _Source(this.label);

  final String label;
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  String _query = '';

  _Source _source = _Source.all;

  /// 首页已经拉过专辑的话这里立刻就好，歌曲可能是第一次拉
  late Future<void> _ready = _prepare();

  // ── B站结果 ──
  List<BiliVideo> _videos = const [];
  List<BiliUp> _ups = const [];
  bool _biliLoading = false;
  String? _biliError;
  int _biliSeq = 0;
  Timer? _debounce;

  // ── B站结果分页 ──
  // 搜索接口一页只给 20 条，往下翻靠 page 参数。不传 page_size：
  // B站经常直接忽略它，用「本页不满 20 条」判断到底更可靠。
  static const _biliPageSize = 20;
  int _biliPage = 1;
  bool _biliHasMore = false;
  bool _biliLoadingMore = false;
  String? _biliMoreError;

  Future<void> _prepare() async {
    // 两个请求同时发出去，再一起等 —— 比一个一个 awaits 快一倍
    final albums = library.ensureAlbums();
    final songs = library.ensureSongs();
    await albums;
    await songs;
  }

  void _retry() {
    setState(() {
      _ready = _prepare();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 当前来源要不要打 B站接口
  bool get _wantsBili =>
      biliModel.enabled &&
      (_source == _Source.all ||
          _source == _Source.bili ||
          _source == _Source.up);

  /// 塞壬结果要不要显示
  bool get _wantsSiren => _source == _Source.all || _source == _Source.siren;

  void _onQueryChanged(String value) {
    final next = value.trim();
    setState(() => _query = next);

    _debounce?.cancel();
    if (next.isEmpty) {
      _biliSeq++; // 作废在飞的请求
      setState(() {
        _videos = const [];
        _ups = const [];
        _biliLoading = false;
        _biliError = null;
        _biliPage = 1;
        _biliHasMore = false;
        _biliLoadingMore = false;
        _biliMoreError = null;
      });
      return;
    }
    if (!_wantsBili) return;

    // 每敲一个字就发请求会一路「加载中」闪过去，停手 450ms 再搜
    _debounce = Timer(const Duration(milliseconds: 450), () {
      unawaited(_runBiliSearch());
    });
  }

  Future<void> _runBiliSearch() async {
    final query = _query;
    if (query.isEmpty || !_wantsBili) return;

    // Web 上没有反代就一定发不出去：浏览器必带 Origin，B站风控必拒。
    // 与其让用户对着「B站返回 412」猜，不如直接告诉他缺什么。
    if (kIsWeb && !BiliApi.proxyEnabled) {
      setState(() {
        _biliLoading = false;
        _biliError =
            '网页端的检索须经「接口反代」中转。'
            '地址可在 设置 → 哔哩哔哩数据源 → 接口反代 中修改。';
      });
      return;
    }

    final seq = ++_biliSeq;
    setState(() {
      _biliLoading = true;
      _biliError = null;
      _biliPage = 1;
      _biliHasMore = false;
      _biliLoadingMore = false;
      _biliMoreError = null;
    });

    try {
      final List<BiliVideo> videos;
      List<BiliUp> ups = const [];

      if (_source == _Source.up) {
        videos = const [];
        ups = await BiliApi.searchUps(query);
      } else {
        videos = await BiliApi.searchVideos(query);
        if (_source == _Source.all) {
          // UP 主搜失败不该拖垮整屏视频结果
          try {
            ups = await BiliApi.searchUps(query);
          } catch (_) {
            ups = const [];
          }
        }
      }

      if (!mounted || seq != _biliSeq) return;
      setState(() {
        _videos = videos;
        _ups = ups;
        _biliLoading = false;
        // UP 主不做翻页：一屏就够看，翻下去也还是那几个人。
        _biliHasMore = _source != _Source.up && videos.length >= _biliPageSize;
      });
    } catch (e) {
      if (!mounted || seq != _biliSeq) return;
      setState(() {
        _biliError = e is BiliException ? e.message : 'B站搜索失败：$e';
        _biliLoading = false;
      });
    }
  }

  /// 取下一页 B站视频，追加到现有结果末尾。
  ///
  /// 这里不递增 _biliSeq：翻页失败不该把已经显示的结果作废。只有搜索词
  /// 或来源变了（那一瞬间 seq 会变）时，回来的数据才该被丢掉。
  Future<void> _loadMoreBili() async {
    if (_biliLoading || _biliLoadingMore || !_biliHasMore) return;
    if (_biliMoreError != null) return;

    final query = _query;
    if (query.isEmpty || !_wantsBili || _source == _Source.up) return;

    final seq = _biliSeq;
    final nextPage = _biliPage + 1;
    setState(() => _biliLoadingMore = true);

    try {
      final batch = await BiliApi.searchVideos(query, page: nextPage);
      if (!mounted || seq != _biliSeq) return;

      // 翻页之间 B站结果会漂移，同一支视频可能重复出现
      final seen = _videos.map((v) => v.bvid).toSet();
      final fresh = batch.where((v) => seen.add(v.bvid)).toList();

      setState(() {
        _biliPage = nextPage;
        _videos = [..._videos, ...fresh];
        // 满一页才说明后面可能还有
        _biliHasMore = batch.length >= _biliPageSize;
        _biliLoadingMore = false;
      });
    } catch (e) {
      if (!mounted || seq != _biliSeq) return;
      setState(() {
        _biliLoadingMore = false;
        _biliMoreError = e is BiliException ? e.message : '加载更多失败：$e';
      });
    }
  }

  void _retryMoreBili() {
    setState(() => _biliMoreError = null);
    unawaited(_loadMoreBili());
  }

  void _setSource(_Source source) {
    if (_source == source) return;
    setState(() => _source = source);
    // 切换来源时，已经有词就立刻按新来源再搜一次
    if (_wantsBili && _query.isNotEmpty) {
      unawaited(_runBiliSearch());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: biliModel,
      builder: (context, _) {
        // 开关被关掉时，正停在 B站 / UP 来源就退回「全部」
        if (!biliModel.enabled && _source != _Source.all) {
          _source = _Source.all;
        }

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              // 键盘上的「搜索」键：塞壬结果是即时过滤的，
              // 按下只需要把键盘收起来（默认行为是毫无反应）
              onSubmitted: (_) {
                _dismissKeyboard();
                if (_wantsBili) unawaited(_runBiliSearch());
              },
              decoration: const InputDecoration(
                hintText: '搜索专辑、歌曲或艺人',
                border: InputBorder.none,
              ),
              onChanged: _onQueryChanged,
            ),
            actions: [
              if (_query.isNotEmpty)
                IconButton(
                  onPressed: () {
                    _controller.clear();
                    _onQueryChanged('');
                  },
                  icon: const Icon(Icons.close),
                  tooltip: '清空',
                ),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              if (biliModel.enabled) _sourceBar(context),
              Expanded(
                child: FutureBuilder<void>(
                  future: _ready,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return ErrorView(
                        message: '${snapshot.error}',
                        onRetry: _retry,
                      );
                    }
                    return _Results(
                      query: _query,
                      source: _source,
                      wantsSiren: _wantsSiren,
                      videos: _videos,
                      ups: _ups,
                      biliLoading: _biliLoading,
                      biliError: _biliError,
                      onRetryBili: _runBiliSearch,
                      biliHasMore: _biliHasMore,
                      biliLoadingMore: _biliLoadingMore,
                      biliMoreError: _biliMoreError,
                      onLoadMoreBili: _loadMoreBili,
                      onRetryMoreBili: _retryMoreBili,
                    );
                  },
                ),
              ),
            ],
          ),
          bottomNavigationBar: const MiniPlayerBar(),
        );
      },
    );
  }

  Widget _sourceBar(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final source in _Source.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(source.label),
                        selected: _source == source,
                        onSelected: (_) => _setSource(source),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!biliModel.loggedIn)
            IconButton(
              tooltip: '未登录B站，部分视频可能搜不到',
              icon: Icon(
                Icons.person_off,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('未登录也能搜，但登录后能少踩一些风控。去设置页登录')),
                );
              },
            ),
        ],
      ),
    );
  }

  /// 收起键盘。搜索页的迷你条挂在 bottomNavigationBar 槽位上，
  /// Scaffold 只让 body 避开键盘、这个槽不避 —— 点了结果不收键盘的话，
  /// 刚出现的迷你条会被键盘整个盖住。
  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }
}

class _Results extends StatelessWidget {
  const _Results({
    required this.query,
    required this.source,
    required this.wantsSiren,
    required this.videos,
    required this.ups,
    required this.biliLoading,
    required this.biliError,
    required this.onRetryBili,
    required this.biliHasMore,
    required this.biliLoadingMore,
    required this.biliMoreError,
    required this.onLoadMoreBili,
    required this.onRetryMoreBili,
  });

  final String query;
  final _Source source;
  final bool wantsSiren;
  final List<BiliVideo> videos;
  final List<BiliUp> ups;
  final bool biliLoading;
  final String? biliError;
  final Future<void> Function() onRetryBili;

  /// 视频结果后面是否还有下一页
  final bool biliHasMore;

  /// 正在取下一页
  final bool biliLoadingMore;

  /// 翻页失败的原因（不影响已显示的结果）
  final String? biliMoreError;

  final Future<void> Function() onLoadMoreBili;
  final VoidCallback onRetryMoreBili;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Center(
        child: Text(
          '输入检索关键词，开始搜索档案',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    final q = query.toLowerCase();

    final albums = wantsSiren
        ? library.albums.where((album) {
            return album.name.toLowerCase().contains(q) ||
                album.artistes.any((a) => a.toLowerCase().contains(q));
          }).toList()
        : <Album>[];

    final tracks = wantsSiren
        ? library.songs.where((track) {
            if (track.name.toLowerCase().contains(q)) return true;
            if (track.artists.any((a) => a.toLowerCase().contains(q))) {
              return true;
            }
            return library
                .albumNameOf(track.albumCid)
                .toLowerCase()
                .contains(q);
          }).toList()
        : <Track>[];

    final nothingSiren = albums.isEmpty && tracks.isEmpty;
    final nothingBili = videos.isEmpty && ups.isEmpty;
    final sirenOnly = source == _Source.siren;

    // 只搜塞壬时，给一个和以前一样的「没找到」提示
    if (sirenOnly && nothingSiren) {
      return Center(child: Text('未检索到「$query」相关的档案'));
    }
    if (!sirenOnly &&
        !biliLoading &&
        biliError == null &&
        nothingSiren &&
        nothingBili) {
      return Center(
        child: Text(
          source == _Source.up ? '未检索到「$query」相关的 UP 主' : '未检索到「$query」相关的档案',
        ),
      );
    }

    // 把标题行和数据行压进一个扁平列表，这样能用 ListView.builder
    // 只渲染可见项 —— 搜单个字母时可能命中几百首，全渲染会卡。
    final entries = <Object>[
      if (albums.isNotEmpty) _SectionTitle('塞壬唱片专辑 · ${albums.length}'),
      ...albums,
      if (tracks.isNotEmpty) _SectionTitle('塞壬唱片歌曲 · ${tracks.length}'),
      ...tracks,
      if (videos.isNotEmpty) _SectionTitle('B站视频 · ${videos.length}'),
      ...videos,
      if (ups.isNotEmpty) _SectionTitle('B站UP主 · ${ups.length}'),
      ...ups,
      if (biliLoading) const _LoadingRow(),
      if (biliError != null)
        _ErrorRow(message: biliError!, onRetry: onRetryBili),
      // 视频翻页状态占一行：还有下一页 / 正在取 / 取失败了
      if (videos.isNotEmpty &&
          (biliHasMore || biliLoadingMore || biliMoreError != null))
        _MoreRow(
          loading: biliLoadingMore,
          error: biliMoreError,
          onLoadMore: onLoadMoreBili,
          onRetry: onRetryMoreBili,
        ),
    ];

    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 快到底时自动取下一页：离底部不足 240 像素就触发，
        // 用户基本感觉不到等待。_loadMoreBili 内部有重入保护。
        if (biliHasMore &&
            !biliLoadingMore &&
            biliMoreError == null &&
            notification.metrics.extentAfter < 240) {
          unawaited(onLoadMoreBili());
        }
        return false;
      },
      child: ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];

          if (entry is _SectionTitle) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                entry.text,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
            );
          }

          if (entry is _LoadingRow) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }

          if (entry is _ErrorRow) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(entry.onRetry()),
                    child: const Text('重新检索'),
                  ),
                ],
              ),
            );
          }

          if (entry is _MoreRow) {
            if (entry.loading) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            if (entry.error != null) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: entry.onRetry,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: TextButton(
                  onPressed: () => unawaited(entry.onLoadMore()),
                  child: const Text('加载更多'),
                ),
              ),
            );
          }

          if (entry is Album) {
            return ListTile(
              leading: SizedBox(
                width: 48,
                height: 48,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CoverImage(url: entry.coverUrl),
                ),
              ),
              title: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                entry.artistes.join(' / '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 搜索结果里就能整张加入歌单，不用先点进去。
                  // 曲目要现拉详情接口，所以点下去会有一两秒等待
                  IconButton(
                    onPressed: () => _addAlbumToPlaylist(context, entry),
                    icon: const Icon(Icons.playlist_add),
                    tooltip: '整张加入歌单',
                  ),
                  FavoriteButton(
                    item: favoriteOfAlbum(entry),
                    showToast: false,
                  ),
                ],
              ),
              onTap: () {
                // 不收键盘的话，返回本页时键盘会自己再弹出来
                FocusManager.instance.primaryFocus?.unfocus();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AlbumPage(album: entry),
                  ),
                );
              },
            );
          }

          if (entry is BiliVideo) {
            // 点 B站视频，队列就是这批 B站结果，可以连着听
            final startIndex = videos.indexOf(entry);
            return BiliVideoTile(
              video: entry,
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                playerModel.playQueue(
                  videos.map((video) => video.toTrack()).toList(),
                  start: startIndex,
                );
              },
              onWatch: () {
                FocusManager.instance.primaryFocus?.unfocus();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BiliVideoPage(
                      bvid: entry.bvid,
                      title: entry.title,
                      cover: entry.cover,
                    ),
                  ),
                );
              },
              onAddToPlaylist: () =>
                  showAddToPlaylistSheet(context, [entry.toTrack()]),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DownloadButton(track: entry.toTrack(), iconSize: 20),
                  FavoriteButton(
                    item: favoriteOfVideo(entry),
                    showToast: false,
                  ),
                ],
              ),
            );
          }

          if (entry is BiliUp) {
            return ListTile(
              leading: ClipOval(
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: CoverImage(url: entry.face),
                ),
              ),
              title: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                entry.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: FavoriteButton(
                item: favoriteOfUp(entry),
                showToast: false,
              ),
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => UpPage(up: entry)),
                );
              },
            );
          }

          final track = entry as Track;
          // 点搜索结果里的歌，队列就是这批搜索结果，方便连续听
          final startIndex = tracks.indexOf(track);

          return ListTile(
            leading: SizedBox(
              width: 48,
              height: 48,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CoverImage(url: library.coverOfTrack(track)),
              ),
            ),
            title: Text(
              track.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                library.albumNameOf(track.albumCid),
                if (track.artists.isNotEmpty) track.artists.join(' / '),
              ].where((s) => s.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              // 键盘不收的话，bottomNavigationBar 槽位上刚出现的迷你条会被它盖住
              FocusManager.instance.primaryFocus?.unfocus();
              playerModel.playQueue(tracks, start: startIndex);
            },
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () => showAddToPlaylistSheet(context, [track]),
                  icon: const Icon(Icons.playlist_add),
                  tooltip: '加入歌单',
                ),
                FavoriteButton(
                  item: favoriteOfTrack(
                    track,
                    coverUrl: library.coverOfTrack(track),
                    albumName: library.albumNameOf(track.albumCid),
                  ),
                  showToast: false,
                ),
              ],
            ),
            onLongPress: () => showAddToPlaylistSheet(context, [track]),
          );
        },
      ),
    );
  }
}

/// 列表里的小标题。用一个私有类型而不是 String，
/// 是为了在 builder 里能跟真正的数据行区分开。
class _SectionTitle {
  const _SectionTitle(this.text);
  final String text;
}

class _LoadingRow {
  const _LoadingRow();
}

class _ErrorRow {
  const _ErrorRow({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;
}

/// B站视频分页的状态行：还在取、取失败、或「加载更多」。
class _MoreRow {
  const _MoreRow({
    required this.loading,
    required this.error,
    required this.onLoadMore,
    required this.onRetry,
  });

  final bool loading;
  final String? error;
  final Future<void> Function() onLoadMore;
  final VoidCallback onRetry;
}

/// 搜索结果里「整张专辑加入歌单」。
///
/// 专辑列表接口只给 cid，曲目得现拉详情 —— 所以这里要等一下。
/// 拉失败就提示一下，不要静默什么都不发生。
Future<void> _addAlbumToPlaylist(BuildContext context, Album album) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final detail = await SirenApi.albumDetail(album.cid);
    if (!context.mounted) return;
    await showAddToPlaylistSheet(context, detail.songs);
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('读取「${album.name}」音轨清单失败：$e')),
    );
  }
}
