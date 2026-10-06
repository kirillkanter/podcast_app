import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/catalog/podcast_catalog.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/data/podcast_repository.dart';
import 'package:podcast_app/feed/feed_fetcher.dart';
import 'package:podcast_app/main.dart';

const _feed = '''
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
<title>Тестовый подкаст</title>
<itunes:author>Автор</itunes:author>
<description>Описание подкаста</description>
<item><guid>1</guid><title>Первый выпуск</title>
  <pubDate>Mon, 05 Oct 2026 10:00:00 GMT</pubDate>
  <itunes:duration>3723</itunes:duration>
  <description>&lt;p&gt;О чём выпуск&lt;/p&gt;</description>
  <enclosure url="https://cdn.example.com/1.mp3" type="audio/mpeg"/></item>
<item><guid>2</guid><title>Второй выпуск</title>
  <pubDate>Tue, 06 Oct 2026 10:00:00 GMT</pubDate>
  <enclosure url="https://cdn.example.com/2.mp3" type="audio/mpeg"/></item>
</channel></rss>''';

void main() {
  late AppDatabase db;
  late PodcastRepository repo;

  setUp(() {
    // closeStreamsSynchronously: иначе drift оставляет таймер после теста.
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final client = MockClient((request) async => request.url.toString() == 'https://example.com/feed'
        ? http.Response.bytes(utf8.encode(_feed), 200)
        : http.Response('', 404));
    repo = PodcastRepository(db, FeedFetcher(client: client), parser: PodcastRepository.parseInPlace);
  });

  tearDown(() => db.close());

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  /// pumpAndSettle, который при зависании сообщает шаг и текст на экране.
  Future<void> settle(WidgetTester tester, String step) async {
    try {
      await tester.pumpAndSettle();
    } catch (_) {
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .whereType<String>()
          .join(' | ');
      fail('Интерфейс не успокоился после шага «$step». На экране: $texts');
    }
  }

  testWidgets('пустой список подписок', (tester) async {
    await tester.pumpWidget(PodcastApp(db: db, repository: repo, refreshOnStart: false));
    await tester.pumpAndSettle();

    expect(find.text('Подписок пока нет'), findsOneWidget);
    await disposeApp(tester);
  });

  // Добавление через диалог целиком проверено в podcast_repository_test.
  // Здесь подкаст добавляется до запуска интерфейса: запись в SQLite внутри
  // виртуального времени виджет-теста зависает.
  testWidgets('подписка, экран подкаста и карточка эпизода', (tester) async {
    await tester.runAsync(() => repo.addAndSubscribe('https://example.com/feed'));

    await tester.pumpWidget(PodcastApp(db: db, repository: repo, refreshOnStart: false));
    await settle(tester, 'запуск');
    expect(find.text('Тестовый подкаст'), findsOneWidget);
    expect(find.text('Подписок пока нет'), findsNothing);

    await tester.tap(find.text('Тестовый подкаст'));
    await settle(tester, 'открытие подкаста');
    expect(find.text('Автор'), findsOneWidget);
    expect(find.text('Вы подписаны'), findsOneWidget);
    expect(find.text('Первый выпуск'), findsOneWidget);
    expect(find.text('Второй выпуск'), findsOneWidget);
    // Новые эпизоды сверху.
    expect(
      tester.getTopLeft(find.text('Второй выпуск')).dy,
      lessThan(tester.getTopLeft(find.text('Первый выпуск')).dy),
    );

    await tester.tap(find.text('Первый выпуск'));
    await settle(tester, 'открытие эпизода');
    expect(find.text('О чём выпуск'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await settle(tester, 'закрытие эпизода');
    await tester.pageBack();
    await settle(tester, 'возврат назад');
    expect(find.text('Тестовый подкаст'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('ошибка показывается в диалоге', (tester) async {
    await tester.pumpWidget(PodcastApp(db: db, repository: repo, refreshOnStart: false));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Добавить по ссылке RSS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('feedUrlField')), 'https://example.com/missing');
    await tester.tap(find.byKey(const Key('addFeedButton')));
    await tester.pumpAndSettle();

    expect(find.textContaining('404'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('поиск: популярное, результаты, отметка подписки', (tester) async {
    await tester.runAsync(() => repo.addAndSubscribe('https://example.com/feed'));
    final catalog = PodcastCatalog(
      country: 'ru',
      client: MockClient((request) async {
        if (request.url.host == 'rss.marketingtools.apple.com') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'feed': {
                'results': [
                  {'id': '1'},
                ],
              },
            })),
            200,
          );
        }
        final results = request.url.path == '/lookup'
            ? [
                {'collectionId': 1, 'collectionName': 'Популярный подкаст', 'feedUrl': 'https://pop.example.com/rss'},
              ]
            : [
                // Тот же фид, что в подписках, но с http и слэшем на конце.
                {'collectionId': 2, 'collectionName': 'Тестовый подкаст', 'feedUrl': 'http://example.com/feed/'},
                {'collectionId': 3, 'collectionName': 'Эксклюзив', 'artistName': 'Студия'},
              ];
        return http.Response.bytes(utf8.encode(jsonEncode({'results': results})), 200);
      }),
    );

    await tester.pumpWidget(
      PodcastApp(db: db, repository: repo, catalog: catalog, refreshOnStart: false),
    );
    await settle(tester, 'запуск');
    await tester.tap(find.byKey(const Key('tab-search')));
    await settle(tester, 'открытие поиска');
    expect(find.text('Популярное'), findsOneWidget);
    expect(find.text('Популярный подкаст'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('searchField')), 'тест');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester, 'поиск');
    expect(find.text('Результаты поиска'), findsOneWidget);
    expect(find.text('Тестовый подкаст'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'подписка узнана по адресу фида');
    expect(find.textContaining('только в Apple Podcasts'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('библиотека: три эпизода и экран «Эпизоды» со всеми', (tester) async {
    final items = [
      for (var i = 1; i <= 5; i++)
        '<item><guid>$i</guid><title>Выпуск $i</title><pubDate>0$i Oct 2026 10:00:00 GMT</pubDate>'
            '<enclosure url="https://cdn.example.com/$i.mp3" type="audio/mpeg"/></item>',
    ].join();
    final big = PodcastRepository(
      db,
      FeedFetcher(
        client: MockClient((_) async => http.Response.bytes(
            utf8.encode('<rss version="2.0"><channel><title>Пятёрка</title>$items</channel></rss>'), 200)),
      ),
      parser: PodcastRepository.parseInPlace,
    );
    await tester.runAsync(() => big.addAndSubscribe('https://example.com/five'));

    await tester.pumpWidget(PodcastApp(db: db, repository: big, refreshOnStart: false));
    await settle(tester, 'запуск');
    expect(find.text('Выпуск 5'), findsOneWidget);
    expect(find.text('Выпуск 3'), findsOneWidget);
    expect(find.text('Выпуск 2'), findsNothing, reason: 'в библиотеке только три эпизода');

    await tester.tap(find.text('Все новые эпизоды'));
    await settle(tester, 'открытие всех эпизодов');
    expect(find.text('Эпизоды'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Выпуск 1'),
      200,
      scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first,
    );
    expect(find.text('Выпуск 1'), findsOneWidget);

    await disposeApp(tester);
  });
}
