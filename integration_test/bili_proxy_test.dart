// 端到端验证「前端 → Go 反代 → B站」整条链路。
//
// 这个用例的价值在于它跑的是真正的前端代码路径，而不是 curl：
//   · 搜索走的是 BiliApi 的透明反代封装（带 X-Session、Referer 由服务端补）
//   · 媒体地址在原生端**不会**被包装：反代只服务 Web 的 <video>/<audio>，
//     桌面/手机由 libmpv 自己带 Referer
//   · 播放交给 media_kit，进度真的往前走才算通过
//
// 需要先在本地起服务：
//   cd server && ./biliproxy -addr 127.0.0.1:8787
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:podenco_music/bili_api.dart';
import 'package:podenco_music/player_model.dart';

const _proxy = 'http://127.0.0.1:8787';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // flutter_test 默认把 HttpClient 拦成返回 400，真实网络测试要放开
    HttpOverrides.global = null;
  });

  tearDownAll(() async {
    // 别把反代配置留给下一个用例 / 用户
    await BiliApi.setProxy('');
  });

  testWidgets('反代：探活、搜索、取流、播放', (tester) async {
    // 1. 配置反代。这一步内部会 POST /bili/session，
    //    顺带验证服务是通的 —— 不通会直接返回 false
    final ok = await BiliApi.setProxy(_proxy);
    expect(ok, isTrue, reason: '反代会话建立失败，先确认服务已启动');
    expect(BiliApi.proxyEnabled, isTrue);

    // 2. 搜索。这是被 Origin 挡死的那一层，走反代之后必须能拿到结果
    final videos = await BiliApi.searchVideos('明日方舟');
    // ignore: avoid_print
    print('反代搜索到 ${videos.length} 条，首条：${videos.isEmpty ? '无' : videos.first.title}');
    expect(videos, isNotEmpty, reason: '反代搜索没有结果');

    final first = videos.first;

    // 3. 媒体地址在原生端必须是**直连 CDN**：反代只给 Web 用
    //    （浏览器设不了 Referer），libmpv 自己带，走直链少一跳。
    //    地址里出现 127.0.0.1:8787/bili/media 反而是错的。
    final urls = await BiliApi.audioUrls(first.bvid);
    expect(urls, isNotEmpty, reason: '没拿到音轨候选地址');
    // ignore: avoid_print
    print('取流地址：${urls.first.substring(0, urls.first.length.clamp(0, 90))}…');
    expect(urls.first, isNot(contains('/bili/media/')),
        reason: '原生端不该把媒体地址包成反代地址');
    expect(urls.first, contains('bilivideo'), reason: '媒体地址应该指向 CDN');

    // 4. 真的放一遍。走到这里说明 CDN 直链 + 请求头确实能解码出声，
    //    而不只是拿到一个 200 的壳子
    final watch = Stopwatch()..start();
    await playerModel.playQueue([first.toTrack()]);

    var startedAt = -1;
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (playerModel.position.inMilliseconds > 300) {
        startedAt = watch.elapsedMilliseconds;
        break;
      }
    }
    // ignore: avoid_print
    print('反代起播耗时：${startedAt}ms，报错：${playerModel.error}');

    expect(playerModel.error, isNull, reason: '播放报错：${playerModel.error}');
    expect(startedAt, greaterThan(0), reason: '15 秒内进度都没动，直链取流没成功');

    await playerModel.pause();
  });

  // 会话相关的两个用例
  _sessionReuseTests();
}

// 会话复用是「不掉登录」的关键，单独一个用例盯着它。
//
// 之前的行为是每次启动都新建会话：客户端的登录凭证持久化，服务端的会话
// 却换了新的，两者一错开，界面上还写着「已登录」，请求却全被当成匿名。
void _sessionReuseTests() {
  testWidgets('会话：旧 sid 可复用，失效时自动重建', (tester) async {
    final ok = await BiliApi.setProxy(_proxy);
    expect(ok, isTrue);

    final first = BiliApi.sid;
    expect(first, isNotNull, reason: '建立反代后应该有 sid');

    // 1. 拿旧 sid 恢复：必须原样复用，不能新建
    final reused = await BiliApi.restoreProxy(_proxy, first);
    expect(reused, isTrue);
    expect(BiliApi.sid, first, reason: '有效的 sid 不该被换掉');

    // 2. 拿一个服务端不认识的 sid：应该走重建
    final unknown = '0123456789abcdef0123456789abcdef';
    final rebuilt = await BiliApi.restoreProxy(_proxy, unknown);
    expect(rebuilt, isTrue);
    expect(BiliApi.sid, isNot(unknown), reason: '未知 sid 必须被替换');
    expect(BiliApi.sid, isNotNull);

    // 3. 新建出来的会话在服务端确实存在
    expect(await BiliApi.sessionKnown(), isTrue);
  });

  testWidgets('会话：凭证可以推回服务端', (tester) async {
    // 用一串测试专用的假凭证，验证「只写不读」这条链路通
    final ok = await BiliApi.setProxy(_proxy);
    expect(ok, isTrue);

    final imported = await BiliApi.importSession(
      cookie: 'SESSDATA=integration-test; bili_jct=csrf; DedeUserID=1',
      mid: 1,
    );
    expect(imported, isTrue, reason: '服务端应接受这份凭证');

    // 空 cookie 不该发请求，直接返回 false
    expect(await BiliApi.importSession(cookie: null), isFalse);
    expect(await BiliApi.importSession(cookie: ''), isFalse);
  });
}
