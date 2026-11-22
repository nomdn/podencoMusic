import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/video/video_playback_base.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  VideoSnapshot playingAt(int ms, {double speed = 1.0}) => VideoSnapshot(
        initialized: true,
        playing: true,
        position: Duration(milliseconds: ms),
        speed: speed,
        capturedAt: t0,
      );

  group('倍速档位与快照', () {
    test('快照默认 1x，copyWith 只改倍速时其它字段不变', () {
      const base = VideoSnapshot(
        initialized: true,
        position: Duration(seconds: 3),
      );
      expect(base.speed, 1.0);

      final changed = base.copyWith(speed: 1.5);
      expect(changed.speed, 1.5);
      expect(changed.initialized, isTrue);
      expect(changed.position, const Duration(seconds: 3));
      expect(base.speed, 1.0);
    });

    test('非法倍速回退 1x，超出范围夹到 0.25~4', () {
      expect(normalizeVideoSpeed(0), 1.0);
      expect(normalizeVideoSpeed(-2), 1.0);
      expect(normalizeVideoSpeed(double.nan), 1.0);
      expect(normalizeVideoSpeed(double.infinity), 1.0);
      expect(normalizeVideoSpeed(0.1), 0.25);
      expect(normalizeVideoSpeed(9), 4.0);
      expect(normalizeVideoSpeed(1.25), 1.25);
    });

    test('控制条档位含 1x 且从慢到快有序', () {
      expect(videoSpeeds, contains(1.0));
      final sorted = List<double>.from(videoSpeeds)..sort();
      expect(videoSpeeds, sorted);
    });
  });

  group('弹幕时间轴插值', () {
    test('插值按倍速推进，1x / 2x / 0.5x 都跟得上画面', () {
      final now = t0.add(const Duration(milliseconds: 300));
      expect(interpolatedPositionMs(playingAt(2000), now), 2300);
      expect(interpolatedPositionMs(playingAt(2000, speed: 2), now), 2600);
      expect(interpolatedPositionMs(playingAt(2000, speed: 0.5), now), 2150);
      expect(interpolatedPositionMs(playingAt(2000, speed: 1.5), now), 2450);
    });

    test('暂停、缓冲、没有时间戳时不插值', () {
      final now = t0.add(const Duration(milliseconds: 300));
      final paused = playingAt(2000).copyWith(playing: false);
      final buffering = playingAt(2000).copyWith(buffering: true);
      const noStamp = VideoSnapshot(
        initialized: true,
        playing: true,
        position: Duration(milliseconds: 2000),
      );

      expect(interpolatedPositionMs(paused, now), 2000);
      expect(interpolatedPositionMs(buffering, now), 2000);
      expect(interpolatedPositionMs(noStamp, now), 2000);
    });

    test('上报时间倒退或太久远时不插值，避免卡顿后弹幕乱飘', () {
      expect(
        interpolatedPositionMs(playingAt(2000), t0.subtract(const Duration(milliseconds: 10))),
        2000,
      );
      expect(
        interpolatedPositionMs(playingAt(2000, speed: 2), t0.add(const Duration(milliseconds: 600))),
        2000,
      );
    });

    test('非法倍速按 1x 兜底', () {
      final now = t0.add(const Duration(milliseconds: 300));
      final broken = playingAt(2000, speed: double.nan);
      expect(interpolatedPositionMs(broken, now), 2300);
    });
  });
}
