import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, kDebugMode, kIsWeb, debugPrint;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bili_api.dart';
import '../player_model.dart';
import '../video/video_playback.dart';
import '../widgets/bili_danmaku_overlay.dart';
import '../widgets/bili_reply_section.dart';
import '../widgets/bili_video_download_button.dart';
import '../widgets/cover_image.dart';

/// 临时诊断日志：只在 debug 下、且只在关键调用点输出。
void _probe(String msg) {
  if (!kDebugMode) return;
  debugPrint('[BILI-VIDEO] $msg');
}

/// 看B站视频（带画面）。
///
/// 播放器按平台分两套，实现在 `lib/video/`：
///
/// · 原生端（Windows / Linux / Android）→ media_kit / libmpv
///   一个播放器同时吃下 DASH 的画面流和音轨流（外挂音轨），请求头由
///   mpv 自己带 —— 不需要本地反代，也不会出现两个 ExoPlayer 抢
///   AudioFocus 把画面顶停的老问题。
///
/// · Web → video_player（`<video>`）
///   浏览器不能设请求头，音源必须走远端反代；DASH 只能两个标签拼，
///   由 `WebVideoPlayback` 内部对时间轴。
///
/// 页面本身只管：拿流、切清晰度、弹幕、控制条，播放器细节一概不碰。
class BiliVideoPage extends StatefulWidget {
  const BiliVideoPage({
    super.key,
    required this.bvid,
    required this.title,
    this.cover = '',
    this.initialPosition,
    this.loop = false,
  });

  final String bvid;
  final String title;

  /// 加载时要显示的封面，避免一片黑
  final String cover;

  /// 起播位置。仅调试用（URL 查询串钩子传进来）：初始化完成后先 seek
  /// 到这里再播，省掉手动拖进度条。为 null 时从 0 开始，与正常入口一致。
  final Duration? initialPosition;

  /// 循环播放。仅调试用，配合定点复现同一段。
  final bool loop;

  @override
  State<BiliVideoPage> createState() => _BiliVideoPageState();
}

class _BiliVideoPageState extends State<BiliVideoPage> {
  final VideoPlayback _playback = createVideoPlayback();

  bool _loading = true;
  String? _error;

  /// 等一次真实点击才能开播的遮罩。
  ///
  /// 浏览器只放行「静音」自动播放。调试钩子是从 URL 直接 push 本页的，
  /// 没有用户手势，带声音的 play() 会被 Chrome 静默拒绝 —— 症状就是
  /// 弹幕照常滚、画面一动不动。正常入口（搜索页/空间页点进来）自带
  /// 手势，不受影响。
  bool _needsTap = false;

  /// 接口给的真实宽高比。播放器上报的 size 在刚起播时经常还是空的，
  /// 靠它算比例会把画面摆错。
  double? _apiRatio;

  /// 当前清晰度（B站 qn），默认 720P。用户切换后记住。
  int _qn = 64;
  static const _qnKey = 'bili_video_qn_v1';

  /// 弹幕开关。默认开，关掉只是不画。
  ///
  /// 弹幕数据照旧拉：重新打开时不用再等一次请求，而且发送条、弹幕量
  /// 这些信息都还在。用户关一次就永远记住 —— 有人就是嫌它挡字幕。
  bool _danmakuOn = true;
  static const _danmakuKey = 'bili_danmaku_on_v1';

  /// 服务端当前实际能给的档位（未登录只有 720P/360P）。
  List<int> _qualities = const [];
  List<String> _qualityDesc = const [];

  /// DASH 起不来时置位，之后一律请求合并流（MP4），不再尝试 DASH。
  bool _forceMuxed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
    // 音乐先停：视频一出声就是两路声音叠在一起。
    // 必须等这一帧 build 完再停 —— PlayerModel.pause() 会同步
    // notifyListeners()，在 initState（build 阶段）直接调用会让监听它的
    // ListenableBuilder/AnimatedWidget 在构建途中被标脏，抛
    // "setState() or markNeedsBuild() called during build"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (playerModel.playing) {
        _probe('打开视频页，暂停音乐播放器');
        unawaited(playerModel.pause());
      }
    });
  }

  /// 先读回上次选的清晰度，再加载视频 —— 直接 _load 会用默认 720P，
  /// 用户选过 1080P 的话第一帧就白闪一次低画质。
  Future<void> _boot() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_qnKey);
    if (saved != null && saved > 0) _qn = saved;
    // 没存过就是开 —— 老用户升级上来行为不变
    final danmaku = prefs.getBool(_danmakuKey);
    if (danmaku != null) _danmakuOn = danmaku;
    await _load();
  }

  /// 开关弹幕，顺手记住。只影响这一层的绘制，不碰数据。
  Future<void> _toggleDanmaku() async {
    setState(() => _danmakuOn = !_danmakuOn);
    _probe('弹幕${_danmakuOn ? '开' : '关'}');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_danmakuKey, _danmakuOn);
  }

  /// 切换清晰度：记住选择、从当前位置续播。
  Future<void> _switchQuality(int qn) async {
    if (qn == _qn) return;
    final pos = _playback.state.value.position;
    _qn = qn;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_qnKey, qn);
    if (!mounted) return;
    // 传 resumeAt 会跳过「等你点播放」的遮罩，直接续播
    await _load(resumeAt: pos);
  }

  @override
  void dispose() {
    unawaited(_playback.dispose());
    super.dispose();
  }

  Future<void> _load({Duration? resumeAt}) async {
    // Web 上没有反代就看不了：`<video>` 设不了 Referer，而视频 CDN
    // 强制要求它，裸请求一律 403。这里直接说清楚，免得用户盯着黑屏。
    if (kIsWeb && !BiliApi.proxyEnabled) {
      setState(() {
        _loading = false;
        _error = '网页端观看影像须经「接口反代」中转：'
            '浏览器无法修改 Referer，影像 CDN 将直接拒绝请求。';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 宽高比和播放地址都要请求 view 接口，并行取省一轮往返
      final ratioFuture = BiliApi.videoAspectRatio(widget.bvid);
      final stream = await BiliApi.videoStream(
        widget.bvid,
        qn: _qn,
        forceMuxed: _forceMuxed,
      );
      final url = stream.url;
      _qualities = stream.accept;
      _qualityDesc = stream.acceptDesc;
      _apiRatio = await ratioFuture;
      if (!mounted) return;

      // 起播位置：交给播放器在 loadfile 时处理，弹幕层从第一帧起
      // 就能拿到正确的时间轴，不用「先出 0 秒再跳」。
      final start = resumeAt ?? widget.initialPosition;

      // 钩子入口没有用户手势，先别 play（会被浏览器拒掉），交给遮罩上
      // 的那一次点击。正常入口照旧直接播。换画质续播（resumeAt != null）
      // 时不用再等手势：页面早就被用户点过，播放权限还在。
      final needsGesture =
          resumeAt == null && (widget.initialPosition != null || widget.loop);

      try {
        await _playback.open(VideoSource(
          url: url,
          audioUrl: stream.audioUrl,
          // 这两个头是硬性要求：没有 Referer，B站视频 CDN 直接 403。
          // 原生端由 libmpv 带上（http-header-fields）；Web 端设不了，
          // 但地址已经被远端反代包装过，传进来不影响。
          headers: BiliApi.streamHeaders(widget.bvid),
          startAt: start,
          loop: widget.loop,
          volume: playerModel.volume,
        ));
      } on VideoPlaybackException catch (e) {
        // DASH 起不来就**必须**退回合并流重来一次：DASH 的画面流里没有
        // 声音，硬撑下去就是整个视频静音。
        if (stream.audioUrl != null && !_forceMuxed) {
          _forceMuxed = true;
          debugPrint('[BILI-VIDEO] ${e.message}，回退合并流重载');
          if (!mounted) return;
          return await _load(resumeAt: start);
        }
        rethrow;
      }
      if (!mounted) return;

      if (needsGesture) {
        setState(() => _needsTap = true);
      } else {
        _probe('起播：dash=${stream.audioUrl != null} '
            'start=${start?.inMilliseconds}ms loop=${widget.loop}');
        await _playback.play();
        if (!mounted) return;
      }

      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is BiliException ? e.message : '视频加载失败：$e';
      });
    }
  }

  /// 遮罩上的一次点击：既是「开始播放」的意图，也是浏览器认可的用户手势。
  Future<void> _startPlayback() async {
    setState(() => _needsTap = false);
    try {
      await _playback.play();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '播放失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          // 弹幕开关：关掉时图标压暗，不用点开菜单就知道当前状态
          IconButton(
            tooltip: _danmakuOn ? '关闭弹幕' : '开启弹幕',
            onPressed: () => unawaited(_toggleDanmaku()),
            icon: Icon(
              _danmakuOn ? Icons.subtitles : Icons.subtitles_off,
              size: 22,
              color: _danmakuOn ? Colors.white : Colors.white38,
            ),
          ),
          PopupMenuButton<int>(
            tooltip: '清晰度',
            icon: const Icon(Icons.high_quality, size: 22),
            initialValue: _qn,
            onSelected: (v) => unawaited(_switchQuality(v)),
            itemBuilder: (_) => [
              // 只列服务端真能给的档位：未登录上限 720P，列 1080P 只会
              // 让用户选了却拿到同样的 720P。
              if (_qualities.isEmpty)
                const PopupMenuItem<int>(value: 64, child: Text('720P'))
              else
                for (var i = 0; i < _qualities.length; i++)
                  PopupMenuItem<int>(
                    value: _qualities[i],
                    child: Text(
                      i < _qualityDesc.length
                          ? _qualityDesc[i]
                          : BiliApi.qualityLabels[_qualities[i]] ??
                              '${_qualities[i]}',
                    ),
                  ),
              const PopupMenuDivider(),
              // 说明当前处在哪条路上，免得以为是我藏了高档位
              PopupMenuItem<int>(
                value: -1,
                enabled: false,
                child: Text(
                  !BiliApi.hasSession
                      ? '未登录上限 720P · 登录后可到 1080P'
                      : (_playback.hasAudioTrack
                          ? 'DASH 音视频分流已启用'
                          : '该视频只提供合并流（MP4）'),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _body(),
    );
  }

  /// 视频宽高比。优先级：接口 dimension > 播放器上报 size > 16:9。
  double _videoRatio(VideoSnapshot value) {
    final api = _apiRatio;
    if (api != null && api > 0) return api;
    final reported = value.aspectRatio;
    if (reported > 0) return reported;
    return 16 / 9;
  }

  Widget _body() {
    return ValueListenableBuilder<VideoSnapshot>(
      valueListenable: _playback.state,
      builder: (context, snapshot, _) {
        if (_error != null) return _errorView();
        if (_loading || !snapshot.initialized) return _loadingView();
        return _videoView(snapshot);
      },
    );
  }

  Widget _errorView() {
    // 必须自己撑满并居中：Scaffold body 给的是一整屏的紧约束，但
    // Column(mainAxisSize.min) 只占自身高度，会贴着左上角落 —— 所以
    // 外面套 Center；顺带包一层滚动，小窗口里说明文字变长也不会溢出。
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, size: 48, color: Colors.white54),
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回音轨库'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loadingView() {
    // Stack 默认按子节点收缩；这里给 fit: expand，让 Stack 撑满 body，
    // 转圈才会真正落在屏幕中央，而不是缩成一小块贴在左上角。
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.cover.isNotEmpty)
          Opacity(
            opacity: 0.25,
            child: CoverImage(url: widget.cover, fit: BoxFit.contain),
          ),
        const Center(child: CircularProgressIndicator()),
      ],
    );
  }

  /// 视频区不拉伸：按原比例显示并限制最大高度 620，宽屏下不铺满。
  Widget _videoView(VideoSnapshot snapshot) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 620),
            child: AspectRatio(
              aspectRatio: _videoRatio(snapshot),
              child: Stack(
                alignment: Alignment.center,
                fit: StackFit.expand,
                children: [
                  // 画面。原生端是 media_kit 的 Video（自己会 contain），
                  // Web 端是 VideoPlayer + 藏在角落的音轨标签。
                  _playback.buildSurface(),
                  // 弹幕层盖在画面上，指针透传给播放器
                  BiliDanmakuOverlay(
                    clock: _playback.state,
                    bvid: widget.bvid,
                    enabled: _danmakuOn,
                  ),
                  // 钩子入口的「点击开播」遮罩：这一下点击同时也是浏览器
                  // 认可的用户手势，之后 play() 才不会被拒。
                  if (_needsTap)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _startPlayback,
                        child: const ColoredBox(
                          color: Color(0x99000000),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.play_circle_filled,
                                  size: 64,
                                  color: Colors.white,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  '点击开始播放',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          _Controls(playback: _playback),
          _DanmakuSendBar(clock: _playback.state, bvid: widget.bvid),
          BiliVideoDownloadButton(
            bvid: widget.bvid,
            title: widget.title,
            author: '',
          ),
          const Divider(height: 1),
          BiliReplySection(bvid: widget.bvid),
        ],
      ),
    );
  }
}

/// 简单控制条：进度 + 播放暂停 + 时间。
class _Controls extends StatefulWidget {
  const _Controls({required this.playback});

  final VideoPlayback playback;

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  /// 拖动中的位置（毫秒）。非 null 时进度条显示它，而不是播放器的实时值，
  /// 否则拖动过程中会被 position 流拽回去。
  double? _dragMs;

  void _toggle(VideoSnapshot value) {
    _probe('用户点了播放/暂停按钮：当前 playing=${value.playing}');
    if (value.playing) {
      unawaited(widget.playback.pause());
      return;
    }
    // 播完后再点播放要从头开始，否则什么都不发生
    if (value.duration > Duration.zero && value.position >= value.duration) {
      unawaited(widget.playback.seek(Duration.zero));
    }
    unawaited(widget.playback.play());
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoSnapshot>(
      valueListenable: widget.playback.state,
      builder: (context, value, _) {
        final total = value.duration;
        final maxMs = total.inMilliseconds.toDouble();
        final max = maxMs > 0 ? maxMs : 1.0;
        final posMs = value.position.inMilliseconds.toDouble().clamp(0.0, max);
        final shown = (_dragMs ?? posMs).clamp(0.0, max);

        return Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          color: Colors.black,
          child: Row(
            children: [
              IconButton(
                color: Colors.white,
                iconSize: 28,
                tooltip: value.playing ? '暂停' : '播放',
                icon: Icon(
                  value.playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                ),
                onPressed: () => _toggle(value),
              ),
              Text(
                _fmt(Duration(milliseconds: shown.round())),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: shown,
                  max: max,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  onChanged:
                      maxMs > 0 ? (v) => setState(() => _dragMs = v) : null,
                  onChangeEnd: maxMs > 0
                      ? (v) {
                          unawaited(
                            widget.playback
                                .seek(Duration(milliseconds: v.round())),
                          );
                          setState(() => _dragMs = null);
                        }
                      : null,
                ),
              ),
              Text(
                _fmt(total),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 发弹幕的输入条。输入后带当前播放进度一起发给B站。
class _DanmakuSendBar extends StatefulWidget {
  const _DanmakuSendBar({required this.clock, required this.bvid});

  final ValueListenable<VideoSnapshot> clock;
  final String bvid;

  @override
  State<_DanmakuSendBar> createState() => _DanmakuSendBarState();
}

class _DanmakuSendBarState extends State<_DanmakuSendBar> {
  final _input = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final error = await sendDanmaku(
      bvid: widget.bvid,
      text: text,
      progressMs: widget.clock.value.position.inMilliseconds,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (error == null) {
      _input.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('弹幕发送成功'), duration: Duration(seconds: 2)),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        children: [
          const Icon(Icons.chat_bubble_outline, color: Colors.white54, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _input,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                hintText: '发条弹幕（需登录）',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                isDense: true,
                border: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white70),
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          _sending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: const Icon(Icons.send, color: Colors.white70, size: 20),
                  tooltip: '发送弹幕',
                  onPressed: _send,
                ),
        ],
      ),
    );
  }
}

String _fmt(Duration d) {
  final total = d.inSeconds;
  final m = (total ~/ 60).toString().padLeft(2, '0');
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
