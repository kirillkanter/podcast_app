import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/feed/models.dart';
import 'package:podcast_app/feed/rss_parser.dart';

const feedUrl = 'https://example.com/feed.xml';

String feedWith(List<(String guid, String title)> items) => '''
<rss version="2.0"><channel><title>Тест</title>
${items.map((i) => '<item><guid>${i.$1}</guid><title>${i.$2}</title>'
        '<enclosure url="https://x.org/${i.$1}.mp3" type="audio/mpeg"/></item>').join()}
</channel></rss>''';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('сохранение полного фида', () async {
    final feed = parseFeedBytes(File('test/fixtures/full.xml').readAsBytesSync());
    final result = await db.saveParsedFeed(feedUrl, feed, etag: '"abc"');

    expect(result.newEpisodes, 3);
    expect(result.totalEpisodes, 3);

    final podcast = await db.select(db.podcasts).getSingle();
    expect(podcast.title, 'Тестовый подкаст');
    expect(podcast.podcastType, PodcastType.serial);
    expect(podcast.categories.split('\n'), hasLength(3));
    expect(podcast.etag, '"abc"');
    expect(podcast.lastError, isNull);

    final episodes = await db.watchEpisodes(result.podcastId).first;
    expect(episodes.map((e) => e.episodeKey), ['g:ep-2', 'g:ep-trailer', 'g:ep-media']);
    expect(episodes.first.durationMs, 3723000);
    expect(episodes[1].episodeType, EpisodeType.trailer);

    final transcripts = await db.select(db.episodeTranscripts).get();
    expect(transcripts, hasLength(2));
  });

  test('повторное сохранение: без дублей, id стабильны, старые эпизоды остаются', () async {
    final first = await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('1', 'Один'), ('2', 'Два')])));
    final idsBefore = {
      for (final e in await db.watchEpisodes(first.podcastId).first) e.episodeKey: e.id,
    };

    final second = await db.saveParsedFeed(
      feedUrl,
      parseFeed(feedWith([('3', 'Три'), ('2', 'Два (исправлено)')])),
    );

    expect(second.podcastId, first.podcastId);
    expect(second.newEpisodes, 1);
    expect(second.totalEpisodes, 3);

    final after = {for (final e in await db.watchEpisodes(first.podcastId).first) e.episodeKey: e};
    expect(after.keys, containsAll(['g:1', 'g:2', 'g:3']));
    expect(after['g:2']!.id, idsBefore['g:2']);
    expect(after['g:2']!.title, 'Два (исправлено)');
  });

  test('позиция и отметка «прослушан»', () async {
    final r = await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('1', 'Один')])));
    final episodeId = (await db.watchEpisodes(r.podcastId).first).single.id;

    await db.savePosition(episodeId, const Duration(minutes: 5));
    var state = await db.episodeState(episodeId);
    expect(state!.positionMs, 300000);
    expect(state.played, isFalse);
    expect(state.dirty, isTrue);

    await db.setPlayed(episodeId, true);
    state = await db.episodeState(episodeId);
    expect(state!.played, isTrue);
    expect(state.positionMs, 0);
    expect(state.playedAt, isNotNull);

    // Новая позиция не снимает отметку «прослушан».
    await db.savePosition(episodeId, const Duration(seconds: 10));
    state = await db.episodeState(episodeId);
    expect(state!.played, isTrue);
    expect(state.positionMs, 10000);
  });

  test('подписка и отписка (мягкое удаление)', () async {
    final r = await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('1', 'Один')])));

    await db.setSubscribed(r.podcastId, true);
    expect(await db.watchSubscribedPodcasts().first, hasLength(1));

    await db.setSubscribed(r.podcastId, false);
    expect(await db.watchSubscribedPodcasts().first, isEmpty);

    final sub = await db.select(db.subscriptions).getSingle();
    expect(sub.subscribed, isFalse);
    expect(sub.dirty, isTrue);
  });

  test('ошибка обновления сохраняется, успешное обновление её сбрасывает', () async {
    final r = await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('1', 'Один')])));
    await db.markFeedError(r.podcastId, 'HTTP 500');
    expect((await db.select(db.podcasts).getSingle()).lastError, 'HTTP 500');

    await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('1', 'Один')])));
    expect((await db.select(db.podcasts).getSingle()).lastError, isNull);
  });

  test('удаление подкаста каскадно удаляет эпизоды и состояние', () async {
    final r = await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('1', 'Один')])));
    final episodeId = (await db.watchEpisodes(r.podcastId).first).single.id;
    await db.savePosition(episodeId, const Duration(seconds: 1));

    await (db.delete(db.podcasts)..where((p) => p.id.equals(r.podcastId))).go();

    expect(await db.select(db.episodes).get(), isEmpty);
    expect(await db.select(db.episodeStates).get(), isEmpty);
  });

  test('скорость воспроизведения подкаста', () async {
    final r = await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('1', 'Один')])));
    expect(await db.podcastSpeed(r.podcastId), isNull);

    await db.setPodcastSpeed(r.podcastId, 1.5);
    expect(await db.podcastSpeed(r.podcastId), 1.5);

    await db.setPodcastSpeed(r.podcastId, 2.0);
    expect(await db.podcastSpeed(r.podcastId), 2.0);
    final settings = await db.select(db.podcastSettings).getSingle();
    expect(settings.dirty, isTrue);
  });

  test('эпизод по id', () async {
    final r = await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('1', 'Один')])));
    final id = (await db.watchEpisodes(r.podcastId).first).single.id;
    expect((await db.episodeById(id))!.title, 'Один');
    expect(await db.episodeById(id + 100), isNull);
  });

  group('лента библиотеки', () {
    Future<int> addFeed(String url, List<(String, String)> items) async {
      final r = await db.saveParsedFeed(url, parseFeed(feedWith(items)));
      await db.setSubscribed(r.podcastId, true);
      return r.podcastId;
    }

    Future<int> episodeId(String guid) async =>
        (await (db.select(db.episodes)..where((e) => e.guid.equals(guid))).getSingle()).id;

    test('новые, начатые и загруженные', () async {
      await addFeed(feedUrl, [('a', 'A'), ('b', 'B'), ('c', 'C')]);
      final other = await addFeed('https://example.com/other.xml', [('x', 'X')]);
      await db.setSubscribed(other, false);

      await db.setPlayed(await episodeId('a'), true);
      await db.savePosition(await episodeId('b'), const Duration(minutes: 3));
      await db.saveDownload(DownloadsCompanion(
        episodeId: Value(await episodeId('c')),
        status: const Value(DownloadStatus.completed),
        filePath: const Value('/tmp/c.mp3'),
      ));

      final fresh = await db.watchFeed(FeedFilter.fresh).first;
      expect(fresh.map((e) => e.episode.title), unorderedEquals(['B', 'C']),
          reason: 'прослушанные и эпизоды без подписки не попадают');
      expect(fresh.first.podcast.title, 'Тест');

      final started = await db.watchFeed(FeedFilter.started).first;
      expect(started.map((e) => e.episode.title), ['B']);
      expect(started.single.state!.positionMs, 180000);

      final downloaded = await db.watchFeed(FeedFilter.downloaded).first;
      expect(downloaded.map((e) => e.episode.title), ['C']);
    });

    test('счётчик новых: только появившиеся после добавления и не начатые', () async {
      final id = await addFeed(feedUrl, [('a', 'A')]);
      expect(await db.watchNewEpisodeCounts().first, isEmpty, reason: 'эпизоды при добавлении не новые');

      // Подкаст добавлен вчера, потом вышли два эпизода, один начали слушать.
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await (db.update(db.podcasts)..where((p) => p.id.equals(id))).write(PodcastsCompanion(createdAt: Value(yesterday)));
      await (db.update(db.episodes)..where((e) => e.podcastId.equals(id)))
          .write(EpisodesCompanion(firstSeenAt: Value(yesterday)));
      await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('a', 'A'), ('b', 'B'), ('c', 'C')])));
      await db.savePosition(await episodeId('c'), const Duration(seconds: 30));

      expect(await db.watchNewEpisodeCounts().first, {id: 1});
    });
  });

  group('очередь и архив', () {
    late List<int> ids;

    setUp(() async {
      final r = await db.saveParsedFeed(feedUrl, parseFeed(feedWith([('a', 'A'), ('b', 'B'), ('c', 'C'), ('d', 'D')])));
      await db.setSubscribed(r.podcastId, true);
      final byGuid = {for (final e in await db.watchEpisodes(r.podcastId).first) e.guid: e.id};
      ids = [byGuid['a']!, byGuid['b']!, byGuid['c']!, byGuid['d']!];
    });

    Future<List<String>> titles() async => [for (final q in await db.watchQueue().first) q.episode.title];

    test('добавление, «следующим», перестановка, удаление, очистка', () async {
      await db.addToQueue(ids[0]);
      await db.addToQueue(ids[1]);
      await db.addToQueue(ids[2]);
      await db.addToQueue(ids[0]);
      expect(await titles(), ['A', 'B', 'C'], reason: 'повторное добавление не двигает');

      await db.addToQueue(ids[3], next: true);
      expect(await titles(), ['D', 'A', 'B', 'C']);

      await db.moveInQueue(ids[3], 3);
      expect(await titles(), ['A', 'B', 'C', 'D']);
      await db.moveInQueue(ids[2], 0);
      expect(await titles(), ['C', 'A', 'B', 'D']);
      await db.moveInQueue(ids[1], 1);
      expect(await titles(), ['C', 'B', 'A', 'D']);

      await db.removeFromQueue(ids[1]);
      expect(await titles(), ['C', 'A', 'D']);
      expect(await db.nextInQueue(), ids[2]);
      expect(await db.nextInQueue(exclude: ids[2]), ids[0]);
      expect(await db.watchInQueue(ids[1]).first, isFalse);

      // Удалённый возвращается в конец.
      await db.addToQueue(ids[1]);
      expect(await titles(), ['C', 'A', 'D', 'B']);

      await db.clearQueue();
      expect(await titles(), isEmpty);
    });

    test('много перестановок в одно место не ломают порядок', () async {
      for (final id in ids) {
        await db.addToQueue(id);
      }
      for (var i = 0; i < 80; i++) {
        await db.moveInQueue(ids[i % 2 == 0 ? 3 : 2], 1);
      }
      final order = await titles();
      expect(order.first, 'A');
      expect(order.toSet(), {'A', 'B', 'C', 'D'});
      expect(order, hasLength(4));
    });

    test('прослушанный уходит из очереди и в архив, снятие отметки возвращает', () async {
      await db.addToQueue(ids[0]);
      await db.setPlayed(ids[0], true);
      expect(await titles(), isEmpty);
      expect(await db.isArchived(ids[0]), isTrue);

      final page = await db.watchEpisodesWithState((await db.episodeById(ids[0]))!.podcastId).first;
      expect(page.firstWhere((e) => e.episode.id == ids[0]).archived, isTrue);

      await db.setPlayed(ids[0], false);
      expect(await db.isArchived(ids[0]), isFalse);
    });

    test('автоархив можно выключить', () async {
      await db.setSetting(QueueSettings.autoArchive, 'false');
      await db.setPlayed(ids[0], true);
      expect(await db.isArchived(ids[0]), isFalse);
    });

    test('архив скрывает из ленты и уводит из очереди', () async {
      await db.addToQueue(ids[1]);
      await db.setArchived(ids[1], true);
      expect(await titles(), isEmpty);
      final fresh = await db.watchFeed(FeedFilter.fresh).first;
      expect(fresh.map((e) => e.episode.title), isNot(contains('B')));

      await db.setArchived(ids[1], false);
      final again = await db.watchFeed(FeedFilter.fresh).first;
      expect(again.map((e) => e.episode.title), contains('B'));
      expect(again.firstWhere((e) => e.episode.title == 'B').queued, isFalse);
    });

    test('изменения с сервера: позднее локальное не затирается', () async {
      await db.addToQueue(ids[0]);
      final local = (await db.dirtyStateItems()).single;
      expect(local.kind, 'queue');
      expect(local.enclosureUrl, 'https://x.org/a.mp3');

      final older = local.changed.subtract(const Duration(minutes: 1));
      expect(await db.applyRemoteQueue(ids[0], order: 5, removed: true, changed: older), isFalse);
      expect(await titles(), ['A']);

      final newer = local.changed.add(const Duration(minutes: 1));
      expect(await db.applyRemoteQueue(ids[0], order: 5, removed: true, changed: newer), isTrue);
      expect(await titles(), isEmpty);
      expect(await db.dirtyStateItems(), isEmpty, reason: 'изменение с сервера не отправляется обратно');

      expect(await db.applyRemoteArchive(ids[2], archived: true, changed: newer), isTrue);
      expect(await db.isArchived(ids[2]), isTrue);
    });
  });
}
