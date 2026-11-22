import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 播放器对外暴露的一帧状态。
///
/// 只留页面真正用得到的东西：位置（弹幕和进度条）、时长、播放态、
/// 画面比例、错误。不把某个具体播放器的 `value` 结构泄漏到 UI 里 ——
/// 否则换一个播放器就要改一遍页面。
@immutable
class VideoSnapshot {
  const VideoSnapshot({
    this.initialized = false,
    this.playing = false,
    this.buffering = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.size = Size.zero,
    this.speed = 1.0,
    this.capturedAt,
  });

  final bool initialized;
  final bool playing;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final Size size;

  /// 当前播放倍速。弹幕层拿它校准插值 —— 2x 时视频时间走得比墙上时钟快一倍。
  final double speed;

  /// 这一帧状态是什么时候发出的。弹幕层拿它做位置插值，
  /// 把离散上报的 position 铺成每帧连续的动画。
  final DateTime? capturedAt;

  double get aspectRatio =>
      size.width > 0 && size.height > 0 ? size.width / size.height : 0;

  VideoSnapshot copyWith({
    bool? initialized,
    bool? playing,
    bool? buffering,
    Duration? position,
    Duration? duration,
    Size? size,
    double? speed,
    DateTime? capturedAt,
  }) {
    return VideoSnapshot(
      initialized: initialized ?? this.initialized,
      playing: playing ?? this.playing,
      buffering: buffering ?? this.buffering,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      size: size ?? this.size,
      speed: speed ?? this.speed,
      capturedAt: capturedAt ?? this.capturedAt,
    );
  }
}

/// 控制条里可选的倍速档位。
const List<double> videoSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 兜底非法值：倍速必须有限且为正，超出播放器常见范围就夹到区间内。
double normalizeVideoSpeed(double speed) =>
    speed.isFinite && speed > 0 ? speed.clamp(0.25, 4.0) : 1.0;

/// 把离散上报的 position 插值到 [now]（毫秒）。
///
/// Web 的 position 只有约 4Hz，弹幕却每帧重绘；直接用上报值会一顿一顿。
/// 用「上报值 + 距上报时刻流逝的墙上时间 × 倍速」铺平，上限 600ms ——
/// 缓冲/卡顿时最多多算半秒，不会越飘越远。暂停、缓冲、切倍速瞬间不上报
/// 新位置时按上一次的倍速算，误差由下一次真值校准。
int interpolatedPositionMs(VideoSnapshot snapshot, DateTime now) {
  var ms = snapshot.position.inMilliseconds;
  final captured = snapshot.capturedAt;
  if (captured != null && snapshot.playing && !snapshot.buffering) {
    final drift = now.difference(captured).inMilliseconds;
    if (drift > 0 && drift < 600) {
      ms += (drift * normalizeVideoSpeed(snapshot.speed)).round();
    }
  }
  return ms;
}

/// 要播放的一条流。
///
/// [audioUrl] 非空表示这是 DASH：`url` 里只有画面，声音在另一条流上。
/// 具体怎么把两者合到一个播放器里，是各平台实现的事 ——
/// 原生端交给 libmpv，Web 端只能起第二个 `<video>` 自己对时间轴。
@immutable
class VideoSource {
  const VideoSource({
    required this.url,
    required this.headers,
    this.audioUrl,
    this.startAt,
    this.loop = false,
    this.volume = 1.0,
  });

  final String url;
  final String? audioUrl;
  final Map<String, String> headers;
  final Duration? startAt;
  final bool loop;
  final double volume;
}

/// 视频播放器接口。
///
/// 两个实现：
///   · `video_playback_native.dart` —— media_kit / libmpv，一个播放器同时
///     吃下画面和音轨，请求头直接带上，不需要任何反代
///   · `video_playback_web.dart` —— video_player（HTMLVideoElement），
///     请求头带不了，音源必须走远端反代
abstract class VideoPlayback {
  /// 当前状态。页面用 [ValueListenableBuilder] 监听，弹幕层每帧读它。
  ValueListenable<VideoSnapshot> get state;

  /// 画面 widget（已经按比例摆好，外层不要再套缩放）。
  Widget buildSurface();

  /// 打开一个音源。抛异常表示这条流放不了，调用方可以降级重试。
  Future<void> open(VideoSource source);

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  /// 是否是 DASH 分流（画面 + 独立音轨）。只用于给用户看当前走哪条路。
  bool get hasAudioTrack;

  /// 当前倍速。页面用它显示档位，弹幕层用它校准位置。
  double get speed;

  /// 设置倍速。切清晰度重新 open 后要由实现自己恢复这个值。
  Future<void> setSpeed(double speed);

  Future<void> dispose();
}

/// 这条流放不了。[message] 会直接显示给用户。
class VideoPlaybackException implements Exception {
  const VideoPlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}
