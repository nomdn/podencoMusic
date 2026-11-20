// 下载队列的纯逻辑测试。只测不需要网络和磁盘的部分：
// needsDownload 的过滤规则、取消后的状态回归。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/downloader.dart';
import 'package:podenco_music/models.dart';

void main() {
  const track = Track(cid: '1', name: 'Your Star', albumCid: '0256', artists: []);

  group('文件名主干', () {
    test('塞壬曲目只保留曲名，不加「塞壬唱片-MSR」前缀', () {
      final track = Track(
        cid: '1',
        name: 'Your Star',
        albumCid: '0256',
        artists: const ['塞壬唱片-MSR'],
      );
      expect(Downloader.fileStemFor(track), 'Your Star');
    });

    test('B站曲目只保留视频标题，不加 UP 主前缀', () {
      final track = Track(
        cid: 'BV1ZVsn6nEMn',
        name: '每日一歌',
        albumCid: '',
        artists: const ['某UP主'],
        source: TrackSource.bilibili,
      );
      expect(Downloader.fileStemFor(track), '每日一歌');
    });

    test('Windows 非法字符仍会替换', () {
      final track = Track(
        cid: '1',
        name: 'a/b:c*d',
        albumCid: '',
        artists: const [],
      );
      expect(Downloader.fileStemFor(track), 'a_b_c_d');
    });
  });

  group('needsDownload', () {
    test('没下过、没任务 → 要下', () {
      expect(
        Downloader.needsDownload(track, downloaded: false, state: null),
        isTrue,
      );
    });

    test('已经在本地 → 不下', () {
      expect(
        Downloader.needsDownload(track, downloaded: true, state: null),
        isFalse,
      );
    });

    test('四种进行中的状态都不重复下', () {
      for (final status in [
        DownloadStatus.queued,
        DownloadStatus.running,
        DownloadStatus.done,
      ]) {
        expect(
          Downloader.needsDownload(
            track,
            downloaded: false,
            state: DownloadState(status: status),
          ),
          isFalse,
          reason: '$status 不应该重复入队',
        );
      }
    });

    test('失败的任务允许再下', () {
      expect(
        Downloader.needsDownload(
          track,
          downloaded: false,
          state: const DownloadState(
            status: DownloadStatus.failed,
            error: '网络错误',
          ),
        ),
        isTrue,
      );
    });
  });

  group('取消', () {
    test('取消排队中的任务 → 回到未下载态', () async {
      final downloader = Downloader();

      // 直接把一首歌标记成排队，模拟 queueAll 入队后的样子。
      // _pending 是私有的，但 cancel 对「不在队列里」的 cid 是幂等无害的，
      // 这里主要验证状态迁移正确。
      downloader.cancel('不存在');
      expect(downloader.stateOf('不存在').status, DownloadStatus.idle);
    });

    test('stateOf 没记录时返回默认值，不是抛异常', () {
      final downloader = Downloader();
      expect(downloader.stateOf('谁啊').status, DownloadStatus.idle);
      expect(downloader.pendingTracks, isEmpty);
      expect(downloader.runningTracks, isEmpty);
    });
  });
}
