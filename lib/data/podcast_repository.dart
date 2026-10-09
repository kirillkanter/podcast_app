/// Операции с подкастами: добавление по ссылке, обновление, подписка.
/// Связывает загрузчик фидов, парсер и БД.
library;

import 'dart:isolate';

import 'package:drift/drift.dart' show Value;

import '../feed/feed_fetcher.dart';
import '../feed/feed_url.dart';
import '../feed/models.dart';
import '../feed/rss_parser.dart';
import 'db/database.dart';

/// Ошибка, которую можно показать пользователю как есть.
class PodcastException implements Exception {
  const PodcastException(this.message);
  final String message;

  @override
  String toString() => message;
}

class RefreshSummary {
  const RefreshSummary({required this.newEpisodes, required this.failed});

  final int newEpisodes;

  /// Подкасты, которые не удалось обновить: id → текст ошибки.
  final Map<int, String> failed;
}

typedef FeedParserFn = Future<ParsedFeed> Function(
    List<int> bytes, String feedUrl, String? charset);

/// Версия разбора фидов. Если разбор изменился (исправили ошибку),
/// версия растёт — и все фиды разбираются заново, даже без изменений.
const feedParserVersion = 1;

/// Отпечаток содержимого фида: длина и 64-битный FNV-1a, плюс версия разбора.
/// Совпал с сохранённым — фид не менялся, разбирать и записывать нечего.
String feedContentHash(List<int> bytes) {
  var h = 0xcbf29ce484222325;
  for (final b in bytes) {
    h ^= b;
    h *= 0x100000001b3;
  }
  return 'v$feedParserVersion:${bytes.length}:${h.toUnsigned(64).toRadixString(16)}';
}

/// Отпечаток и, если он не совпал с [known], разобранный фид.
typedef _Checked = ({String hash, ParsedFeed? feed});

class PodcastRepository {
  PodcastRepository(this._db, this._fetcher, {FeedParserFn? parser}) : _customParse = parser;

  final AppDatabase _db;
  final FeedFetcher _fetcher;

  /// Свой разбор (тесты); `null` — в отдельном потоке.
  final FeedParserFn? _customParse;

  /// Отпечаток и разбор — в отдельном потоке: и то и другое на большом
  /// фиде заметно по времени. Если фид не изменился с прошлого раза,
  /// разобранный фид не возвращается: передавать его в основной поток
  /// и переписывать сотни эпизодов в базе незачем.
  Future<_Checked> _parseIfChanged(List<int> bytes, String feedUrl, String? charset, String? known) {
    final custom = _customParse;
    if (custom != null) {
      final hash = feedContentHash(bytes);
      if (hash == known) return Future.value((hash: hash, feed: null));
      return custom(bytes, feedUrl, charset).then((feed) => (hash: hash, feed: feed));
    }
    return _checkInIsolate(bytes, feedUrl, charset, known);
  }

  /// Отдельная статическая функция: замыкание для другого потока не должно
  /// захватить репозиторий (в нём база, её туда не передать).
  static Future<_Checked> _checkInIsolate(List<int> bytes, String feedUrl, String? charset, String? known) =>
      Isolate.run(() {
        final hash = feedContentHash(bytes);
        if (hash == known) return (hash: hash, feed: null);
        return (hash: hash, feed: parseFeedBytes(bytes, feedUrl: feedUrl, httpCharset: charset));
      });

  /// Разбор в текущем потоке — для тестов.
  static Future<ParsedFeed> parseInPlace(List<int> bytes, String feedUrl, String? charset) async =>
      parseFeedBytes(bytes, feedUrl: feedUrl, httpCharset: charset);

  /// Добавляет подкаст по ссылке и подписывается на него.
  /// Возвращает id подкаста.
  Future<int> addAndSubscribe(String input) => add(input, subscribe: true);

  /// Загружает подкаст по ссылке и сохраняет в БД. С [subscribe] = false
  /// подкаст можно посмотреть до подписки (например, из поиска).
  /// Уже известный подкаст не загружается заново.
  Future<int> add(String input, {required bool subscribe}) async {
    final parsed = parseFeedInput(input);
    if (parsed == null) {
      throw const PodcastException('Это не похоже на ссылку. Вставьте адрес RSS-фида.');
    }

    final String requestedUrl;
    try {
      requestedUrl = switch (parsed) {
        DirectFeedUrl(:final url) => url.toString(),
        ApplePodcastsLink(:final id) => await _fetcher.resolveApplePodcast(id),
      };
    } on FeedFetchException catch (e) {
      throw PodcastException(e.message);
    }

    final existing = await _db.findPodcastByUrl(requestedUrl);
    if (existing != null) {
      if (subscribe) await _db.setSubscribed(existing.id, true);
      return existing.id;
    }

    var loaded = await _download(requestedUrl);

    // Фид сообщает, что переехал: загружаем новый адрес (один раз,
    // чтобы два фида, ссылающиеся друг на друга, не зациклили загрузку).
    final moved = loaded.feed.newFeedUrl;
    if (moved != null && moved != loaded.url) {
      try {
        loaded = await _download(moved);
      } on PodcastException {
        // Новый адрес не работает — остаёмся на старом.
      }
    }

    final already = await _db.findPodcastByUrl(loaded.url);
    if (already != null) {
      if (subscribe) await _db.setSubscribed(already.id, true);
      await _save(already.id, loaded);
      return already.id;
    }

    final result = await _db.saveParsedFeed(
      loaded.url,
      loaded.feed,
      etag: loaded.etag,
      lastModified: loaded.lastModified,
      contentHash: loaded.hash,
    );
    if (subscribe) await _db.setSubscribed(result.podcastId, true);
    return result.podcastId;
  }

  /// Обновляет один подкаст. Возвращает число новых эпизодов.
  /// Ошибку записывает в БД и пробрасывает как [PodcastException].
  ///
  /// [checked] — копить сюда подкасты, где ничего не изменилось, чтобы
  /// записать «проверено» одним запросом на все (см. [refreshAll]).
  Future<int> refresh(int podcastId, {List<int>? checked}) async {
    final podcast = await _db.podcastById(podcastId);
    if (podcast == null) return 0;

    try {
      final FetchResult result;
      try {
        result = await _fetcher.fetch(
          podcast.feedUrl,
          etag: podcast.etag,
          lastModified: podcast.lastModified,
        );
      } on FeedFetchException catch (e) {
        throw PodcastException(e.message);
      }

      switch (result) {
        case FeedNotModified():
          if (checked != null) {
            checked.add(podcastId);
          } else {
            await _db.markFeedNotModified(podcastId);
          }
          return 0;
        case final FeedFetched fetched:
          final checkedFeed = await _parseSafely(fetched, podcast.feedUrl, known: podcast.contentHash);
          final feed = checkedFeed.feed;
          if (feed == null) {
            // Содержимое то же, что в прошлый раз.
            final moved = fetched.movedPermanently && fetched.finalUrl != podcast.feedUrl;
            if (moved) await _db.updateFeedUrl(podcastId, fetched.finalUrl);
            final cacheChanged = fetched.etag != podcast.etag || fetched.lastModified != podcast.lastModified;
            if (checked != null && !moved && !cacheChanged) {
              checked.add(podcastId);
            } else {
              await _db.markFeedNotModified(podcastId,
                  etag: Value(fetched.etag), lastModified: Value(fetched.lastModified));
            }
            return 0;
          }
          var url = podcast.feedUrl;
          if (fetched.movedPermanently && fetched.finalUrl != url) {
            url = fetched.finalUrl;
          } else if (feed.newFeedUrl != null && feed.newFeedUrl != url) {
            // Следующее обновление загрузит фид уже с нового адреса.
            url = feed.newFeedUrl!;
          }
          if (url != podcast.feedUrl && !await _db.updateFeedUrl(podcastId, url)) {
            url = podcast.feedUrl;
          }
          // ETag относится к адресу, с которого фид реально получен.
          final cacheValid = url == podcast.feedUrl || fetched.movedPermanently;
          final saved = await _db.saveParsedFeed(
            url,
            feed,
            etag: cacheValid ? fetched.etag : null,
            lastModified: cacheValid ? fetched.lastModified : null,
            contentHash: checkedFeed.hash,
          );
          return saved.newEpisodes;
      }
    } on PodcastException catch (e) {
      await _db.markFeedError(podcastId, e.message);
      rethrow;
    }
  }

  /// Обновляет все подписки, не больше [parallel] одновременно.
  ///
  /// [olderThan] — только подкасты, которые не проверялись дольше этого
  /// (при запуске приложения: только что проверенные фоновой задачей
  /// или прошлым запуском не трогаем).
  ///
  /// Неизменившиеся подкасты отмечаются проверенными одним запросом в конце:
  /// каждая запись в базу заставляет экраны перечитать списки, и десяток
  /// отдельных записей подряд давал десяток мелких подтормаживаний.
  Future<RefreshSummary> refreshAll({int parallel = 4, Duration? olderThan}) async {
    final now = DateTime.now();
    final podcasts = [
      for (final p in await _db.subscribedPodcasts())
        if (olderThan == null || p.lastCheckedAt == null || now.difference(p.lastCheckedAt!) >= olderThan) p,
    ];
    var added = 0;
    final failed = <int, String>{};
    final checked = <int>[];
    final queue = [...podcasts];

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final p = queue.removeLast();
        try {
          added += await refresh(p.id, checked: checked);
        } on PodcastException catch (e) {
          failed[p.id] = e.message;
        }
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    await _db.markFeedsChecked(checked);
    return RefreshSummary(newEpisodes: added, failed: failed);
  }

  Future<void> setSubscribed(int podcastId, bool subscribed) =>
      _db.setSubscribed(podcastId, subscribed);

  // -------------------------------------------------------------------------

  Future<_Loaded> _download(String url) async {
    final FetchResult result;
    try {
      result = await _fetcher.fetch(url);
    } on FeedFetchException catch (e) {
      throw PodcastException(e.message);
    }
    if (result is! FeedFetched) {
      // Без ETag сервер не может ответить 304; на всякий случай.
      throw const PodcastException('Сервер вернул пустой ответ.');
    }
    final finalUrl = result.movedPermanently ? result.finalUrl : url;
    final checked = await _parseSafely(result, finalUrl);
    return _Loaded(
      url: finalUrl,
      feed: checked.feed!,
      hash: checked.hash,
      etag: result.etag,
      lastModified: result.lastModified,
    );
  }

  Future<_Checked> _parseSafely(FeedFetched result, String feedUrl, {String? known}) async {
    try {
      return await _parseIfChanged(result.bytes, feedUrl, result.charset, known);
    } on FeedParseException catch (e) {
      throw PodcastException('Не удалось прочитать фид: ${e.message}');
    } catch (e) {
      // Ошибка в самом парсере не должна ронять обновление остальных подписок.
      throw PodcastException('Не удалось прочитать фид ($e).');
    }
  }

  Future<void> _save(int podcastId, _Loaded loaded) async {
    await _db.updateFeedUrl(podcastId, loaded.url);
    await _db.saveParsedFeed(
      loaded.url,
      loaded.feed,
      etag: loaded.etag,
      lastModified: loaded.lastModified,
      contentHash: loaded.hash,
    );
  }
}

class _Loaded {
  const _Loaded({required this.url, required this.feed, required this.hash, this.etag, this.lastModified});

  final String url;
  final ParsedFeed feed;
  final String hash;
  final String? etag;
  final String? lastModified;
}
