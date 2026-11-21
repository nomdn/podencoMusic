import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/fmp4_remux.dart';

int u32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

String fourCC(List<int> b, int o) => String.fromCharCodes(b, o, o + 4);

List<TestBox> boxes(List<int> b, [int start = 0, int? end]) {
  end ??= b.length;
  final result = <TestBox>[];
  var cursor = start;
  while (cursor + 8 <= end) {
    final size = u32(b, cursor);
    result.add(TestBox(fourCC(b, cursor + 4), cursor, size, cursor + 8));
    cursor += size;
  }
  return result;
}

class TestBox {
  final String type;
  final int start;
  final int size;
  final int payload;

  const TestBox(this.type, this.start, this.size, this.payload);

  int get end => start + size;
}

TestBox find(List<TestBox> list, String type) => list.firstWhere((b) => b.type == type);

List<int> box(String type, List<int> payload) => <int>[
      (payload.length + 8) >> 24 & 0xFF,
      (payload.length + 8) >> 16 & 0xFF,
      (payload.length + 8) >> 8 & 0xFF,
      (payload.length + 8) & 0xFF,
      ...type.codeUnits,
      ...payload,
    ];

List<int> fullBox(String type, int version, int flags, List<int> payload) =>
    box(type, <int>[
      version,
      flags >> 16 & 0xFF,
      flags >> 8 & 0xFF,
      flags & 0xFF,
      ...payload,
    ]);

List<int> u32List(Iterable<int> values) => values
    .expand((v) => <int>[
          v >> 24 & 0xFF,
          v >> 16 & 0xFF,
          v >> 8 & 0xFF,
          v & 0xFF,
        ])
    .toList();

/// 构造一个最小 fMP4：两个音频采样，时长各 1024，总 2048。
Uint8List buildFixture() {
  final ftyp = box('ftyp', <int>[
    ...'isom'.codeUnits,
    0,
    0,
    0,
    0,
    ...'isom'.codeUnits,
    ...'mp41'.codeUnits,
  ]);

  final stsd = fullBox('stsd', 0, 0, <int>[
    ...u32List([1]),
    ...box('mp4a', List<int>.filled(20, 0)),
  ]);
  final stbl = box('stbl', <int>[
    ...stsd,
    ...fullBox('stts', 0, 0, u32List([0])),
    ...fullBox('stsc', 0, 0, u32List([0])),
    ...fullBox('stsz', 0, 0, u32List([0, 0])),
    ...fullBox('stco', 0, 0, u32List([0])),
  ]);
  final dref = fullBox('dref', 0, 0, <int>[
    ...u32List([1]),
    ...fullBox('url ', 0, 1, const <int>[]),
  ]);
  final minf = box('minf', <int>[
    ...fullBox('smhd', 0, 0, const <int>[0, 0, 0, 0]),
    ...box('dinf', dref),
    ...stbl,
  ]);
  final hdlr = fullBox('hdlr', 0, 0, <int>[
    0,
    0,
    0,
    0, // pre_defined
    ...'soun'.codeUnits,
    ...List<int>.filled(12, 0),
    0, // name
  ]);
  final mdia = box('mdia', <int>[
    ...fullBox('mdhd', 0, 0, <int>[
      ...u32List([0, 0, 48000, 0]),
    ]),
    ...hdlr,
    ...minf,
  ]);
  final tkhd = fullBox('tkhd', 0, 7, <int>[
    ...u32List([0, 0, 1, 0, 0]), // track id = 1
    ...List<int>.filled(8, 0),
    ...List<int>.filled(36, 0),
  ]);
  final trak = box('trak', <int>[...tkhd, ...mdia]);
  final mvhd = fullBox('mvhd', 0, 0, <int>[
    ...u32List([0, 0, 1000, 0, 0x00010000]),
    ...List<int>.filled(10 * 4, 0),
    ...u32List([2]),
  ]);
  final moov = box('moov', <int>[...mvhd, ...trak]);

  List<int> buildMoof(int dataOffset) => box('moof', <int>[
        ...fullBox('mfhd', 0, 0, u32List([1])),
        ...box('traf', <int>[
          ...fullBox('tfhd', 0, 0x38, <int>[
            ...u32List([1, 1024, 2, 0x02000000]),
          ]),
          ...fullBox('tfdt', 0, 0, u32List([0])),
          ...fullBox('trun', 0, 0x201, <int>[
            ...u32List([2, dataOffset, 2, 3]),
          ]),
        ]),
      ]);

  final moofSize = buildMoof(0).length;
  final moof = buildMoof(moofSize + 8);
  final mdat = box('mdat', <int>[1, 2, 3, 4, 5]);
  return Uint8List.fromList(<int>[...ftyp, ...moov, ...moof, ...mdat]);
}

void main() {
  test('fMP4 被重封装成带采样表的标准 MP4', () {
    final input = buildFixture();
    final output = remuxFragmentedMp4(input);

    final top = boxes(output);
    expect(top.map((b) => b.type), <String>['ftyp', 'mdat', 'moov']);

    // 采样数据逐字节一致
    final inputMdat = find(boxes(input), 'mdat');
    final outputMdat = find(top, 'mdat');
    expect(
      output.sublist(outputMdat.payload, outputMdat.end),
      input.sublist(inputMdat.payload, inputMdat.end),
    );

    final moov = find(top, 'moov');
    final trak = find(boxes(output, moov.payload, moov.end), 'trak');
    final mdia = find(boxes(output, trak.payload, trak.end), 'mdia');
    final mdhd = find(boxes(output, mdia.payload, mdia.end), 'mdhd');
    expect(u32(output, mdhd.payload + 16), 2048); // duration，timescale=48000

    final minf = find(boxes(output, mdia.payload, mdia.end), 'minf');
    final stbl = find(boxes(output, minf.payload, minf.end), 'stbl');
    final stblBoxes = boxes(output, stbl.payload, stbl.end);
    final stts = find(stblBoxes, 'stts');
    final stco = find(stblBoxes, 'stco');

    expect(u32(output, stts.payload + 4), 1); // 一条 time-to-sample 记录
    expect(u32(output, stts.payload + 8), 2); // 两个采样
    expect(u32(output, stts.payload + 12), 1024);
    expect(u32(output, stco.payload + 4), 2); // 两个 chunk
    expect(u32(output, stco.payload + 8), outputMdat.payload);
    expect(u32(output, stco.payload + 12), outputMdat.payload + 2);
  });

  test('标准 MP4 原样返回（幂等）', () {
    final input = buildFixture();
    final once = remuxFragmentedMp4(input);
    final twice = remuxFragmentedMp4(once);
    expect(twice, same(once));
  });

  test('title/artist 写成 udta/meta/ilst 的 ©nam / ©ART', () {
    final output = remuxFragmentedMp4(
      buildFixture(),
      title: '测试曲名',
      artist: '某UP主',
    );

    final moov = find(boxes(output), 'moov');
    final moovBoxes = boxes(output, moov.payload, moov.end);
    final udta = find(moovBoxes, 'udta');
    final meta = find(boxes(output, udta.payload, udta.end), 'meta');
    final metaBoxes = boxes(output, meta.payload, meta.end);
    final ilst = find(metaBoxes, 'ilst');

    // ilst 里的每个 item 是 4 字节 atom id + data 盒；data 的 payload 前 4 字节
    // 是 fullbox 头（version+flags），flags=1 表示 UTF-8。
    final items = boxes(output, ilst.payload, ilst.end);
    expect(items.map((b) => b.type), containsAll(<String>['©nam', '©ART']));

    String atomValue(TestBox item) {
      final data = boxes(output, item.start + 4, item.end).single;
      return utf8.decode(output.sublist(data.payload + 4, data.end));
    }

    expect(atomValue(items.firstWhere((b) => b.type == '©nam')), '测试曲名');
    expect(atomValue(items.firstWhere((b) => b.type == '©ART')), '某UP主');
  });

  test('没有 title/artist 时不写 udta', () {
    final output = remuxFragmentedMp4(buildFixture());
    final moov = find(boxes(output), 'moov');
    expect(
      boxes(output, moov.payload, moov.end).map((b) => b.type),
      isNot(contains('udta')),
    );
  });
}
