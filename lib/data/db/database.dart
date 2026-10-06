import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../feed/models.dart';
import 'tables.dart';

export 'tables.dart' show DownloadStatus;

part 'database.g.dart';

class FeedSaveResult {
  const FeedSaveResult({
    required this.podcastId,
    required this.newEpisodes,
    required this.totalEpisodes,
  });

  final int podcastId;

  /// Эпизоды, которых не было в БД до этого сохранения.
  final int newEpisodes;
  final int totalEpisodes;
}

@DriftDatabase(tables: [
  Podcasts,
  Episodes,
  EpisodeTranscripts,
  Subscriptions,
  EpisodeStates,
  PodcastSettings,
  QueueEntries,
  Downloads,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// БД в папке документов приложения (Android и Windows).
  AppDatabase.defaults() : super(driftDatabase(name: 'podcasts'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        beforeOpen: (details) async {
          // В SQLite внешние ключи по умолчанию выключены.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  // -------------------------------------------------------------------------
  // Фиды
  // -------------------------------------------------------------------------

  /// Создаёт или обновляет подкаст и его эпизоды по разобранному фиду.
  ///
  /// Эпизоды, исчезнувшие из фида, не удаляются: у них может быть позиция,
  /// загрузка или место в очереди, а фиды часто отдают только последние N.
  Future<FeedSaveResult> saveParsedFeed(
    String feedUrl,
    ParsedFeed feed, {
    String? etag,
    String? lastModified,
  }) {
    return transaction(() async {
      final now = DateTime.now();
      final podcastData = PodcastsCompanion(
        feedUrl: Value(feedUrl),
        title: Value(feed.title.isEmpty ? feedUrl : feed.title),
        description: Value(feed.description),
        link: Value(feed.link),
        imageUrl: Value(feed.imageUrl),
        author: Value(feed.author),
        language: Value(feed.language),
        categories: Value(feed.categories.join('\n')),
        explicit: Value(feed.explicit),
        podcastType: Value(feed.type),
        podcastGuid: Value(feed.podcastGuid),
        etag: Value(etag),
        lastModified: Value(lastModified),
        lastCheckedAt: Value(now),
        lastSuccessAt: Value(now),
        lastError: const Value(null),
      );

      final existing = await (select(podcasts)..where((p) => p.feedUrl.equals(feedUrl)))
          .getSingleOrNull();
      final int podcastId;
      if (existing == null) {
        podcastId = await into(podcasts).insert(podcastData);
      } else {
        podcastId = existing.id;
        await (update(podcasts)..where((p) => p.id.equals(podcastId))).write(podcastData);
      }

      final knownKeys = (await _episodeIdsByKey(podcastId)).keys.toSet();

      await batch((b) {
        for (final e in feed.episodes) {
          final row = _episodeCompanion(podcastId, e);
          b.insert(
            episodes,
            row,
            onConflict: DoUpdate(
              (_) => row,
              target: [episodes.podcastId, episodes.episodeKey],
            ),
          );
        }
      });

      // Транскрипты заменяем целиком для эпизодов из текущего фида.
      final idsByKey = await _episodeIdsByKey(podcastId);
      final currentIds = [for (final e in feed.episodes) idsByKey[e.key]!];
      await batch((b) {
        b.deleteWhere(episodeTranscripts, (t) => t.episodeId.isIn(currentIds));
        for (final e in feed.episodes) {
          for (final t in e.transcripts) {
            b.insert(
              episodeTranscripts,
              EpisodeTranscriptsCompanion(
                episodeId: Value(idsByKey[e.key]!),
                url: Value(t.url),
                mimeType: Value(t.mimeType),
                language: Value(t.language),
                rel: Value(t.rel),
              ),
              mode: InsertMode.insertOrIgnore,
            );
          }
        }
      });

      return FeedSaveResult(
        podcastId: podcastId,
        newEpisodes: feed.episodes.where((e) => !knownKeys.contains(e.key)).length,
        totalEpisodes: idsByKey.length,
      );
    });
  }

  /// Записывает ошибку обновления фида, не трогая остальные данные.
  Future<void> markFeedError(int podcastId, String error) {
    return (update(podcasts)..where((p) => p.id.equals(podcastId))).write(
      PodcastsCompanion(
        lastCheckedAt: Value(DateTime.now()),
        lastError: Value(error),
      ),
    );
  }

  Future<Map<String, int>> _episodeIdsByKey(int podcastId) async {
    final query = selectOnly(episodes)
      ..addColumns([episodes.id, episodes.episodeKey])
      ..where(episodes.podcastId.equals(podcastId));
    final rows = await query.get();
    return {
      for (final r in rows) r.read(episodes.episodeKey)!: r.read(episodes.id)!,
    };
  }

  EpisodesCompanion _episodeCompanion(int podcastId, ParsedEpisode e) => EpisodesCompanion(
        podcastId: Value(podcastId),
        episodeKey: Value(e.key),
        guid: Value(e.guid),
        title: Value(e.title),
        description: Value(e.description),
        summary: Value(e.summary),
        link: Value(e.link),
        pubDate: Value(e.pubDate),
        enclosureUrl: Value(e.enclosure.url),
        enclosureType: Value(e.enclosure.mimeType),
        enclosureLength: Value(e.enclosure.length),
        durationMs: Value(e.duration?.inMilliseconds),
        imageUrl: Value(e.imageUrl),
        season: Value(e.season),
        episodeNumber: Value(e.episodeNumber),
        episodeType: Value(e.type),
        explicit: Value(e.explicit),
        chaptersUrl: Value(e.chapters?.url),
        chaptersType: Value(e.chapters?.mimeType),
      );

  // -------------------------------------------------------------------------
  // Чтение
  // -------------------------------------------------------------------------

  Stream<List<Podcast>> watchSubscribedPodcasts() {
    final query = select(podcasts).join([
      innerJoin(subscriptions, subscriptions.podcastId.equalsExp(podcasts.id)),
    ])
      ..where(subscriptions.subscribed.equals(true))
      ..orderBy([OrderingTerm.asc(podcasts.title)]);
    return query.map((row) => row.readTable(podcasts)).watch();
  }

  Stream<List<Episode>> watchEpisodes(int podcastId) {
    return (select(episodes)
          ..where((e) => e.podcastId.equals(podcastId))
          ..orderBy([
            (e) => OrderingTerm(expression: e.pubDate, mode: OrderingMode.desc, nulls: NullsOrder.last),
          ]))
        .watch();
  }

  // -------------------------------------------------------------------------
  // Синхронизируемое состояние. Любое изменение ставит dirty = true.
  // -------------------------------------------------------------------------

  Future<void> setSubscribed(int podcastId, bool subscribed) {
    final row = SubscriptionsCompanion(
      podcastId: Value(podcastId),
      subscribed: Value(subscribed),
      updatedAt: Value(DateTime.now()),
      dirty: const Value(true),
    );
    return into(subscriptions).insertOnConflictUpdate(row);
  }

  /// Сохраняет позицию воспроизведения, не трогая флаг «прослушан».
  Future<void> savePosition(int episodeId, Duration position) {
    final now = DateTime.now();
    final ms = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
    return into(episodeStates).insert(
      EpisodeStatesCompanion(
        episodeId: Value(episodeId),
        positionMs: Value(ms),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
      onConflict: DoUpdate(
        (_) => EpisodeStatesCompanion(
          positionMs: Value(ms),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      ),
    );
  }

  /// Отметка «прослушан» сбрасывает позицию: при повторном запуске
  /// эпизод начнётся сначала.
  Future<void> setPlayed(int episodeId, bool played) {
    final now = DateTime.now();
    final changes = EpisodeStatesCompanion(
      played: Value(played),
      playedAt: Value(played ? now : null),
      positionMs: const Value(0),
      updatedAt: Value(now),
      dirty: const Value(true),
    );
    return into(episodeStates).insert(
      changes.copyWith(episodeId: Value(episodeId)),
      onConflict: DoUpdate((_) => changes),
    );
  }

  Future<EpisodeState?> episodeState(int episodeId) =>
      (select(episodeStates)..where((s) => s.episodeId.equals(episodeId))).getSingleOrNull();
}
