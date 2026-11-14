import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'history_model.dart';
import 'models.dart';
import 'siren_api.dart';
import 'storage.dart';

/// 全局唯一的播放器。整个 app 只有一份播放状态，所以做成单例。
///
/// 用 ChangeNotifier + ListenableBuilder 是因为它最接近 Vue 的响应式：
/// 状态变了 notifyListeners()，监听的界面自己重建。
/// 等以后状态复杂了再换 Riverpod，现在这层完全够用。
class PlayerModel extends ChangeNotifier {
  PlayerModel() {
    // 播放进度：约 200ms 一次，用来滚歌词和推进度条
    _subs.add(
      _audio.onPositionChanged.listen((position) {
        _position = position;
        _syncLyricIndex();
        _probeDurationIfNeeded();
        notifyListeners();
      }),
    );

    // 播放状态的唯一事实来源在插件里。手写的 _playing 只做即时反馈，
    // 真实的状态变化（出错、外部打断、平台异步行为）都从这里纠偏 ——
    // 没有它，一次丢失的平台回复就能让按钮永远冻在旧状态上。
    _subs.add(
      _audio.onPlayerStateChanged.listen((state) {
        final playing = state == PlayerState.playing;
        if (playing == _playing) return;
        _playing = playing;
        notifyListeners();
      }),
    );

    // 时长要等音频加载完才知道，拿到之前进度条是 0
    _subs.add(
      _audio.onDurationChanged.listen((duration) {
        _duration = duration;
        notifyListeners();
      }),
    );

    // 一首放完之后干什么，取决于播放模式
    _subs.add(
      _audio.onPlayerComplete.listen((_) => unawaited(_onComplete())),
    );

    // 进度轮询兜底。Windows 端 audioplayers 在后台线程发事件，引擎
    // 明确警告可能丢消息 —— 这台机器上进度事件真的会丢，进度条就
    // 永远不动。方法通道的回复（resume 丢，getCurrentPosition 不丢）
    // 是可靠的，所以每 500ms 主动问一次。暂停时返回的进度和当前一致，
    // 值没变就不 notify，零开销。
    _positionPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_pollPosition());
    });
  }

  final AudioPlayer _audio = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];

  List<Track> _queue = const [];
  int _index = -1;

  bool _playing = false;
  bool _loading = false;
  String? _error;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  SongDetail? _detail;
  List<LyricLine> _lyrics = const [];
  int _lyricIndex = -1;

  PlayMode _mode = PlayMode.listLoop;
  double _volume = 1.0;

  /// 静音前的音量，用于「点一下静音、再点一下恢复」
  double _volumeBeforeMute = 1.0;

  /// _load 的轮次号。快速切歌会并发多个 _load，只有最新一轮生效，
  /// 旧轮在每个 await 之后检查自己是不是已经过期。
  int _loadSeq = 0;

  /// duration 兜底探测的进行中标记，见 _probeDurationIfNeeded。
  bool _probingDuration = false;

  /// 进度轮询定时器，见构造函数里的说明。
  Timer? _positionPollTimer;

  Timer? _saveTimer;

  // ── 对外只读状态 ─────────────────────────────────────────

  List<Track> get queue => _queue;
  int get index => _index;
  bool get playing => _playing;
  bool get loading => _loading;
  String? get error => _error;
  Duration get position => _position;
  Duration get duration => _duration;
  SongDetail? get detail => _detail;
  List<LyricLine> get lyrics => _lyrics;
  int get lyricIndex => _lyricIndex;
  PlayMode get mode => _mode;
  double get volume => _volume;
  bool get muted => _volume == 0;

  Track? get current =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;

  bool get hasTrack => current != null;

  double get progress {
    final total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  // ── 启动恢复 ─────────────────────────────────────────────

  /// 冷启动时把上次的队列、模式、音量读回来。
  ///
  /// 只恢复「听什么」，不恢复「播到哪」—— 音频直链带签名会过期，
  /// 恢复进度得重新换源，那就等于一开 app 就自动放歌了，很打扰。
  /// 所以恢复后是暂停态，点播放才真正加载。
  Future<void> restore() async {
    final snapshot = await PlayerStorage.load();
    if (snapshot == null) return;

    if (snapshot.queue.isNotEmpty) {
      _queue = snapshot.queue;
      _index = snapshot.index.clamp(0, _queue.length - 1);
    }
    _mode = snapshot.mode;
    _volume = snapshot.volume;
    _volumeBeforeMute = _volume > 0 ? _volume : 1.0;

    await _audio.setVolume(_volume);
    notifyListeners();
  }

  // ── 播放控制 ─────────────────────────────────────────────

  /// 把一整个列表塞进队列并从 start 开始播。
  /// 专辑页点「播放全部」、单曲页点某一首，走的都是这里。
  Future<void> playQueue(List<Track> tracks, {int start = 0}) async {
    if (tracks.isEmpty) return;
    _queue = List.of(tracks);
    _index = start.clamp(0, _queue.length - 1);
    await _load();
  }

  /// 播 / 暂停。
  Future<void> toggle() async {
    if (!hasTrack) return;

    if (_playing) {
      // 先翻图标再发暂停，点了立刻有反应；真状态由状态流兜底
      _playing = false;
      notifyListeners();
      try {
        await _audio.pause();
      } catch (_) {
        // pause 失败不打断 UI，状态流会纠偏
      }
      return;
    }

    // 从上次的队列恢复过来时，音频源还没设过，得先走一整轮加载
    if (_detail == null) {
      await _load();
      return;
    }

    // resume 的平台回复在 Windows 上可能丢（C++ Play 抛异常时不回包）。
    // 丢回复 = Play 大概率真的失败了，所以这里不能乐观置播放态骗人，
    // 直接退回完整重载 —— songDetail 有缓存，几秒就能重新出声。
    try {
      await _audio.resume().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      await _load();
      return;
    }
    _playing = true;
    notifyListeners();
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    _index = _mode == PlayMode.shuffle
        ? _randomIndex()
        : (_index + 1) % _queue.length;
    await _load();
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    // 播了 3 秒以上，按上一首其实是「重播当前这首」，
    // 这是音乐播放器的通行行为，不是 bug
    if (_position.inSeconds >= 3) {
      await seek(Duration.zero);
      return;
    }
    // 上一首不走随机：随机模式下「上一首」的语义没法定义，
    // 退回顺序表里前一首是用户的普遍预期
    _index = (_index - 1 + _queue.length) % _queue.length;
    await _load();
  }

  Future<void> seek(Duration target) async {
    // 大 wav 还在缓冲时拖进度条，原生 seek 可能超时 —— 别让异常炸到
    // 调用方（播放页的 onChangeEnd 没 await），UI 照拨，位置由进度流纠偏
    try {
      await _audio.seek(target).timeout(const Duration(seconds: 8));
    } catch (_) {
      // seek 失败不打断播放
    }
    _position = target;
    _syncLyricIndex();
    notifyListeners();
  }

  Future<void> stop() async {
    await _audio.stop();
    _playing = false;
    _position = Duration.zero;
    notifyListeners();
  }

  // ── 模式与音量 ───────────────────────────────────────────

  void setMode(PlayMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    _scheduleSave();
  }

  /// 按 顺序 → 单曲循环 → 随机 轮着切，按钮点一下就换一个
  void cycleMode() {
    setMode(PlayMode.values[(_mode.index + 1) % PlayMode.values.length]);
  }

  Future<void> setVolume(double value) async {
    final next = value.clamp(0.0, 1.0);
    if (next == _volume) return;
    _volume = next;
    if (next > 0) _volumeBeforeMute = next;
    await _audio.setVolume(next);
    notifyListeners();
    _scheduleSave();
  }

  /// 静音开关。恢复时用的是静音前的音量，不是固定拉满。
  Future<void> toggleMute() async {
    if (_volume > 0) {
      _volumeBeforeMute = _volume;
      await setVolume(0);
    } else {
      await setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 1);
    }
  }

  // ── 内部 ────────────────────────────────────────────────

  /// 一首播完之后的行为。
  ///
  /// 播完状态的播放器在 Windows 上 resume 的回复会丢（C++ Play 抛异常
  /// 不回包），所以这里的每个 await 都必须带超时，超时一律退回完整
  /// 重载 —— songDetail 有缓存，重载比干等便宜得多。
  Future<void> _onComplete() async {
    if (_mode == PlayMode.singleLoop) {
      // 单曲循环不换源，直接把进度拨回 0 接着放，省掉一次网络往返
      try {
        await _audio.seek(Duration.zero).timeout(const Duration(seconds: 5));
        await _audio.resume().timeout(const Duration(seconds: 5));
        _position = Duration.zero;
        _playing = true;
        _syncLyricIndex();
        notifyListeners();
        return;
      } catch (_) {
        // 有些平台在 completed 状态下 seek/resume 不生效，那就退回重新加载
        await _load();
        return;
      }
    }
    await next();
  }

  /// 随机但避开当前这首。试 8 次还撞就顺延，
  /// 这样队列只有两首时也不会卡在同一首上打转。
  int _randomIndex() {
    if (_queue.length <= 1) return _index;
    final random = Random();
    var next = _index;
    for (var i = 0; i < 8 && next == _index; i++) {
      next = random.nextInt(_queue.length);
    }
    return next == _index ? (_index + 1) % _queue.length : next;
  }

  /// 真正去拉地址、换源、开播。切歌和首次播放都走这里。
  Future<void> _load() async {
    final track = current;
    if (track == null) return;

    // 防重入：连点「下一首」会并发多个 _load，旧轮在每个 await 之后
    // 检查轮次号，过期就静默退出，避免两轮互相覆盖状态。
    final seq = ++_loadSeq;

    _loading = true;
    _error = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _probingDuration = false;
    _lyrics = const [];
    _lyricIndex = -1;
    _detail = null;
    notifyListeners();

    try {
      // 先拿直链。注意这一步没法省 —— 列表接口里没有播放地址。
      final detail = await SirenApi.songDetail(track.cid);
      if (seq != _loadSeq) return;

      // 老存档里的歌可能没带 albumCid（专辑详情接口不返回这个字段），
      // 用详情结果补回去，否则封面和专辑名查不到，播放页标题会退化成「正在播放」。
      if (track.albumCid.isEmpty && detail.albumCid.isNotEmpty) {
        _queue = [
          for (var i = 0; i < _queue.length; i++)
            i == _index ? _queue[i].copyWith(albumCid: detail.albumCid) : _queue[i],
        ];
      }

      // 上一次播的必须先掐掉，否则两个音频源会叠在一起出声
      await _audio.stop();
      if (seq != _loadSeq) return;
      await _audio.setSourceUrl(detail.sourceUrl);
      if (seq != _loadSeq) return;
      // 换源之后音量会重置，得重新设一次
      await _audio.setVolume(_volume);

      // resume 的平台回复在 Windows 上可能丢（C++ 抛异常时不回 result）。
      // 丢回复 ≈ Play 真的失败了，报错让用户再按一次 —— 下一次走
      // toggle 的重载路径。这里不重试，避免 _load 递归调用自己。
      try {
        await _audio.resume().timeout(const Duration(seconds: 5));
      } on TimeoutException {
        if (seq != _loadSeq) return;
        _error = '播放启动失败，请再按一次播放';
        _loading = false;
        _playing = false;
        notifyListeners();
        _scheduleSave();
        return;
      }
      if (seq != _loadSeq) return;

      _detail = detail;
      _playing = true;
      _loading = false;
      notifyListeners();
      _scheduleSave();
      historyModel.record(track);

      // 歌词单独拉，不阻塞播放。没歌词的歌（大量纯音乐）就是空列表。
      final lyricUrl = detail.lyricUrl;
      if (lyricUrl != null) unawaited(_loadLyric(lyricUrl, detail.cid));
    } on SirenException catch (e) {
      if (seq != _loadSeq) return;
      _error = e.message;
      _loading = false;
      _playing = false;
      notifyListeners();
      _scheduleSave();
    } on TimeoutException {
      // setSourceUrl 内部等 LOADEDDATA 有 30 秒上限，大 wav 缓冲慢会走到这
      if (seq != _loadSeq) return;
      _error = '音频加载超时，网络太慢或文件太大';
      _loading = false;
      _playing = false;
      notifyListeners();
      _scheduleSave();
    } catch (e) {
      if (seq != _loadSeq) return;
      _error = '播放失败：$e';
      _loading = false;
      _playing = false;
      notifyListeners();
      _scheduleSave();
    }
  }

  /// 进度轮询：问一次当前进度，变了才更新、才 notify。
  /// 与事件流并存 —— 事件到得早就被去重跳过，事件丢了就由这里救场。
  Future<void> _pollPosition() async {
    if (!hasTrack || _loading) return;
    try {
      final position = await _audio.getCurrentPosition();
      if (position == null || position == _position) return;
      _position = position;
      _syncLyricIndex();
      _probeDurationIfNeeded();
      notifyListeners();
    } catch (_) {
      // 问不到就等下一轮，别让一次失败打断轮询
    }
  }

  /// Windows 端偶尔只给 position 不给 duration（NaN 被折算成 0），
  /// 进度条会一直禁用。等第一帧位置回来还没拿到时长，就主动问一次。
  Future<void> _probeDurationIfNeeded() async {
    if (_duration != Duration.zero ||
        _position == Duration.zero ||
        _probingDuration) {
      return;
    }
    _probingDuration = true;
    try {
      final d = await _audio.getDuration();
      if (_duration == Duration.zero && d != null && d > Duration.zero) {
        _duration = d;
        notifyListeners();
      }
    } catch (_) {
      // 问不到就问不到，onDurationChanged 之后可能还会来
    } finally {
      _probingDuration = false;
    }
  }

  /// 歌词是延迟到的，所以要防一手「切歌了歌词才回来」：
  /// 请求回来时对一下 cid 还是不是当前这首。
  Future<void> _loadLyric(String url, String cid) async {
    try {
      final lines = await SirenApi.lyric(url);
      if (current?.cid != cid) return;
      _lyrics = lines;
      _syncLyricIndex();
      notifyListeners();
    } catch (_) {
      // 歌词失败不影响播放，安静吞掉
    }
  }

  /// 按当前播放位置，算出应该高亮第几行。
  /// 歌词量级最多几百行，线性扫一遍比二分好写，也够快。
  void _syncLyricIndex() {
    if (_lyrics.isEmpty) return;
    var index = -1;
    for (var i = 0; i < _lyrics.length; i++) {
      if (_lyrics[i].time <= _position) {
        index = i;
      } else {
        break;
      }
    }
    _lyricIndex = index;
  }

  /// 状态变了就攒一下再写盘。连续切歌、拖音量时不会每次都写文件。
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(
        PlayerStorage.save(
          PlayerSnapshot(
            queue: _queue,
            index: _index,
            mode: _mode,
            volume: _volume,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _positionPollTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _audio.dispose();
    super.dispose();
  }
}

/// 全局单例。页面里直接 `playerModel.xxx` 用。
final playerModel = PlayerModel();
