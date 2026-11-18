import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'video_playback_base.dart';

/// 原生端（Windows / Linux / Android）的视频播放器：media_kit → libmpv。
///
/// 关键点：**一个播放器搞定 DASH**。
///
/// 以前 Android 用两个 ExoPlayer（画面一个、音轨一个），两个都会去申请
/// AudioFocus，部分设备上系统会把画面那个直接暂停 —— 表现就是「播几百
/// 毫秒后自己停了」，而且完全没有任何错误日志。
///
/// libmpv 的解法是外挂音轨：主文件只开画面流，再用 `audio-add` 把音轨
/// 追加上去，输出仍然只有一个 audio track。音画同步由 mpv 内部处理，
/// 不存在两套时钟，也不存在抢焦点。
///
/// 请求头也由 mpv 自己带（`http-header-fields`），所以 B站 CDN 的 Referer
/// 校验不需要任何反代。
class NativeVideoPlayback implements VideoPlayback {
  NativeVideoPlayback() {
    // 立刻建好 video output：等第一次 buildSurface 才建的话，mpv 可能已经
    // 在没有 vo 的情况下开始解析，挂载画面时又要重新初始化一遍。
    _videoController = VideoController(_player);
    _subs.add(_player.stream.playing.listen((value) {
      _emit(_snapshot.copyWith(playing: value));
    }));
    _subs.add(_player.stream.buffering.listen((value) {
      _emit(_snapshot.copyWith(buffering: value));
    }));
    _subs.add(_player.stream.position.listen((value) {
      _emit(_snapshot.copyWith(position: value));
    }));
    _subs.add(_player.stream.duration.listen((value) {
      _emit(_snapshot.copyWith(
        duration: value,
        initialized: value > Duration.zero || _snapshot.initialized,
      ));
    }));
    _subs.add(_player.stream.width.listen((value) {
      _width = value ?? 0;
      _emit(_snapshot.copyWith(size: Size(_width.toDouble(), _height.toDouble())));
    }));
    _subs.add(_player.stream.height.listen((value) {
      _height = value ?? 0;
      _emit(_snapshot.copyWith(size: Size(_width.toDouble(), _height.toDouble())));
    }));
    // mpv 的 error 流里混着大量非致命日志（找不到字体、profile 不认识…），
    // 只打进控制台，不往 UI 上顶 —— 真正的失败由 open() 抛异常表达。
    _subs.add(_player.stream.error.listen((message) {
      debugPrint('[VIDEO] mpv: $message');
    }));
  }

  final Player _player = Player(
    configuration: const PlayerConfiguration(title: 'Podenco Music'),
  );
  late final VideoController _videoController;

  final List<StreamSubscription<dynamic>> _subs = [];
  final ValueNotifier<VideoSnapshot> _notifier =
      ValueNotifier(const VideoSnapshot());
  VideoSnapshot _snapshot = const VideoSnapshot();

  int _width = 0;
  int _height = 0;
  bool _hasAudio = false;

  @override
  ValueListenable<VideoSnapshot> get state => _notifier;

  @override
  Widget buildSurface() => Video(
        controller: _videoController,
        controls: NoVideoControls,
        fit: BoxFit.contain,
        fill: const Color(0xFF000000),
      );

  @override
  bool get hasAudioTrack => _hasAudio;

  void _emit(VideoSnapshot next) {
    _snapshot = next.copyWith(capturedAt: DateTime.now());
    _notifier.value = _snapshot;
  }

  @override
  Future<void> open(VideoSource source) async {
    _hasAudio = source.audioUrl != null;
    _width = 0;
    _height = 0;
    _emit(const VideoSnapshot());

    await _player.setVolume(source.volume.clamp(0.0, 1.0) * 100);
    await _player.setPlaylistMode(
      source.loop ? PlaylistMode.single : PlaylistMode.none,
    );

    // start 交给 mpv 在 loadfile 时处理，比开播后再 seek 干净：
    // 少一次「先出 0 秒那帧再跳」的闪动。
    await _player.open(
      Media(
        source.url,
        httpHeaders: source.headers,
        start: source.startAt,
      ),
      play: false,
    );

    if (source.audioUrl != null) {
      await _waitUntilLoaded();
      await _attachAudio(source.audioUrl!);
      final ok = await _waitForAudioTrack(const Duration(seconds: 5));
      if (!ok) {
        throw const VideoPlaybackException('DASH 音轨没能挂上，改用合并流');
      }
    }
  }

  /// 等主文件真正加载出参数。`open()` 只是把 loadfile 发出去，mpv 还在
  /// 后面解析，太早发 `audio-add` 会撞上「没有正在播放的文件」。
  Future<void> _waitUntilLoaded() async {
    if (_snapshot.initialized || _width > 0) return;
    final completer = Completer<void>();
    late final StreamSubscription<dynamic> sub;
    void done() {
      if (!completer.isCompleted) completer.complete();
    }

    sub = _player.stream.duration.listen((value) {
      if (value > Duration.zero) done();
    });
    final subWidth = _player.stream.width.listen((value) {
      if (value != null && value > 0) done();
    });
    final subError = _player.stream.error.listen((_) => done());
    try {
      await completer.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const VideoPlaybackException('视频流加载超时');
    } finally {
      await sub.cancel();
      await subWidth.cancel();
      await subError.cancel();
    }
  }

  /// 把独立音轨挂到当前文件上。
  ///
  /// 用 mpv 的 `audio-add` 而不是另起一个播放器：输出设备只有一个，
  /// 音画同步由 mpv 按时间戳对齐，Windows 的音频焦点、Android 的
  /// AudioFocus 都只归这一个播放器管。
  Future<void> _attachAudio(String url) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.command(['audio-add', url]);
      // 默认不会自动选中新加的音轨，`auto` 让它成为当前音轨
      await platform.setProperty('aid', 'auto');
      debugPrint('[VIDEO] 已外挂 DASH 音轨');
    } catch (e) {
      debugPrint('[VIDEO] 外挂音轨失败：$e');
      throw const VideoPlaybackException('DASH 音轨加载失败');
    }
  }

  Future<bool> _waitForAudioTrack(Duration timeout) async {
    if (_player.state.tracks.audio.isNotEmpty) return true;
    final completer = Completer<bool>();
    late final StreamSubscription<Tracks> sub;
    sub = _player.stream.tracks.listen((tracks) {
      if (tracks.audio.isNotEmpty && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return false;
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _player.dispose();
    _notifier.dispose();
  }
}

/// 原生端工厂。
VideoPlayback createVideoPlayback() => NativeVideoPlayback();
