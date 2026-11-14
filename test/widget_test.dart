// 只测不依赖网络的部分：LRC 解析。
// 页面级测试要 mock 接口，等以后接测试框架再说。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/siren_api.dart';

void main() {
  test('LRC 解析：时间戳转成 Duration，纯时间戳的空行丢掉', () {
    const raw = '''
[00:14.89]制作/作曲：DJ OKAWARI
[00:20.89]
[00:22.89]Flashback of the memory
''';

    final lines = SirenApi.parseLrc(raw);

    expect(lines.length, 2);
    expect(
      lines.first.time,
      const Duration(minutes: 0, seconds: 14, milliseconds: 890),
    );
    expect(lines.first.text, '制作/作曲：DJ OKAWARI');
    expect(lines.last.text, 'Flashback of the memory');
  });

  test('LRC 解析：三位毫秒也能认，乱序会排好', () {
    const raw = '''
[00:10.500]第二句
[00:05.05]第一句
''';

    final lines = SirenApi.parseLrc(raw);

    expect(lines.length, 2);
    expect(lines[0].text, '第一句');
    expect(lines[0].time, const Duration(seconds: 5, milliseconds: 50));
    expect(lines[1].text, '第二句');
    expect(lines[1].time, const Duration(seconds: 10, milliseconds: 500));
  });

  test('LRC 解析：没有时间戳的行直接跳过', () {
    const raw = '这是一行普通文字\n[00:01.00]正式歌词\n';

    final lines = SirenApi.parseLrc(raw);

    expect(lines.length, 1);
    expect(lines.single.text, '正式歌词');
  });
}
