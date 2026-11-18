import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'audio_engine_base.dart';

/// 原生端（Windows / Linux / Android）的播放引擎：media_kit → libmpv。
///
/// 选它而不是 audioplayers，唯一的原因是 **请求头**：B站音轨的 CDN 会校验
/// `Referer`，audioplayers 的 `UrlSource` 没有传 headers 的口子，
/// 只能在本机起一个 HTTP 反代去补。libmpv 的 `http-header-fields` 直接支持，
/// 于是整层本地反代可以删掉。
///
/// 顺带的好处：Windows / Linux 不再依赖平台自带的解码器（Media Foundation
/// 对 fMP4 支持很差），Android 也不再走 MediaPlayer 那条老路。
class MediaKitAudioEngine implements AudioEngine {
  MediaKitAudioEngine();

  final Player _player = Player(
    configuration: const PlayerConfiguration(
      // 音频场景不需要额外的缓冲，默认值偏保守，起播会慢半拍
      bufferSize: 8 * 1024 * 1024,
    ),
  );

  @override
  Stream<Duration> get positions => _player.stream.position;

  @override
  Stream<Duration> get durations => _player.stream.duration;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<void> get completedStream =>
      _player.stream.completed.where((done) => done).map((_) {});

  @override
  Stream<String> get errors => _player.stream.error;

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    await _player.open(
      Media(url, httpHeaders: headers),
      // 由 PlayerModel 决定什么时候真正开声，避免换源瞬间抢跑
      play: false,
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0) * 100);

  @override
  Future<Duration?> position() async => _player.state.position;

  @override
  Future<Duration?> duration() async => _player.state.duration;

  @override
  Future<void> dispose() => _player.dispose();
}

AudioEngine createAudioEngine() => MediaKitAudioEngine();
