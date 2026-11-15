import 'package:audio_service/audio_service.dart';

import 'library.dart';
import 'models.dart';
import 'player_model.dart';

/// 把 [playerModel] 的播放状态桥接成标准媒体通知（MediaSession）。
///
/// 为什么要有它：国内各 ROM 的「灵动岛」类功能（小米焦点通知、荣耀
/// 灵动胶囊、OPPO 流体云）、锁屏控制和耳机线控，读的都是系统的
/// MediaSession + MediaStyle 媒体通知 —— 不需要任何厂商 SDK。
/// audio_service 负责前台服务与通知的机械部分，本类只做两件事：
///
/// 1. 状态：监听 playerModel / library 的 notify，把播放状态翻译成
///    playbackState（播放 / 暂停 / 缓冲 / 进度）和 mediaItem（歌名 /
///    歌手 / 封面 / 时长）推给系统。
/// 2. 命令：通知按钮、锁屏、线控的回调直接委托给 playerModel 的
///    现有方法 —— 播放逻辑零改动。
///
/// 只在 Android 初始化（audio_service 不支持 Windows/Linux 桌面），
/// 见 main.dart 的门控。
class PodencoMediaHandler extends BaseAudioHandler {
  PodencoMediaHandler() {
    playerModel.addListener(_sync);
    // 冷启动恢复队列时专辑列表还没回来，封面是空串；专辑到了要补 artUri
    library.addListener(_sync);
    _sync();
  }

  /// 上次推给系统的曲目签名。notify 因 position 变化每几百毫秒就来
  /// 一次，元信息没变就不该重发 mediaItem（原生侧会重建通知元数据）。
  String _itemSig = '';

  /// 上次发布的队列签名。队列替换 / 回填 albumCid 才会变。
  String _lastQueueSig = '';

  // ── 状态同步：playerModel → 系统媒体会话 ─────────────────

  void _sync() {
    final m = playerModel;
    final track = m.current;

    // ── 当前曲目元信息 ──
    if (track != null) {
      final cover = library.coverOf(track.albumCid);
      final title = m.detail?.name ?? track.name;
      final artist = artistsOf(m.detail?.artists ?? track.artists);
      final duration = m.duration > Duration.zero ? m.duration : null;

      final sig = [track.cid, title, artist, cover, duration].join('|');
      if (sig != _itemSig) {
        _itemSig = sig;
        mediaItem.add(
          MediaItem(
            id: track.cid,
            title: title,
            artist: artist,
            album: library.albumNameOf(track.albumCid),
            // 专辑还没拉回来时 coverOf 是空串，别把坏地址塞给系统
            artUri: cover.isEmpty ? null : Uri.parse(cover),
            duration: duration,
          ),
        );
      }
    } else if (_itemSig.isNotEmpty) {
      // 队列被清空：把元信息一并撤掉，别让系统记住上一首
      _itemSig = '';
      mediaItem.add(null);
    }

    // 队列：锁屏 / 胶囊的上一首、下一首预览靠它
    final queueSig = m.queue.map((t) => t.cid).join(',');
    if (queueSig != _lastQueueSig) {
      _lastQueueSig = queueSig;
      queue.add(m.queue.map(_mediaItemOf).toList());
    }

    // 播放状态。position 的推进本身就要持续上报（通知进度条 / 胶囊
    // 进度靠它），所以这里不去重
    playbackState.add(
      PlaybackState(
        controls: [
          if (m.hasTrack) ...[
            if (m.playing) MediaControl.pause else MediaControl.play,
            MediaControl.skipToPrevious,
            MediaControl.skipToNext,
          ],
        ],
        systemActions: const {MediaAction.seek},
        processingState: m.loading
            ? AudioProcessingState.buffering
            : m.hasTrack
            ? AudioProcessingState.ready
            : AudioProcessingState.idle,
        playing: m.playing,
        updatePosition: m.position,
        bufferedPosition: m.position,
        speed: m.playing ? 1.0 : 0.0,
        queueIndex: m.index,
      ),
    );
  }

  /// 队列项映射成 MediaItem。列表项没有详情，标题 / 歌手 / 封面够用。
  MediaItem _mediaItemOf(Track track) {
    final cover = library.coverOf(track.albumCid);
    return MediaItem(
      id: track.cid,
      title: track.name,
      artist: artistsOf(track.artists),
      album: library.albumNameOf(track.albumCid),
      artUri: cover.isEmpty ? null : Uri.parse(cover),
    );
  }

  /// 歌手名拼接，与下载元数据（downloader.dart）同一惯例：
  /// 空列表兜底成厂牌名，纯音乐曲目太多，别让通知栏空着。
  String artistsOf(List<String> artists) =>
      artists.isEmpty ? '塞壬唱片-MSR' : artists.join(' / ');

  // ── 命令：系统（通知 / 锁屏 / 线控）→ playerModel ─────────

  @override
  Future<void> play() async {
    if (!playerModel.playing) await playerModel.toggle();
  }

  @override
  Future<void> pause() async {
    if (playerModel.playing) await playerModel.toggle();
  }

  @override
  Future<void> skipToNext() => playerModel.next();

  @override
  Future<void> skipToPrevious() => playerModel.previous();

  @override
  Future<void> seek(Duration position) => playerModel.seek(position);

  @override
  Future<void> stop() async {
    await playerModel.stop();
    // 停掉前台服务并撤掉通知；下次点播会随 playbackState 重新拉起
    await super.stop();
  }
}
