// CLI 诊断工具：生成一个模拟塞壬 CDN 结构的 WAV，走真实的 writeWavTags，
// 产出的文件留给 ffprobe / mutagen 检查标签是否真的可读。
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:podenco_music/audio_tags.dart';

Uint8List _le32(int v) => Uint8List.fromList([
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
]);

Future<void> main() async {
  final dir = Directory('build/probe');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File('${dir.path}/song.wav');

  // 模拟塞壬 CDN：JUNK + fmt + 只有 4 字节的空 LIST/INFO + data
  final b = BytesBuilder();
  b.add('RIFF'.codeUnits);
  b.add(_le32(0));
  b.add('WAVE'.codeUnits);
  b.add('JUNK'.codeUnits);
  b.add(_le32(28));
  b.add(List<int>.filled(28, 0));
  b.add('fmt '.codeUnits);
  b.add(_le32(16));
  b.add([1, 0, 2, 0]); // PCM / 2ch
  b.add(_le32(44100));
  b.add(_le32(176400));
  b.add([4, 0]);
  b.add([16, 0]);
  b.add('LIST'.codeUnits);
  b.add(_le32(4));
  b.add('INFO'.codeUnits);
  b.add('data'.codeUnits);
  b.add(_le32(3528));
  b.add(List<int>.filled(3528, 0));
  await file.writeAsBytes(b.toBytes());

  await writeWavTags(
    file,
    const AudioTag(
      title: '用不上的雨刷',
      artist: '塞壬唱片-MSR',
      album: '直到大地变成一颗酸橙OST',
    ),
  );

  print(file.absolute.path);
  print('size=${await file.length()}');
}
