import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../library.dart';
import '../models.dart';
import '../storage.dart';
import '../widgets/cover_image.dart';
import '../widgets/error_view.dart';
import '../widgets/mini_player.dart';
import 'album_page.dart';
import 'downloads_page.dart';
import 'history_page.dart';
import 'playlists_page.dart';
import 'search_page.dart';

/// 首页：全部专辑的网格。
///
/// 数据走 Library 缓存，第二次进来不会重新请求。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List<Album>> _request = library.ensureAlbums();

  /// 排序偏好。接口本来就按发行顺序给（新的在前），
  /// 所以「默认顺序」就是接口顺序，不额外造排序键。
  bool _sortByName = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      UiStorage.loadSortByName().then(
        (value) {
          if (mounted && value != _sortByName) {
            setState(() => _sortByName = value);
          }
        },
      ),
    );
  }

  void _reload() {
    setState(() => _request = library.ensureAlbums());
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SearchPage()),
    );
  }

  void _openPlaylists() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PlaylistsPage()),
    );
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HistoryPage()),
    );
  }

  void _openDownloads() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DownloadsPage()),
    );
  }

  Future<void> _setSortByName(bool value) async {
    if (value == _sortByName) return;
    setState(() => _sortByName = value);
    await UiStorage.saveSortByName(value);
  }

  List<Album> _sort(List<Album> albums) {
    if (!_sortByName) return albums;
    final sorted = [...albums];
    sorted.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Podenco Music'),
        titleSpacing: 20,
        actions: [
          PopupMenuButton<bool>(
            onSelected: (value) => unawaited(_setSortByName(value)),
            icon: const Icon(Icons.sort),
            tooltip: '排序方式',
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: false,
                checked: !_sortByName,
                child: const Text('默认顺序'),
              ),
              CheckedPopupMenuItem(
                value: true,
                checked: _sortByName,
                child: const Text('按名称'),
              ),
            ],
          ),
          IconButton(
            onPressed: _openHistory,
            icon: const Icon(Icons.history),
            tooltip: '播放历史',
          ),
          IconButton(
            onPressed: _openDownloads,
            icon: const Icon(Icons.download),
            tooltip: '下载管理',
          ),
          IconButton(
            onPressed: _openPlaylists,
            icon: const Icon(Icons.library_music),
            tooltip: '歌单',
          ),
          IconButton(
            onPressed: _openSearch,
            icon: const Icon(Icons.search),
            tooltip: '搜索',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<List<Album>>(
        future: _request,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: '${snapshot.error}',
              onRetry: _reload,
            );
          }

          final albums = snapshot.data ?? const <Album>[];
          if (albums.isEmpty) {
            return const Center(child: Text('没有拿到专辑数据'));
          }
          return _AlbumGrid(albums: _sort(albums), onRefresh: () async => _reload());
        },
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.albums, required this.onRefresh});

  final List<Album> albums;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder 拿的是「这个 GridView 能用多宽」，
    // 用它算列数比 MediaQuery 准 —— 窗口左边如果有侧栏也不会算错。
    return LayoutBuilder(
      builder: (context, constraints) {
        const padding = 16.0;
        const gap = 12.0;

        final usable = constraints.maxWidth - padding * 2;
        // 每格至少 170 宽，最宽 6 列（再宽封面就太夸张了）
        final columns = (usable / 170).floor().clamp(2, 6);
        final itemWidth = (usable - gap * (columns - 1)) / columns;

        return RefreshIndicator(
          onRefresh: onRefresh,
          child: GridView.builder(
            padding: const EdgeInsets.all(padding),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: gap,
              mainAxisSpacing: gap,
              // 高度 = 封面（正方形，宽高相等）+ 文字区 66
              mainAxisExtent: itemWidth + 66,
            ),
            itemCount: albums.length,
            itemBuilder: (context, index) {
              return _AlbumCard(album: albums[index]);
            },
          ),
        );
      },
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      // Card 默认带 4px 外边距，会让格子看起来忽大忽小，清掉
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => AlbumPage(album: album)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: CoverImage(url: album.coverUrl),
            ),
            // 文字区用 Expanded 吃掉剩下的高度，
            // 这样不管中文字体行高怎么变都不会溢出
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      album.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      album.artistes.isEmpty ? '未知艺人' : album.artistes.join(' / '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
