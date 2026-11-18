/// 按平台挑选视频播放器。
///
/// 原生端 → libmpv（一个播放器吃 DASH，自带请求头）
/// Web 端 → video_player（两个 `<video>` 拼 DASH，音源走远端反代）
library;

export 'video_playback_base.dart';
export 'video_playback_web.dart' if (dart.library.io) 'video_playback_native.dart';
