import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'audio_engine_base.dart';

/// Web 端的播放引擎：audioplayers（HTMLAudioElement）。
///
/// 浏览器不允许给 `<audio>` 设请求头，B站 CDN 没有 `Referer` 会直接 403，
/// 所以 Web 上音源地址必须是**远端反代**包装过的 `_mediaUrls(...)`。
/// 这层反代删不掉 —— 它是浏览器能力的硬限制，不是历史包袱。
class WebAudioEngine implements AudioEngine {
  WebAudioEngine();

  final AudioPlayer _player = AudioPlayer();

  @override
  Stream<Duration> get positions => _player.onPositionChanged;

  @override
  Stream<Duration> get durations => _player.onDurationChanged;

  @override
  Stream<bool> get playingStream => _player.onPlayerStateChanged
      .map((state) => state == PlayerState.playing);

  @override
  Stream<void> get completedStream =>
      _player.onPlayerComplete.map((_) {});

  /// 浏览器端没有可用的错误通道，失败时表现为「状态一直不是 playing」，
  /// 由 PlayerModel 的超时兜底。
  @override
  Stream<String> get errors => const Stream<String>.empty();

  @override
  Future<void> open(String url, {Map<String, String>? headers}) =>
      _player.setSourceUrl(url);

  @override
  Future<void> play() => _player.resume();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<Duration?> position() => _player.getCurrentPosition();

  @override
  Future<Duration?> duration() => _player.getDuration();

  @override
  Future<void> dispose() => _player.dispose();
}

AudioEngine createAudioEngine() => WebAudioEngine();
