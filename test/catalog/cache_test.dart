import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/catalog/podcast_catalog.dart';
import 'package:podcast_app/data/disk_cache.dart';
import 'package:podcast_app/ui/cover_image.dart';

String _chart(String title) => jsonEncode({
      'feed': {
        'entry': [
          {
            'im:name': {'label': title},
            'id': {
              'attributes': {'im:id': '101'},
            },
          },
        ],
      },
    });

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('bcaster_cache_test'));
  tearDown(() async => dir.delete(recursive: true));

  group('каталог', () {
    test('ответ сохраняется на диск и берётся оттуда после перезапуска', () async {
      var requests = 0;
      PodcastCatalog make(http.Response Function() respond) => PodcastCatalog(
            country: 'ru',
            cacheDirectory: () async => dir,
            client: MockClient((_) async {
              requests++;
              return respond();
            }),
          )..retryDelay = Duration.zero;

      final first = make(() => http.Response.bytes(utf8.encode(_chart('Свежий')), 200));
      expect((await first.chart(genreId: 1533)).single.title, 'Свежий');
      expect(requests, 1);
      // Запись на диск идёт в фоне.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // «Перезапуск»: новый каталог, сеть не нужна.
      final second = make(() => http.Response('сбой', 500));
      expect((await second.chart(genreId: 1533)).single.title, 'Свежий');
      expect(requests, 1, reason: 'свежий ответ — с диска');
    });

    test('без сети — сохранённый ответ, даже устаревший', () async {
      final key = Uri.https('itunes.apple.com', '/ru/rss/toppodcasts/limit=50/genre=1533/json').toString();
      final disk = DiskCache(() async => dir, extension: '.json');
      await disk.write(key, utf8.encode(_chart('Вчерашний')));
      final file = File('${dir.path}/${DiskCache.hash(key)}.json');
      await file.setLastModified(DateTime.now().subtract(const Duration(days: 2)));

      var requests = 0;
      final catalog = PodcastCatalog(
        country: 'ru',
        cacheDirectory: () async => dir,
        client: MockClient((_) async {
          requests++;
          throw const SocketException('нет сети');
        }),
      )..retryDelay = Duration.zero;
      expect((await catalog.chart(genreId: 1533)).single.title, 'Вчерашний');
      expect(requests, greaterThan(0), reason: 'устаревший ответ сначала пробуем обновить');
    });

    test('готовый список доступен сразу', () async {
      final catalog = PodcastCatalog(
        country: 'ru',
        client: MockClient((_) async => http.Response.bytes(utf8.encode(_chart('Один')), 200)),
      );
      final future = catalog.chart();
      expect(catalog.peek(future), isNull);
      await future;
      expect(catalog.peek(catalog.chart())!.single.title, 'Один');
    });
  });

  group('обложки', () {
    test('скачиваются один раз, даже если просят одновременно', () async {
      var requests = 0;
      final covers = CoverCache(
        directory: () async => dir,
        client: MockClient((_) async {
          requests++;
          return http.Response.bytes([1, 2, 3], 200, headers: {'content-type': 'image/jpeg'});
        }),
      );
      final both = await Future.wait([covers.bytes('https://img/1.jpg'), covers.bytes('https://img/1.jpg')]);
      expect(both.first, [1, 2, 3]);
      expect(requests, 1);

      final again = CoverCache(
        directory: () async => dir,
        client: MockClient((_) async => throw const SocketException('нет сети')),
      );
      expect(await again.bytes('https://img/1.jpg'), [1, 2, 3], reason: 'с диска, без сети');
    });

    test('вместо картинки пришла страница — не сохраняется', () async {
      final covers = CoverCache(
        directory: () async => dir,
        client: MockClient((_) async => http.Response('<html>', 200, headers: {'content-type': 'text/html'})),
      );
      await expectLater(covers.bytes('https://img/2.jpg'), throwsA(isA<HttpException>()));
      expect(dir.listSync(), isEmpty);
    });
  });

  test('очистка оставляет новые файлы', () async {
    final disk = DiskCache(() async => dir);
    for (var i = 0; i < 5; i++) {
      await disk.write('k$i', List.filled(1000, i));
      await File('${dir.path}/${DiskCache.hash('k$i')}')
          .setLastModified(DateTime.now().subtract(Duration(minutes: 10 - i)));
    }
    await disk.prune(3000);
    expect(await disk.read('k0'), isNull);
    expect(await disk.read('k4'), isNotNull);
    expect(dir.listSync().length, lessThanOrEqualTo(2));
  });
}
