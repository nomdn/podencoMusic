// 双源 Track 的序列化：老存档必须还能读，新字段必须不丢。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/models.dart';

void main() {
  group('来源与附加字段', () {
    const bili = Track(
      cid: 'BV1ZVsn6nEMn',
      name: '视频标题',
      albumCid: '',
      artists: ['某UP'],
      source: TrackSource.bilibili,
      coverUrl: 'https://i0.hdslb.com/a.jpg',
      durationMs: 816000,
    );

    test('B站曲目序列化后能原样读回来', () {
      final back = Track.fromJson(bili.toJson());
      expect(back.source, TrackSource.bilibili);
      expect(back.cid, 'BV1ZVsn6nEMn');
      expect(back.coverUrl, 'https://i0.hdslb.com/a.jpg');
      expect(back.durationMs, 816000);
      expect(back.artists, ['某UP']);
    });

    test('B站曲目会写出 source 字段，塞壬不写（省存档空间）', () {
      expect(bili.toJson().containsKey('source'), isTrue);

      const siren = Track(
        cid: '306846',
        name: 'Your Star',
        albumCid: '0256',
        artists: ['塞壬'],
      );
      final json = siren.toJson();
      expect(json.containsKey('source'), isFalse);
      expect(json.containsKey('coverUrl'), isFalse);
      expect(json.containsKey('durationMs'), isFalse);
    });

    test('老存档没有 source 字段 → 一律当塞壬', () {
      final back = Track.fromJson({
        'cid': '306846',
        'name': 'Your Star',
        'albumCid': '0256',
        'artists': ['塞壬'],
      });
      expect(back.source, TrackSource.siren);
      expect(back.isBili, isFalse);
      expect(back.coverUrl, isEmpty);
      expect(back.durationMs, 0);
    });

    test('copyWith 只改指定字段，来源和封面不变', () {
      final patched = bili.copyWith(albumCid: '0256');
      expect(patched.albumCid, '0256');
      expect(patched.source, TrackSource.bilibili);
      expect(patched.coverUrl, bili.coverUrl);
      expect(patched.durationMs, 816000);
    });
  });

  group('歌单混装两个来源', () {
    test('Playlist 序列化能同时装下塞壬和B站的歌', () {
      const playlist = Playlist(
        id: 'p',
        name: '混着听',
        createdAt: 1,
        tracks: [
          Track(
            cid: '306846',
            name: '塞壬的歌',
            albumCid: '0256',
            artists: ['塞壬'],
          ),
          Track(
            cid: 'BV1xx',
            name: 'B站的视频',
            albumCid: '',
            artists: ['某UP'],
            source: TrackSource.bilibili,
            coverUrl: 'https://i0.hdslb.com/b.jpg',
          ),
        ],
      );

      final back = Playlist.fromJson(playlist.toJson());
      expect(back.tracks.length, 2);
      expect(back.tracks[0].isBili, isFalse);
      expect(back.tracks[1].isBili, isTrue);
      expect(back.tracks[1].coverUrl, 'https://i0.hdslb.com/b.jpg');
    });
  });
}
