import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../feed/models.dart';
import 'tables.dart';

export 'tables.dart' show DownloadStatus;

part 'database.g.dart';

typedef EpisodeWithState = ({Episode episode, EpisodeState? state, Download? download});

/// Подписка, изменённая локально и ещё не отправленная на сервер.
typedef DirtySubscription = ({int podcastId, String feedUrl, bool subscribed});

/// Состояние эпизода, изменённое локально и ещё не отправленное на сервер.
typedef DirtyEpisodeState = ({
  int episodeId,
  String feedUrl,
  String enclosureUrl,
  int positionMs,
  bool played,
  int? durationMs,
});

/// Эпизод для общей ленты библиотеки.
typedef FeedEpisode = ({Episode episode, Podcast podcast, EpisodeState? state, Download? download});

/// Какие эпизоды показывать в ленте библиотеки.
enum FeedFilter {
  /// Непрослушанные эпизоды подписок, сначала свежие.
  fresh,

  /// Начатые и не дослушанные, сначала недавно слушавшиеся.
  started,

  /// Загруженные на устройство.
  downloaded,
}

/// Загрузка вместе с эпизодом и подкастом — для экрана «Загрузки».
typedef DownloadWithEpisode = ({Download download, Episode episode, Podcast podcast});

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
  AppSettings,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// БД в папке документов приложения (Android и Windows).
  AppDatabase.defaults() : super(driftDatabase(name: 'podcasts'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Этап 4: настройки и признак автозагрузки.
            await m.createTable(appSettings);
            await m.addColumn(downloads, downloads.auto);
          }
        },
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

  /// Фид не изменился (HTTP 304): отмечаем успешную проверку.
  Future<void> markFeedNotModified(int podcastId) {
    final now = DateTime.now();
    return (update(podcasts)..where((p) => p.id.equals(podcastId))).write(
      PodcastsCompanion(
        lastCheckedAt: Value(now),
        lastSuccessAt: Value(now),
        lastError: const Value(null),
      ),
    );
  }

  /// Переводит подкаст на новый адрес фида. Если этот адрес уже занят
  /// другим подкастом, ничего не делает и возвращает `false`.
  Future<bool> updateFeedUrl(int podcastId, String newUrl) {
    return transaction(() async {
      final taken = await findPodcastByUrl(newUrl);
      if (taken != null) return taken.id == podcastId;
      await (update(podcasts)..where((p) => p.id.equals(podcastId)))
          .write(PodcastsCompanion(feedUrl: Value(newUrl)));
      return true;
    });
  }

  Future<Podcast?> findPodcastByUrl(String feedUrl) =>
      (select(podcasts)..where((p) => p.feedUrl.equals(feedUrl))).getSingleOrNull();

  Future<Podcast?> podcastById(int id) =>
      (select(podcasts)..where((p) => p.id.equals(id))).getSingleOrNull();

  Stream<Podcast?> watchPodcast(int id) =>
      (select(podcasts)..where((p) => p.id.equals(id))).watchSingleOrNull();

  Stream<bool> watchIsSubscribed(int podcastId) =>
      (select(subscriptions)..where((s) => s.podcastId.equals(podcastId)))
          .watchSingleOrNull()
          .map((s) => s?.subscribed ?? false);

  Future<List<Podcast>> subscribedPodcasts() {
    final query = select(podcasts).join([
      innerJoin(subscriptions, subscriptions.podcastId.equalsExp(podcasts.id)),
    ])
      ..where(subscriptions.subscribed.equals(true));
    return query.map((row) => row.readTable(podcasts)).get();
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

  Stream<List<EpisodeWithState>> watchEpisodesWithState(int podcastId) {
    final query = select(episodes).join([
      leftOuterJoin(episodeStates, episodeStates.episodeId.equalsExp(episodes.id)),
      leftOuterJoin(downloads, downloads.episodeId.equalsExp(episodes.id)),
    ])
      ..where(episodes.podcastId.equals(podcastId))
      ..orderBy([
        OrderingTerm(expression: episodes.pubDate, mode: OrderingMode.desc, nulls: NullsOrder.last),
        OrderingTerm.asc(episodes.id),
      ]);
    return query
        .map((row) => (
              episode: row.readTable(episodes),
              state: row.readTableOrNull(episodeStates),
              download: row.readTableOrNull(downloads),
            ))
        .watch();
  }

  // -------------------------------------------------------------------------
  // Настройки
  // -------------------------------------------------------------------------

  Future<String?> setting(String key) async =>
      (await (select(appSettings)..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Stream<String?> watchSetting(String key) =>
      (select(appSettings)..where((s) => s.key.equals(key)))
          .watchSingleOrNull()
          .map((s) => s?.value);

  Future<void> setSetting(String key, String value) =>
      into(appSettings).insertOnConflictUpdate(AppSettingsCompanion(key: Value(key), value: Value(value)));

  // -------------------------------------------------------------------------
  // Загрузки
  // -------------------------------------------------------------------------

  Future<Download?> download(int episodeId) =>
      (select(downloads)..where((d) => d.episodeId.equals(episodeId))).getSingleOrNull();

  Stream<Download?> watchDownload(int episodeId) =>
      (select(downloads)..where((d) => d.episodeId.equals(episodeId))).watchSingleOrNull();

  Future<void> saveDownload(DownloadsCompanion row) =>
      into(downloads).insertOnConflictUpdate(row.copyWith(updatedAt: Value(DateTime.now())));

  Future<void> updateDownload(int episodeId, DownloadsCompanion changes) =>
      (update(downloads)..where((d) => d.episodeId.equals(episodeId)))
          .write(changes.copyWith(updatedAt: Value(DateTime.now())));

  Future<void> deleteDownloadRow(int episodeId) =>
      (delete(downloads)..where((d) => d.episodeId.equals(episodeId))).go();

  Future<List<Download>> downloadsWithStatus(Iterable<DownloadStatus> statuses) =>
      (select(downloads)
            ..where((d) => d.status.isIn(statuses.map((s) => s.name)))
            ..orderBy([(d) => OrderingTerm.asc(d.updatedAt)]))
          .get();

  /// Сколько байт занимают загруженные файлы.
  Future<int> downloadedBytes() async {
    final sum = downloads.totalBytes.sum();
    final query = selectOnly(downloads)
      ..addColumns([sum])
      ..where(downloads.status.equals(DownloadStatus.completed.name));
    return (await query.getSingle()).read(sum) ?? 0;
  }

  Stream<List<DownloadWithEpisode>> watchDownloadList() {
    final query = select(downloads).join([
      innerJoin(episodes, episodes.id.equalsExp(downloads.episodeId)),
      innerJoin(podcasts, podcasts.id.equalsExp(episodes.podcastId)),
    ])
      ..where(downloads.status.isNotIn([DownloadStatus.removed.name]))
      ..orderBy([OrderingTerm.desc(downloads.updatedAt)]);
    return query
        .map((row) => (
              download: row.readTable(downloads),
              episode: row.readTable(episodes),
              podcast: row.readTable(podcasts),
            ))
        .watch();
  }

  /// Лента библиотеки: эпизоды подписок по фильтру.
  Stream<List<FeedEpisode>> watchFeed(FeedFilter filter, {int limit = 30}) {
    final query = select(episodes).join([
      innerJoin(podcasts, podcasts.id.equalsExp(episodes.podcastId)),
      if (filter != FeedFilter.downloaded)
        innerJoin(
          subscriptions,
          subscriptions.podcastId.equalsExp(episodes.podcastId) & subscriptions.subscribed.equals(true),
          useColumns: false,
        ),
      leftOuterJoin(episodeStates, episodeStates.episodeId.equalsExp(episodes.id)),
      leftOuterJoin(downloads, downloads.episodeId.equalsExp(episodes.id)),
    ]);
    final byDate = OrderingTerm(expression: episodes.pubDate, mode: OrderingMode.desc, nulls: NullsOrder.last);
    switch (filter) {
      case FeedFilter.fresh:
        query
          ..where(episodeStates.played.isNull() | episodeStates.played.equals(false))
          ..orderBy([byDate, OrderingTerm.desc(episodes.id)]);
      case FeedFilter.started:
        query
          ..where(episodeStates.positionMs.isBiggerThanValue(0) & episodeStates.played.equals(false))
          ..orderBy([OrderingTerm.desc(episodeStates.updatedAt)]);
      case FeedFilter.downloaded:
        query
          ..where(downloads.status.equals(DownloadStatus.completed.name))
          ..orderBy([byDate, OrderingTerm.desc(episodes.id)]);
    }
    query.limit(limit);
    return query
        .map((row) => (
              episode: row.readTable(episodes),
              podcast: row.readTable(podcasts),
              state: row.readTableOrNull(episodeStates),
              download: row.readTableOrNull(downloads),
            ))
        .watch();
  }

  /// Сколько у каждого подкаста новых эпизодов: появившихся после добавления
  /// подкаста и ещё не начатых. id подкаста → число.
  Stream<Map<int, int>> watchNewEpisodeCounts() {
    return customSelect(
      'SELECT e.podcast_id AS pid, COUNT(*) AS n FROM episodes e '
      'JOIN podcasts p ON p.id = e.podcast_id '
      'LEFT JOIN episode_states s ON s.episode_id = e.id '
      'WHERE julianday(e.first_seen_at) > julianday(p.created_at) + 0.001 '
      'AND (s.episode_id IS NULL OR (s.played = 0 AND s.position_ms = 0)) '
      'GROUP BY e.podcast_id',
      readsFrom: {episodes, podcasts, episodeStates},
    ).watch().map((rows) => {for (final r in rows) r.read<int>('pid'): r.read<int>('n')});
  }

  /// Последние [count] эпизодов подкаста по дате с их состоянием и загрузкой.
  Future<List<EpisodeWithState>> latestEpisodes(int podcastId, int count) async {
    final query = select(episodes).join([
      leftOuterJoin(episodeStates, episodeStates.episodeId.equalsExp(episodes.id)),
      leftOuterJoin(downloads, downloads.episodeId.equalsExp(episodes.id)),
    ])
      ..where(episodes.podcastId.equals(podcastId))
      ..orderBy([
        OrderingTerm(expression: episodes.pubDate, mode: OrderingMode.desc, nulls: NullsOrder.last),
        OrderingTerm.desc(episodes.id),
      ])
      ..limit(count);
    return query
        .map((row) => (
              episode: row.readTable(episodes),
              state: row.readTableOrNull(episodeStates),
              download: row.readTableOrNull(downloads),
            ))
        .get();
  }

  /// Сколько последних эпизодов подкаста держать загруженными;
  /// `null` — как в общих настройках.
  Future<int?> podcastAutoDownloadCount(int podcastId) async {
    final row = await (select(podcastSettings)..where((s) => s.podcastId.equals(podcastId)))
        .getSingleOrNull();
    return row?.autoDownloadCount;
  }

  Stream<int?> watchPodcastAutoDownloadCount(int podcastId) =>
      (select(podcastSettings)..where((s) => s.podcastId.equals(podcastId)))
          .watchSingleOrNull()
          .map((s) => s?.autoDownloadCount);

  Future<void> setPodcastAutoDownloadCount(int podcastId, int? count) {
    final now = DateTime.now();
    return into(podcastSettings).insert(
      PodcastSettingsCompanion(
        podcastId: Value(podcastId),
        autoDownloadCount: Value(count),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
      onConflict: DoUpdate(
        (_) => PodcastSettingsCompanion(
          autoDownloadCount: Value(count),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      ),
    );
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

  Future<Episode?> episodeById(int id) =>
      (select(episodes)..where((e) => e.id.equals(id))).getSingleOrNull();

  /// Скорость воспроизведения подкаста; `null` — не задана.
  Future<double?> podcastSpeed(int podcastId) async {
    final row = await (select(podcastSettings)..where((s) => s.podcastId.equals(podcastId)))
        .getSingleOrNull();
    return row?.playbackSpeed;
  }

  Future<void> setPodcastSpeed(int podcastId, double speed) {
    final now = DateTime.now();
    return into(podcastSettings).insert(
      PodcastSettingsCompanion(
        podcastId: Value(podcastId),
        playbackSpeed: Value(speed),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
      onConflict: DoUpdate(
        (_) => PodcastSettingsCompanion(
          playbackSpeed: Value(speed),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      ),
    );
  }

  Future<EpisodeState?> episodeState(int episodeId) =>
      (select(episodeStates)..where((s) => s.episodeId.equals(episodeId))).getSingleOrNull();

  // -------------------------------------------------------------------------
  // Синхронизация
  // -------------------------------------------------------------------------

  Future<List<DirtySubscription>> dirtySubscriptions() async {
    final query = select(subscriptions).join([
      innerJoin(podcasts, podcasts.id.equalsExp(subscriptions.podcastId)),
    ])
      ..where(subscriptions.dirty.equals(true));
    return query
        .map((row) => (
              podcastId: row.readTable(subscriptions).podcastId,
              feedUrl: row.readTable(podcasts).feedUrl,
              subscribed: row.readTable(subscriptions).subscribed,
            ))
        .get();
  }

  /// Снимает флаг dirty с подписок, не изменившихся после [before]
  /// (изменения во время отправки уйдут в следующий раз).
  Future<void> markSubscriptionsSynced(Iterable<int> podcastIds, DateTime before) =>
      (update(subscriptions)
            ..where((s) => s.podcastId.isIn(podcastIds) & s.updatedAt.isSmallerOrEqualValue(before)))
          .write(const SubscriptionsCompanion(dirty: Value(false)));

  /// Изменение подписки с сервера: без флага dirty, чтобы не отправлять обратно.
  Future<void> applyRemoteSubscription(int podcastId, bool subscribed) =>
      into(subscriptions).insertOnConflictUpdate(SubscriptionsCompanion(
        podcastId: Value(podcastId),
        subscribed: Value(subscribed),
        updatedAt: Value(DateTime.now()),
        dirty: const Value(false),
      ));

  Stream<int> watchDirtySubscriptionCount() {
    final count = subscriptions.podcastId.count();
    final query = selectOnly(subscriptions)
      ..addColumns([count])
      ..where(subscriptions.dirty.equals(true));
    return query.map((row) => row.read(count) ?? 0).watchSingle();
  }

  Future<List<DirtyEpisodeState>> dirtyEpisodeStates() async {
    final query = select(episodeStates).join([
      innerJoin(episodes, episodes.id.equalsExp(episodeStates.episodeId)),
      innerJoin(podcasts, podcasts.id.equalsExp(episodes.podcastId)),
    ])
      ..where(episodeStates.dirty.equals(true));
    return query.map((row) {
      final s = row.readTable(episodeStates);
      final e = row.readTable(episodes);
      return (
        episodeId: s.episodeId,
        feedUrl: row.readTable(podcasts).feedUrl,
        enclosureUrl: e.enclosureUrl,
        positionMs: s.positionMs,
        played: s.played,
        durationMs: e.durationMs,
      );
    }).get();
  }

  Future<void> markEpisodeStatesSynced(Iterable<int> episodeIds, DateTime before) =>
      (update(episodeStates)
            ..where((s) => s.episodeId.isIn(episodeIds) & s.updatedAt.isSmallerOrEqualValue(before)))
          .write(const EpisodeStatesCompanion(dirty: Value(false)));

  /// Эпизод по адресу аудиофайла; при нескольких совпадениях — из подкаста
  /// с адресом [feedUrl].
  Future<Episode?> findEpisodeByEnclosure(String enclosureUrl, {String? feedUrl}) async {
    final query = select(episodes).join([
      innerJoin(podcasts, podcasts.id.equalsExp(episodes.podcastId)),
    ])
      ..where(episodes.enclosureUrl.equals(enclosureUrl));
    final rows = await query.get();
    if (rows.isEmpty) return null;
    for (final row in rows) {
      if (row.readTable(podcasts).feedUrl == feedUrl) return row.readTable(episodes);
    }
    return rows.first.readTable(episodes);
  }

  /// Состояние эпизода с сервера. Локальные неотправленные изменения
  /// важнее: если состояние dirty, ничего не меняем и возвращаем `false`.
  Future<bool> applyRemoteEpisodeState(int episodeId, {required int positionMs, required bool played}) {
    return transaction(() async {
      final current = await episodeState(episodeId);
      if (current != null && current.dirty) return false;
      final now = DateTime.now();
      await into(episodeStates).insertOnConflictUpdate(EpisodeStatesCompanion(
        episodeId: Value(episodeId),
        positionMs: Value(played ? 0 : positionMs),
        played: Value(played),
        playedAt: Value(played ? (current?.playedAt ?? now) : null),
        updatedAt: Value(now),
        dirty: const Value(false),
      ));
      return true;
    });
  }
}
