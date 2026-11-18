// 弹幕 protobuf 解析：拿真实抓取的分段样本钉住，防止哪天B站改字段结构
// 或者我们手写的 varint 解析出错 —— 弹幕全解析不出来时界面只是"没有弹幕"，
// 不会报错，属于最容易悄悄坏掉的那类功能。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/bili_api.dart';

void main() {
  group('弹幕 protobuf', () {
    test('真实分段样本能解析出弹幕', () {
      final bytes = File('test/fixtures_bili_danmaku.bin').readAsBytesSync();
      final danmaku = BiliApi.parseDanmakuProtobuf(bytes);

      expect(danmaku, isNotEmpty, reason: '真实样本应该能解析出弹幕');
      // 样本是从弹幕流开头截的 8KB，至少要有几十条
      expect(danmaku.length, greaterThan(10));

      final first = danmaku.first;
      expect(first.text, isNotEmpty);
      expect(first.timeMs, greaterThanOrEqualTo(0));
      expect(first.mode, inInclusiveRange(1, 9));
      // 颜色必须是完整 ARGB（0xFF000000 以上）
      expect(first.color, greaterThanOrEqualTo(0xFF000000));
    });

    test('时间轴按毫秒且落在合理范围', () {
      final bytes = File('test/fixtures_bili_danmaku.bin').readAsBytesSync();
      final danmaku = BiliApi.parseDanmakuProtobuf(bytes);
      for (final d in danmaku) {
        // 这一段是视频前 6 分钟
        expect(d.timeMs, lessThan(6 * 60 * 1000));
      }
    });

    test('空数据和垃圾数据不抛异常', () {
      expect(BiliApi.parseDanmakuProtobuf([]), isEmpty);
      expect(BiliApi.parseDanmakuProtobuf([0xFF, 0xFF, 0xFF]), isEmpty);
      expect(
        BiliApi.parseDanmakuProtobuf([1, 2, 3, 4, 5]),
        isEmpty,
      );
    });

    test('高级弹幕(mode=7)解析出正文和屏幕坐标', () {
      // 真实样本：["0.05","0.1","1-1","4.07","我们从陌生到相爱",...,"宋体",0]
      const content =
          '["0.05","0.1","1-1","4.07","我们从陌生到相爱",0,0,"0.05","0.1",0,0,1,"宋体",0]';
      final textBytes = utf8.encode(content);
      final elem = <int>[
        0x10, 0x88, 0x27, // field 2 = 5000
        0x18, 0x07, // field 3 = mode 7（高级）
        0x3A, textBytes.length, ...textBytes, // field 7 = content JSON
      ];
      final bytes = <int>[0x0A, elem.length, ...elem];

      final result = BiliApi.parseDanmakuProtobuf(bytes);
      expect(result, hasLength(1));
      final d = result.first;
      expect(d.mode, 7);
      expect(d.text, '我们从陌生到相爱', reason: '应显示正文而非整串 JSON');
      expect(d.advanced, isNotNull);
      expect(d.advanced!.x, closeTo(0.05, 0.001));
      expect(d.advanced!.y, closeTo(0.1, 0.001));
      expect(d.advanced!.fontName, '宋体');
    });

    test('运动高级弹幕解析出起点/终点/运动时长', () {
      // 用户报的视频 BV1FrFhejEcB 里的真实运动弹幕：
      // [0,0.9,"1-1",8,"work work work work",0,0,0.05,0.1,500,0,1,"SimHei",1]
      const content =
          '[0,0.9,"1-1",8,"work work work work",0,0,0.05,0.1,500,0,1,"SimHei",1]';
      final textBytes = utf8.encode(content);
      final elem = <int>[
        0x10, 0x88, 0x27,
        0x18, 0x07, // mode 7
        0x3A, textBytes.length, ...textBytes,
      ];
      final bytes = <int>[0x0A, elem.length, ...elem];

      final d = BiliApi.parseDanmakuProtobuf(bytes).single;
      expect(d.text, 'work work work work');
      expect(d.advanced, isNotNull);
      final a = d.advanced!;
      expect(a.isMoving, isTrue);
      expect(a.x, closeTo(0, 0.001));
      expect(a.y, closeTo(0.9, 0.001));
      expect(a.toX, closeTo(0.05, 0.001));
      expect(a.toY, closeTo(0.1, 0.001));
      expect(a.moveMs, 500);
      expect(a.fontName, 'SimHei');
    });

    test('像素坐标的高级弹幕归一化到 0~1', () {
      // 用户视频 BV1cD4y1S7Yx 的真实弹幕：坐标是 862×568 画布的像素值
      // ["37","385","1-1","5","法老王深情献唱",0,0,"299","372","500",...]
      const content =
          '["37","385","1-1","5","法老王深情献唱",0,0,"299","372","500",0,1,"SimHei",1]';
      final textBytes = utf8.encode(content);
      final elem = <int>[
        0x10, 0x88, 0x27,
        0x18, 0x07,
        0x3A, textBytes.length, ...textBytes,
      ];
      final bytes = <int>[0x0A, elem.length, ...elem];

      final d = BiliApi.parseDanmakuProtobuf(bytes).single;
      expect(d.text, '法老王深情献唱');
      final a = d.advanced!;
      // >1 的坐标按 862×568 虚拟画布归一化（见 BiliApi._advCanvasW，
      // 同一视频 x 最大 797、y 最大 554 反证画布尺寸）：
      // 37/862=0.0429, 385/568=0.6778 —— 不能被 clamp 成 1 挤到角落
      expect(a.x, closeTo(37 / 862, 0.001));
      expect(a.y, closeTo(385 / 568, 0.001));
      expect(a.toX, closeTo(299 / 862, 0.001));
      expect(a.toY, closeTo(372 / 568, 0.001));
    });

    test('手工构造一条弹幕能正确读回', () {
      // DanmakuElem: progress=2(varint 5000), mode=3(1), content=7("测试弹幕")
      final textBytes = utf8.encode('测试弹幕'); // 每字 3 字节
      final elem = <int>[
        0x10, 0x88, 0x27, // field 2 = 5000（varint: 5000 = 0x88 0x27）
        0x18, 0x01, // field 3 = 1
        0x3A, textBytes.length, ...textBytes, // field 7 = "测试弹幕"
      ];
      // 外层 DmSegMobileReply: field 1 (elem), 长度 = elem.length
      final bytes = <int>[0x0A, elem.length, ...elem];

      final result = BiliApi.parseDanmakuProtobuf(bytes);
      expect(result, hasLength(1));
      expect(result.first.text, '测试弹幕');
      expect(result.first.timeMs, 5000);
      expect(result.first.mode, 1);
    });
  });
}
