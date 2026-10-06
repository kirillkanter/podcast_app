// Проверка синхронизации с настоящим сервером oPodSync (папка sync-server).
//
// В CI сервер запускается встроенным сервером PHP, см. .github/workflows/build.yml.
// Локально тест пропускается, если не заданы переменные окружения:
//   OPODSYNC_URL=http://127.0.0.1:8085 OPODSYNC_USER=... OPODSYNC_PASSWORD=...
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/data/podcast_repository.dart';
import 'package:podcast_app/feed/feed_fetcher.dart';
import 'package:podcast_app/sync/gpodder_client.dart';
import 'package:podcast_app/sync/sync_service.dart';

final _server = Platform.environment['OPODSYNC_URL'];
final _user = Platform.environment['OPODSYNC_USER'] ?? '';
final _password = Platform.environment['OPODSYNC_PASSWORD'] ?? '';

// Уникальный фид на каждый запуск: сервер общий для всех тестов.
final _feedUrl = 'https://example.com/feed-${DateTime.now().microsecondsSinceEpoch}.xml';

String get _feed => '''
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
<title>Интеграционный подкаст</title>
${[1, 2].map((n) => '''
<item><guid>$n</guid><title>Эпизод $n</title>
  <itunes:duration>1800</itunes:duration>
  <enclosure url="$_feedUrl/$n.mp3" type="audio/mpeg"/></item>''').join()}
</channel></rss>''';

class _Device {
  _Device(String name) : db = AppDatabase(NativeDatabase.memory()) {
    repo = PodcastRepository(
      db,
      FeedFetcher(
        client: MockClient((r) async => r.url.toString() == _feedUrl
            ? http.Response.bytes(utf8.encode(_feed), 200)
            : http.Response('', 404)),
      ),
      parser: PodcastRepository.parseInPlace,
    );
    // Настоящий HTTP-клиент: запросы идут на сервер oPodSync.
    sync = SyncService(db: db, repository: repo, deviceCaption: name, deviceType: 'desktop');
  }

  final AppDatabase db;
  late final PodcastRepository repo;
  late final SyncService sync;

  Future<int> episode(int n) async => (await db.findEpisodeByEnclosure('$_feedUrl/$n.mp3'))!.id;
}

void main() {
  test(
    'oPodSync: вход, подписка, позиция и «прослушано» между двумя устройствами',
    () async {
      final a = _Device('CI A');
      final b = _Device('CI B');
      addTearDown(() async {
        await a.db.close();
        await b.db.close();
      });

      await expectLater(
        a.sync.signIn(server: _server!, username: _user, password: 'неверный-пароль'),
        throwsA(isA<SyncException>().having((e) => e.unauthorized, 'unauthorized', isTrue)),
      );

      await a.repo.addAndSubscribe(_feedUrl);
      await a.db.savePosition(await a.episode(1), const Duration(minutes: 7));
      await a.db.setPlayed(await a.episode(2), true);
      await a.sync.signIn(server: _server, username: _user, password: _password);
      await a.sync.syncNow();

      await b.sync.signIn(server: _server, username: _user, password: _password);
      final result = await b.sync.syncNow();
      expect(result.feedErrors, isEmpty);

      final podcast = await b.db.findPodcastByUrl(_feedUrl);
      expect(podcast, isNotNull, reason: 'подписка пришла с сервера');
      expect(await b.db.watchIsSubscribed(podcast!.id).first, isTrue);
      expect((await b.db.episodeState(await b.episode(1)))!.positionMs, 420000);
      expect((await b.db.episodeState(await b.episode(2)))!.played, isTrue);

      // Обратно: B отписывается, A узнаёт об этом.
      await b.repo.setSubscribed(podcast.id, false);
      await b.sync.syncNow();
      await a.sync.syncNow();
      final aPodcast = await a.db.findPodcastByUrl(_feedUrl);
      expect(await a.db.watchIsSubscribed(aPodcast!.id).first, isFalse);
    },
    skip: _server == null ? 'OPODSYNC_URL не задан — нет сервера oPodSync' : false,
  );
}
