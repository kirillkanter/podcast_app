import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/catalog/podcast_catalog.dart';

/// Ответ iTunes Search / Lookup с двумя подкастами: обычным и без RSS.
String itunesJson(List<Map<String, Object?>> results) =>
    jsonEncode({'resultCount': results.length, 'results': results});

const science = {
  'collectionId': 101,
  'collectionName': 'Наука за 5 минут',
  'artistName': 'Автор',
  'feedUrl': 'https://example.com/science.xml',
  'artworkUrl100': 'https://img.example.com/100.jpg',
  'artworkUrl600': 'https://img.example.com/600.jpg',
  'primaryGenreName': 'Наука',
  'trackCount': 42,
};

const exclusive = {
  'collectionId': 202,
  'collectionName': 'Эксклюзив',
  'artistName': 'Студия',
  'artworkUrl100': 'https://img.example.com/e100.jpg',
};

void main() {
  test('поиск: запрос, страна, разбор результатов', () async {
    late Uri seen;
    final catalog = PodcastCatalog(
      country: 'RU',
      client: MockClient((request) async {
        seen = request.url;
        return http.Response.bytes(utf8.encode(itunesJson([science, exclusive])), 200);
      }),
    );

    final results = await catalog.search('  наука ');

    expect(seen.host, 'itunes.apple.com');
    expect(seen.path, '/search');
    expect(seen.queryParameters['term'], 'наука');
    expect(seen.queryParameters['country'], 'ru');
    expect(seen.queryParameters['media'], 'podcast');

    expect(results, hasLength(2));
    final s = results.first;
    expect(s.id, '101');
    expect(s.title, 'Наука за 5 минут');
    expect(s.author, 'Автор');
    expect(s.feedUrl, 'https://example.com/science.xml');
    expect(s.artworkUrl, 'https://img.example.com/600.jpg');
    expect(s.genre, 'Наука');
    expect(s.episodeCount, 42);

    final e = results.last;
    expect(e.feedUrl, isNull, reason: 'подкаст только в Apple Podcasts');
    expect(e.artworkUrl, 'https://img.example.com/e100.jpg');
  });

  test('пустой запрос не ходит в сеть', () async {
    var calls = 0;
    final catalog = PodcastCatalog(client: MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    expect(await catalog.search('   '), isEmpty);
    expect(calls, 0);
  });

  test('популярное: чарт страны + адреса фидов, порядок как в чарте', () async {
    final requests = <Uri>[];
    final catalog = PodcastCatalog(
      country: 'ru',
      client: MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == 'rss.marketingtools.apple.com') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'feed': {
                'results': [
                  {'id': '202', 'name': 'Эксклюзив'},
                  {'id': '101', 'name': 'Наука за 5 минут'},
                  {'id': '999', 'name': 'Нет в lookup'},
                ],
              },
            })),
            200,
          );
        }
        // Lookup возвращает в своём порядке.
        return http.Response.bytes(utf8.encode(itunesJson([science, exclusive])), 200);
      }),
    );

    final top = await catalog.top(limit: 3);

    expect(requests.first.path, '/api/v2/ru/podcasts/top/3/podcasts.json');
    expect(requests.last.path, '/lookup');
    expect(requests.last.queryParameters['id'], '202,101,999');
    expect(top.map((p) => p.id), ['202', '101']);
  });

  test('ошибки понятны пользователю', () async {
    final catalog = PodcastCatalog(client: MockClient((_) async => http.Response('', 503)));
    await expectLater(
      catalog.search('x'),
      throwsA(isA<CatalogException>().having((e) => e.message, 'message', contains('503'))),
    );

    final broken = PodcastCatalog(client: MockClient((_) async => http.Response('not json', 200)));
    await expectLater(broken.search('x'), throwsA(isA<CatalogException>()));
  });

  test('чарт рубрики: старая лента iTunes, крупные обложки, адреса фидов дозапросом', () async {
    final seen = <Uri>[];
    final chart = {
      'feed': {
        'entry': [
          {
            'im:name': {'label': 'Наука за 5 минут'},
            'im:artist': {'label': 'Автор'},
            'im:image': [
              {'label': 'https://is1.mzstatic.com/image/thumb/a/55x55bb.png'},
              {'label': 'https://is1.mzstatic.com/image/thumb/a/170x170bb.png'},
            ],
            'id': {
              'label': 'https://podcasts.apple.com/ru/podcast/id101',
              'attributes': {'im:id': '101'},
            },
            'category': {
              'attributes': {'im:id': '1533', 'label': 'Наука'},
            },
          },
          {
            'im:name': {'label': 'Эксклюзив'},
            'id': {
              'attributes': {'im:id': '202'},
            },
          },
        ],
      },
    };
    final catalog = PodcastCatalog(
      country: 'ru',
      client: MockClient((request) async {
        seen.add(request.url);
        final body = request.url.path == '/lookup' ? itunesJson([science, exclusive]) : jsonEncode(chart);
        return http.Response.bytes(utf8.encode(body), 200);
      }),
    );

    final items = await catalog.chart(genreId: 1533, limit: 25);
    expect(seen.single.path, '/ru/rss/toppodcasts/limit=25/genre=1533/json');
    expect(items.map((p) => p.title), ['Наука за 5 минут', 'Эксклюзив']);
    expect(items.first.artworkUrl, 'https://is1.mzstatic.com/image/thumb/a/600x600bb.jpg');
    expect(items.first.genre, 'Наука');
    expect(items.first.feedUrl, isNull);

    await catalog.chart(genreId: 1533, limit: 25);
    expect(seen, hasLength(1), reason: 'чарт запоминается');

    final full = await catalog.withFeeds(items);
    expect(seen.last.path, '/lookup');
    expect(seen.last.queryParameters['id'], '101,202');
    expect(full.first.feedUrl, 'https://example.com/science.xml');
    expect(full.last.feedUrl, isNull);
  });

  test('чарт из одной записи: entry — объект, а не список', () {
    final items = PodcastCatalog.parseChart({
      'feed': {
        'entry': {
          'im:name': {'label': 'Один'},
          'id': {
            'attributes': {'im:id': '7'},
          },
        },
      },
    });
    expect(items.single.id, '7');
    expect(PodcastCatalog.parseChart({'feed': {}}), isEmpty);
  });

  test('популярное: 502 повторяется, потом берётся запасной чарт iTunes', () async {
    var marketing = 0;
    final catalog = PodcastCatalog(
      country: 'ru',
      client: MockClient((request) async {
        if (request.url.host == 'rss.marketingtools.apple.com') {
          marketing++;
          return http.Response('Bad Gateway', 502);
        }
        if (request.url.path == '/lookup') {
          return http.Response.bytes(utf8.encode(itunesJson([science])), 200);
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'feed': {
              'entry': [
                {
                  'im:name': {'label': 'Наука за 5 минут'},
                  'id': {
                    'attributes': {'im:id': '101'},
                  },
                },
              ],
            },
          })),
          200,
        );
      }),
    )..retryDelay = Duration.zero;

    final top = await catalog.top();
    expect(marketing, 3, reason: 'первая попытка и два повтора');
    expect(top.single.title, 'Наука за 5 минут');
    expect(top.single.feedUrl, 'https://example.com/science.xml');
  });
}
