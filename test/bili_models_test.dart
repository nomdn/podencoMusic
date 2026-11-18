// B站数据模型的解析：搜索接口返回的东西脏得很有规律，逐条钉住。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/bili_models.dart';
import 'package:podenco_music/models.dart';

void main() {
  group('标题清洗', () {
    test('去掉搜索高亮的 em 标签', () {
      expect(
        sanitizeBiliText('【<em class="keyword">明日方舟</em>】攻略'),
        '【明日方舟】攻略',
      );
    });

    test('解 HTML 实体', () {
      expect(sanitizeBiliText('A &amp; B &quot;test&quot;'), 'A & B "test"');
    });

    test('前后空白抹掉', () {
      expect(sanitizeBiliText('  标题  '), '标题');
    });
  });

  group('图片地址', () {
    test('协议相对地址补成 https', () {
      expect(
        normalizeBiliImage('//i0.hdslb.com/a.jpg'),
        'https://i0.hdslb.com/a.jpg',
      );
    });

    test('http 升级成 https（安卓默认禁明文）', () {
      expect(
        normalizeBiliImage('http://i1.hdslb.com/a.jpg'),
        'https://i1.hdslb.com/a.jpg',
      );
    });

    test('空串和正常 https 原样返回', () {
      expect(normalizeBiliImage(''), '');
      expect(
        normalizeBiliImage('https://i0.hdslb.com/a.jpg'),
        'https://i0.hdslb.com/a.jpg',
      );
    });
  });

  group('时长解析', () {
    test('mm:ss', () => expect(parseBiliDuration('13:36'), 816000));
    test('h:mm:ss', () => expect(parseBiliDuration('1:02:03'), 3723000));
    test('纯秒数', () => expect(parseBiliDuration(90), 90000));
    test('坏数据返回 0', () {
      expect(parseBiliDuration(null), 0);
      expect(parseBiliDuration('abc'), 0);
      expect(parseBiliDuration(''), 0);
    });
  });

  group('数字格式化', () {
    test('一万以上折成万', () => expect(formatBiliCount(123456), '12.3 万'));
    test('一亿以上折成亿', () => expect(formatBiliCount(123456789), '1.2 亿'));
    test('一万以下原样', () => expect(formatBiliCount(999), '999'));
  });

  group('BiliVideo', () {
    final json = {
      'bvid': 'BV1ZVsn6nEMn',
      'aid': 117619441009775,
      'title': '【<em class="keyword">明日方舟</em>】攻略',
      'pic': '//i0.hdslb.com/bfs/archive/x.jpg',
      'author': '魔法Zc目录',
      'mid': 13164144,
      'duration': '13:36',
      'play': 392830,
      'pubdate': 1794730601,
    };

    test('字段解析：标题干净、封面补全、时长换算成毫秒', () {
      final video = BiliVideo.fromJson(json);
      expect(video.bvid, 'BV1ZVsn6nEMn');
      expect(video.title, '【明日方舟】攻略');
      expect(video.cover, 'https://i0.hdslb.com/bfs/archive/x.jpg');
      expect(video.mid, 13164144);
      expect(video.durationMs, 816000);
    });

    test('转成 Track 时带上 bilibili 来源、封面和时长', () {
      final track = BiliVideo.fromJson(json).toTrack();
      expect(track.source, TrackSource.bilibili);
      expect(track.isBili, isTrue);
      expect(track.cid, 'BV1ZVsn6nEMn');
      expect(track.artists, ['魔法Zc目录']);
      // B站曲目没有专辑，albumCid 必须留空，否则会被塞壬的专辑表查到空白
      expect(track.albumCid, isEmpty);
      expect(track.coverUrl, startsWith('https://'));
      expect(track.durationMs, 816000);
    });
  });

  group('BiliUp', () {
    test('副标题优先显示粉丝和视频数', () {
      const up = BiliUp(
        mid: 1,
        name: '某UP',
        face: '',
        fans: 12345,
        videoCount: 67,
      );
      expect(up.subtitle, '1.2 万 粉丝 · 67 个视频');
    });

    test('没有粉丝数时退回签名', () {
      const up = BiliUp(mid: 1, name: '某UP', face: '', sign: '简介文字');
      expect(up.subtitle, '简介文字');
    });
  });
}
