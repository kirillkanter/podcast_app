import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/data/podcast_repository.dart';
import 'package:podcast_app/feed/feed_fetcher.dart';
import 'package:podcast_app/sync/gpodder_client.dart';
import 'package:podcast_app/sync/sync_service.dart';

import 'fake_gpodder_server.dart';

const feedUrl = 'https://example.com/feed';

final _feed = '''
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
<title>Общий подкаст</title>
${[1, 2, 3].map((n) => '''
<item><guid>$n</guid><title>Эпизод $n</title>
  <pubDate>0$n Oct 2026 10:00:00 GMT</pubDate>
  <itunes:duration>3600</itunes:duration>
  <enclosure url="https://cdn.example.com/$n.mp3" type="audio/mpeg"/></item>''').join()}
</channel></rss>''';

/// Одно устройство: своя БД, свой загрузчик фидов, общий сервер синхронизации.
class Device {
  Device(this.server, String name)
      : db = AppDatabase(NativeDatabase.memory()) {
    repo = PodcastRepository(
      db,
      FeedFetcher(
        client: MockClient((r) async => r.url.toString() == feedUrl
            ? http.Response.bytes(utf8.encode(_feed), 200)
            : http.Response('', 404)),
      ),
      parser: PodcastRepository.parseInPlace,
    );
    sync = SyncService(
      db: db,
      repository: repo,
      clientFactory: server.client,
      deviceCaption: name,
      deviceType: 'mobile',
    );
  }

  final FakeGpodderServer server;
  final AppDatabase db;
  late final PodcastRepository repo;
  late final SyncService sync;

  Future<void> signIn() =>
      sync.signIn(server: 'https://sync.example.com', username: 'kirill', password: 'secret123');

  Future<int?> podcastId() async => (await db.findPodcastByUrl(feedUrl))?.id;

  Future<int> episode(int n) async =>
      (await db.findEpisodeByEnclosure('https://cdn.example.com/$n.mp3'))!.id;

  Future<EpisodeState?> state(int n) async => db.episodeState(await episode(n));

  Future<bool> subscribed() async {
    final id = await podcastId();
    return id != null && await db.watchIsSubscribed(id).first;
  }
}

void main() {
  late FakeGpodderServer server;
  late Device phone;
  late Device laptop;

  setUp(() {
    server = FakeGpodderServer();
    phone = Device(server, 'Телефон');
    laptop = Device(server, 'Ноутбук');
  });

  tearDown(() async {
    await phone.db.close();
    await laptop.db.close();
  });

  test('неверный пароль — понятная ошибка, данные не сохраняются', () async {
    await expectLater(
      phone.sync.signIn(server: 'sync.example.com', username: 'kirill', password: 'wrong'),
      throwsA(isA<SyncException>()
          .having((e) => e.unauthorized, 'unauthorized', isTrue)
          .having((e) => e.message, 'message', contains('логин или пароль'))),
    );
    expect(await phone.sync.isConfigured, isFalse);
  });

  test('подписка и позиция переходят на другое устройство', () async {
    await phone.repo.addAndSubscribe(feedUrl);
    await phone.db.savePosition(await phone.episode(2), const Duration(minutes: 5));
    await phone.signIn();
    await phone.sync.syncNow();

    expect(server.subscriptions.keys, [feedUrl]);
    expect(server.devices, hasLength(1));

    await laptop.signIn();
    final result = await laptop.sync.syncNow();

    expect(result.subscriptionsAdded, 1);
    expect(await laptop.subscribed(), isTrue);
    final state = await laptop.state(2);
    expect(state!.positionMs, 300000);
    expect(state.played, isFalse);
    expect(state.dirty, isFalse, reason: 'полученное с сервера не отправляется обратно');
  });

  test('отметка «прослушано» и её снятие', () async {
    await phone.repo.addAndSubscribe(feedUrl);
    await phone.signIn();
    await laptop.signIn();
    await phone.sync.syncNow();
    await laptop.sync.syncNow();

    await laptop.db.setPlayed(await laptop.episode(1), true);
    await laptop.sync.syncNow();
    await phone.sync.syncNow();
    expect((await phone.state(1))!.played, isTrue);

    await phone.db.setPlayed(await phone.episode(1), false);
    await phone.sync.syncNow();
    await laptop.sync.syncNow();
    final s = await laptop.state(1);
    expect(s!.played, isFalse);
    expect(s.positionMs, 0);
  });

  test('очередь и архив переходят на другое устройство', () async {
    await phone.repo.addAndSubscribe(feedUrl);
    await phone.signIn();
    await laptop.signIn();
    await phone.sync.syncNow();
    await laptop.sync.syncNow();

    await phone.db.addToQueue(await phone.episode(3));
    await phone.db.addToQueue(await phone.episode(1));
    await phone.db.setArchived(await phone.episode(2), true);
    await phone.sync.syncNow();
    final result = await laptop.sync.syncNow();
    expect(result.stateUpdated, 3);
    expect(await laptop.db.queueIds(), [await laptop.episode(3), await laptop.episode(1)]);
    expect(await laptop.db.isArchived(await laptop.episode(2)), isTrue);
    expect(await laptop.db.dirtyStateItems(), isEmpty, reason: 'полученное не отправляется обратно');

    // Перестановка и возврат из архива — обратно на телефон.
    await laptop.db.moveInQueue(await laptop.episode(1), 0);
    await laptop.db.setArchived(await laptop.episode(2), false);
    await laptop.sync.syncNow();
    await phone.sync.syncNow();
    expect(await phone.db.queueIds(), [await phone.episode(1), await phone.episode(3)]);
    expect(await phone.db.isArchived(await phone.episode(2)), isFalse);
  });

  test('сервер без очереди: остальное синхронизируется, ошибки нет', () async {
    server.supportsState = false;
    await phone.repo.addAndSubscribe(feedUrl);
    await phone.db.addToQueue(await phone.episode(1));
    await phone.signIn();
    await phone.sync.syncNow();
    expect(server.subscriptions.keys, [feedUrl]);
    expect(await phone.db.setting(SyncSettings.stateUnsupported), 'true');
    expect(await phone.db.dirtyStateItems(), hasLength(1), reason: 'уйдёт, когда сервер научится');
    expect(await phone.db.setting(SyncSettings.lastError), '');
  });

  test('отписка переходит на другое устройство', () async {
    await phone.repo.addAndSubscribe(feedUrl);
    await phone.signIn();
    await laptop.signIn();
    await phone.sync.syncNow();
    await laptop.sync.syncNow();
    expect(await laptop.subscribed(), isTrue);

    await phone.repo.setSubscribed((await phone.podcastId())!, false);
    await phone.sync.syncNow();
    final result = await laptop.sync.syncNow();

    expect(result.subscriptionsRemoved, 1);
    expect(await laptop.subscribed(), isFalse);
  });

  test('последнее действие побеждает, неотправленное локальное не затирается', () async {
    await phone.repo.addAndSubscribe(feedUrl);
    await phone.signIn();
    await laptop.signIn();
    await phone.sync.syncNow();
    await laptop.sync.syncNow();

    // Телефон дослушал до 10 минут и отправил.
    await phone.db.savePosition(await phone.episode(3), const Duration(minutes: 10));
    await phone.sync.syncNow();

    // Ноутбук тем временем слушал офлайн до 20 минут и ещё не отправил:
    // при синхронизации его позиция уходит на сервер, а не затирается.
    await laptop.db.savePosition(await laptop.episode(3), const Duration(minutes: 20));
    await laptop.sync.syncNow();
    expect((await laptop.state(3))!.positionMs, 1200000);

    // Телефон получает позицию ноутбука как самую свежую.
    await phone.sync.syncNow();
    expect((await phone.state(3))!.positionMs, 1200000);
  });

  test('повторная синхронизация без изменений ничего не отправляет', () async {
    await phone.repo.addAndSubscribe(feedUrl);
    await phone.signIn();
    await phone.sync.syncNow();
    final before = server.requests.where((r) => r.method == 'POST').length;

    await phone.sync.syncNow();
    expect(server.requests.where((r) => r.method == 'POST').length, before);
  });

  test('выход сохраняет данные на устройстве', () async {
    await phone.repo.addAndSubscribe(feedUrl);
    await phone.signIn();
    await phone.sync.syncNow();
    await phone.sync.signOut();

    expect(await phone.sync.isConfigured, isFalse);
    expect(await phone.subscribed(), isTrue);
    expect((await phone.sync.syncNow()).subscriptionsAdded, 0, reason: 'без аккаунта синхронизация не идёт');
  });

  group('клиент gPodder', () {
    test('веб-страница вместо API — подсказка про адрес и Cloudflare', () async {
      final client = GpodderClient(
        server: 'sync.example.com',
        username: 'kirill',
        password: 'x',
        client: MockClient((_) async => http.Response('<html>Just a moment...</html>', 403,
            headers: {'content-type': 'text/html'})),
      );
      await expectLater(
        client.login(),
        throwsA(isA<SyncException>().having((e) => e.message, 'message', contains('Cloudflare'))),
      );
    });

    test('адрес сервера нормализуется', () {
      expect(GpodderClient.normalizeServer('sync.bcaster.ru/'), 'https://sync.bcaster.ru');
      expect(GpodderClient.normalizeServer(' http://host:8080 '), 'http://host:8080');
    });

    test('разбор действий: время без зоны считается UTC, пустые поля не отправляются', () {
      final a = EpisodeAction.fromJson({
        'podcast': 'p',
        'episode': 'e',
        'action': 'PLAY',
        'position': 10,
        'total': 20.0,
        'timestamp': '2026-10-06T10:00:00',
      })!;
      expect(a.action, 'play');
      expect(a.total, 20);
      expect(a.timestamp, DateTime.utc(2026, 10, 6, 10));
      expect(
        const EpisodeAction(podcast: 'p', episode: 'e', action: 'new').toJson(),
        {'podcast': 'p', 'episode': 'e', 'action': 'new'},
      );
    });
  });
}
