import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'video_playback_base.dart';

/// Web 端的视频播放器：官方 `video_player`（HTMLVideoElement）。
///
/// 浏览器里有两件事做不到，所以这一层注定要比原生端复杂：
///
/// 1. **不能给 `<video>` 设请求头** —— B站视频 CDN 没有 Referer 直接 403，
///    音源地址必须由远端反代包装好再送进来。
/// 2. **DASH 没有单标签的解** —— 一个 `<video>` 放不了「画面流 + 音轨流」。
///    只能起两个 `<video>`（画面静音、音轨出声），再用定时器把音轨的
///    currentTime 钉在画面上。Web 上不存在 Android 那种 AudioFocus 抢占，
///    所以这套双标签方案在浏览器里是稳的。
class WebVideoPlayback implements VideoPlayback {
  VideoPlayerController? _video;
  VideoPlayerController? _audio;
  Timer? _syncTimer;
  bool _syncSeekLogged = false;
  bool _disposed = false;

  final ValueNotifier<VideoSnapshot> _notifier =
      ValueNotifier(const VideoSnapshot());

  @override
  ValueListenable<VideoSnapshot> get state => _notifier;

  @override
  bool get hasAudioTrack => _audio != null;

  @override
  Widget buildSurface() {
    final video = _video;
    if (video == null) return const SizedBox.shrink();
    final children = <Widget>[VideoPlayer(video)];
    final audio = _audio;
    if (audio != null) {
      // 音轨也要挂进 Widget 树，Web 上才会真的创建 DOM 元素并出声。
      // 缩成左上角 1×1，视觉上看不见。
      children.add(
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: IgnorePointer(child: VideoPlayer(audio)),
        ),
      );
    }
    return Stack(alignment: Alignment.center, fit: StackFit.expand, children: children);
  }

  @override
  Future<void> open(VideoSource source) async {
    await _teardown();
    _syncSeekLogged = false;

    final video = VideoPlayerController.networkUrl(
      Uri.parse(source.url),
      httpHeaders: source.headers,
    );
    _video = video;
    await video.initialize();
    if (_disposed) {
      await video.dispose();
      return;
    }
    video.addListener(_pull);

    final audioUrl = source.audioUrl;
    if (audioUrl != null) {
      await video.setVolume(0);
      final audio = VideoPlayerController.networkUrl(
        Uri.parse(audioUrl),
        httpHeaders: source.headers,
      );
      try {
        await audio.initialize();
        if (_disposed) {
          await audio.dispose();
          return;
        }
        audio.addListener(_pull);
        await audio.setVolume(source.volume);
        if (source.loop) await audio.setLooping(true);
        _audio = audio;
        _startAudioSync();
      } catch (e) {
        await audio.dispose();
        await video.setVolume(source.volume);
        throw const VideoPlaybackException('DASH 音轨初始化失败，改用合并流');
      }
    } else {
      await video.setVolume(source.volume);
    }

    if (source.loop) await video.setLooping(true);

    final start = source.startAt;
    if (start != null && start > Duration.zero) {
      final duration = video.value.duration;
      final target = duration > Duration.zero && start >= duration
          ? duration - const Duration(milliseconds: 500)
          : start;
      await video.seekTo(target);
      await _audio?.seekTo(target);
    }

    _pull();
  }

  void _pull() {
    if (_disposed) return;
    final video = _video;
    if (video == null) return;
    final value = video.value;
    _notifier.value = VideoSnapshot(
      initialized: value.isInitialized,
      playing: value.isPlaying,
      buffering: value.isBuffering,
      position: value.position,
      duration: value.duration,
      size: value.size,
      capturedAt: DateTime.now(),
    );
  }

  /// 把音轨钉在画面上（只有 DASH 双标签才需要）。
  ///
  /// 以画面为时钟源：两路流的缓冲、解码速度都不一样，偏移超过 300ms
  /// 人耳就能听出「嘴型对不上」，所以每 500ms 校一次。
  void _startAudioSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final video = _video;
      final audio = _audio;
      if (video == null || audio == null) return;
      if (!video.value.isInitialized || !audio.value.isInitialized) return;

      final vPlaying = video.value.isPlaying;
      final aPlaying = audio.value.isPlaying;
      if (vPlaying && !aPlaying) {
        unawaited(audio.play());
      } else if (!vPlaying && aPlaying) {
        unawaited(audio.pause());
      }

      final drift =
          (video.value.position - audio.value.position).inMilliseconds;
      if (drift.abs() > 300) {
        if (!_syncSeekLogged) {
          debugPrint('[VIDEO] 音轨漂移 ${drift}ms，重新对齐');
          _syncSeekLogged = true;
        }
        unawaited(audio.seekTo(video.value.position));
      } else {
        _syncSeekLogged = false;
      }
    });
  }

  @override
  Future<void> play() async {
    // 浏览器的手势窗口只在这一拍有效，音轨要先跟着一起起来
    await _audio?.play();
    await _video?.play();
  }

  @override
  Future<void> pause() async {
    await _video?.pause();
    await _audio?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _video?.seekTo(position);
    await _audio?.seekTo(position);
  }

  Future<void> _teardown() async {
    _syncTimer?.cancel();
    _syncTimer = null;
    _audio?.removeListener(_pull);
    final audio = _audio;
    final video = _video;
    _audio = null;
    _video = null;
    await audio?.dispose();
    await video?.dispose();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _teardown();
    _notifier.dispose();
  }
}

/// Web 端工厂。
VideoPlayback createVideoPlayback() => WebVideoPlayback();
