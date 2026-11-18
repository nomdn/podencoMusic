// 歌单导出的内容生成：不碰 IO，纯字符串，适合直接断言。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/models.dart';
import 'package:podenco_music/playlist_export.dart';

Playlist _sample() => const Playlist(
  id: 'p1',
  name: '我的收藏',
  createdAt: 1794615129443,
  tracks: [
    Track(
      cid: '306846',
      name: 'Your Star',
      albumCid: '0256',
      artists: ['塞壬唱片-MSR', 'DJ Okawari'],
    ),
    Track(cid: '880306', name: 'Radian', albumCid: '0256', artists: []),
  ],
);

void main() {
  group('JSON 导出', () {
    test('是合法 JSON，且带得到曲目 cid 与专辑', () {
      final text = buildExportContent(_sample(), PlaylistFormat.json);
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(json['version'], 1);
      expect(json['app'], 'Podenco Music');

      final playlist = json['playlist'] as Map<String, dynamic>;
      expect(playlist['name'], '我的收藏');
      expect((playlist['tracks'] as List).length, 2);
      expect((playlist['tracks'] as List).first['cid'], '306846');
      expect((playlist['tracks'] as List).first['albumCid'], '0256');
    });

    test('没有 BOM，能直接被标准解析器吃下去', () {
      final text = buildExportContent(_sample(), PlaylistFormat.json);
      expect(text.codeUnitAt(0), isNot(0xFEFF));
      expect(jsonDecode(text), isA<Map<String, dynamic>>());
    });
  });

  group('M3U 导出', () {
    test('头部是 #EXTM3U，并写上歌单名', () {
      final lines = buildExportContent(_sample(), PlaylistFormat.m3u).split('\n');
      expect(lines.first, '#EXTM3U');
      expect(lines[1], '#PLAYLIST:我的收藏');
    });

    test('每首都是 EXTINF + 一行页面链接', () {
      final lines = buildExportContent(_sample(), PlaylistFormat.m3u)
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();

      expect(lines[2], '#EXTINF:-1,塞壬唱片-MSR / DJ Okawari - Your Star');
      expect(
        lines[3],
        'https://monster-siren.hypergryph.com/music/306846',
      );
    });

    test('没有艺人时只写歌名，不留下 " - " 这种空壳', () {
      final text = buildExportContent(_sample(), PlaylistFormat.m3u);
      expect(text.contains('#EXTINF:-1,Radian'), isTrue);
      expect(text.contains(' - Radian'), isFalse);
    });
  });

  group('文件名清洗', () {
    test('Windows 非法字符换成下划线', () {
      final name = sanitizeFileName('a/b\\c:d*e?f"g<h>i|j');
      expect(name.contains(RegExp(r'[\\/:*?"<>|]')), isFalse);
    });

    test('全是非法字符时给兜底名', () {
      expect(sanitizeFileName('///'), '未命名歌单');
      expect(sanitizeFileName('   '), '未命名歌单');
    });

    test('去掉结尾的点和空格（Windows 存不了）', () {
      expect(sanitizeFileName('歌单...'), '歌单');
      expect(sanitizeFileName('歌单   '), '歌单');
    });

    test('正常名字原样保留', () {
      expect(sanitizeFileName('卫戍协议：规程 OST'), '卫戍协议：规程 OST');
    });

    test('扩展名跟着格式走', () {
      expect(extensionFor(PlaylistFormat.json), '.json');
      expect(extensionFor(PlaylistFormat.m3u), '.m3u8');
    });
  });
}
