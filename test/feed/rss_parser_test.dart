import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/feed/models.dart';
import 'package:podcast_app/feed/rss_parser.dart';

List<int> fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

void main() {
  group('полный фид со всеми расширениями', () {
    late ParsedFeed feed;
    setUpAll(() => feed = parseFeedBytes(fixture('full.xml')));

    test('метаданные канала', () {
      expect(feed.title, 'Тестовый подкаст');
      expect(feed.description, '<p>Подкаст о <b>технологиях</b>.</p>');
      expect(feed.link, 'https://example.com/podcast');
      expect(feed.imageUrl, 'https://example.com/cover.jpg');
      expect(feed.author, 'Иван Петров');
      expect(feed.ownerName, 'Иван Петров');
      expect(feed.ownerEmail, 'ivan@example.com');
      expect(feed.language, 'ru');
      expect(feed.categories, [
        'Technology',
        'Society & Culture',
        'Society & Culture › Documentary',
      ]);
      expect(feed.explicit, isFalse);
      expect(feed.type, PodcastType.serial);
      expect(feed.podcastGuid, '917393e3-1b1e-5cef-ace4-edaa54e1f810');
      expect(feed.locked, isTrue);
      expect(feed.funding.single.url, 'https://example.com/donate');
      expect(feed.funding.single.label, 'Поддержать проект');
    });

    test('эпизод без аудио пропущен и попал в предупреждения', () {
      expect(feed.episodes.map((e) => e.key), ['g:ep-2', 'g:ep-trailer', 'g:ep-media']);
      expect(feed.warnings, contains('Пропущено эпизодов без аудио или видео: 1.'));
    });

    test('эпизод с главами, транскриптами и участниками', () {
      final e = feed.episodes[0];
      expect(e.guid, 'ep-2');
      expect(e.title, 'Эпизод 2. Главы и транскрипты');
      expect(e.link, 'https://example.com/ep2');
      expect(e.pubDate, DateTime.utc(2026, 10, 6, 7));
      expect(e.description, '<p>Полное <i>описание</i> эпизода.</p>');
      expect(e.summary, 'Подзаголовок');
      expect(e.enclosure.url, 'https://cdn.example.com/ep2.mp3');
      expect(e.enclosure.mimeType, 'audio/mpeg');
      expect(e.enclosure.length, 34216300);
      expect(e.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(e.imageUrl, 'https://example.com/ep2.jpg');
      expect(e.season, 1);
      expect(e.episodeNumber, 2);
      expect(e.type, EpisodeType.full);
      expect(e.explicit, isTrue);
      expect(e.chapters?.url, 'https://example.com/ep2/chapters.json');
      expect(e.chapters?.mimeType, 'application/json+chapters');

      expect(e.transcripts, hasLength(2));
      expect(e.transcripts[0].url, 'https://example.com/ep2/transcript.vtt');
      expect(e.transcripts[0].language, 'ru');
      expect(e.transcripts[0].rel, 'captions');
      expect(e.transcripts[1].mimeType, 'text/html');

      expect(e.persons.map((p) => p.name), ['Иван Петров', 'Мария Смирнова']);
      expect(e.persons[0].role, 'host');
      expect(e.persons[0].href, 'https://example.com/ivan');
      expect(e.persons[0].img, 'https://example.com/ivan.jpg');
    });

    test('трейлер: нестандартный MIME, нулевая длина, podcast:season', () {
      final e = feed.episodes[1];
      expect(e.type, EpisodeType.trailer);
      expect(e.enclosure.mimeType, 'audio/mp4');
      expect(e.enclosure.length, isNull);
      expect(e.duration, const Duration(seconds: 95));
      expect(e.season, 1);
      expect(e.pubDate, DateTime.utc(2026, 10, 5, 9));
    });

    test('media:group: выбирается аудио, длительность берётся у него же', () {
      final e = feed.episodes[2];
      expect(e.enclosure.url, 'https://cdn.example.com/ep1.mp3');
      expect(e.enclosure.mimeType, 'audio/mpeg');
      expect(e.enclosure.length, 500);
      expect(e.duration, const Duration(minutes: 30));
      expect(e.imageUrl, 'https://example.com/ep1-thumb.jpg');
      expect(e.pubDate, DateTime.utc(2026, 10, 1, 12, 30));
    });
  });

  group('кривой фид', () {
    late ParsedFeed feed;
    setUpAll(() => feed = parseFeedBytes(
          fixture('messy.xml'),
          feedUrl: 'https://example.org/podcasts/feed.rss',
        ));

    test('необъявленный префикс, сущности, голый &, управляющий символ', () {
      expect(feed.title, 'Кривой   фид');
      expect(feed.author, 'Автор без неймспейса');
      expect(feed.description, 'Описание\u00A0с неразрывным пробелом & голым амперсандом');
    });

    test('относительные ссылки разрешаются от адреса фида', () {
      expect(feed.imageUrl, 'https://example.org/podcasts/cover.jpg');
      expect(feed.episodes[1].enclosure.url, 'https://example.org/media/b.mp3');
      expect(feed.episodes[2].enclosure.url, 'https://cdn.example.org/d.m4a');
    });

    test('дубли guid: другой файл — отдельный эпизод, тот же файл — пропуск', () {
      expect(feed.episodes.map((e) => e.key), [
        'g:dup',
        'u:https://example.org/media/b.mp3',
        'u:https://cdn.example.org/d.m4a',
      ]);
      expect(feed.episodes[1].guid, 'dup');
      expect(feed.warnings, contains('Эпизодов с повторяющимся guid: 2.'));
      expect(feed.warnings, contains('Пропущено эпизодов без аудио или видео: 1.'));
    });

    test('эпизод A: атрибут URL в верхнем регистре, audio/mp3, мусор в length', () {
      final a = feed.episodes[0];
      expect(a.enclosure.url, 'https://cdn.example.org/a.mp3');
      expect(a.enclosure.mimeType, 'audio/mpeg');
      expect(a.enclosure.length, isNull);
      expect(a.pubDate, DateTime.utc(2026, 10, 6, 7));
      expect(a.duration, const Duration(minutes: 62, seconds: 3));
    });

    test('эпизод B: MIME по расширению, русская дата, дробные секунды', () {
      final b = feed.episodes[1];
      expect(b.enclosure.mimeType, 'audio/mpeg');
      expect(b.enclosure.length, 2048);
      expect(b.pubDate, DateTime.utc(2026, 10, 6, 9));
      expect(b.duration, const Duration(seconds: 3723, milliseconds: 500));
    });

    test('эпизод D: заголовок из itunes:title, без guid, без даты', () {
      final d = feed.episodes[2];
      expect(d.title, 'Запасной заголовок');
      expect(d.guid, isNull);
      expect(d.enclosure.mimeType, 'audio/mp4');
      expect(d.pubDate, isNull);
      expect(d.duration, isNull);
    });
  });

  group('кодировки', () {
    test('windows-1251 из XML-декларации, вариант URI itunes с заглавными', () {
      final feed = parseFeedBytes(fixture('cp1251.xml'));
      expect(feed.title, 'Подкаст в кодировке Windows-1251 — «тест» №1');
      expect(feed.author, 'Ёжик Ёлкин');
      expect(feed.episodes.single.title, 'Выпуск первый');
      expect(feed.warnings, isEmpty);
    });

    test('UTF-8 с BOM', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...fixture('full.xml')];
      expect(parseFeedBytes(bytes).title, 'Тестовый подкаст');
    });
  });

  group('пространства имён и ошибки', () {
    test('нестандартный префикс с правильным URI', () {
      const xml = '''
<rss version="2.0" xmlns:it="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>T</title>
    <it:author>Автор</it:author>
    <item><title>E</title><enclosure url="https://x.org/e.mp3" type="audio/mpeg"/>
      <it:duration>10</it:duration></item>
  </channel>
</rss>''';
      final feed = parseFeed(xml);
      expect(feed.author, 'Автор');
      expect(feed.episodes.single.duration, const Duration(seconds: 10));
    });

    test('неизвестный URI с префиксом itunes разбирается по префиксу', () {
      const xml = '''
<rss version="2.0" xmlns:itunes="https://example.com/not-itunes">
  <channel><title>T</title><itunes:author>Не тот</itunes:author></channel>
</rss>''';
      // URI неизвестен, поэтому срабатывает разбор по префиксу — это
      // осознанный компромисс в пользу кривых фидов.
      expect(parseFeed(xml).author, 'Не тот');
    });

    test('Atom-фид', () {
      expect(
        () => parseFeed('<feed xmlns="http://www.w3.org/2005/Atom"><title>T</title></feed>'),
        throwsA(isA<FeedParseException>()),
      );
    });

    test('HTML-страница вместо фида', () {
      expect(
        () => parseFeed('<html><body>Not found</body></html>'),
        throwsA(isA<FeedParseException>()
            .having((e) => e.message, 'message', contains('веб-страница'))),
      );
    });

    test('битый XML', () {
      expect(
        () => parseFeed('<rss><channel><title>T</channel></rss>'),
        throwsA(isA<FeedParseException>()),
      );
    });

    test('нет channel', () {
      expect(() => parseFeed('<rss version="2.0"></rss>'), throwsA(isA<FeedParseException>()));
    });

    test('пустой фид без названия', () {
      final feed = parseFeed('<rss version="2.0"><channel></channel></rss>');
      expect(feed.title, '');
      expect(feed.episodes, isEmpty);
      expect(feed.warnings, contains('У подкаста нет названия.'));
    });
  });
}
