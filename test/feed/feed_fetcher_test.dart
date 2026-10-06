import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/feed/feed_fetcher.dart';

void main() {
  test('200: тело, ETag, Last-Modified, charset', () async {
    late http.BaseRequest seen;
    final fetcher = FeedFetcher(client: MockClient((request) async {
      seen = request;
      return http.Response.bytes(utf8.encode('<rss/>'), 200, headers: {
        'etag': '"v1"',
        'last-modified': 'Tue, 06 Oct 2026 10:00:00 GMT',
        'content-type': 'application/rss+xml; charset=windows-1251',
      });
    }));

    final r = await fetcher.fetch('https://example.com/feed') as FeedFetched;
    expect(utf8.decode(r.bytes), '<rss/>');
    expect(r.finalUrl, 'https://example.com/feed');
    expect(r.movedPermanently, isFalse);
    expect(r.etag, '"v1"');
    expect(r.lastModified, 'Tue, 06 Oct 2026 10:00:00 GMT');
    expect(r.charset, 'windows-1251');
    expect(seen.headers['user-agent'], startsWith('podcast_app/'));
    expect(seen.headers.containsKey('if-none-match'), isFalse);
  });

  test('304 и условные заголовки', () async {
    late http.BaseRequest seen;
    final fetcher = FeedFetcher(client: MockClient((request) async {
      seen = request;
      return http.Response('', 304);
    }));

    final r = await fetcher.fetch('https://example.com/feed', etag: '"v1"', lastModified: 'X');
    expect(r, isA<FeedNotModified>());
    expect(seen.headers['if-none-match'], '"v1"');
    expect(seen.headers['if-modified-since'], 'X');
  });

  test('301 → 200: постоянный переезд, относительный Location', () async {
    final fetcher = FeedFetcher(client: MockClient((request) async {
      if (request.url.path == '/old') {
        return http.Response('', 301, headers: {'location': '/new'});
      }
      return http.Response('<rss/>', 200);
    }));

    final r = await fetcher.fetch('https://example.com/old') as FeedFetched;
    expect(r.finalUrl, 'https://example.com/new');
    expect(r.movedPermanently, isTrue);
  });

  test('302 в цепочке делает переезд временным', () async {
    final fetcher = FeedFetcher(client: MockClient((request) async {
      switch (request.url.path) {
        case '/a':
          return http.Response('', 302, headers: {'location': 'https://cdn.example.com/b'});
        case '/b':
          return http.Response('', 301, headers: {'location': '/c'});
        default:
          return http.Response('<rss/>', 200);
      }
    }));

    final r = await fetcher.fetch('https://example.com/a') as FeedFetched;
    expect(r.finalUrl, 'https://cdn.example.com/c');
    expect(r.movedPermanently, isFalse);
  });

  test('бесконечные редиректы', () async {
    final fetcher = FeedFetcher(client: MockClient((request) async {
      return http.Response('', 301, headers: {'location': '/loop'});
    }));
    await expectLater(
      fetcher.fetch('https://example.com/loop'),
      throwsA(isA<FeedFetchException>()
          .having((e) => e.message, 'message', contains('перенаправлений'))),
    );
  });

  test('HTTP-ошибки превращаются в понятные сообщения', () async {
    for (final (code, text) in [
      (404, 'не найден'),
      (403, 'закрыт'),
      (410, 'удалил'),
      (503, 'сервера'),
    ]) {
      final fetcher = FeedFetcher(client: MockClient((_) async => http.Response('', code)));
      await expectLater(
        fetcher.fetch('https://example.com/feed'),
        throwsA(isA<FeedFetchException>()
            .having((e) => e.statusCode, 'statusCode', code)
            .having((e) => e.message, 'message', contains(text))),
      );
    }
  });

  test('нет сети', () async {
    final fetcher = FeedFetcher(client: MockClient((_) async {
      throw const SocketException('Failed host lookup');
    }));
    await expectLater(
      fetcher.fetch('https://example.com/feed'),
      throwsA(isA<FeedFetchException>()
          .having((e) => e.message, 'message', contains('Нет соединения'))),
    );
  });

  test('слишком большой фид', () async {
    final fetcher = FeedFetcher(
      maxBytes: 10,
      client: MockClient((_) async => http.Response('x' * 100, 200)),
    );
    await expectLater(
      fetcher.fetch('https://example.com/feed'),
      throwsA(isA<FeedFetchException>()),
    );
  });

  test('логин и пароль из ссылки уходят в Basic-авторизацию', () async {
    late http.BaseRequest seen;
    final fetcher = FeedFetcher(client: MockClient((request) async {
      seen = request;
      return http.Response('<rss/>', 200);
    }));
    await fetcher.fetch('https://user:p%40ss@example.com/feed');
    expect(seen.headers['authorization'], 'Basic ${base64.encode(utf8.encode('user:p@ss'))}');
  });

  group('Apple Podcasts', () {
    test('адрес фида из iTunes Lookup', () async {
      final fetcher = FeedFetcher(client: MockClient((request) async {
        expect(request.url.host, 'itunes.apple.com');
        expect(request.url.queryParameters['id'], '123');
        return http.Response(
          jsonEncode({
            'resultCount': 1,
            'results': [
              {'feedUrl': 'https://example.com/feed.xml'},
            ],
          }),
          200,
        );
      }));
      expect(await fetcher.resolveApplePodcast('123'), 'https://example.com/feed.xml');
    });

    test('подкаст без открытого RSS', () async {
      final fetcher = FeedFetcher(client: MockClient((_) async => http.Response(
            jsonEncode({
              'resultCount': 1,
              'results': [
                {'collectionName': 'Exclusive'},
              ],
            }),
            200,
          )));
      await expectLater(
        fetcher.resolveApplePodcast('1'),
        throwsA(isA<FeedFetchException>()
            .having((e) => e.message, 'message', contains('только в Apple Podcasts'))),
      );
    });

    test('не найден', () async {
      final fetcher = FeedFetcher(client: MockClient((_) async => http.Response(
            jsonEncode({'resultCount': 0, 'results': <Object>[]}),
            200,
          )));
      await expectLater(fetcher.resolveApplePodcast('1'), throwsA(isA<FeedFetchException>()));
    });
  });
}
