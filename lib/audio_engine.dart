/// 按平台挑选播放引擎。
///
/// `dart.library.io` 为真 = 原生端（Windows / Linux / Android）→ media_kit；
/// 否则是 Web → audioplayers + 远端反代。
library;

export 'audio_engine_base.dart';
export 'audio_engine_web.dart' if (dart.library.io) 'audio_engine_io.dart';
