// 真机（Windows 桌面）端到端验证：B站音轨能不能真的放出声。
//
// `flutter test` 里跑不了 —— 那是纯 Dart VM，没有插件；这条要
//   flutter test integration_test/bili_audio_test.dart -d windows
// 会在真窗口里启动应用，用真实的 libmpv（media_kit）。
//
// 之所以要这么验，是因为「音频放不了」的根因在原生解码层：
// 播放器拿不到请求头时不会抛可读的异常，只会静默失败。只有看
// position 有没有真的往前走，才能确定是真出声了。
//
// 注意这条路径**不经过任何反代**：libmpv 自己带 Referer / UA，
// 直接吃 B站 CDN 的 fMP4 音轨。
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:podenco_music/models.dart';
import 'package:podenco_music/player_model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('B站音轨：直连 CDN 流式放出声', (tester) async {
    // 这是个老视频，地址相对稳定，适合当冒烟用例
    const bvid = 'BV1ZVsn6nEMn';

    await playerModel.playQueue([
      const Track(
        cid: bvid,
        name: '冒烟用例',
        albumCid: '',
        artists: ['测试'],
        source: TrackSource.bilibili,
      ),
    ]);

    // 等加载结束（最多 15 秒）
    for (var i = 0; i < 60 && playerModel.loading; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(playerModel.error, isNull, reason: '播放报错：${playerModel.error}');
    expect(playerModel.loading, isFalse, reason: '一直卡在加载中');

    // 放 3 秒，看进度有没有走。进度为 0 = 没出声（浏览器/解码器静默失败）
    await tester.pump(const Duration(seconds: 3));
    expect(
      playerModel.position.inMilliseconds,
      greaterThan(500),
      reason: '3 秒后进度还是 ${playerModel.position.inMilliseconds}ms，说明没真的出声',
    );

    await playerModel.pause();
  });
}
