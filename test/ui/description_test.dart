import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/ui/description.dart';

void main() {
  test('таймкоды и ссылки в описании', () {
    final parts = parseDescription(
      '<p>Гость — <a href="https://example.com/guest?a=1&amp;b=2">Иван</a>.</p>'
      '<p>00:00 Вступление<br>12:40 — Главное<br>1:02:03 Вопросы</p>'
      '<p>Сайт: https://bcaster.ru. Не время: 12:75 и 2026:10</p>',
    );
    final links = parts.whereType<DescLink>().toList();
    expect(links.map((l) => l.url), ['https://example.com/guest?a=1&b=2', 'https://bcaster.ru']);
    expect(links.first.text, 'Иван');
    final times = parts.whereType<DescTime>().map((t) => t.at).toList();
    expect(times, [
      Duration.zero,
      const Duration(minutes: 12, seconds: 40),
      const Duration(hours: 1, minutes: 2, seconds: 3),
    ]);
    expect(plainText(parts), contains('Не время: 12:75 и 2026:10'));
    expect(parseDescription('Ссылка: https:// и всё').whereType<DescLink>(), isEmpty);
  });

  test('ссылка-таймкод становится таймкодом', () {
    final parts = parseDescription('<a href="#t=754">12:34</a> тема');
    expect(parts.first, isA<DescTime>());
    expect((parts.first as DescTime).at, const Duration(minutes: 12, seconds: 34));
  });

  test('главы из строк описания', () {
    final chapters = chaptersFromText('Темы выпуска:\n'
        '00:00 — Вступление\n'
        '(03:15) Как снимают Землю\n'
        'Кто покупает снимки — 24:40\n'
        '1:01:05 Вопросы слушателей\n'
        'Подписывайтесь!');
    expect(chapters, const [
      Chapter(Duration.zero, 'Вступление'),
      Chapter(Duration(minutes: 3, seconds: 15), 'Как снимают Землю'),
      Chapter(Duration(minutes: 24, seconds: 40), 'Кто покупает снимки'),
      Chapter(Duration(hours: 1, minutes: 1, seconds: 5), 'Вопросы слушателей'),
    ]);
    expect(chaptersFromText('Запись от 12:00'), isEmpty, reason: 'одна строка — не главы');
    expect(chaptersFromText('10:00 Б\n05:00 А'), isEmpty, reason: 'время не по порядку');
  });

  test('главы Podcasting 2.0 и текущая глава', () {
    final chapters = parseChaptersJson('{"version":"1.2.0","chapters":['
        '{"startTime":195.5,"title":"Вторая"},{"startTime":0,"title":"Первая"},'
        '{"startTime":300,"title":"Скрытая","toc":false},{"startTime":400}]}');
    expect(chapters.map((c) => c.title), ['Первая', 'Вторая']);
    expect(chapters[1].start, const Duration(milliseconds: 195500));
    expect(currentChapter(chapters, const Duration(minutes: 1)), 0);
    expect(currentChapter(chapters, const Duration(minutes: 4)), 1);
    expect(parseChaptersJson('не json'), isEmpty);
  });
}
