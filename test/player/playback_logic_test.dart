import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/player/playback_logic.dart';

void main() {
  group('resumePosition', () {
    test('продолжает с сохранённой позиции', () {
      expect(
        resumePosition(positionMs: 120000, played: false, durationMs: 3600000),
        const Duration(minutes: 2),
      );
    });

    test('прослушанный эпизод — сначала', () {
      expect(resumePosition(positionMs: 120000, played: true, durationMs: 3600000), Duration.zero);
    });

    test('почти дослушанный эпизод — сначала', () {
      expect(resumePosition(positionMs: 3590000, played: false, durationMs: 3600000), Duration.zero);
    });

    test('без длительности — с позиции', () {
      expect(resumePosition(positionMs: 5000, played: false), const Duration(seconds: 5));
    });

    test('нулевая позиция', () {
      expect(resumePosition(positionMs: 0, played: false, durationMs: 1000), Duration.zero);
    });
  });

  test('seekRelative не выходит за границы', () {
    const duration = Duration(minutes: 10);
    expect(seekRelative(const Duration(seconds: 5), -rewindStep, duration), Duration.zero);
    expect(seekRelative(const Duration(minutes: 9, seconds: 50), fastForwardStep, duration), duration);
    expect(seekRelative(const Duration(minutes: 1), fastForwardStep, duration),
        const Duration(minutes: 1, seconds: 30));
    expect(seekRelative(const Duration(minutes: 1), fastForwardStep, null),
        const Duration(minutes: 1, seconds: 30));
  });

  test('formatClock', () {
    expect(formatClock(Duration.zero), '0:00');
    expect(formatClock(const Duration(minutes: 12, seconds: 5)), '12:05');
    expect(formatClock(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(formatClock(const Duration(seconds: -3)), '0:00');
  });

  test('formatSpeed', () {
    expect(formatSpeed(1.0), '1×');
    expect(formatSpeed(1.1), '1,1×');
    expect(formatSpeed(1.5), '1,5×');
    expect(formatSpeed(1.75), '1,75×');
    expect(formatSpeed(2.0), '2×');
    expect(formatSpeed(0.8), '0,8×');
    expect([for (final s in playbackSpeeds) formatSpeed(s)], everyElement(isNot(contains('.'))));
  });

  test('таймер сна: оставшееся время', () {
    final now = DateTime(2026, 10, 6, 12);
    final timer = SleepTimer.at(now.add(const Duration(minutes: 30)));
    expect(timer.remaining(now), const Duration(minutes: 30));
    expect(timer.remaining(now.add(const Duration(hours: 1))), Duration.zero);
  });
}
