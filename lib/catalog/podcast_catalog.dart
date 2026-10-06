/// Каталог подкастов: поиск и популярное через открытые API Apple Podcasts.
///
/// Ключ API не нужен. iTunes Search API ищет по названию и автору,
/// а чарт «популярное» берётся из RSS-ленты Apple Marketing Tools
/// и дополняется адресами фидов через iTunes Lookup.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

class CatalogPodcast {
  const CatalogPodcast({
    required this.id,
    required this.title,
    this.author,
    this.feedUrl,
    this.artworkUrl,
    this.genre,
    this.episodeCount,
  });

  /// id в Apple Podcasts.
  final String id;
  final String title;
  final String? author;

  /// `null` — подкаст доступен только в Apple Podcasts, открытого RSS нет.
  final String? feedUrl;
  final String? artworkUrl;
  final String? genre;
  final int? episodeCount;
}

class CatalogException implements Exception {
  const CatalogException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PodcastCatalog {
  PodcastCatalog({http.Client? client, String? country})
      : _client = client ?? http.Client(),
        country = (country ?? 'us').toLowerCase();

  final http.Client _client;

  /// Двухбуквенный код страны: влияет на «популярное» и порядок выдачи.
  final String country;

  static const _timeout = Duration(seconds: 20);

  /// Поиск по названию и автору.
  Future<List<CatalogPodcast>> search(String term, {int limit = 50}) async {
    final query = term.trim();
    if (query.isEmpty) return const [];
    final data = await _getJson(Uri.https('itunes.apple.com', '/search', {
      'media': 'podcast',
      'entity': 'podcast',
      'term': query,
      'country': country,
      'limit': '$limit',
    }));
    return _parseItunesResults(data);
  }

  /// Популярные подкасты в стране [country].
  Future<List<CatalogPodcast>> top({int limit = 50}) async {
    final chart = await _getJson(Uri.https(
      'rss.marketingtools.apple.com',
      '/api/v2/$country/podcasts/top/$limit/podcasts.json',
    ));
    final feed = chart is Map<String, Object?> ? chart['feed'] : null;
    final results = feed is Map<String, Object?> ? feed['results'] : null;
    if (results is! List) return const [];
    final ids = [
      for (final r in results)
        if (r is Map<String, Object?> && r['id'] is String) r['id']! as String,
    ];
    if (ids.isEmpty) return const [];

    // В чарте нет адресов фидов: дозапрашиваем их пачкой.
    final lookup = await _getJson(Uri.https('itunes.apple.com', '/lookup', {
      'id': ids.join(','),
      'entity': 'podcast',
      'country': country,
    }));
    final byId = {for (final p in _parseItunesResults(lookup)) p.id: p};
    // Порядок — как в чарте.
    return [for (final id in ids) ?byId[id]];
  }

  void close() => _client.close();

  Future<Object?> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'user-agent': 'BasicCaster/0.7 (+https://bcaster.ru)'})
          .timeout(_timeout);
    } on TimeoutException {
      throw const CatalogException('Каталог не ответил вовремя. Попробуйте позже.');
    } on SocketException {
      throw const CatalogException('Нет соединения с интернетом.');
    } on http.ClientException catch (e) {
      throw CatalogException('Ошибка соединения: ${e.message}');
    }
    if (response.statusCode != 200) {
      throw CatalogException('Каталог вернул ошибку (код ${response.statusCode}).');
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const CatalogException('Каталог вернул некорректный ответ.');
    }
  }

  static List<CatalogPodcast> _parseItunesResults(Object? data) {
    final results = data is Map<String, Object?> ? data['results'] : null;
    if (results is! List) return const [];
    return [
      for (final r in results)
        if (r is Map<String, Object?> && _str(r['collectionName']) != null && r['collectionId'] != null)
          CatalogPodcast(
            id: '${r['collectionId']}',
            title: _str(r['collectionName'])!,
            author: _str(r['artistName']),
            feedUrl: _str(r['feedUrl']),
            artworkUrl: _str(r['artworkUrl600']) ?? _str(r['artworkUrl100']),
            genre: _str(r['primaryGenreName']),
            episodeCount: r['trackCount'] is int ? r['trackCount']! as int : null,
          ),
    ];
  }

  static String? _str(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
}
