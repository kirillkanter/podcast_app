/// Операции с подкастами: добавление по ссылке, обновление, подписка.
/// Связывает загрузчик фидов, парсер и БД.
library;

import 'dart:isolate';

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

class PodcastRepository {
  PodcastRepository(this._db, this._fetcher, {FeedParserFn? parser})
      : _parse = parser ?? _parseInIsolate;

  final AppDatabase _db;
  final FeedFetcher _fetcher;
  final FeedParserFn _parse;

  /// Разбор большого фида может занять заметное время, поэтому он идёт
  /// в отдельном потоке, чтобы не подвисал интерфейс.
  static Future<ParsedFeed> _parseInIsolate(List<int> bytes, String feedUrl, String? charset) =>
      Isolate.run(() => parseFeedBytes(bytes, feedUrl: feedUrl, httpCharset: charset));

  /// Разбор в текущем потоке — для тестов.
  static Future<ParsedFeed> parseInPlace(List<int> bytes, String feedUrl, String? charset) async =>
      parseFeedBytes(bytes, feedUrl: feedUrl, httpCharset: charset);

  /// Добавляет подкаст по ссылке и подписывается на него.
  /// Возвращает id подкаста.
  Future<int> addAndSubscribe(String input) async {
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
      await _db.setSubscribed(existing.id, true);
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
      await _db.setSubscribed(already.id, true);
      await _save(already.id, loaded);
      return already.id;
    }

    final result = await _db.saveParsedFeed(
      loaded.url,
      loaded.feed,
      etag: loaded.etag,
      lastModified: loaded.lastModified,
    );
    await _db.setSubscribed(result.podcastId, true);
    return result.podcastId;
  }

  /// Обновляет один подкаст. Возвращает число новых эпизодов.
  /// Ошибку записывает в БД и пробрасывает как [PodcastException].
  Future<int> refresh(int podcastId) async {
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
          await _db.markFeedNotModified(podcastId);
          return 0;
        case final FeedFetched fetched:
          final feed = await _parseSafely(fetched, podcast.feedUrl);
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
          );
          return saved.newEpisodes;
      }
    } on PodcastException catch (e) {
      await _db.markFeedError(podcastId, e.message);
      rethrow;
    }
  }

  /// Обновляет все подписки, не больше [parallel] одновременно.
  Future<RefreshSummary> refreshAll({int parallel = 4}) async {
    final podcasts = await _db.subscribedPodcasts();
    var added = 0;
    final failed = <int, String>{};
    final queue = [...podcasts];

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final p = queue.removeLast();
        try {
          added += await refresh(p.id);
        } on PodcastException catch (e) {
          failed[p.id] = e.message;
        }
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
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
    final feed = await _parseSafely(result, finalUrl);
    return _Loaded(
      url: finalUrl,
      feed: feed,
      etag: result.etag,
      lastModified: result.lastModified,
    );
  }

  Future<ParsedFeed> _parseSafely(FeedFetched result, String feedUrl) async {
    try {
      return await _parse(result.bytes, feedUrl, result.charset);
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
    );
  }
}

class _Loaded {
  const _Loaded({required this.url, required this.feed, this.etag, this.lastModified});

  final String url;
  final ParsedFeed feed;
  final String? etag;
  final String? lastModified;
}
