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
}
