import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/data/opml.dart';
import 'package:podcast_app/data/podcast_repository.dart';
import 'package:podcast_app/feed/feed_fetcher.dart';

String _feed(String title) => '''
<rss version="2.0"><channel><title>$title</title>
<item><guid>1</guid><title>Эпизод</title><enclosure url="https://cdn.example.com/1.mp3" type="audio/mpeg"/></item>
</channel></rss>''';

void main() {
  group('разбор OPML', () {
    test('вложенные группы, повторы, feed:// и разные регистры атрибутов', () {
      const text = '''﻿<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0"><head><title>Экспорт</title></head><body>
  <outline text="Подкасты">
    <outline type="rss" text="Первый &amp; лучший" xmlUrl="https://a.example.com/feed"/>
    <outline type="rss" title="Второй" text="Второй (text)" xmlurl="http://b.example.com/rss"/>
  </outline>
  <outline text="Повтор" xmlUrl="https://a.example.com/feed"/>
  <outline text="Без названия" xmlUrl="feed://c.example.com/podcast"/>
  <outline text="Не фид" htmlUrl="https://site.example.com"/>
  <outline text="Мусор" xmlUrl="javascript:alert(1)"/>
</body></opml>''';
      final entries = parseOpml(text);
      expect(entries.map((e) => e.url), [
        'https://a.example.com/feed',
        'http://b.example.com/rss',
        'https://c.example.com/podcast',
      ]);
      expect(entries[0].title, 'Первый & лучший');
      expect(entries[1].title, 'Второй');
    });

    test('не OPML — понятная ошибка', () {
      expect(() => parseOpml('<rss><channel/></rss>'), throwsFormatException);
      expect(() => parseOpml('это не xml'), throwsFormatException);
    });
  });

  group('импорт и экспорт', () {
    late AppDatabase db;
    late PodcastRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url == 'https://a.example.com/feed') return http.Response.bytes(utf8.encode(_feed('Подкаст А')), 200);
        if (url == 'https://b.example.com/feed') return http.Response.bytes(utf8.encode(_feed('Подкаст Б')), 200);
        return http.Response('', 404);
      });
      repo = PodcastRepository(db, FeedFetcher(client: client), parser: PodcastRepository.parseInPlace);
    });

    tearDown(() => db.close());

    test('подписка на фиды из файла, ошибки не останавливают импорт', () async {
      await repo.addAndSubscribe('https://a.example.com/feed');
      final progress = <int>[];
      final result = await importOpml(db, repo, [
        (title: 'А', url: 'https://a.example.com/feed'),
        (title: 'Б', url: 'https://b.example.com/feed'),
        (title: 'Пропавший', url: 'https://gone.example.com/feed'),
      ], onProgress: progress.add);

      expect(result.added, 1);
      expect(result.already, 1);
      expect(result.failed.single.$1.title, 'Пропавший');
      expect(progress.last, 3);
      final titles = (await db.subscribedPodcasts()).map((p) => p.title).toSet();
      expect(titles, {'Подкаст А', 'Подкаст Б'});
    });

    test('экспорт читается обратно', () async {
      await repo.addAndSubscribe('https://a.example.com/feed');
      await repo.addAndSubscribe('https://b.example.com/feed');
      final text = buildOpml(await db.subscribedPodcasts(), now: DateTime.utc(2026, 10, 7, 12));
      expect(text, contains('Wed, 07 Oct 2026 12:00:00 GMT'));
      final back = parseOpml(text);
      expect(back.map((e) => e.url).toSet(), {'https://a.example.com/feed', 'https://b.example.com/feed'});
      expect(back.map((e) => e.title).toSet(), {'Подкаст А', 'Подкаст Б'});
    });
  });
}
