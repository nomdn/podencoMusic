// 真实网络的冒烟检查。文件名不带 _test 后缀，`flutter test` 不会自动收它，
// 需要时手动跑：flutter test test/bili_live_check.dart
//
// 存在的意义：B站接口对请求头、Cookie、风控非常敏感，curl 通的组合
// 换成 Dart 的 http 包不一定还通。改 bili_api.dart 之后跑一遍这个。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/bili_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // flutter_test 默认把所有 HttpClient 请求拦成 400（保证测试不发真请求）。
    // 这个文件就是要发真请求，必须把拦截摘掉。
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  test('访客 cookie → 视频搜索', () async {
    await BiliApi.ensureGuestCookie();
    final videos = await BiliApi.searchVideos('明日方舟');
    expect(videos, isNotEmpty);

    final first = videos.first;
    // ignore: avoid_print
    print('视频 ${videos.length} 条；首条：${first.bvid} / ${first.title} / '
        '${first.durationMs}ms / ${first.cover}');
    expect(first.bvid, startsWith('BV'));
    expect(first.title, isNot(contains('<em')));
  });

  test('UP 主搜索', () async {
    final ups = await BiliApi.searchUps('塞壬唱片');
    expect(ups, isNotEmpty);
    // ignore: avoid_print
    print('UP ${ups.length} 个；首个：${ups.first.mid} / ${ups.first.name} / '
        '${ups.first.subtitle}');
  });

  test('UP 视频列表（搜索 + 按 mid 过滤）', () async {
    final ups = await BiliApi.searchUps('魔法Zc目录');
    expect(ups, isNotEmpty);
    final target = ups.firstWhere(
      (up) => up.mid == 13164144,
      orElse: () => ups.first,
    );

    final videos = await BiliApi.upVideos(target.mid, target.name);
    // ignore: avoid_print
    print('${target.name}：${videos.length} 个视频');
    expect(videos, isNotEmpty);
    expect(videos.every((v) => v.mid == target.mid), isTrue);
  });

  test('音频地址可以换出来', () async {
    final url = await BiliApi.audioUrl('BV1ZVsn6nEMn');
    // ignore: avoid_print
    print('音频：${url.substring(0, url.length > 80 ? 80 : url.length)}…');
    expect(url, startsWith('http'));
    expect(url, contains('bilivideo'));
  });

  // 字幕要用真登录态跑：字幕列表只有登录后才给。
  //
  //   BILI_PROXY=http://127.0.0.1:8787 BILI_SID=<sid> \
  //     flutter test test/bili_live_check.dart --plain-name 字幕
  //
  // 这条盯的是一个具体的 bug：未签名的 `x/player/v2` 会给**别的视频**的
  // AI 字幕（播放页歌词和画面完全对不上）。签名之后没有字幕就必须是空。
  test('字幕：签名接口，不串台', () async {
    final proxy = Platform.environment['BILI_PROXY'];
    final sid = Platform.environment['BILI_SID'];
    if (proxy == null || sid == null) {
      // ignore: avoid_print
      print('跳过：没给 BILI_PROXY / BILI_SID');
      return;
    }

    expect(await BiliApi.restoreProxy(proxy, sid), isTrue);

    // 官方 MV，账号能看到 12 条官方字幕，中文那条 47 行、末条 211s（视频 213s）
    final real = await BiliApi.subtitleLines('BV1GJ411x7h7');
    // ignore: avoid_print
    print('有字幕的视频：${real.length} 行；首句 ${real.isEmpty ? "-" : real.first.text}');
    expect(real, isNotEmpty);
    expect(real.first.text, isNotEmpty);

    // 这个视频本来一条字幕都没有。串台时这里会冒出「帕尼尼减肥法」那种内容。
    final none = await BiliApi.subtitleLines('BV1mpnd64Ep2');
    // ignore: avoid_print
    print('没字幕的视频：${none.length} 行');
    expect(none, isEmpty);
  });
}
