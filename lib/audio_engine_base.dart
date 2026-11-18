/// 播放引擎的公共接口。
///
/// 为什么要有这层：B站音轨必须带 `Referer` / `User-Agent` 才肯放行，
/// 而浏览器里改不了请求头 —— Web 只能靠远端反代补头，原生端（Windows /
/// Linux / Android）的 libmpv 自己就能带 headers，没必要再套一层本地 socket
/// 反代。两个平台的播放器能力不一样，但 PlayerModel 只关心「放什么、放到哪」，
/// 所以把差异收在这里。
///
/// 实现：
///   · `audio_engine_io.dart`   —— media_kit（libmpv），支持自定义请求头
///   · `audio_engine_web.dart`  —— audioplayers（HTMLAudioElement），
///     由远端反代负责补 Referer
library;

/// 一个能出声的播放器。
///
/// 只暴露单曲播放需要的最小集合：PlayerModel 自己维护队列、模式和歌词，
/// 引擎不管业务。
abstract class AudioEngine {
  /// 播放进度。约 100~500ms 一次，取决于底层播放器。
  Stream<Duration> get positions;

  /// 时长。加载完成 / 换源后才会有值。
  Stream<Duration> get durations;

  /// 播放状态。以底层为准 —— UI 手写的状态被外部打断时靠它纠偏。
  Stream<bool> get playingStream;

  /// 一首放完。只在真的播到结尾时触发，暂停 / 换源不算。
  Stream<void> get completedStream;

  /// 底层播放器报错（解码失败、网络 4xx 等）。
  ///
  /// 目前只有 `_load` 里的「换下一个候选地址」会用到，为空也无所谓。
  Stream<String> get errors;

  /// 换成一个网络音源。
  ///
  /// [headers] 只在原生端有效：Web 的 HTMLAudioElement 不允许自定义请求头。
  Future<void> open(String url, {Map<String, String>? headers});

  Future<void> play();

  Future<void> pause();

  /// 卸载当前音源并停住。下一次播放必须重新 [open]。
  Future<void> stop();

  Future<void> seek(Duration position);

  /// 音量，0.0 ~ 1.0。
  Future<void> setVolume(double volume);

  /// 当前进度。拿不到时返回 null（Web 上偶发）。
  Future<Duration?> position();

  /// 总时长。还没探测出来时返回 null。
  Future<Duration?> duration();

  Future<void> dispose();
}
