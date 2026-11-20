/// 把 B站 DASH 音轨的 fragmented MP4 重封装成标准 MP4（M4A）。
///
/// 为什么需要这一步：B站 `playurl` 的 DASH 音轨是 `ftyp + moov + sidx +
/// (moof + mdat)*` 结构，`moov` 里的 `mdhd.duration` 是 0，真正的采样时长
/// 散落在每个 `trun` 里。系统 MediaScanner 与华为手表的解码器多半只认
/// 带完整 sample table 的标准 MP4，直接把 fMP4 存成 .m4a 会出现时长 0 /
/// 不同步 / 无法播放。
///
/// 这里只依赖 `dart:typed_data`，Web / Android / 桌面共用一份实现。
/// B站音轨是 AAC 压缩流，单文件一般几 MB，整包在内存里处理可以接受；
/// 塞壬的 WAV 不走这条路。
library;

import 'dart:typed_data';

class Fmp4RemuxException implements Exception {
  final String message;

  const Fmp4RemuxException(this.message);

  @override
  String toString() => 'Fmp4RemuxException: $message';
}

class _Box {
  final String type;
  final int start;
  final int size;
  final int header;

  const _Box(this.type, this.start, this.size, this.header);

  int get end => start + size;
  int get payloadStart => start + header;
}

class _Sample {
  final int size;
  final int duration;
  final int flags;
  final int compositionOffset;
  int sourceOffset = 0;

  _Sample({
    required this.size,
    required this.duration,
    required this.flags,
    required this.compositionOffset,
  });
}

class _Fragment {
  final List<_Sample> samples;

  const _Fragment(this.samples);
}

/// 输入是完整的 fMP4 字节。
/// 如果发现输入本来就是标准 MP4（没有 `moof`），原样返回，方便重复调用。
Uint8List remuxFragmentedMp4(Uint8List input) {
  final top = _boxes(input, 0, input.length);
  final moofExists = top.any((box) => box.type == 'moof');
  if (!moofExists) return input;

  final ftyp = _find(top, 'ftyp') ??
      (throw const Fmp4RemuxException('缺少 ftyp 盒'));
  final moov = _find(top, 'moov') ??
      (throw const Fmp4RemuxException('缺少 moov 初始化段'));

  // ── 1. 从初始化段拿到音频轨参数 ──────────────────────────────
  final initTrack = _findAudioTrack(input, moov);
  if (initTrack == null) {
    throw const Fmp4RemuxException('初始化段里没有音频轨');
  }

  final trakChildren = _children(input, initTrack);
  final tkhd = _find(trakChildren, 'tkhd') ??
      (throw const Fmp4RemuxException('音频轨缺少 tkhd'));
  final trackId = _readTrackId(input, tkhd);

  final mdia = _find(trakChildren, 'mdia') ??
      (throw const Fmp4RemuxException('音频轨缺少 mdia'));
  final mdiaChildren = _children(input, mdia);
  final mdhd = _find(mdiaChildren, 'mdhd') ??
      (throw const Fmp4RemuxException('音频轨缺少 mdhd'));
  final hdlr = _find(mdiaChildren, 'hdlr') ??
      (throw const Fmp4RemuxException('音频轨缺少 hdlr'));

  final mdhdVersion = input[mdhd.payloadStart];
  final mediaTimescale = _readTimescale(input, mdhd);
  if (mediaTimescale <= 0) {
    throw const Fmp4RemuxException('音频轨 timescale 非法');
  }

  final minf = _find(mdiaChildren, 'minf') ??
      (throw const Fmp4RemuxException('音频轨缺少 minf'));
  final minfChildren = _children(input, minf);
  final stbl = _find(minfChildren, 'stbl') ??
      (throw const Fmp4RemuxException('音频轨缺少 stbl'));
  final stblChildren = _children(input, stbl);
  final stsd = _find(stblChildren, 'stsd') ??
      (throw const Fmp4RemuxException('音频轨缺少 stsd'));

  final moovChildren = _children(input, moov);
  final mvhd = _find(moovChildren, 'mvhd') ??
      (throw const Fmp4RemuxException('缺少 mvhd'));
  final movieTimescale = _readTimescale(input, mvhd);

  // ── 2. 遍历所有 moof/mdat，收集采样描述 ──────────────────────
  final samples = <_Sample>[];
  _Fragment? pendingFragment;

  for (final box in top) {
    if (box.type == 'moof') {
      pendingFragment = _parseMoof(input, box, trackId);
      continue;
    }
    if (box.type != 'mdat' || pendingFragment == null) continue;

    final fragmentSamples = pendingFragment.samples;
    for (final sample in fragmentSamples) {
      if (sample.sourceOffset < box.payloadStart ||
          sample.sourceOffset + sample.size > box.end) {
        throw Fmp4RemuxException(
          '采样数据超出 mdat 边界（offset=${sample.sourceOffset}, size=${sample.size}）',
        );
      }
    }
    samples.addAll(fragmentSamples);
    pendingFragment = null;
  }

  if (samples.isEmpty) {
    throw const Fmp4RemuxException('没有从 moof 里解析出任何采样');
  }

  // ── 3. 组装输出：ftyp + mdat + moov ──────────────────────────
  // moov 放在末尾，采样偏移只由 ftyp 和 mdat 头决定，不必二次回填。
  final ftypBytes = _slice(input, ftyp.start, ftyp.end);
  final mdatHeaderSize = 8;
  final payloadStart = ftypBytes.length + mdatHeaderSize;
  var writeCursor = payloadStart;
  final sampleOffsets = <int>[];
  final sampleSizes = <int>[];
  final durations = <int>[];
  final compositionOffsets = <int>[];
  final sampleFlags = <int>[];

  final mdatPayload = BytesBuilder(copy: false);
  for (final sample in samples) {
    sampleOffsets.add(writeCursor);
    sampleSizes.add(sample.size);
    durations.add(sample.duration);
    compositionOffsets.add(sample.compositionOffset);
    sampleFlags.add(sample.flags);
    writeCursor += sample.size;
    mdatPayload.add(_slice(input, sample.sourceOffset, sample.sourceOffset + sample.size));
  }
  final mdatPayloadBytes = mdatPayload.takeBytes();
  if (ftypBytes.length + mdatHeaderSize + mdatPayloadBytes.length > 0xFFFFFFFF) {
    throw const Fmp4RemuxException('文件超过 4GB，暂不支持');
  }

  final totalDuration = durations.fold<int>(0, (sum, value) => sum + value);
  final movieDuration = movieTimescale > 0
      ? (totalDuration * movieTimescale / mediaTimescale).round()
      : totalDuration;

  final newStbl = _box('stbl', <Uint8List>[
    _slice(input, stsd.start, stsd.end), // 只保留解码器配置，不复制旧的空表
    _buildStts(durations),
    if (compositionOffsets.any((value) => value != 0))
      _buildCtts(compositionOffsets),
    if (sampleFlags.any((value) => (value & 0x00010000) != 0))
      _buildStss(samples.length),
    _fullBox('stsc', 0, 0, _u32List(<int>[1, 1, 1])),
    _fullBox('stsz', 0, 0, <int>[
      ..._u32List(<int>[0, samples.length]),
      ...sampleSizes.expand(_u32Bytes),
    ]),
    _buildChunkOffsets(sampleOffsets),
  ]);

  final minfOther = minfChildren
      .where((box) => box.type != 'stbl')
      .map((box) => _slice(input, box.start, box.end))
      .toList();
  final newMinf = _box('minf', <Uint8List>[...minfOther, newStbl]);
  final newMdia = _box('mdia', <Uint8List>[
    _patchDuration(input, mdhd, mdhdVersion, totalDuration),
    _slice(input, hdlr.start, hdlr.end),
    newMinf,
  ]);
  final tkhdVersion = input[tkhd.payloadStart];
  final newTrak = _box('trak', <Uint8List>[
    _patchDuration(input, tkhd, tkhdVersion, movieDuration),
    newMdia,
  ]);
  final mvhdVersion = input[mvhd.payloadStart];
  final newMoov = _box('moov', <Uint8List>[
    _patchDuration(input, mvhd, mvhdVersion, movieDuration),
    newTrak,
  ]);

  final output = BytesBuilder(copy: false)
    ..add(ftypBytes)
    ..add(_box('mdat', <Uint8List>[mdatPayloadBytes]))
    ..add(newMoov);
  return output.takeBytes();
}

// ── moof 解析 ────────────────────────────────────────────────

_Fragment _parseMoof(Uint8List bytes, _Box moof, int trackId) {
  final samples = <_Sample>[];
  for (final child in _children(bytes, moof)) {
    if (child.type != 'traf') continue;
    final trafChildren = _children(bytes, child);
    final tfhd = _find(trafChildren, 'tfhd');
    if (tfhd == null) continue;

    final reader = _Reader(bytes, tfhd.payloadStart);
    reader.skip(4); // version + flags
    final fragmentTrackId = reader.u32();
    if (fragmentTrackId != trackId) continue;

    final flags = _u24(bytes, tfhd.payloadStart + 1);
    var base = moof.start;
    var defaultDuration = 0;
    var defaultSize = 0;
    var defaultFlags = 0;
    if ((flags & 0x000001) != 0) base = reader.u64();
    if ((flags & 0x000002) != 0) reader.skip(4); // sample_description_index
    if ((flags & 0x000008) != 0) defaultDuration = reader.u32();
    if ((flags & 0x000010) != 0) defaultSize = reader.u32();
    if ((flags & 0x000020) != 0) defaultFlags = reader.u32();
    if ((flags & 0x020000) != 0) base = moof.start;

    for (final trun in trafChildren.where((box) => box.type == 'trun')) {
      final version = bytes[trun.payloadStart];
      final trunFlags = _u24(bytes, trun.payloadStart + 1);
      final sampleReader = _Reader(bytes, trun.payloadStart + 4);
      final count = sampleReader.u32();
      if (count > 1000000) {
        throw Fmp4RemuxException('trun 采样数异常：$count');
      }

      int? dataOffset;
      int? firstSampleFlags;
      if ((trunFlags & 0x000001) != 0) dataOffset = sampleReader.i32();
      if ((trunFlags & 0x000004) != 0) firstSampleFlags = sampleReader.u32();

      // data_offset 是相对 base 的；没有就紧接在 moof 之后。
      final fragmentDataStart = dataOffset == null
          ? base + moof.size
          : base + dataOffset;
      var relative = 0;

      for (var i = 0; i < count; i++) {
        final duration = (trunFlags & 0x000100) != 0
            ? sampleReader.u32()
            : defaultDuration;
        final size = (trunFlags & 0x000200) != 0
            ? sampleReader.u32()
            : defaultSize;
        final sampleFlagValue = (trunFlags & 0x000400) != 0
            ? sampleReader.u32()
            : (i == 0 && firstSampleFlags != null
                ? firstSampleFlags
                : defaultFlags);
        final composition = (trunFlags & 0x000800) != 0
            ? (version == 0 ? sampleReader.u32() : sampleReader.i32())
            : 0;
        if (size <= 0) {
          throw const Fmp4RemuxException('采样大小为 0，无法 remux');
        }
        samples.add(_Sample(
          size: size,
          duration: duration,
          flags: sampleFlagValue,
          compositionOffset: composition,
        )..sourceOffset = fragmentDataStart + relative);
        relative += size;
      }
    }
  }
  return _Fragment(samples);
}

// ── box 构造 ────────────────────────────────────────────────

Uint8List _box(String type, List<Uint8List> payloads) {
  var length = 8;
  for (final payload in payloads) {
    length += payload.length;
  }
  final result = BytesBuilder(copy: false)
    ..add(_u32Bytes(length))
    ..add(_ascii(type));
  for (final payload in payloads) {
    result.add(payload);
  }
  return result.takeBytes();
}

Uint8List _fullBox(String type, int version, int flags, List<int> payload) {
  return _box(type, <Uint8List>[
    Uint8List.fromList(<int>[
      version,
      (flags >> 16) & 0xFF,
      (flags >> 8) & 0xFF,
      flags & 0xFF,
    ]),
    Uint8List.fromList(payload),
  ]);
}

Uint8List _buildStts(List<int> durations) {
  final counts = <int>[];
  final deltas = <int>[];
  for (final duration in durations) {
    if (deltas.isNotEmpty && deltas.last == duration) {
      counts[counts.length - 1]++;
    } else {
      counts.add(1);
      deltas.add(duration);
    }
  }
  final payload = <int>[..._u32Bytes(counts.length)];
  for (var i = 0; i < counts.length; i++) {
    payload.addAll(_u32Bytes(counts[i]));
    payload.addAll(_u32Bytes(deltas[i]));
  }
  return _fullBox('stts', 0, 0, payload);
}

Uint8List _buildCtts(List<int> offsets) {
  final counts = <int>[];
  final values = <int>[];
  for (final offset in offsets) {
    if (values.isNotEmpty && values.last == offset) {
      counts[counts.length - 1]++;
    } else {
      counts.add(1);
      values.add(offset);
    }
  }
  final version = values.any((value) => value < 0) ? 1 : 0;
  final payload = <int>[..._u32Bytes(counts.length)];
  for (var i = 0; i < counts.length; i++) {
    payload.addAll(_u32Bytes(counts[i]));
    payload.addAll(_u32Bytes(values[i] & 0xFFFFFFFF));
  }
  return _fullBox('ctts', version, 0, payload);
}

Uint8List _buildStss(int sampleCount) {
  final payload = <int>[
    ..._u32Bytes(sampleCount),
    ...List<int>.generate(sampleCount, (index) => index + 1).expand(_u32Bytes),
  ];
  return _fullBox('stss', 0, 0, payload);
}

Uint8List _buildChunkOffsets(List<int> offsets) {
  final use64 = offsets.any((value) => value > 0xFFFFFFFF);
  final payload = <int>[
    ..._u32Bytes(offsets.length),
    ...offsets.expand(
      (value) => use64 ? _u64Bytes(value) : _u32Bytes(value),
    ),
  ];
  return _fullBox(use64 ? 'co64' : 'stco', 0, 0, payload);
}

Uint8List _patchDuration(
  Uint8List bytes,
  _Box box,
  int version,
  int duration,
) {
  final copy = Uint8List.fromList(_slice(bytes, box.start, box.end));
  final offset = box.type == 'tkhd'
      ? (version == 0 ? 28 : 36)
      : (version == 0 ? 24 : 32);
  if (version == 0) {
    _writeU32(copy, offset, duration);
  } else {
    _writeU64(copy, offset, duration);
  }
  return copy;
}

// ── box 读取工具 ────────────────────────────────────────────

List<_Box> _boxes(Uint8List bytes, int start, int end) {
  final result = <_Box>[];
  var cursor = start;
  while (cursor + 8 <= end) {
    var size = _readU32(bytes, cursor);
    final type = _asciiAt(bytes, cursor + 4, 4);
    var header = 8;
    if (size == 1) {
      if (cursor + 16 > end) {
        throw Fmp4RemuxException('盒 $type 的扩展长度不完整');
      }
      size = _readU64(bytes, cursor + 8);
      header = 16;
    } else if (size == 0) {
      size = end - cursor;
    }
    if (size < header || cursor + size > end) {
      throw Fmp4RemuxException('盒 $type 大小非法：$size');
    }
    result.add(_Box(type, cursor, size, header));
    cursor += size;
  }
  return result;
}

List<_Box> _children(Uint8List bytes, _Box box) =>
    _boxes(bytes, box.payloadStart, box.end);

_Box? _find(List<_Box> boxes, String type) {
  for (final box in boxes) {
    if (box.type == type) return box;
  }
  return null;
}

_Box? _findAudioTrack(Uint8List bytes, _Box moov) {
  for (final trak in _children(bytes, moov).where((box) => box.type == 'trak')) {
    final mdia = _find(_children(bytes, trak), 'mdia');
    if (mdia == null) continue;
    final hdlr = _find(_children(bytes, mdia), 'hdlr');
    if (hdlr == null) continue;
    if (_asciiAt(bytes, hdlr.payloadStart + 8, 4) == 'soun') return trak;
  }
  return null;
}

int _readTrackId(Uint8List bytes, _Box tkhd) {
  final version = bytes[tkhd.payloadStart];
  final offset = tkhd.payloadStart + (version == 0 ? 12 : 20);
  return _readU32(bytes, offset);
}

int _readTimescale(Uint8List bytes, _Box box) {
  final version = bytes[box.payloadStart];
  final offset = box.payloadStart + (version == 0 ? 12 : 20);
  return _readU32(bytes, offset);
}

class _Reader {
  final Uint8List bytes;
  int _offset;

  _Reader(this.bytes, this._offset);

  int get offset => _offset;

  void skip(int count) => _offset += count;

  int u32() {
    final value = _readU32(bytes, _offset);
    _offset += 4;
    return value;
  }

  int i32() {
    final value = u32();
    return value >= 0x80000000 ? value - 0x100000000 : value;
  }

  int u64() {
    final value = _readU64(bytes, _offset);
    _offset += 8;
    return value;
  }
}

int _readU32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _readU64(Uint8List bytes, int offset) =>
    ByteData.view(bytes.buffer, bytes.offsetInBytes + offset, 8)
        .getUint64(0, Endian.big);

int _u24(Uint8List bytes, int offset) =>
    (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];

void _writeU32(Uint8List bytes, int offset, int value) {
  bytes[offset] = (value >> 24) & 0xFF;
  bytes[offset + 1] = (value >> 16) & 0xFF;
  bytes[offset + 2] = (value >> 8) & 0xFF;
  bytes[offset + 3] = value & 0xFF;
}

void _writeU64(Uint8List bytes, int offset, int value) {
  final data = ByteData.view(bytes.buffer, bytes.offsetInBytes + offset, 8);
  data.setUint64(0, value, Endian.big);
}

Uint8List _slice(Uint8List bytes, int start, int end) =>
    Uint8List.sublistView(bytes, start, end);

String _asciiAt(Uint8List bytes, int start, int length) =>
    String.fromCharCodes(bytes, start, start + length);

Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);

List<int> _u32Bytes(int value) => <int>[
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

List<int> _u64Bytes(int value) => <int>[
      (value >> 56) & 0xFF,
      (value >> 48) & 0xFF,
      (value >> 40) & 0xFF,
      (value >> 32) & 0xFF,
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

List<int> _u32List(Iterable<int> values) =>
    values.expand(_u32Bytes).toList();
