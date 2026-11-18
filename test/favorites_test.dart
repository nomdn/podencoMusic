// 收藏：模型的序列化 + 增删逻辑。持久化用 mock 的 SharedPreferences。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/favorites_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('FavoriteItem 序列化往返不丢字段', () {
    const item = FavoriteItem(
      kind: FavoriteKind.biliVideo,
      id: 'BV1xx',
      name: '某个视频',
      subtitle: '某UP',
      coverUrl: 'https://i0.hdslb.com/a.jpg',
      artists: ['某UP'],
      addedAt: 123,
    );

    final back = FavoriteItem.fromJson(item.toJson());
    expect(back.kind, FavoriteKind.biliVideo);
    expect(back.id, 'BV1xx');
    expect(back.name, '某个视频');
    expect(back.coverUrl, item.coverUrl);
    expect(back.addedAt, 123);
  });

  test('不认识的 kind 退化成塞壬单曲，而不是整条丢掉', () {
    final back = FavoriteItem.fromJson({'kind': 'unknown', 'id': 'x'});
    expect(back.kind, FavoriteKind.sirenSong);
  });

  test('B站视频还原成 Track 时保留 bilibili 来源', () {
    const item = FavoriteItem(
      kind: FavoriteKind.biliVideo,
      id: 'BV1xx',
      name: '视频',
      coverUrl: 'https://a/b.jpg',
      artists: ['UP'],
    );
    final track = item.toTrack();
    expect(track.isBili, isTrue);
    expect(track.coverUrl, 'https://a/b.jpg');
  });

  test('塞壬单曲还原成 Track 时是 siren 来源，并带上专辑 cid', () {
    const item = FavoriteItem(
      kind: FavoriteKind.sirenSong,
      id: '306846',
      name: '歌',
      albumCid: '0256',
      artists: ['塞壬'],
    );
    final track = item.toTrack();
    expect(track.isBili, isFalse);
    expect(track.albumCid, '0256');
  });

  test('toggle 两次回到原点', () async {
    final model = FavoriteModel();
    await model.load();
    expect(model.items, isEmpty);

    const item = FavoriteItem(
      kind: FavoriteKind.sirenAlbum,
      id: '0256',
      name: '专辑',
    );

    expect(model.toggle(item), isTrue);
    expect(model.contains(FavoriteKind.sirenAlbum, '0256'), isTrue);
    expect(model.countOf(FavoriteKind.sirenAlbum), 1);

    expect(model.toggle(item), isFalse);
    expect(model.items, isEmpty);
  });

  test('不同种类的同一个 id 互不影响', () async {
    final model = FavoriteModel();
    await model.load();

    model.toggle(
      const FavoriteItem(kind: FavoriteKind.sirenSong, id: '100', name: '单曲'),
    );
    model.toggle(
      const FavoriteItem(kind: FavoriteKind.biliVideo, id: '100', name: '视频'),
    );

    expect(model.contains(FavoriteKind.sirenSong, '100'), isTrue);
    expect(model.contains(FavoriteKind.biliVideo, '100'), isTrue);

    model.remove(FavoriteKind.sirenSong, '100');
    expect(model.contains(FavoriteKind.sirenSong, '100'), isFalse);
    expect(model.contains(FavoriteKind.biliVideo, '100'), isTrue);
  });
}
