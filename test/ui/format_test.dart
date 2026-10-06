import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/ui/format.dart';

void main() {
  group('formatEpisodeDate', () {
    final now = DateTime(2026, 10, 6, 15);

    test('сегодня, вчера, этот и прошлый год', () {
      expect(formatEpisodeDate(DateTime(2026, 10, 6, 1), now: now), 'Сегодня');
      expect(formatEpisodeDate(DateTime(2026, 10, 5, 23), now: now), 'Вчера');
      expect(formatEpisodeDate(DateTime(2026, 5, 1), now: now), '1 мая');
      expect(formatEpisodeDate(DateTime(2024, 3, 12), now: now), '12 марта 2024');
      expect(formatEpisodeDate(null, now: now), '');
    });
  });

  test('formatDuration', () {
    expect(formatDuration(3723000), '1 ч 02 мин');
    expect(formatDuration(45 * 60 * 1000), '45 мин');
    expect(formatDuration(40 * 1000), '40 сек');
    expect(formatDuration(null), '');
    expect(formatDuration(0), '');
  });

  test('plural', () {
    String ep(int n) => plural(n, 'эпизод', 'эпизода', 'эпизодов');
    expect(ep(1), 'эпизод');
    expect(ep(2), 'эпизода');
    expect(ep(5), 'эпизодов');
    expect(ep(11), 'эпизодов');
    expect(ep(12), 'эпизодов');
    expect(ep(21), 'эпизод');
    expect(ep(22), 'эпизода');
    expect(ep(111), 'эпизодов');
  });

  test('htmlToText', () {
    expect(
      htmlToText('<p>Первый&nbsp;абзац &amp; ещё</p><p>Второй<br/>строка</p>'
          '<ul><li>один</li><li>два</li></ul><script>alert(1)</script>&#8212;&#x2014;'),
      'Первый абзац & ещё\n\nВторой\nстрока\n\n• один\n\n• два\n\n——',
    );
    expect(htmlToText(null), '');
    expect(htmlToText('Просто текст'), 'Просто текст');
  });
}
