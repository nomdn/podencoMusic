import 'package:material_ui/material_ui.dart';

import '../bili_models.dart';
import '../favorites_model.dart';
import '../models.dart';
import '../player_model.dart';
import '../widgets/cover_image.dart';
import '../widgets/mini_player.dart';
import 'album_page.dart';
import 'up_page.dart';

/// 收藏页。四类东西分四个 tab，因为它们点下去的后果完全不同：
/// 专辑进详情、单曲和视频直接播、UP 主进主页。
class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: FavoriteKind.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('收藏'),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (final kind in FavoriteKind.values) Tab(text: kind.label),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (final kind in FavoriteKind.values) _FavoriteList(kind: kind),
          ],
        ),
        bottomNavigationBar: const MiniPlayerBar(),
      ),
    );
  }
}

class _FavoriteList extends StatelessWidget {
  const _FavoriteList({required this.kind});

  final FavoriteKind kind;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: favoritesModel,
      builder: (context, _) {
        final items = favoritesModel.of(kind);
        if (items.isEmpty) {
          return _Empty(kind: kind);
        }

        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return switch (kind) {
              FavoriteKind.sirenAlbum => _AlbumRow(item: item),
              FavoriteKind.sirenSong => _SongRow(
                item: item,
                queue: items,
                index: index,
              ),
              FavoriteKind.biliVideo => _SongRow(
                item: item,
                queue: items,
                index: index,
              ),
              FavoriteKind.biliUp => _UpRow(item: item),
            };
          },
        );
      },
    );
  }
}

/// 塞壬专辑：方形封面，点开进专辑详情。
class _AlbumRow extends StatelessWidget {
  const _AlbumRow({required this.item});

  final FavoriteItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _Thumb(url: item.coverUrl),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: item.subtitle.isEmpty
          ? null
          : Text(item.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _RemoveButton(item: item),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AlbumPage(
            album: Album(
              cid: item.id,
              name: item.name,
              coverUrl: item.coverUrl,
              artistes: item.artists,
            ),
          ),
        ),
      ),
    );
  }
}

/// 单曲 / B站视频：点一下就以整个收藏列表为队列开始播。
class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.item,
    required this.queue,
    required this.index,
  });

  final FavoriteItem item;
  final List<FavoriteItem> queue;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isVideo = item.kind == FavoriteKind.biliVideo;

    return ListTile(
      leading: _Thumb(url: item.coverUrl, width: isVideo ? 64 : 48),
      title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (item.subtitle.isNotEmpty) item.subtitle,
          if (isVideo) 'B站',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: _RemoveButton(item: item),
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        playerModel.playQueue(
          queue.map((entry) => entry.toTrack()).toList(),
          start: index,
        );
      },
    );
  }
}

/// UP 主：圆形头像，点开进主页。
class _UpRow extends StatelessWidget {
  const _UpRow({required this.item});

  final FavoriteItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ClipOval(child: _Thumb(url: item.coverUrl)),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: item.subtitle.isEmpty
          ? null
          : Text(item.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _RemoveButton(item: item),
      onTap: () {
        final mid = int.tryParse(item.id) ?? 0;
        if (mid <= 0) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => UpPage(
              up: BiliUp(
                mid: mid,
                name: item.name,
                face: item.coverUrl,
                sign: item.subtitle,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url, this.width = 48});

  final String url;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: width / (width > 48 ? 16 / 9 : 1),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CoverImage(url: url),
      ),
    );
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.item});

  final FavoriteItem item;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '取消收藏',
      icon: Icon(Icons.favorite, color: Theme.of(context).colorScheme.error),
      onPressed: () => favoritesModel.remove(item.kind, item.id),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.kind});

  final FavoriteKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.favorite_border,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '档案室暂无${kind.label}记录',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              switch (kind) {
                FavoriteKind.sirenAlbum => '在专辑详情页点亮心形，即可收录',
                FavoriteKind.sirenSong => '在播放页或检索结果里点亮心形',
                FavoriteKind.biliVideo => '在B站检索结果里点亮心形',
                FavoriteKind.biliUp => '在 UP 主页点亮心形',
              },
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
