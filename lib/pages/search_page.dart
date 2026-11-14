import 'package:material_ui/material_ui.dart';

import '../library.dart';
import '../models.dart';
import '../player_model.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/cover_image.dart';
import '../widgets/error_view.dart';
import '../widgets/mini_player.dart';
import 'album_page.dart';

/// 搜索页。数据是本地过滤 —— 塞壬没有搜索接口，
/// 但它总共就 900 多首歌，一次全拉到内存里过滤反而更快。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  String _query = '';

  /// 首页已经拉过专辑的话这里立刻就好，歌曲可能是第一次拉
  late Future<void> _ready = _prepare();

  Future<void> _prepare() async {
    // 两个请求同时发出去，再一起等 —— 比一个一个 awaits 快一倍
    final albums = library.ensureAlbums();
    final songs = library.ensureSongs();
    await albums;
    await songs;
  }

  void _retry() {
    setState(() => _ready = _prepare());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索专辑、歌曲或艺人',
            border: InputBorder.none,
          ),
          onChanged: (value) => setState(() => _query = value.trim()),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              onPressed: () {
                _controller.clear();
                setState(() => _query = '');
              },
              icon: const Icon(Icons.close),
              tooltip: '清空',
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: FutureBuilder<void>(
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
          return _Results(query: _query);
        },
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Center(
        child: Text(
          '输入关键词开始搜索',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final q = query.toLowerCase();

    final albums = library.albums.where((album) {
      return album.name.toLowerCase().contains(q) ||
          album.artistes.any((a) => a.toLowerCase().contains(q));
    }).toList();

    final tracks = library.songs.where((track) {
      if (track.name.toLowerCase().contains(q)) return true;
      if (track.artists.any((a) => a.toLowerCase().contains(q))) return true;
      return library.albumNameOf(track.albumCid).toLowerCase().contains(q);
    }).toList();

    if (albums.isEmpty && tracks.isEmpty) {
      return Center(
        child: Text('没有找到「$query」相关的内容'),
      );
    }

    // 把标题行和数据行压进一个扁平列表，这样能用 ListView.builder
    // 只渲染可见项 —— 搜单个字母时可能命中几百首，全渲染会卡。
    final entries = <Object>[
      if (albums.isNotEmpty) _SectionTitle('专辑 · ${albums.length}'),
      ...albums,
      if (tracks.isNotEmpty) _SectionTitle('歌曲 · ${tracks.length}'),
      ...tracks,
    ];

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];

        if (entry is _SectionTitle) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              entry.text,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
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
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AlbumPage(album: entry),
              ),
            ),
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
              child: CoverImage(url: library.coverOf(track.albumCid)),
            ),
          ),
          title: Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              library.albumNameOf(track.albumCid),
              if (track.artists.isNotEmpty) track.artists.join(' / '),
            ].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => playerModel.playQueue(tracks, start: startIndex),
          onLongPress: () => showAddToPlaylistSheet(context, [track]),
        );
      },
    );
  }
}

/// 列表里的小标题。用一个私有类型而不是 String，
/// 是为了在 builder 里能跟真正的数据行区分开。
class _SectionTitle {
  const _SectionTitle(this.text);
  final String text;
}
