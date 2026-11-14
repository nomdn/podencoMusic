import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:podenco_music/audio_tags.dart';

int indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('debug_tags');
  final file = File('${dir.path}${Platform.pathSeparator}cdn.mp3');

  final oldTag = BytesBuilder();
  oldTag.add(utf8.encode('ID3'));
  oldTag.add([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09]);
  oldTag.add(utf8.encode('TRCK11/99'));
  final marker = utf8.encode('MPEG_AUDIO_DATA');
  oldTag.add(marker);
  await file.writeAsBytes(oldTag.toBytes());
  final input = await file.readAsBytes();
  print('input length=${input.length}');
  print('input ID3@${indexOf(input, utf8.encode("ID3"))} '
      'TRCK11/99@${indexOf(input, utf8.encode("TRCK11/99"))} '
      'MPEG@${indexOf(input, marker)}');

  const tag = AudioTag(title: '用不上的雨刷', artist: '塞壬唱片-MSR', album: '酸橙OST', trackNumberText: '3/12');
  final tagBytes = buildId3v2(tag);
  print('tagBytes length=${tagBytes.length}');

  await writeMp3Tags(file, tag);

  final output = await file.readAsBytes();
  print('output length=${output.length}');
  print('output ID3@${indexOf(output, utf8.encode("ID3"))} '
      'TIT2@${indexOf(output, utf8.encode("TIT2"))} '
      'TRCK@${indexOf(output, utf8.encode("TRCK"))} '
      'TRCK11/99@${indexOf(output, utf8.encode("TRCK11/99"))} '
      'TALB@${indexOf(output, utf8.encode("TALB"))} '
      'MPEG@${indexOf(output, marker)}');
  await dir.delete(recursive: true);
}
