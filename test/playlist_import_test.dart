// 歌单导入的解析层：纯字符串进、纯对象出，不碰网络也不碰文件。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/models.dart';
import 'package:podenco_music/playlist_export.dart';
import 'package:podenco_music/playlist_import.dart';

const _sample = Playlist(
  id: 'p1',
  name: '我的收藏',
  createdAt: 1794615129443,
  tracks: [
    Track(
      cid: '306846',
      name: 'Your Star',
      albumCid: '0256',
      artists: ['塞壬唱片-MSR'],
    ),
    Track(cid: '880306', name: 'Radian', albumCid: '0256', artists: []),
  ],
);

void main() {
  group('JSON 导入', () {
    test('自己导出的备份能原样读回来', () {
      final text = buildExportContent(_sample, PlaylistFormat.json);
      final result = parsePlaylistJson(text);

      expect(result, hasLength(1));
      expect(result.single.name, '我的收藏');
      expect(result.single.tracks.map((t) => t.cid), ['306846', '880306']);
      expect(result.single.tracks.first.albumCid, '0256');
      expect(result.single.tracks.first.artists, ['塞壬唱片-MSR']);
      expect(result.single.note, isNull);
    });

    test('裸歌单对象（没有 app/version 外壳）也认', () {
      final text = '{"name":"手写的","tracks":[{"cid":"1","name":"A"}]}';
      final result = parsePlaylistJson(text);
      expect(result.single.name, '手写的');
      expect(result.single.tracks.single.cid, '1');
    });

    test('一文件多歌单：playlists 数组和裸数组都支持', () {
      const body = '{"name":"甲","tracks":[{"cid":"1"}]},'
          '{"name":"乙","tracks":[{"cid":"2"}]}';

      expect(
        parsePlaylistJson('{"playlists":[$body]}').map((p) => p.name),
        ['甲', '乙'],
      );
      expect(
        parsePlaylistJson('[$body]').map((p) => p.name),
        ['甲', '乙'],
      );
    });

    test('缺名字给兜底名，空 cid 与重复曲目被扔掉并记一条 note', () {
      final text = '''
      {"tracks":[
        {"cid":"1","name":"A"},
        {"cid":"1","name":"A 重复"},
        {"cid":"","name":"没有 id"},
        {"name":"也没有 id"},
        {"cid":"2","name":"B"}
      ]}
      ''';
      final result = parsePlaylistJson(text).single;

      expect(result.name, '导入的歌单');
      expect(result.tracks.map((t) => t.cid), ['1', '2']);
      expect(result.note, contains('3 条'));
    });

    test('坏 JSON / 找不到歌单 / 空歌单都抛中文错误', () {
      expect(
        () => parsePlaylistJson('{不是 json'),
        throwsA(isA<PlaylistImportException>()),
      );
      expect(
        () => parsePlaylistJson('{"app":"x"}'),
        throwsA(isA<PlaylistImportException>()),
      );
      expect(
        () => parsePlaylistJson('{"playlist":{"tracks":[]}}'),
        throwsA(isA<PlaylistImportException>()),
      );
    });
  });

  group('M3U 导入', () {
    test('抠出 #PLAYLIST 名字和每首 cid，重复的只留一次', () {
      const text = '''
#EXTM3U
#PLAYLIST:卫戍协议
#EXTINF:-1,塞壬 - Your Star
https://monster-siren.hypergryph.com/music/306846
#EXTINF:-1,塞壬 - Radian
https://monster-siren.hypergryph.com/music/880306?from=m3u
#EXTINF:-1,手写的那种
306846
''';
      final parsed = parseM3u(text);

      expect(parsed.name, '卫戍协议');
      expect(parsed.cids, ['306846', '880306']);
    });

    test('没有 #PLAYLIST 时名字为 null，交给调用方用文件名兜底', () {
      const text = '#EXTM3U\nhttps://monster-siren.hypergryph.com/music/42\n';
      final parsed = parseM3u(text);
      expect(parsed.name, isNull);
      expect(parsed.cids, ['42']);
    });

    test('一行纯 cid 也认（别人手工整理的 m3u）', () {
      expect(parseM3u('1234\n5678\n').cids, ['1234', '5678']);
    });

    test('全是注释时 cid 列表为空', () {
      expect(parseM3u('#EXTM3U\n#PLAYLIST:空\n').cids, isEmpty);
    });
  });

  group('格式判断', () {
    test('抬头是 { 或 [ 就按 JSON 处理，前后空白不影响', () {
      expect(looksLikeJson('  \n{"a":1}'), isTrue);
      expect(looksLikeJson('[1,2]'), isTrue);
      expect(looksLikeJson('#EXTM3U\n'), isFalse);
    });
  });
}
