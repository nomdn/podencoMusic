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
    this.capturedAt,
  });

  final bool initialized;
  final bool playing;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final Size size;

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
    DateTime? capturedAt,
  }) {
    return VideoSnapshot(
      initialized: initialized ?? this.initialized,
      playing: playing ?? this.playing,
      buffering: buffering ?? this.buffering,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      size: size ?? this.size,
      capturedAt: capturedAt ?? this.capturedAt,
    );
  }
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

  Future<void> dispose();
}

/// 这条流放不了。[message] 会直接显示给用户。
class VideoPlaybackException implements Exception {
  const VideoPlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}
