import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 音频元数据（ID3v2.3）写入。下载完成后把歌名 / 艺人 / 专辑 /
/// 曲目号 / 专辑封面写进音频文件，音乐播放器和文件管理器才能
/// 认出这是哪首歌、显示封面。
///
/// 两种载体：
///   MP3 → 文件头部的 ID3v2.3 标签（业界标准，所有播放器都认）
///   WAV → RIFF `id3 ` 附加块（文件尾追加 + 修正 RIFF 长度字段；
///         foobar2000 / VLC / MusicBee 认它，Windows 资源管理器
///         只认 RIFF INFO —— 这是 WAV 格式本身没有统一解法的坑）
///
/// 文本帧一律 UTF-16 + BOM：塞壬歌名大量中文，ISO-8859-1 装不下。
class AudioTag {
  const AudioTag({
    required this.title,
    required this.artist,
    this.album,
    this.trackNumberText,
    this.coverBytes,
    this.coverMime = 'image/jpeg',
  });

  final String title;
  final String artist;

  /// 所属专辑名，没有就不写 TALB 帧。
  final String? album;

  /// 形如 "3/12"，null 就不写 TRCK 帧。
  final String? trackNumberText;

  /// 专辑封面图原始字节（JPEG 或 PNG），null 就不写 APIC 帧。
  final Uint8List? coverBytes;

  /// 封面的 MIME（按文件魔数判断，写入 APIC 时用）。
  final String coverMime;
}

/// 组装完整的 ID3v2.3 字节（含 10 字节文件头）。
Uint8List buildId3v2(AudioTag tag) {
  final frames = BytesBuilder();
  frames.add(_textFrame('TIT2', tag.title));
  if (tag.artist.isNotEmpty) frames.add(_textFrame('TPE1', tag.artist));
  final album = tag.album;
  if (album != null && album.isNotEmpty) {
    frames.add(_textFrame('TALB', album));
  }
  final trackNo = tag.trackNumberText;
  if (trackNo != null && trackNo.isNotEmpty) {
    frames.add(_textFrame('TRCK', trackNo));
  }
  final cover = tag.coverBytes;
  if (cover != null && cover.isNotEmpty) {
    frames.add(_apicFrame(cover, tag.coverMime));
  }

  final payload = frames.toBytes();
  final out = BytesBuilder();
  out.add(ascii.encode('ID3'));
  out.add([0x03, 0x00]); // 版本 2.3.0
  out.add([0x00]); // flags：无 unsync / 无扩展头
  out.add(_syncsafe(payload.length));
  out.add(payload);
  return out.toBytes();
}

/// MP3：把 ID3v2 写到文件头部。流式搬运原文件内容，
/// 几十 MB 也不会整个读进内存。CDN 的 MP3 自带一个不完整的 ID3v2
/// （只有曲目号和年份，没有歌名封面）—— 写入时跳过旧标签，避免
/// 同一文件里叠两个 ID3（不同播放器读头读尾的行为不一致）。
Future<void> writeMp3Tags(File file, AudioTag tag) async {
  // 先读文件头判断旧标签要跳过多长
  final head = await _readHead(file, 64);
  var contentOffset = 0;
  while (contentOffset + 10 <= head.length &&
      head[contentOffset] == 0x49 &&
      head[contentOffset + 1] == 0x44 &&
      head[contentOffset + 2] == 0x33) {
    // ID3v2 头里的长度是 syncsafe 编码
    final size = (head[contentOffset + 6] << 21) |
        (head[contentOffset + 7] << 14) |
        (head[contentOffset + 8] << 7) |
        head[contentOffset + 9];
    contentOffset += 10 + size;
  }

  final tagBytes = buildId3v2(tag);
  final tmp = File('${file.path}.tagtmp');
  final sink = tmp.openWrite();
  try {
    sink.add(tagBytes);
    await sink.addStream(file.openRead(contentOffset, null));
    await sink.flush();
    await sink.close();
    await tmp.rename(file.path);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}

Future<Uint8List> _readHead(File file, int count) async {
  final raf = await file.open();
  try {
    await raf.setPosition(0);
    return await raf.read(count);
  } finally {
    await raf.close();
  }
}

/// WAV：追加 RIFF `LIST/INFO` 与 `id3 ` 两个块，再修正 RIFF 长度字段
/// （偏移 4 的 LE DWORD = 文件总长 - 8）。写入后 RIFF 结构依然合法。
///
/// 为什么两份都写：WAV 没有统一的标签标准，不同播放器各读各的。
///   · `LIST/INFO`（INAM / IART / IPRD）是 RIFF 原生写法，Windows、
///     不少播放器与部分 Android 解析器认这个；
///   · `id3 ` 块是安卓系播放器的常见做法，和 MP3 那份 ID3v2.3 是同一批字节。
/// 实测华为手表对只带 `id3 ` 块的 WAV 仍显示未知，所以补一份 INFO ——
/// 它读哪个都行，最差也能多一条线索。
Future<void> writeWavTags(File file, AudioTag tag) async {
  // 只处理真 WAV：头 12 字节必须是 RIFF....WAVE
  final raf = await file.open(mode: FileMode.append);
  try {
    await raf.setPosition(0);
    final head = await raf.read(12);
    final isWave = head.length == 12 &&
        head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46 &&
        head[8] == 0x57 && head[9] == 0x41 && head[10] == 0x56 && head[11] == 0x45;
    if (!isWave) {
      throw const FormatException('不是 RIFF/WAVE 文件');
    }

    final tagBytes = buildId3v2(tag);
    final chunk = BytesBuilder();
    final info = _riffInfoChunk(tag);
    if (info != null) chunk.add(info);
    chunk.add(ascii.encode('id3 '));
    chunk.add(_le32(tagBytes.length));
    chunk.add(tagBytes);
    // RIFF 块要 2 字节对齐：奇数长度补一个 pad 字节（不计入块大小）
    if (tagBytes.length.isOdd) chunk.add([0x00]);

    await raf.setPosition(file.lengthSync());
    await raf.writeFrom(chunk.toBytes());

    // 修正 RIFF 长度字段：此时 raf.length() 已包含 pad 字节
    final newSize = await raf.length() - 8;
    await raf.setPosition(4);
    await raf.writeFrom(_le32(newSize));
  } finally {
    await raf.close();
  }
}

/// 把 AudioTag 拼成 RIFF 的 `LIST`/`INFO` 块；没有任何可用字段时返回 null。
///
/// 子块格式：4 字节 ID + 4 字节 LE 长度 + 以 0 结尾的字符串，奇数长度补 pad。
/// 文本按 UTF-8 写 —— INFO 名义上是 ANSI，但塞壬大量中文，写 GBK 只会更糟；
/// 读得懂 UTF-8 的解析器能正确显示，读不懂的至少 ASCII 部分还在。
Uint8List? _riffInfoChunk(AudioTag tag) {
  final subs = BytesBuilder();
  var count = 0;

  void add(String id, String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    final body = <int>[...utf8.encode(v), 0x00];
    subs.add(ascii.encode(id));
    subs.add(_le32(body.length));
    subs.add(body);
    if (body.length.isOdd) subs.add([0x00]);
    count++;
  }

  add('INAM', tag.title);
  add('IART', tag.artist);
  add('IPRD', tag.album ?? '');
  if (count == 0) return null;

  final body = subs.toBytes();
  final out = BytesBuilder();
  out.add(ascii.encode('LIST'));
  // LIST 的长度 = 'INFO' 四个字节 + 所有子块（含各自的 pad）
  out.add(_le32(body.length + 4));
  out.add(ascii.encode('INFO'));
  out.add(body);
  if ((body.length + 4).isOdd) out.add([0x00]);
  return out.toBytes();
}

/// 单个帧：帧 ID(4) + 大端长度(4) + 标志(2) + 内容。
Uint8List _frame(String id, List<int> body) {
  final out = BytesBuilder();
  out.add(ascii.encode(id));
  final size = body.length;
  out.add([
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
  ]);
  out.add([0x00, 0x00]);
  out.add(body);
  return out.toBytes();
}

/// v2.3 文本帧内容：0x01 编码标记 + UTF-16LE(带 BOM) + 终止符。
Uint8List _textFrame(String id, String value) {
  final payload = BytesBuilder();
  payload.add([0x01]);
  payload.add(_utf16WithBom(value));
  return _frame(id, payload.toBytes());
}

Uint8List _utf16WithBom(String value) {
  final out = BytesBuilder();
  out.add([0xFF, 0xFE]); // LE BOM
  for (final unit in value.codeUnits) {
    out.add([unit & 0xFF, (unit >> 8) & 0xFF]);
  }
  out.add([0x00, 0x00]); // 终止符
  return out.toBytes();
}

/// APIC 封面帧：ISO 编码标记 + MIME + 图片类型(0x03 正封面) + 空描述 + 图。
Uint8List _apicFrame(Uint8List image, String mime) {
  final payload = BytesBuilder();
  payload.add([0x00]);
  payload.add(ascii.encode(mime));
  payload.add([0x00]);
  payload.add([0x03]);
  payload.add([0x00]);
  payload.add(image);
  return _frame('APIC', payload.toBytes());
}

/// ID3v2.3 的标签长度用 syncsafe 编码（每字节最高位恒 0）。
Uint8List _syncsafe(int size) => Uint8List.fromList([
  (size >> 21) & 0x7F,
  (size >> 14) & 0x7F,
  (size >> 7) & 0x7F,
  size & 0x7F,
]);

Uint8List _le32(int v) => Uint8List.fromList([
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
]);
