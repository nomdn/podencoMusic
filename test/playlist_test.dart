// 歌单的持久化往返 + 模型操作测试。
// 跟 storage_test.dart 一样走 shared_preferences 的内存版实现。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/models.dart';
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
  });
}
