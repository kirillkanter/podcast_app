import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../feed/models.dart';
import 'tables.dart';

export 'tables.dart' show DownloadStatus, BookKind, BookShelf;

part 'database.g.dart';

/// Эпизод с состоянием. [queued] — стоит в очереди, [archived] — в архиве.
typedef EpisodeWithState = ({
  Episode episode,
  EpisodeState? state,
  Download? download,
  bool queued,
  bool archived,
});

/// Элемент очереди или ленты: эпизод вместе с подкастом.
typedef QueueItem = FeedEpisode;

/// Изменение очереди или архива для отправки на сервер.
/// [kind] — `queue` или `archive`; [removed] — убран из очереди / возвращён
/// из архива; [value] — порядок в очереди.
typedef DirtyStateItem = ({
  String kind,
  int episodeId,
  String feedUrl,
  String enclosureUrl,
  double? value,
  bool removed,
  DateTime changed,
});

/// Последний эпизод плеера: возвращается в мини-плеер после перезапуска
/// и переходит между устройствами.
abstract final class PlayerSettings {
  /// id эпизода; пусто — плеер закрыт.
  static const last = 'player.last';

  /// Когда эпизод запустили (UTC, ISO 8601) — чтобы понять, какое
  /// устройство слушало позже.
  static const lastAt = 'player.lastAt';

  /// Скорость по умолчанию — для подкастов без своей скорости.
  static const speed = 'player.speed';

  /// Шаг перемотки назад и вперёд, секунды.
  static const rewind = 'player.rewind';
  static const forward = 'player.forward';
}

/// Ключи настроек очереди, архива и жестов.
abstract final class QueueSettings {
  /// Дослушав эпизод, играть следующий из очереди. По умолчанию включено.
  static const continuePlayback = 'queue.continue';

  /// Недослушанный эпизод, с которого переключились на другой, встаёт
  /// первым в очередь. По умолчанию включено.
  static const requeueInterrupted = 'queue.requeueInterrupted';

  /// Прослушанные эпизоды сразу уходят в архив. По умолчанию включено.
  static const autoArchive = 'archive.autoPlayed';

  /// Действие по свайпу влево и вправо, см. [SwipeAction].
  static const swipeLeft = 'swipe.left';
  static const swipeRight = 'swipe.right';
}

/// Что делает свайп по эпизоду в списке.
enum SwipeAction {
  archive('В архив'),
  queue('В очередь'),
  played('Прослушан'),
  download('Скачать'),
  none('Ничего');

  const SwipeAction(this.label);

  final String label;

  static SwipeAction parse(String? value, SwipeAction fallback) =>
      values.where((a) => a.name == value).firstOrNull ?? fallback;
}

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
  DateTime updatedAt,
});

/// Эпизод для общей ленты библиотеки.
typedef FeedEpisode = ({
  Episode episode,
  Podcast podcast,
  EpisodeState? state,
  Download? download,
  bool queued,
  bool archived,
});

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
  EpisodeArchives,
  Downloads,
  AppSettings,
  Books,
  BookTracks,
  BookChapters,
  BookProgresses,
  BookBookmarks,
  BookSources,
  BookHighlights,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// БД в папке документов приложения (Android и Windows).
  AppDatabase.defaults() : super(driftDatabase(name: 'podcasts'));

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Этап 4: настройки и признак автозагрузки.
            await m.createTable(appSettings);
            await m.addColumn(downloads, downloads.auto);
          }
          if (from < 3) {
            // Новый дизайн, этап 2: архив. Уже прослушанные эпизоды сразу
            // в архиве — так же, как будут уходить туда новые. На сервер
            // их не отправляем: другие устройства сделают то же самое.
            await m.createTable(episodeArchives);
            await customStatement(
              'INSERT OR IGNORE INTO episode_archives (episode_id, archived, updated_at, dirty) '
              "SELECT episode_id, 1, strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime'), 0 FROM episode_states WHERE played = 1",
            );
          }
          if (from < 4) {
            // Книги: аудиокниги и текстовые.
            await m.createTable(books);
            await m.createTable(bookTracks);
            await m.createTable(bookChapters);
            await m.createTable(bookProgresses);
            await m.createTable(bookBookmarks);
            await m.createTable(bookSources);
          }
          if (from < 5) {
            // Выделения цветом и заметки в текстовых книгах.
            await m.createTable(bookHighlights);
          }
        },
        beforeOpen: (details) async {
          // В SQLite внешние ключи по умолчанию выключены.
          await customStatement('PRAGMA foreign_keys = ON');
          // С базой может работать и фоновая задача Android: журнал WAL
          // позволяет читать во время записи, а ожидание вместо ошибки
          // «база занята» сглаживает одновременные записи.
          try {
            await customStatement('PRAGMA busy_timeout = 5000');
            await customStatement('PRAGMA journal_mode = WAL');
          } catch (_) {
            // Не поддерживается (например, база в памяти в тестах) — не важно.
          }
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

  /// Подкаст, фид которого пока не загрузился (подписка с другого
  /// устройства): название — адрес сайта, ошибка видна в библиотеке.
  /// Обновление фидов заполнит его, как только фид станет доступен.
  Future<int> addPodcastPlaceholder(String feedUrl, {String? error}) async {
    final existing = await findPodcastByUrl(feedUrl);
    if (existing != null) return existing.id;
    final host = Uri.tryParse(feedUrl)?.host;
    return into(podcasts).insert(PodcastsCompanion.insert(
      feedUrl: feedUrl,
      title: host == null || host.isEmpty ? feedUrl : host,
      lastError: Value(error),
      lastCheckedAt: Value(DateTime.now()),
    ));
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

  /// Присоединения для признаков «в очереди» и «в архиве».
  List<Join> get _flagJoins => [
        leftOuterJoin(
          queueEntries,
          queueEntries.episodeId.equalsExp(episodes.id) & queueEntries.removed.equals(false),
        ),
        leftOuterJoin(
          episodeArchives,
          episodeArchives.episodeId.equalsExp(episodes.id) & episodeArchives.archived.equals(true),
        ),
      ];

  EpisodeWithState _withState(TypedResult row) => (
        episode: row.readTable(episodes),
        state: row.readTableOrNull(episodeStates),
        download: row.readTableOrNull(downloads),
        queued: row.readTableOrNull(queueEntries) != null,
        archived: row.readTableOrNull(episodeArchives) != null,
      );

  FeedEpisode _feedEpisode(TypedResult row) => (
        episode: row.readTable(episodes),
        podcast: row.readTable(podcasts),
        state: row.readTableOrNull(episodeStates),
        download: row.readTableOrNull(downloads),
        queued: row.readTableOrNull(queueEntries) != null,
        archived: row.readTableOrNull(episodeArchives) != null,
      );

  /// Не в архиве.
  Expression<bool> get _notArchived => episodeArchives.episodeId.isNull();

  Stream<List<EpisodeWithState>> watchEpisodesWithState(int podcastId) {
    final query = select(episodes).join([
      leftOuterJoin(episodeStates, episodeStates.episodeId.equalsExp(episodes.id)),
      leftOuterJoin(downloads, downloads.episodeId.equalsExp(episodes.id)),
      ..._flagJoins,
    ])
      ..where(episodes.podcastId.equals(podcastId))
      ..orderBy([
        OrderingTerm(expression: episodes.pubDate, mode: OrderingMode.desc, nulls: NullsOrder.last),
        OrderingTerm.asc(episodes.id),
      ]);
    return query.map(_withState).watch();
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
      ..._flagJoins,
    ]);
    final byDate = OrderingTerm(expression: episodes.pubDate, mode: OrderingMode.desc, nulls: NullsOrder.last);
    switch (filter) {
      case FeedFilter.fresh:
        query
          ..where((episodeStates.played.isNull() | episodeStates.played.equals(false)) & _notArchived)
          ..orderBy([byDate, OrderingTerm.desc(episodes.id)]);
      case FeedFilter.started:
        query
          ..where(episodeStates.positionMs.isBiggerThanValue(0) & episodeStates.played.equals(false) & _notArchived)
          ..orderBy([OrderingTerm.desc(episodeStates.updatedAt)]);
      case FeedFilter.downloaded:
        query
          ..where(downloads.status.equals(DownloadStatus.completed.name))
          ..orderBy([byDate, OrderingTerm.desc(episodes.id)]);
    }
    query.limit(limit);
    return query.map(_feedEpisode).watch();
  }

  /// Сколько у каждого подкаста новых эпизодов: появившихся после добавления
  /// подкаста и ещё не начатых. id подкаста → число.
  Stream<Map<int, int>> watchNewEpisodeCounts() {
    return customSelect(
      'SELECT e.podcast_id AS pid, COUNT(*) AS n FROM episodes e '
      'JOIN podcasts p ON p.id = e.podcast_id '
      'LEFT JOIN episode_states s ON s.episode_id = e.id '
      'LEFT JOIN episode_archives a ON a.episode_id = e.id AND a.archived = 1 '
      'WHERE julianday(e.first_seen_at) > julianday(p.created_at) + 0.001 '
      // Вышедшие задолго до подписки — не новые, даже если лента загрузилась
      // позже (не открывалась без VPN и т. п.).
      "AND (e.pub_date IS NULL OR julianday(e.pub_date) > julianday(p.created_at) - 2) "
      'AND (s.episode_id IS NULL OR (s.played = 0 AND s.position_ms = 0)) '
      'AND a.episode_id IS NULL '
      'GROUP BY e.podcast_id',
      readsFrom: {episodes, podcasts, episodeStates, episodeArchives},
    ).watch().map((rows) => {for (final r in rows) r.read<int>('pid'): r.read<int>('n')});
  }

  /// Последние [count] эпизодов подкаста по дате с их состоянием и загрузкой.
  Future<List<EpisodeWithState>> latestEpisodes(int podcastId, int count) async {
    final query = select(episodes).join([
      leftOuterJoin(episodeStates, episodeStates.episodeId.equalsExp(episodes.id)),
      leftOuterJoin(downloads, downloads.episodeId.equalsExp(episodes.id)),
      ..._flagJoins,
    ])
      ..where(episodes.podcastId.equals(podcastId))
      ..orderBy([
        OrderingTerm(expression: episodes.pubDate, mode: OrderingMode.desc, nulls: NullsOrder.last),
        OrderingTerm.desc(episodes.id),
      ])
      ..limit(count);
    return query.map(_withState).get();
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
  ///
  /// Прослушанный эпизод уходит из очереди и (если включено в настройках)
  /// в архив; снятие отметки возвращает его из архива.
  Future<void> setPlayed(int episodeId, bool played) {
    return transaction(() async {
      final now = DateTime.now();
      final changes = EpisodeStatesCompanion(
        played: Value(played),
        playedAt: Value(played ? now : null),
        positionMs: const Value(0),
        updatedAt: Value(now),
        dirty: const Value(true),
      );
      await into(episodeStates).insert(
        changes.copyWith(episodeId: Value(episodeId)),
        onConflict: DoUpdate((_) => changes),
      );
      if (played) {
        await removeFromQueue(episodeId);
        if (await _autoArchive()) await setArchived(episodeId, true);
      } else if (await isArchived(episodeId)) {
        await setArchived(episodeId, false);
      }
    });
  }

  Future<bool> _autoArchive() async => await setting(QueueSettings.autoArchive) != 'false';

  // -------------------------------------------------------------------------
  // Очередь. Порядок — дробное число: перестановка меняет одну строку.
  // Удаление мягкое (removed), чтобы передать его на другие устройства.
  // -------------------------------------------------------------------------

  Stream<List<QueueItem>> watchQueue() {
    final query = select(queueEntries).join([
      innerJoin(episodes, episodes.id.equalsExp(queueEntries.episodeId)),
      innerJoin(podcasts, podcasts.id.equalsExp(episodes.podcastId)),
      leftOuterJoin(episodeStates, episodeStates.episodeId.equalsExp(episodes.id)),
      leftOuterJoin(downloads, downloads.episodeId.equalsExp(episodes.id)),
      leftOuterJoin(
        episodeArchives,
        episodeArchives.episodeId.equalsExp(episodes.id) & episodeArchives.archived.equals(true),
      ),
    ])
      ..where(queueEntries.removed.equals(false))
      ..orderBy([OrderingTerm.asc(queueEntries.sortOrder), OrderingTerm.asc(queueEntries.episodeId)]);
    return query.map(_feedEpisode).watch();
  }

  Future<List<QueueEntry>> _queueRows() => (select(queueEntries)
        ..where((q) => q.removed.equals(false))
        ..orderBy([(q) => OrderingTerm.asc(q.sortOrder), (q) => OrderingTerm.asc(q.episodeId)]))
      .get();

  /// id эпизодов очереди по порядку.
  Future<List<int>> queueIds() async => [for (final q in await _queueRows()) q.episodeId];

  /// Первый эпизод очереди, кроме [exclude].
  Future<int?> nextInQueue({int? exclude}) async {
    for (final q in await _queueRows()) {
      if (q.episodeId != exclude) return q.episodeId;
    }
    return null;
  }

  Stream<bool> watchInQueue(int episodeId) => (select(queueEntries)
        ..where((q) => q.episodeId.equals(episodeId) & q.removed.equals(false)))
      .watchSingleOrNull()
      .map((q) => q != null);

  /// Добавить в конец очереди или, если [next], в начало. Эпизод, который
  /// уже в очереди, при [next] переносится в начало, иначе остаётся на месте.
  Future<void> addToQueue(int episodeId, {bool next = false}) {
    return transaction(() async {
      final rows = await _queueRows();
      final present = rows.any((q) => q.episodeId == episodeId);
      if (present && !next) return;
      final others = rows.where((q) => q.episodeId != episodeId).toList();
      final double order;
      if (others.isEmpty) {
        order = 0;
      } else if (next) {
        order = others.first.sortOrder - 1;
      } else {
        order = others.last.sortOrder + 1;
      }
      await _writeQueue(episodeId, order: order, removed: false);
    });
  }

  Future<void> removeFromQueue(int episodeId) async {
    final row = await (select(queueEntries)..where((q) => q.episodeId.equals(episodeId))).getSingleOrNull();
    if (row == null || row.removed) return;
    await _writeQueue(episodeId, order: row.sortOrder, removed: true);
  }

  Future<void> clearQueue() {
    return transaction(() async {
      for (final q in await _queueRows()) {
        await _writeQueue(q.episodeId, order: q.sortOrder, removed: true);
      }
    });
  }

  /// Переставить эпизод на место [newIndex] (считая без него самого).
  Future<void> moveInQueue(int episodeId, int newIndex) {
    return transaction(() async {
      final rows = await _queueRows();
      if (!rows.any((q) => q.episodeId == episodeId)) return;
      final others = rows.where((q) => q.episodeId != episodeId).toList();
      final index = newIndex.clamp(0, others.length);
      final before = index > 0 ? others[index - 1].sortOrder : null;
      final after = index < others.length ? others[index].sortOrder : null;
      if (before != null && after != null && after - before < 1e-6) {
        // Дробные части исчерпались: перенумеровываем всю очередь.
        final ordered = [...others]..insert(index, rows.firstWhere((q) => q.episodeId == episodeId));
        for (var i = 0; i < ordered.length; i++) {
          await _writeQueue(ordered[i].episodeId, order: i.toDouble(), removed: false);
        }
        return;
      }
      final order = switch ((before, after)) {
        (null, null) => 0.0,
        (null, final a?) => a - 1,
        (final b?, null) => b + 1,
        (final b?, final a?) => (a + b) / 2,
      };
      await _writeQueue(episodeId, order: order, removed: false);
    });
  }

  Future<void> _writeQueue(int episodeId, {required double order, required bool removed}) =>
      into(queueEntries).insertOnConflictUpdate(QueueEntriesCompanion(
        episodeId: Value(episodeId),
        sortOrder: Value(order),
        removed: Value(removed),
        updatedAt: Value(DateTime.now()),
        dirty: const Value(true),
      ));

  // -------------------------------------------------------------------------
  // Архив
  // -------------------------------------------------------------------------

  /// В архив (эпизод скрывается из списков и уходит из очереди) или обратно.
  Future<void> setArchived(int episodeId, bool archived) {
    return transaction(() async {
      await into(episodeArchives).insertOnConflictUpdate(EpisodeArchivesCompanion(
        episodeId: Value(episodeId),
        archived: Value(archived),
        updatedAt: Value(DateTime.now()),
        dirty: const Value(true),
      ));
      if (archived) await removeFromQueue(episodeId);
    });
  }

  Future<bool> isArchived(int episodeId) async =>
      (await (select(episodeArchives)..where((a) => a.episodeId.equals(episodeId))).getSingleOrNull())
          ?.archived ??
      false;

  // -------------------------------------------------------------------------
  // Синхронизация очереди и архива (отдельно от gPodder, см. bcaster.php)
  // -------------------------------------------------------------------------

  Future<List<DirtyStateItem>> dirtyStateItems() async {
    final queue = await (select(queueEntries).join([
      innerJoin(episodes, episodes.id.equalsExp(queueEntries.episodeId)),
      innerJoin(podcasts, podcasts.id.equalsExp(episodes.podcastId)),
    ])
          ..where(queueEntries.dirty.equals(true)))
        .map<DirtyStateItem>((row) {
      final q = row.readTable(queueEntries);
      return (
        kind: 'queue',
        episodeId: q.episodeId,
        feedUrl: row.readTable(podcasts).feedUrl,
        enclosureUrl: row.readTable(episodes).enclosureUrl,
        value: q.sortOrder,
        removed: q.removed,
        changed: q.updatedAt,
      );
    }).get();
    final archive = await (select(episodeArchives).join([
      innerJoin(episodes, episodes.id.equalsExp(episodeArchives.episodeId)),
      innerJoin(podcasts, podcasts.id.equalsExp(episodes.podcastId)),
    ])
          ..where(episodeArchives.dirty.equals(true)))
        .map<DirtyStateItem>((row) {
      final a = row.readTable(episodeArchives);
      return (
        kind: 'archive',
        episodeId: a.episodeId,
        feedUrl: row.readTable(podcasts).feedUrl,
        enclosureUrl: row.readTable(episodes).enclosureUrl,
        value: null,
        removed: !a.archived,
        changed: a.updatedAt,
      );
    }).get();
    return [...queue, ...archive];
  }

  Stream<int> watchDirtyStateCount() {
    return customSelect(
      'SELECT (SELECT COUNT(*) FROM queue_entries WHERE dirty = 1) + '
      '(SELECT COUNT(*) FROM episode_archives WHERE dirty = 1) AS n',
      readsFrom: {queueEntries, episodeArchives},
    ).watchSingle().map((r) => r.read<int>('n'));
  }

  /// Неотправленные изменения очереди — выбросить (первая синхронизация
  /// с уже существующей общей очередью: она важнее местной).
  Future<void> dropUnsyncedQueue() => (update(queueEntries)..where((q) => q.dirty.equals(true)))
      .write(const QueueEntriesCompanion(removed: Value(true), dirty: Value(false)));

  Future<void> markStateSynced(String kind, Iterable<int> episodeIds, DateTime before) {
    if (kind == 'queue') {
      return (update(queueEntries)
            ..where((q) => q.episodeId.isIn(episodeIds) & q.updatedAt.isSmallerOrEqualValue(before)))
          .write(const QueueEntriesCompanion(dirty: Value(false)));
    }
    return (update(episodeArchives)
          ..where((a) => a.episodeId.isIn(episodeIds) & a.updatedAt.isSmallerOrEqualValue(before)))
        .write(const EpisodeArchivesCompanion(dirty: Value(false)));
  }

  /// Изменение очереди с сервера. Более позднее локальное изменение,
  /// ещё не отправленное, важнее. Возвращает `true`, если применено.
  Future<bool> applyRemoteQueue(int episodeId, {required double order, required bool removed, required DateTime changed}) {
    return transaction(() async {
      final current = await (select(queueEntries)..where((q) => q.episodeId.equals(episodeId))).getSingleOrNull();
      if (current != null && current.dirty && !current.updatedAt.isBefore(changed)) return false;
      await into(queueEntries).insertOnConflictUpdate(QueueEntriesCompanion(
        episodeId: Value(episodeId),
        sortOrder: Value(order),
        removed: Value(removed),
        updatedAt: Value(changed),
        dirty: const Value(false),
      ));
      return true;
    });
  }

  /// Изменение архива с сервера; правило то же, что для очереди.
  Future<bool> applyRemoteArchive(int episodeId, {required bool archived, required DateTime changed}) {
    return transaction(() async {
      final current = await (select(episodeArchives)..where((a) => a.episodeId.equals(episodeId))).getSingleOrNull();
      if (current != null && current.dirty && !current.updatedAt.isBefore(changed)) return false;
      await into(episodeArchives).insertOnConflictUpdate(EpisodeArchivesCompanion(
        episodeId: Value(episodeId),
        archived: Value(archived),
        updatedAt: Value(changed),
        dirty: const Value(false),
      ));
      return true;
    });
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

  Stream<EpisodeState?> watchEpisodeState(int episodeId) =>
      (select(episodeStates)..where((s) => s.episodeId.equals(episodeId))).watchSingleOrNull();

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
        updatedAt: s.updatedAt,
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

  /// Состояние эпизода с сервера. Побеждает более позднее изменение
  /// ([changed] — когда его сделали на другом устройстве): если здесь
  /// состояние менялось позже или тогда же, ничего не меняем и возвращаем
  /// `false`. Без [changed] (старые данные) локальное неотправленное
  /// изменение важнее.
  Future<bool> applyRemoteEpisodeState(
    int episodeId, {
    required int positionMs,
    required bool played,
    DateTime? changed,
  }) {
    return transaction(() async {
      final current = await episodeState(episodeId);
      if (current != null) {
        if (changed == null ? current.dirty : !current.updatedAt.isBefore(changed)) return false;
      }
      final now = DateTime.now();
      await into(episodeStates).insertOnConflictUpdate(EpisodeStatesCompanion(
        episodeId: Value(episodeId),
        positionMs: Value(played ? 0 : positionMs),
        played: Value(played),
        playedAt: Value(played ? (current?.playedAt ?? now) : null),
        updatedAt: Value(changed ?? now),
        dirty: const Value(false),
      ));
      // Дослушан на другом устройстве: здесь — так же, как при локальном
      // прослушивании, но без отправки обратно (то устройство сделало это само).
      if (played && !(current?.played ?? false)) {
        await (update(queueEntries)..where((q) => q.episodeId.equals(episodeId) & q.removed.equals(false)))
            .write(QueueEntriesCompanion(removed: const Value(true), updatedAt: Value(now), dirty: const Value(false)));
        if (await _autoArchive()) {
          await into(episodeArchives).insert(
            EpisodeArchivesCompanion(
              episodeId: Value(episodeId),
              archived: const Value(true),
              updatedAt: Value(now),
              dirty: const Value(false),
            ),
            mode: InsertMode.insertOrIgnore,
          );
        }
      }
      return true;
    });
  }
}
