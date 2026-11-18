import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_ui/material_ui.dart';
import '../video/video_playback_base.dart';

import '../bili_api.dart';
import '../bili_danmaku_3d.dart';
import '../bili_models.dart';
import '../bili_store.dart';

/// 一条正在飞行的高级弹幕（mode=7）。
class _AdvancedFlying {
  _AdvancedFlying({
    required this.item,
    required this.bornAt,
    required this.duration,
    required this.painter,
    required this.width,
    required this.height,
  });

  final BiliDanmaku item;

  /// 出现时的播放进度（毫秒，绝对时间）
  final int bornAt;

  /// 在屏幕上的时长（毫秒）
  final int duration;

  /// 排版好的文字。layout 只做一次，每帧 paint 命中引擎字形缓存。
  final TextPainter painter;

  final double width;
  final double height;

  bool disposed = false;

  /// 幂等。dispose 路径有过期清理、seek 清屏、widget 销毁三处，
  /// 任何一处重复触发都绝不能让 TextPainter.dispose 抛断言 ——
  /// 那会把 _onFrame 打断，后续每帧抛异常，弹幕层永久停更。
  void dispose() {
    if (disposed) return;
    disposed = true;
    painter.dispose();
  }
}

/// 盖在视频画面上的弹幕层，全部用 CustomPainter 自绘：
///
/// · 普通弹幕（mode 1~6）→ [_NormalPainter]
///   位置是视频 position 的纯函数，暂停 / seek / 倍速都直接跟随播放器；
///   Web 上播放器 `timeupdate` 只有约 4Hz，组件内部做位置插值和 30fps 限帧。
///   早期试过逐帧 `toImage` 烘焙，每秒创建几十张 GPU 纹理把 Windows 的
///   Skia GL 管线打崩（EGL Context Lost 12302），所以现在只画 TextPainter，
///   依赖字形缓存，不产生额外纹理。
///
/// · 高级弹幕（mode 7）→ [_AdvancedPainter]
///   支持任意坐标、运动轨迹、旋转和独立显示时长；同屏只有几十条，
///   每帧直接画 TextPainter 没有压力，不需要任何烘焙。
///
/// 时间轴同步：两层都只读视频 position。暂停 = 位置不变 = 弹幕静止；
/// seek = 位置跳变 = 清屏重排。不存在第二套逻辑时钟漂移的问题。
/// 一条正在飞的普通弹幕（mode 1~6）。
///
/// 刻意不存 x 字段：位置每次按 (pos - bornAt) 现算。一旦把位置存下来
/// 自己推进，推进就依赖帧间隔，又会绕回「引擎时钟 vs 视频时钟」的老坑。
class _NormalFlying {
  _NormalFlying({
    required this.item,
    required this.bornAt,
    required this.lane,
    required this.fixed,
    required this.painter,
    required this.width,
    required this.height,
  });

  final BiliDanmaku item;

  /// 上屏时刻（视频 position 毫秒）。用上屏时刻而不是弹幕自带的 timeMs：
  /// 派发总有一点延迟，用 timeMs 会让每条都从屏幕中间起步。
  final int bornAt;

  final int lane;

  /// mode 4/5 固定弹幕：水平居中、不滚动
  final bool fixed;

  final TextPainter painter;
  final double width;
  final double height;

  bool disposed = false;

  void dispose() {
    if (disposed) return;
    disposed = true;
    painter.dispose();
  }
}

/// 普通弹幕当前的左边界。
/// B站高级弹幕画布（862×568）→ 视口的映射。
///
/// **位置铺满整个播放器**：B站的高级弹幕和滚动弹幕一样，无视视频画面
/// 尺寸、铺满整个播放器区域，所以 x/y 各自按所在轴铺开（`x·W/862`、
/// `y·H/568`），不做留边。之前试过整体 contain + 居中，位置会缩进中间
/// 一小块，和滚动弹幕不对齐，观感不对。
///
/// **但字号取两轴的较小值**（等比）：字号如果跟着宽轴走（`W/862`），
/// 16:9 播放器里就比纵向空间大出 1.17 倍，看着比 B站 大一圈 —— 这正是
/// 「高级弹幕被放得很大」的来源。取 min 之后文字本身仍按等比缩放，
/// 不会跟着横向被拉宽。
({double sx, double sy, double s}) _advFit(Size size) {
  final sx = size.width / 862.0;
  final sy = size.height / 568.0;
  return (sx: sx, sy: sy, s: math.min(sx, sy));
}

double _normalX(_NormalFlying f, double viewportWidth, int posMs) {
  if (f.fixed) return (viewportWidth - f.width) / 2;
  final seconds = (posMs - f.bornAt) / 1000.0;
  final speed =
      (viewportWidth + f.width) / BiliDanmakuOverlayState._scrollSeconds;
  return viewportWidth - seconds * speed;
}

class BiliDanmakuOverlay extends StatefulWidget {
  const BiliDanmakuOverlay({
    super.key,
    required this.clock,
    required this.bvid,
    this.enabled = true,
  });

  /// 播放进度源。每帧读一次，不依赖播放器的具体实现。
  final ValueListenable<VideoSnapshot> clock;
  final String bvid;
  final bool enabled;

  @override
  State<BiliDanmakuOverlay> createState() => BiliDanmakuOverlayState();
}

class BiliDanmakuOverlayState extends State<BiliDanmakuOverlay>
    with SingleTickerProviderStateMixin {
  /// 当前挂载的弹幕层。调试扩展 ext.podenco/danmaku 靠它读引擎内部状态。
  ///
  /// 之所以要这个：屏幕上「有没有重复」以前只能靠肉眼看截图，而引擎内
  /// 到底有几条、是不是同一条被放了两遍，只有 activeEntries 说得清。
  /// 把它暴露成 VM Service 扩展后，断言变成读一个 JSON 就行。
  static BiliDanmakuOverlayState? active;

  /// 高级弹幕每帧允许排版的数量。满屏轰炸时分帧摊开，单帧只花 ~3ms
  static const int _layoutBudgetPerFrame = 20;

  /// 高级弹幕同屏上限
  static const int _maxOnScreen = 120;

  /// 60fps 逐帧驱动
  late final Ticker _ticker;

  // ── 普通弹幕自绘层（mode 1~6）──────────────────────────────
  //
  // 早期用过自带逻辑时钟的弹幕引擎，它和 video_player 的 position
  // 是两个独立时钟。Web 上帧间隔会被 clamp，掉帧/窗口不聚焦时逻辑
  // 时钟推进慢于真实时间 —— 弹幕越来越滞后（实测视频 47 秒、屏上还是
  // 17 秒那批），滚动弹幕本该 4~8 秒滚完却永远滚不完，看着就是
  // 「同一批弹幕反复出现 / 一堵墙」。桌面端帧率稳，所以只有 Web 炸。
  //
  // 自绘只有一个时间基准：position。暂停 = 位置不变 = 弹幕静止；
  // seek = 位置跳变 = 清屏重排。不存在两套时钟对不齐的可能。

  /// 普通弹幕（mode 1~6），按时间升序
  List<BiliDanmaku> _normal = const [];

  /// 屏上的普通弹幕
  final List<_NormalFlying> _normalFlying = [];

  /// 下一条待派发的下标（严格递增，保证每条只出现一次）
  int _normalCursor = 0;

  /// 轨道高度。配合 16 号字不挤，也和 B站的行距观感接近。
  static const double _trackHeight = 26;

  /// 一条滚动弹幕穿过整屏的时长（秒）。B站约 8 秒，与文字长短无关。
  static const double _scrollSeconds = 8;

  /// 固定弹幕（mode 4/5）停留时长
  static const int _fixedStayMs = 4000;

  // ── 高级弹幕层（mode 7）────────────────────────────────────
  List<BiliDanmaku> _advanced = const [];
  final List<BiliDanmaku> _pending = [];
  final List<_AdvancedFlying> _flying = [];
  int _cursor = 0;
  int _lastPos = -1;

  /// 时间轴重建次数。调试用：seek 是否真的走到重建、以及触发频率。

  /// _onFrame 执行计数。Ticker 一旦停了，这个数不再增长 —— 用来区分
  /// 「逻辑没同步」和「根本没有帧」。
  int _frameCount = 0;


  /// 画板重绘通知器：只驱动高级弹幕 CustomPaint，widget 树不动
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  TextPainter? _counterPainter;

  int _dbgFrames = 0;

  @override
  void initState() {
    super.initState();
    active = this;
    _ticker = createTicker(_onFrame)..start();
    unawaited(_load());
  }

  /// 当前播放位置（毫秒）。
  ///
  /// 播放器的 position 是离散上报的（Web 上约 250ms 一次，libmpv 稍密一些），
  /// 而弹幕是每帧重绘的。直接读上报值，滚动弹幕就会「一秒跳几下」；
  /// 这里用「上报值 + 距上报时刻流逝的时间」插值，上限 600ms ——
  /// 缓冲、卡顿的时候最多多算半秒，不会被拖成越飘越远。
  int get _clockPosMs {
    final snapshot = widget.clock.value;
    var ms = snapshot.position.inMilliseconds;
    final captured = snapshot.capturedAt;
    if (captured != null && snapshot.playing && !snapshot.buffering) {
      final drift = DateTime.now().difference(captured).inMilliseconds;
      if (drift > 0 && drift < 600) ms += drift;
    }
    return ms;
  }

  /// 弹幕层瞬时快照。字段扁平，便于直接断言。
  Map<String, Object?> probeSnapshot() {
    final posMs = _clockPosMs;
    final width = _viewportSize().width;
    final entries = <Map<String, Object?>>[];
    final atCount = <String, int>{};
    final textCount = <String, int>{};
    for (final f in _normalFlying) {
      final at = f.item.timeMs;
      final atKey = '$at|${f.item.text}';
      atCount[atKey] = (atCount[atKey] ?? 0) + 1;
      textCount[f.item.text] = (textCount[f.item.text] ?? 0) + 1;
      entries.add({
        'at': at,
        'type': f.fixed ? (f.item.mode == 5 ? 'T' : 'B') : 'S',
        'text': f.item.text,
        'x': _normalX(f, width, posMs).round().toString(),
        'lane': '${f.lane}',
      });
    }
    var atDup = 0;
    var textDup = 0;
    atCount.forEach((_, n) {
      if (n > atDup) atDup = n;
    });
    textCount.forEach((_, n) {
      if (n > textDup) textDup = n;
    });
    return {
      'mounted': true,
      'probeVer': 4,
      'posMs': posMs,
      'isPlaying': widget.clock.value.playing,
      'active': _normalFlying.length,
      'cursor': _normalCursor,
      'frames': _frameCount,
      'normalTotal': _normal.length,
      'advancedTotal': _advanced.length,
      'flyingAdvanced': _flying.length,
      'atDup': atDup,
      'textDup': textDup,
      'entries': entries,
    };
  }

  @override
  void didUpdateWidget(covariant BiliDanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) {
      _lastPos = -1;
      _resetAdvanced();
    }
  }

  @override
  void dispose() {
    if (identical(active, this)) active = null;
    _ticker.dispose();
    _clearFlying();
    _counterPainter?.dispose();
    _repaint.dispose();
    _renderPosNotifier.dispose();
    _clearNormalFlying();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await BiliApi.fetchDanmaku(widget.bvid);
      if (!mounted) return;
      setState(() {
        _all(items);
        _lastPos = -1; // 触发一次 seekTo 对齐，把中途载入的弹幕对准进度
      });
    } catch (_) {
      // 弹幕是锦上添花，失败就当没弹幕
    }
  }

  void _all(List<BiliDanmaku> items) {
    // mode 1~6 → 普通弹幕层；mode 7 → 高级弹幕自绘层
    final normal = <BiliDanmaku>[];
    final advanced = <BiliDanmaku>[];
    for (final d in items) {
      if (d.mode == 7) {
        advanced.add(d);
        continue;
      }
      normal.add(d);
    }
    _normal = normal;
    _advanced = advanced;

    // 普通弹幕走 loadTimeline：把整份「已录制流」一次性交给引擎，
    // 每条带 media 时间戳 BarrageItem.at。引擎内部的 BarrageTimeline
    // 用 dueBy() 按 media 时间逐条释放（每条只释放一次），并由
    // seekTo() 把引擎逻辑时钟直接设成视频位置 —— 弹幕「何时出现」
    // 严格由视频进度决定，不存在 live send 那种「队列排队几百 ms
    // 才上屏 → 时间轴错位 / 同帧糊屏」的问题。
    //
    _resetNormal(_clockPosMs);
  }

  /// 按 [posMs] 重排普通弹幕：清屏 + 游标定位。
  ///
  /// 自绘没有等待队列、没有引擎时钟，所以 seek 就是这三件事：把屏上的
  /// 丢掉、把游标挪到新位置之后的第一条、重绘。拖动时 position 连跳
  /// 几次也无所谓 —— 每次都是幂等的清屏重排，不会像引擎那样把上一次
  /// 的残留留在队列里。
  void _resetNormal(int posMs) {
    _clearNormalFlying();
    _normalCursor = _firstNormalFrom(posMs);
  }

  void _clearFlying() {
    // 先摘再销毁：即使某个 dispose 抛异常，列表也已干净，
    // 不会留下已销毁的弹幕让后续帧反复踩雷
    final stale = List<_AdvancedFlying>.of(_flying);
    _flying.clear();
    for (final f in stale) {
      f.dispose();
    }
  }

  void _resetAdvanced() {
    _pending.clear();
    _clearFlying();
    // seek 后游标直接跳到新位置之后，不要从头扫描：否则一帧内会把
    // 0~pos 之间所有旧高级弹幕塞进 _pending（几百上千条），既白耗
    // 又可能因 600 上限把 pos 附近真正该显示的挤掉。
    _cursor = _firstAdvancedFrom(_clockPosMs);
  }

  /// 第一条 timeMs >= [pos] 的高级弹幕下标（seek 后从这里继续扫描）
  int _firstAdvancedFrom(int pos) {
    var lo = 0;
    var hi = _advanced.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_advanced[mid].timeMs < pos) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _onFrame(Duration elapsed) {
    if (!mounted || !widget.enabled) return;
    _frameCount++;

    final pos = _clockPosMs;
    final isPlaying = widget.clock.value.playing;

    // seek 识别：首次对齐、往回拖、或往前跳超过 3 秒。
    // 回退阈值 1000ms：Web 端 position 在 seek 后会小幅抖动，阈值太小
    // 会把抖动误判成 seek —— 每次误判都清屏，弹幕会闪。
    final seeked =
        _lastPos < 0 || pos < _lastPos - 1000 || pos > _lastPos + 3000;
    final posChanged = pos != _lastPos;
    _lastPos = pos;

    if (seeked) {
      _resetNormal(pos);
      _resetAdvanced();
      _renderPos = pos;
      _repaint.value++;
      return;
    }

    // 平滑位置每帧都要算：画板按它定位，才顺。
    final renderPos = _smoothPos(pos, elapsed, isPlaying);

    if (posChanged && (_advanced.isNotEmpty || _normal.isNotEmpty)) {
      final size = _viewportSize();
      if (size.width > 0 && size.height > 0) {
        // 普通弹幕：派发到点的、推进并退役（用平滑位置，和画出来一致）
        _dispatchNormal(renderPos, size);
        _advanceNormal(renderPos, size);
      }
      // 高级弹幕流水线：扫描 → 分帧排版 → 清过期
      _scan(pos);
      _drainPending(pos, size);
      _flying.removeWhere((f) {
        final done = pos - f.bornAt > f.duration || f.bornAt > pos + 1000;
        if (done) f.dispose();
        return done;
      });
    }

    // 限帧重绘：弹幕是匀速横移，30fps 与 60fps 肉眼无差，但绘制开销减半。
    // Windows 上每帧重绘二三十条文字（drawParagraph）+ RepaintBoundary
    // 离屏合成，是卡顿的主要来源；Web 上因为 position 只有 4Hz，
    // 重绘本来就不密集，这条限制对它几乎无影响。
    final nowMs = elapsed.inMilliseconds;
    if (nowMs - _lastPaintMs >= 33 && (isPlaying || posChanged)) {
      _lastPaintMs = nowMs;
      _repaint.value++;
    }

    _dbgFrames++;
    if (_dbgFrames % 30 == 0) {
      debugPrint(
        '[DANMAKU] pos=$pos active=${_normalFlying.length} '
        'cursor=$_normalCursor/${_normal.length} adv=${_flying.length}',
      );
    }
  }

  /// 渲染用的平滑位置。
  ///
  /// Web 上 video_player 的 position 来自 timeupdate 事件，只有约 4Hz
  /// （250ms 一次）。直接拿它算弹幕坐标，就是每 250ms 跳一格 —— 肉眼看
  /// 就是卡。这里用 Ticker 的 elapsed 在上一次真实 position 上插值，
  /// 得到 60fps 的平滑位置；position 一更新就用真值校准，误差不累积。
  final ValueNotifier<int> _renderPosNotifier = ValueNotifier<int>(0);
  int get _renderPos => _renderPosNotifier.value;
  set _renderPos(int v) => _renderPosNotifier.value = v;

  int _posBaseRaw = -1;

  /// 上次重绘的 Ticker 时刻，用于把重绘限到约 30fps。
  int _lastPaintMs = 0;
  int _posBaseElapsedMs = 0;
  bool _posBasePlaying = false;

  int _smoothPos(int rawMs, Duration elapsed, bool playing) {
    final now = elapsed.inMilliseconds;
    if (rawMs != _posBaseRaw || playing != _posBasePlaying) {
      _posBaseRaw = rawMs;
      _posBaseElapsedMs = now;
      _posBasePlaying = playing;
      _renderPos = rawMs;
      return _renderPos;
    }
    if (!playing) {
      _renderPos = rawMs;
      return _renderPos;
    }
    final extra = now - _posBaseElapsedMs;
    // 上限 400ms：position 迟迟不更新（缓冲/卡顿）时别插得太远，
    // 免得弹幕跑到视频前面去。
    _renderPos = rawMs + (extra < 400 ? extra : 400);
    return _renderPos;
  }

  /// 弹幕层在屏幕上的尺寸（= 视频显示区域）。build 之前拿不到，返回零。
  Size _viewportSize() {
    final ro = context.findRenderObject();
    if (ro is RenderBox && ro.hasSize) return ro.size;
    return Size.zero;
  }

  /// 第一条 timeMs >= [posMs] 的普通弹幕下标
  int _firstNormalFrom(int posMs) {
    var lo = 0;
    var hi = _normal.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_normal[mid].timeMs < posMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _clearNormalFlying() {
    for (final f in _normalFlying) {
      f.dispose();
    }
    _normalFlying.clear();
  }

  /// 把到点的弹幕派发上屏。每条只派发一次，靠 [_normalCursor] 保证。
  void _dispatchNormal(int posMs, Size size) {
    var budget = 8; // 同帧上限，防密集段一帧糊满屏
    while (budget > 0 && _normalCursor < _normal.length) {
      final d = _normal[_normalCursor];
      if (d.timeMs > posMs) break;
      _normalCursor++;
      // 排太久的（seek 前积压的）不补发，否则一屏全是"迟到的"
      if (posMs - d.timeMs > 3000) continue;
      final painter = _makeNormalPainter(d, size.width);
      final fixed = d.mode == 4 || d.mode == 5;
      final lane = _pickLane(fixed, painter.width, posMs, size);
      if (lane == null) {
        // 轨道全忙：放回去，下一帧再试
        painter.dispose();
        _normalCursor--;
        break;
      }
      _normalFlying.add(
        _NormalFlying(
          item: d,
          bornAt: posMs,
          lane: lane,
          fixed: fixed,
          painter: painter,
          width: painter.width,
          height: painter.height,
        ),
      );
      budget--;
    }
  }

  /// 找一条能放下这条弹幕的轨道。
  ///
  /// 滚动弹幕要求该轨道最后一条的尾巴已经完全进屏（留 20px 间距），
  /// 否则两条会叠在一起；固定弹幕必须独占一条空轨道（B站就是这样）。
  int? _pickLane(bool fixed, double width, int posMs, Size size) {
    final lanes = (size.height / _trackHeight).floor();
    if (lanes <= 0) return null;
    for (var i = 0; i < lanes; i++) {
      _NormalFlying? newest;
      for (final f in _normalFlying) {
        if (f.lane != i) continue;
        if (newest == null || f.bornAt > newest.bornAt) newest = f;
      }
      if (newest == null) return i;
      if (fixed) continue;
      final tail = _normalX(newest, size.width, posMs) + newest.width;
      if (tail < size.width - 20) return i;
    }
    return null;
  }

  /// 推进并退役。滚动看"是否完全滚出左边"，固定看"是否到时长"。
  void _advanceNormal(int posMs, Size size) {
    _normalFlying.removeWhere((f) {
      final gone = f.fixed
          ? posMs - f.bornAt > _fixedStayMs
          : _normalX(f, size.width, posMs) + f.width < 0;
      if (gone) f.dispose();
      return gone;
    });
  }

  /// 普通弹幕字号。B站的 fs 基于 1920 宽的视频（25 是标准档、36 是大字、
  /// 18 是小字），必须按画布宽度等比缩放：固定成 16 会把大字弹幕（比如
  /// 用 ▲ 拼的金字塔）压成普通大小，全屏时又显得太小。
  double _normalFontSize(int raw, double viewportWidth) {
    final base = raw > 0 ? raw.toDouble() : 25;
    return (base * (viewportWidth / 1920.0)).clamp(12.0, 42.0);
  }
  TextPainter _makeNormalPainter(BiliDanmaku d, double viewportWidth) {
    return TextPainter(
      text: TextSpan(
        text: d.text,
        style: TextStyle(
          color: Color(0xFF000000 | (d.color & 0xFFFFFF)),
          fontSize: _normalFontSize(d.fontSize, viewportWidth),
          fontWeight: FontWeight.w600,
          shadows: const [Shadow(offset: Offset(1, 1), color: Colors.black)],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 4000);
  }

  /// 供日志用的弹幕类型短标
  void _scan(int pos) {
    while (_cursor < _advanced.length && _advanced[_cursor].timeMs <= pos) {
      _pending.add(_advanced[_cursor]);
      _cursor++;
    }
    if (_pending.length > 600) {
      _pending.removeRange(0, _pending.length - 600);
    }
  }

  void _drainPending(int pos, Size size) {
    final fit = _advFit(size);
    var budget = _layoutBudgetPerFrame;
    while (budget > 0 &&
        _pending.isNotEmpty &&
        _flying.length < _maxOnScreen) {
      final d = _pending.removeAt(0);
      // 排队太久的不补发
      if (pos - d.timeMs > 5000) continue;
      final adv = d.advanced;
      if (adv == null) continue;

      // 显示时长用 B站自己的 showMs，且保证运动完整
      var duration = adv.showMs;
      if (adv.isMoving && duration < adv.moveMs + 300) {
        duration = adv.moveMs + 300;
      }

      final painter = _makePainter(d, fit.s);
      _flying.add(
        _AdvancedFlying(
          item: d,
          bornAt: pos,
          duration: duration,
          painter: painter,
          width: painter.width,
          height: painter.height,
        ),
      );
      budget--;
    }
  }

  TextPainter _makePainter(BiliDanmaku d, double scale) {
    return TextPainter(
      text: TextSpan(
        text: d.text,
        style: TextStyle(
          color: Color(0xFF000000 | (d.color & 0xFFFFFF)),
          fontSize: _advFontSize(d.fontSize, scale),
          fontWeight: FontWeight.w600,
          // 打包进项目的 SimHei 符号子集（见 pubspec.yaml）。
          // 只含几何符号/ASCII/标点，汉字不在里面 —— 缺字时走引擎
          // fallback 正常显示，所以不会重蹈「指定 SimHei 后反复拉
          // Noto 子集吃到 1G」的覆辙（那时指定的名字在 Web 上不存在）。
          fontFamily: 'DanmakuSymbols',
          // 单个实心阴影叠出右下黑边保证可读。
          shadows: const [
            Shadow(offset: Offset(1, 1), color: Colors.black),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 4000);
  }

  /// 高级弹幕字号。
  ///
  /// B站给的是 **862×568 虚拟画布**上的像素值，乘 [_advFit] 给出的等比
  /// 系数（两轴较小者）。**不能按视口宽度单独算** —— 高级弹幕的位置是
  /// 铺满播放器的，但字号若跟着宽轴走，16:9 下会比纵向空间大出 1.17 倍，
  /// 整屏弹幕看着大一圈，地图这类会直接顶出画面。
  double _advFontSize(int raw, double scale) {
    final scaled = raw.clamp(8, 200) * scale;
    return scaled.clamp(8.0, 200.0);
  }



  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    final hasAdvanced = _advanced.isNotEmpty;

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            // 普通弹幕：自绘画板。位置由视频 position 直接算出，
            // 没有引擎时钟，所以暂停/seek 天然正确。
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _NormalPainter(
                    flying: _normalFlying,
                    renderPos: _renderPosNotifier,
                    repaint: _repaint,
                  ),
                ),
              ),
            ),
            // 高级弹幕：自绘画板。RepaintBoundary 隔离重绘范围，
            // 不加 isComplex —— 每帧都变，光栅缓存只会白白重建位图。
            if (hasAdvanced)
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _AdvancedPainter(
                      flying: _flying,
                      clock: widget.clock,
                      counter: _counterPainter ??= (TextPainter(
                        text: TextSpan(
                          text: '弹幕 ${_normal.length + _advanced.length}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                        textDirection: TextDirection.ltr,
                      )..layout()),
                      repaint: _repaint,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 高级弹幕画板：mode 7 任意坐标 + 运动插值，每帧直接贴排版好的文字。
class _AdvancedPainter extends CustomPainter {
  _AdvancedPainter({
    required this.flying,
    required this.clock,
    required this.counter,
    required super.repaint,
  });

  final List<_AdvancedFlying> flying;
  final ValueListenable<VideoSnapshot> clock;
  final TextPainter counter;

  @override
  void paint(Canvas canvas, Size size) {
    final position = clock.value.position.inMilliseconds;
    counter.paint(canvas, Offset(size.width - counter.width - 8, 6));
    final fit = _advFit(size);

    for (final f in flying) {
      if (f.disposed) continue;
      final elapsed = position - f.bornAt;
      if (elapsed < 0 || elapsed > f.duration) continue;
      final adv = f.item.advanced;
      if (adv == null) continue;

      // 进度：路径弹幕铺满显示时长；直线弹幕用移动时长（静止则 0）
      final t = adv.hasPath
          ? (elapsed / f.duration).clamp(0.0, 1.0).toDouble()
          : (adv.isMoving
              ? (elapsed / adv.moveMs).clamp(0.0, 1.0).toDouble()
              : 0.0);

      // 锚点（文字中心，归一化 → 像素）：路径弹幕沿折线取点，
      // 直线弹幕起点→终点插值
      Offset anchorNorm;
      if (adv.hasPath) {
        anchorNorm = _pathPointAt(adv.pathXY!, adv.pathLength, t);
      } else {
        var px = adv.x;
        var py = adv.y;
        if (adv.isMoving) {
          px = adv.x + (adv.toX - adv.x) * t;
          py = adv.y + (adv.toY - adv.y) * t;
        }
        anchorNorm = Offset(px, py);
      }
      final anchor = Offset(
        anchorNorm.dx * 862.0 * fit.sx,
        anchorNorm.dy * 568.0 * fit.sy,
      );

      // 整个生存期的透明度渐变（content[2] "1-0.77" 等）
      final alpha =
          (adv.alpha1 + (adv.alpha2 - adv.alpha1) * elapsed / f.duration)
              .clamp(0.0, 1.0);

      // 只有 rotY≠0 才是真正的 3D（文字立起来与屏幕垂直）。纯 rotZ 是平面
      // 旋转，必须走 2D 分支 —— 3D 管线把「文字中心」钉在锚点上，2D 分支把
      // 「文字左下角」钉在锚点上，两条路混用会让同一组高级弹幕里旋转过的
      // 元素整体偏移半个字宽 + 半个字高，组合图形直接散架。
      //
      // 实例（BV1cD4y1S7Yx t=6.41s 的合成玉图标，四条锚点全是 400,200）：
      //   □ fs=100 rz=0   ■ fs=75 rz=0   □ fs=90 rz=45   ╳ fs=100 rz=45
      // 四个都按左下角定位、各自绕自身中心旋转才会叠成一个同心图标；
      // 右边的 "  X200"（锚点 430,200）正好贴在图标右缘，也印证 x 是左边缘。
      if (adv.rotY.abs() > 0.01) {
        // ── 官方 3D 弹幕管线（Flash 模型，danmaku2ass/CCL 双向佐证）──
        // 文字是 z=0 平面上的一块板，绕自身中心 rotZ/rotY 旋转，再经
        // 透视投影（消失点=屏幕中心，焦距=宽·tan40°/2，Flash 公式）。
        // 「超小杯」rotY=90°：文字立起来与屏幕垂直，投影成从屏幕中心
        // 指向锚点的斜条、近端大远端小 —— 与官方录屏逐帧吻合。
        //
        // 注意 transform 内部的模型变换是把**文字中心**平移到 anchor，
        // 而 B站 的坐标语义是「左边缘 + 文字顶部」。所以这里先把锚点
        // 换算成文字中心，两条分支落点才一致 —— 否则同一条弹幕带上
        // rotY 就会比不带的高半个行高、右半个字宽。
        final center = Offset(
          anchor.dx + f.width / 2,
          anchor.dy + f.height / 2,
        );
        final m = BiliDanmaku3D.transform(
          canvas: size,
          anchor: center,
          textWidth: f.width,
          textHeight: f.height,
          rotZDeg: adv.rotZ,
          rotYDeg: adv.rotY,
        );

        canvas.save();
        canvas.transform(m.storage);
        // 淡入淡出走硬切（alpha<0.05 跳过），绝不用 saveLayer：
        // 满屏运动弹幕同时渐变时，每条一个离屏 buffer 会把 Windows 的
        // Skia GL 管线打崩 —— EGL Context Lost (12302)，驱动直接重置。
        // 运动弹幕有位移，硬切与渐变肉眼难辨。
        if (alpha > 0.05) {
          f.painter.paint(canvas, Offset.zero);
        }
        canvas.restore();
      } else {
        // 平面弹幕：B站的 (x, y) 是 **左边缘 + 文字顶部**，不要减任何东西。
        //
        // x 是左边缘：合成玉图标组（全部锚点 400,200）里 `□` fs=100 和
        // 右边的 `"  X200"`（锚点 430,200）—— 按中心对齐时 X200 会压进
        // 图标里，按左边缘则正好贴在图标右缘。
        //
        // y 是**文字块顶部**。这里踩过两次坑，记录清楚：
        //   1) 减 width/2、height/2（按中心对齐）→ 每条都往左上挪半身，
        //      大字的 left 直接变负数，出现「整体左偏 + 显示不全」。
        //   2) 减第一行基线（按基线对齐）→ 30 条 y 偏小的弹幕被推出
        //      画面上边。本视频实例：`埃及法老`(fs=127, y=10) 基线对齐
        //      top=-100、`Damedane`(fs=100, y=37) top=-49、象形文字
        //      (fs=100, y=40) top=-46 —— 用户看到的「好多高级弹幕飞到
        //      视口上面」就是这批。按顶部对齐则全部 top≥0。
        //
        // 那「说明文字和金字塔重合」为什么曾经看起来像 y 语义的锅？
        // 因为 `▲` 的墨迹只占 em 框的 13~111（不是整行高）：`▲▲▲`
        // (fs=127, y=330) 墨迹落在 343~441，说明文字(fs=20, y=440)
        // 落在 441~461，**刚好相接不重叠**。当时的重叠是第 1 条那个
        // 中心对齐造成的，跟顶部/基线无关。
        //
        // 不做 clamp：y 很小的元素本来就该有一截在画布外（B站也是这么
        // 画的，比如从边缘进场的竖线），压进画布反而会让它整体下移。
        final topLeft = Offset(anchor.dx, anchor.dy);
        if (alpha > 0.05) {
          if (adv.rotZ.abs() > 0.01) {
            final center = topLeft + Offset(f.width / 2, f.height / 2);
            canvas.save();
            canvas.translate(center.dx, center.dy);
            canvas.rotate(adv.rotZ * math.pi / 180);
            canvas.translate(-center.dx, -center.dy);
            f.painter.paint(canvas, topLeft);
            canvas.restore();
          } else {
            f.painter.paint(canvas, topLeft);
          }
        }
      }
    }
  }

  /// 按弧长比例在折线上取点：t ∈ [0,1] → 折线上的坐标。
  /// 点数几十个，线性扫段即可，每帧几十条的开销可忽略。
  static Offset _pathPointAt(List<double> xy, double totalLen, double t) {
    if (t <= 0) return Offset(xy[0], xy[1]);
    final target = t * totalLen;
    var acc = 0.0;
    for (var i = 0; i + 3 < xy.length; i += 2) {
      final x0 = xy[i];
      final y0 = xy[i + 1];
      final x1 = xy[i + 2];
      final y1 = xy[i + 3];
      final seg = (Offset(x0, y0) - Offset(x1, y1)).distance;
      if (acc + seg >= target && seg > 0) {
        final local = (target - acc) / seg;
        return Offset(x0 + (x1 - x0) * local, y0 + (y1 - y0) * local);
      }
      acc += seg;
    }
    // t=1 或浮点误差兜底：返回终点
    return Offset(xy[xy.length - 2], xy[xy.length - 1]);
  }

  @override
  bool shouldRepaint(_AdvancedPainter old) => true;
}

/// 供视频页的「发弹幕」按钮回调使用：发送一条弹幕到B站。
Future<String?> sendDanmaku({
  required String bvid,
  required String text,
  required int progressMs,
}) async {
  if (!biliModel.loggedIn) return '需要登录后才能发弹幕';
  if (text.trim().isEmpty) return '弹幕内容不能为空';
  try {
    await BiliApi.postDanmaku(bvid, text.trim(), progressMs: progressMs);
    return null;
  } on BiliException catch (e) {
    return e.message;
  } catch (e) {
    return '弹幕发送失败：$e';
  }
}

/// 普通弹幕画板：每帧按视频 position 现算位置，直接贴排版好的文字。
///
/// 和 flame 那套的本质区别：这里没有任何"推进"逻辑，位置是 position 的
/// 纯函数。所以暂停时位置不动（不需要 pause 状态机）、seek 时位置直接
/// 跳到新值、帧率高低只影响观感流畅度而不影响时间轴正确性。
class _NormalPainter extends CustomPainter {
  _NormalPainter({
    required this.flying,
    required this.renderPos,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<_NormalFlying> flying;

  /// 平滑后的渲染位置（由 State 每帧更新，见 _smoothPos）。
  /// 用 notifier 而不是 int：build 不会每帧跑，传值的话画板永远拿旧值。
  final ValueNotifier<int> renderPos;

  @override
  void paint(Canvas canvas, Size size) {
    if (flying.isEmpty) return;
    final posMs = renderPos.value;
    const track = BiliDanmakuOverlayState._trackHeight;

    for (final f in flying) {
      final x = _normalX(f, size.width, posMs);
      // 完全在视口外的不画（入场/出场时各有一小段）
      if (x > size.width || x + f.width < 0) continue;
      final y = (f.fixed && f.item.mode == 4)
          ? size.height - (f.lane + 1) * track
          : f.lane * track;
      f.painter.paint(
        canvas,
        Offset(x, y.clamp(0.0, (size.height - f.height).clamp(0.0, 1e9))),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NormalPainter oldDelegate) => true;
}
