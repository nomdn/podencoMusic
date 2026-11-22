// 歌单的持久化往返 + 模型操作测试。
// 跟 storage_test.dart 一样走 shared_preferences 的内存版实现。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/models.dart';
import 'package:podenco_music/playlist_import.dart';
import 'package:podenco_music/playlist_model.dart';
import 'package:podenco_music/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 每个用例都从空存储开始
    SharedPreferences.setMockInitialValues({});
  });

  const track = Track(
    cid: '1',
    name: 'Your Star',
    albumCid: '0256',
    artists: ['塞壬唱片-MSR'],
  );

  group('PlaylistStorage', () {
    test('存进去的歌单和曲目能原样读回来', () async {
      const playlists = [
        Playlist(
          id: '1000',
          name: '收藏',
          createdAt: 1720000000000,
          tracks: [track],
        ),
        Playlist(id: '1001', name: '通勤', createdAt: 1720000001000, tracks: []),
      ];

      await PlaylistStorage.save(playlists);
      final loaded = await PlaylistStorage.load();

      expect(loaded.length, 2);
      expect(loaded.first.id, '1000');
      expect(loaded.first.name, '收藏');
      expect(loaded.first.createdAt, 1720000000000);
      expect(loaded.first.tracks.first.cid, '1');
      expect(loaded.first.tracks.first.albumCid, '0256');
      expect(loaded.last.name, '通勤');
      expect(loaded.last.tracks, isEmpty);
    });

    test('没存过时返回空列表，不是抛异常', () async {
      final loaded = await PlaylistStorage.load();
      expect(loaded, isEmpty);
    });

    test('存档是一段乱码也不会崩', () async {
      SharedPreferences.setMockInitialValues({'playlists_v1': '这不是 json'});
      final loaded = await PlaylistStorage.load();
      expect(loaded, isEmpty);
    });

    test('自定义封面链接跟着存档往返', () async {
      const playlists = [
        Playlist(
          id: '1000',
          name: '有封面',
          createdAt: 1720000000000,
          tracks: [],
          coverUrl: 'https://example.com/cover.jpg',
        ),
      ];

      await PlaylistStorage.save(playlists);
      final loaded = await PlaylistStorage.load();

      expect(loaded.single.coverUrl, 'https://example.com/cover.jpg');
    });

    test('旧存档没有封面字段，读成空串走默认封面', () async {
      SharedPreferences.setMockInitialValues({
        'playlists_v1': '{"playlists":[{"id":"1","name":"老歌单","tracks":[]}]}',
      });
      final loaded = await PlaylistStorage.load();

      expect(loaded.single.coverUrl, '');
    });

    test('存档里某一条格式不对，剩下的照常读回来', () async {
      SharedPreferences.setMockInitialValues({
        'playlists_v1':
            '{"playlists":[{"name":"缺id"},{"id":"2","name":"正常的","tracks":[{"cid":"1"}]}]}',
      });
      final loaded = await PlaylistStorage.load();

      expect(loaded.length, 2);
      // 缺的字段用默认值兜住，不炸整份存档
      expect(loaded.first.id, '');
      expect(loaded.last.name, '正常的');
    });
  });

  group('PlaylistModel', () {
    test('create 后立即可见，且新建的排最前面', () {
      final model = PlaylistModel();
      final older = model.create('收藏');
      final newer = model.create('通勤');

      expect(model.playlists.length, 2);
      expect(model.playlists.first.id, newer.id);
      expect(model.playlists.first.name, '通勤');
      expect(model.playlists.last.id, older.id);
      expect(model.playlists.last.name, '收藏');
      // 同一微秒连建两个也不能撞 id，否则后一个会接走前一个的操作
      expect(newer.id, isNot(older.id));
    });

    test('addTrack 按 cid 去重', () {
      final model = PlaylistModel();
      final playlist = model.create('收藏');

      model.addTrack(playlist.id, track);
      model.addTrack(playlist.id, track);

      expect(model.byId(playlist.id)!.tracks.length, 1);
    });

    test('addTracks 批量加歌跳过已有的，一首加一遍', () {
      final model = PlaylistModel();
      final playlist = model.create('收藏');
      const other = Track(cid: '2', name: 'Radian', albumCid: '0256', artists: []);

      model.addTrack(playlist.id, track); // 先有一首
      model.addTracks(playlist.id, [track, other]); // 批量：track 已在，跳过

      final tracks = model.byId(playlist.id)!.tracks;
      expect(tracks.map((t) => t.cid).toSet(), {'1', '2'});
      expect(tracks.length, 2);
    });

    test('addTracks 全部已存在时歌单不变', () {
      final model = PlaylistModel();
      final playlist = model.create('收藏');
      model.addTracks(playlist.id, [track]);

      model.addTracks(playlist.id, [track]);
      expect(model.byId(playlist.id)!.tracks.length, 1);
    });

    test('removeTracks 批量移歌，没有的 cid 忽略', () {
      final model = PlaylistModel();
      final playlist = model.create('收藏');
      const other = Track(cid: '2', name: 'Radian', albumCid: '0256', artists: []);
      model.addTracks(playlist.id, [track, other]);

      model.removeTracks(playlist.id, ['1', '不存在']);
      expect(model.byId(playlist.id)!.tracks.map((t) => t.cid), ['2']);
    });

    test('removeTrack 移掉指定曲目，没有就保持原样', () {
      final model = PlaylistModel();
      final playlist = model.create('收藏');
      model.addTrack(playlist.id, track);
      const other = Track(cid: '2', name: 'Radian', albumCid: '0256', artists: []);
      model.addTrack(playlist.id, other);

      model.removeTrack(playlist.id, '1');
      expect(model.byId(playlist.id)!.tracks.map((t) => t.cid), ['2']);

      model.removeTrack(playlist.id, '不存在');
      expect(model.byId(playlist.id)!.tracks.length, 1);
    });

    test('containsTrack 跟着 add / remove 走', () {
      final model = PlaylistModel();
      final playlist = model.create('收藏');

      expect(model.containsTrack(playlist.id, '1'), isFalse);
      model.addTrack(playlist.id, track);
      expect(model.containsTrack(playlist.id, '1'), isTrue);
      model.removeTrack(playlist.id, '1');
      expect(model.containsTrack(playlist.id, '1'), isFalse);
    });

    test('remove 删掉歌单，rename 换名', () {
      final model = PlaylistModel();
      final playlist = model.create('收藏');
      model.rename(playlist.id, '深夜');
      expect(model.byId(playlist.id)!.name, '深夜');

      model.remove(playlist.id);
      expect(model.byId(playlist.id), isNull);
      expect(model.playlists, isEmpty);
    });

    test('byId 查不到时返回 null，不是抛异常', () {
      final model = PlaylistModel();
      expect(model.byId('不存在'), isNull);
    });

    test('merge 按 cid 去重，源歌单保留不动', () {
      final model = PlaylistModel();
      final first = model.create('A');
      final second = model.create('B');
      const one = Track(cid: '1', name: 'ONE', albumCid: 'x', artists: []);
      const two = Track(cid: '2', name: 'TWO', albumCid: 'x', artists: []);

      model.addTrack(first.id, one);
      model.addTrack(second.id, one); // 两歌单都收了这首
      model.addTrack(second.id, two);

      final merged = model.merge([first.id, second.id], '合并歌单');

      expect(merged, isNotNull);
      expect(merged!.name, '合并歌单');
      expect(merged.tracks.map((track) => track.cid), ['1', '2']);
      expect(model.byId(first.id)!.tracks.length, 1);
      expect(model.byId(second.id)!.tracks.length, 2);
      expect(model.playlists.first.id, merged.id);
    });

    test('merge 少于两个有效歌单返回 null', () {
      final model = PlaylistModel();
      final first = model.create('A');
      model.create('B');

      expect(model.merge([first.id], '合并歌单'), isNull);
      expect(model.merge([first.id, '不存在'], '合并歌单'), isNull);
      expect(model.merge(['不存在', '也没有'], '合并歌单'), isNull);
    });

    test('merge 撞名自动加序号', () {
      final model = PlaylistModel();
      final first = model.create('A');
      final second = model.create('B');
      model.create('合并歌单');

      final merged = model.merge([first.id, second.id], '合并歌单');
      expect(merged!.name, '合并歌单 (2)');
    });

    test('setCover 设置、去空格、恢复默认', () {
      final model = PlaylistModel();
      final playlist = model.create('A');

      model.setCover(playlist.id, '  https://example.com/c.jpg  ');
      expect(model.byId(playlist.id)!.coverUrl, 'https://example.com/c.jpg');

      // 内容没变不该造新对象（监听方不用白重建）
      final withCover = model.byId(playlist.id);
      model.setCover(playlist.id, 'https://example.com/c.jpg');
      expect(identical(model.byId(playlist.id), withCover), isTrue);

      model.setCover(playlist.id, '');
      expect(model.byId(playlist.id)!.coverUrl, '');
    });

    test('备份 JSON 里的封面链接能导入回来', () {
      final parsed = parsePlaylistJson(
        '{"app":"Podenco Music","playlist":{"name":"备份",'
        '"coverUrl":"https://example.com/c.jpg",'
        '"tracks":[{"cid":"1","name":"歌"}]}}',
      );
      expect(parsed.single.coverUrl, 'https://example.com/c.jpg');

      final model = PlaylistModel();
      final imported = model.importPlaylist(
        parsed.single.name,
        parsed.single.tracks,
        coverUrl: parsed.single.coverUrl,
      );
      expect(model.byId(imported.id)!.coverUrl, 'https://example.com/c.jpg');
    });

    test('copyWith 不传封面时保留，传空串时清空', () {
      const playlist = Playlist(
        id: '1',
        name: 'A',
        createdAt: 0,
        tracks: [],
        coverUrl: 'https://example.com/c.jpg',
      );

      expect(playlist.copyWith(name: 'B').coverUrl, playlist.coverUrl);
      expect(playlist.copyWith(coverUrl: '').coverUrl, '');
    });
  });
}
