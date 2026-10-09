import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/data/podcast_repository.dart';
import 'package:podcast_app/feed/feed_fetcher.dart';

String feed(String title, List<String> guids, {String? newFeedUrl}) => '''
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
<title>$title</title>
${newFeedUrl == null ? '' : '<itunes:new-feed-url>$newFeedUrl</itunes:new-feed-url>'}
${guids.map((g) => '<item><guid>$g</guid><title>Эпизод $g</title>'
        '<enclosure url="https://cdn.example.com/$g.mp3" type="audio/mpeg"/></item>').join()}
</channel></rss>''';

/// Фейковый интернет: адрес → обработчик. Записывает все запросы.
class FakeWeb {
  final routes = <String, http.Response Function(http.BaseRequest)>{};
  final requests = <http.BaseRequest>[];

  void serve(String url, String body, {Map<String, String> headers = const {}}) {
    routes[url] = (_) => http.Response.bytes(utf8.encode(body), 200, headers: headers);
  }

  MockClient get client => MockClient((request) async {
        requests.add(request);
        final handler = routes[request.url.toString()];
        return handler == null ? http.Response('', 404) : handler(request);
      });
}

void main() {
  late AppDatabase db;
  late FakeWeb web;
  late PodcastRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    web = FakeWeb();
    repo = PodcastRepository(
      db,
      FeedFetcher(client: web.client),
      parser: PodcastRepository.parseInPlace,
    );
  });
  tearDown(() => db.close());

  Future<List<String>> episodeKeys(int podcastId) async =>
      [for (final e in await db.watchEpisodes(podcastId).first) e.episodeKey]..sort();

  group('добавление', () {
    test('по прямой ссылке: подкаст, эпизоды, подписка', () async {
      web.serve('https://example.com/feed', feed('Тест', ['1', '2']),
          headers: {'etag': '"v1"'});

      final id = await repo.addAndSubscribe('https://example.com/feed');

      final podcast = (await db.podcastById(id))!;
      expect(podcast.title, 'Тест');
      expect(podcast.feedUrl, 'https://example.com/feed');
      expect(podcast.etag, '"v1"');
      expect(await episodeKeys(id), ['g:1', 'g:2']);
      expect(await db.watchIsSubscribed(id).first, isTrue);
    });

    test('повторное добавление того же фида не создаёт дубль', () async {
      web.serve('https://example.com/feed', feed('Тест', ['1']));
      final first = await repo.addAndSubscribe('https://example.com/feed');
      await repo.setSubscribed(first, false);

      final second = await repo.addAndSubscribe('example.com/feed');

      expect(second, first);
      expect(await db.select(db.podcasts).get(), hasLength(1));
      expect(await db.watchIsSubscribed(first).first, isTrue);
    });

    test('просмотр без подписки, потом подписка без повторной загрузки', () async {
      web.serve('https://example.com/feed', feed('Тест', ['1']));

      final id = await repo.add('https://example.com/feed', subscribe: false);
      expect(await db.watchIsSubscribed(id).first, isFalse);
      expect(await db.watchSubscribedPodcasts().first, isEmpty);

      final requestsBefore = web.requests.length;
      expect(await repo.add('https://example.com/feed', subscribe: true), id);
      expect(await db.watchIsSubscribed(id).first, isTrue);
      expect(web.requests.length, requestsBefore, reason: 'известный фид не загружается заново');
    });

    test('по ссылке Apple Podcasts', () async {
      web.routes['https://itunes.apple.com/lookup?id=42&entity=podcast'] = (_) => http.Response(
            jsonEncode({
              'results': [
                {'feedUrl': 'https://example.com/apple-feed'},
              ],
            }),
            200,
          );
      web.serve('https://example.com/apple-feed', feed('Из Apple', ['1']));

      final id = await repo.addAndSubscribe('https://podcasts.apple.com/ru/podcast/x/id42');

      expect((await db.podcastById(id))!.feedUrl, 'https://example.com/apple-feed');
    });

    test('постоянный редирект: сохраняется новый адрес', () async {
      web.routes['https://old.example.com/feed'] =
          (_) => http.Response('', 301, headers: {'location': 'https://new.example.com/feed'});
      web.serve('https://new.example.com/feed', feed('Переехал', ['1']));

      final id = await repo.addAndSubscribe('https://old.example.com/feed');

      expect((await db.podcastById(id))!.feedUrl, 'https://new.example.com/feed');
    });

    test('временный редирект: остаётся исходный адрес', () async {
      web.routes['https://example.com/feed'] =
          (_) => http.Response('', 302, headers: {'location': 'https://cdn.example.com/feed'});
      web.serve('https://cdn.example.com/feed', feed('Через CDN', ['1']));

      final id = await repo.addAndSubscribe('https://example.com/feed');

      expect((await db.podcastById(id))!.feedUrl, 'https://example.com/feed');
    });

    test('itunes:new-feed-url: загружается и сохраняется новый адрес', () async {
      web.serve('https://example.com/old',
          feed('Старый', ['1'], newFeedUrl: 'https://example.com/new'));
      web.serve('https://example.com/new', feed('Новый', ['1', '2']));

      final id = await repo.addAndSubscribe('https://example.com/old');

      final podcast = (await db.podcastById(id))!;
      expect(podcast.feedUrl, 'https://example.com/new');
      expect(podcast.title, 'Новый');
      expect(await episodeKeys(id), ['g:1', 'g:2']);
    });

    test('ошибки понятны пользователю', () async {
      web.serve('https://example.com/page', '<html><body>Сайт</body></html>');

      await expectLater(
        repo.addAndSubscribe('просто текст'),
        throwsA(isA<PodcastException>().having((e) => e.message, 'message', contains('ссылку'))),
      );
      await expectLater(
        repo.addAndSubscribe('https://example.com/missing'),
        throwsA(isA<PodcastException>().having((e) => e.message, 'message', contains('404'))),
      );
      await expectLater(
        repo.addAndSubscribe('https://example.com/page'),
        throwsA(isA<PodcastException>()
            .having((e) => e.message, 'message', contains('веб-страница'))),
      );
      expect(await db.select(db.podcasts).get(), isEmpty);
    });
  });

  group('обновление', () {
    test('ETag отправляется, 304 не меняет эпизоды', () async {
      web.serve('https://example.com/feed', feed('Тест', ['1']), headers: {'etag': '"v1"'});
      final id = await repo.addAndSubscribe('https://example.com/feed');

      web.routes['https://example.com/feed'] = (_) => http.Response('', 304);
      expect(await repo.refresh(id), 0);

      expect(web.requests.last.headers['if-none-match'], '"v1"');
      expect(await episodeKeys(id), ['g:1']);
      expect((await db.podcastById(id))!.lastError, isNull);
    });

    test('новые эпизоды считаются', () async {
      web.serve('https://example.com/feed', feed('Тест', ['1']));
      final id = await repo.addAndSubscribe('https://example.com/feed');

      web.serve('https://example.com/feed', feed('Тест', ['3', '2', '1']));
      expect(await repo.refresh(id), 2);
      expect(await episodeKeys(id), ['g:1', 'g:2', 'g:3']);
    });

    test('ошибка сохраняется в подкасте и сбрасывается успешным обновлением', () async {
      web.serve('https://example.com/feed', feed('Тест', ['1']));
      final id = await repo.addAndSubscribe('https://example.com/feed');

      web.routes['https://example.com/feed'] = (_) => http.Response('', 500);
      await expectLater(repo.refresh(id), throwsA(isA<PodcastException>()));
      expect((await db.podcastById(id))!.lastError, contains('500'));

      web.serve('https://example.com/feed', feed('Тест', ['1']));
      await repo.refresh(id);
      expect((await db.podcastById(id))!.lastError, isNull);
    });

    test('постоянный редирект при обновлении переводит подписку', () async {
      web.serve('https://example.com/feed', feed('Тест', ['1']));
      final id = await repo.addAndSubscribe('https://example.com/feed');

      web.routes['https://example.com/feed'] =
          (_) => http.Response('', 308, headers: {'location': 'https://new.example.com/rss'});
      web.serve('https://new.example.com/rss', feed('Тест', ['1', '2']));

      expect(await repo.refresh(id), 1);
      expect((await db.podcastById(id))!.feedUrl, 'https://new.example.com/rss');
      expect(await db.select(db.podcasts).get(), hasLength(1));
    });

    test('неизменившийся фид не разбирается и не переписывается', () async {
      web.serve('https://example.com/feed', feed('Тест', ['1']));
      final id = await repo.addAndSubscribe('https://example.com/feed');
      expect((await db.podcastById(id))!.contentHash, isNotNull);

      // Пометка в базе, которую перезаписал бы повторный разбор.
      await (db.update(db.episodes)..where((e) => e.podcastId.equals(id)))
          .write(const EpisodesCompanion(title: Value('метка')));
      expect(await repo.refresh(id), 0);
      expect((await db.watchEpisodes(id).first).single.title, 'метка', reason: 'тот же фид — без записи');

      web.serve('https://example.com/feed', feed('Тест', ['1', '2']));
      expect(await repo.refresh(id), 1);
      expect([for (final e in await db.watchEpisodes(id).first) e.title]..sort(), ['Эпизод 1', 'Эпизод 2']);
    });

    test('при запуске недавно проверенные подкасты не запрашиваются', () async {
      web.serve('https://a.example.com/feed', feed('A', ['1']));
      final a = await repo.addAndSubscribe('https://a.example.com/feed');
      web.requests.clear();

      await repo.refreshAll(olderThan: const Duration(minutes: 15));
      expect(web.requests, isEmpty);

      await (db.update(db.podcasts)..where((p) => p.id.equals(a)))
          .write(PodcastsCompanion(lastCheckedAt: Value(DateTime.now().subtract(const Duration(hours: 1)))));
      final before = DateTime.now();
      await repo.refreshAll(olderThan: const Duration(minutes: 15));
      expect(web.requests, hasLength(1));
      expect((await db.podcastById(a))!.lastCheckedAt!.isBefore(before), isFalse, reason: 'отмечен проверенным');
    });

    test('обновление всех подписок: итог и ошибки', () async {
      web.serve('https://a.example.com/feed', feed('A', ['1']));
      web.serve('https://b.example.com/feed', feed('B', ['1']));
      web.serve('https://c.example.com/feed', feed('C', ['1']));
      final a = await repo.addAndSubscribe('https://a.example.com/feed');
      final b = await repo.addAndSubscribe('https://b.example.com/feed');
      final c = await repo.addAndSubscribe('https://c.example.com/feed');
      await repo.setSubscribed(c, false);

      web.serve('https://a.example.com/feed', feed('A', ['1', '2']));
      web.routes['https://b.example.com/feed'] = (_) => http.Response('', 404);
      web.serve('https://c.example.com/feed', feed('C', ['1', '2', '3']));

      final summary = await repo.refreshAll();

      expect(summary.newEpisodes, 1, reason: 'C не обновляется: от него отписались');
      expect(summary.failed.keys, [b]);
      expect(await episodeKeys(a), ['g:1', 'g:2']);
    });
  });
}
