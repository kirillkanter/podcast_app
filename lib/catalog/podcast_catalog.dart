/// Каталог подкастов: поиск и популярное через открытые API Apple Podcasts.
///
/// Ключ API не нужен. iTunes Search API ищет по названию и автору,
/// а чарт «популярное» берётся из RSS-ленты Apple Marketing Tools
/// и дополняется адресами фидов через iTunes Lookup.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show ValueNotifier;
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

/// Рубрика Apple Podcasts для подборок.
class CatalogGenre {
  const CatalogGenre(this.id, this.name);

  /// id жанра в Apple Podcasts.
  final int id;
  final String name;
}

/// Рубрики подборок на экране поиска, в порядке показа.
const catalogGenres = [
  CatalogGenre(1489, 'Новости'),
  CatalogGenre(1324, 'Общество'),
  CatalogGenre(1321, 'Бизнес'),
  CatalogGenre(1533, 'Наука'),
  CatalogGenre(1318, 'Технологии'),
  CatalogGenre(1487, 'История'),
  CatalogGenre(1303, 'Юмор'),
  CatalogGenre(1304, 'Образование'),
  CatalogGenre(1301, 'Искусство'),
  CatalogGenre(1512, 'Здоровье'),
  CatalogGenre(1488, 'Тру-крайм'),
  CatalogGenre(1309, 'Кино и сериалы'),
  CatalogGenre(1545, 'Спорт'),
  CatalogGenre(1310, 'Музыка'),
  CatalogGenre(1305, 'Дети и семья'),
];

class CatalogException implements Exception {
  const CatalogException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Ключ настройки региона каталога (двухбуквенный код; пусто — как в системе).
abstract final class CatalogSettings {
  static const country = 'catalog.country';
}

/// Регионы каталога для выбора в настройках.
const catalogCountries = {
  'ru': 'Россия',
  'kz': 'Казахстан',
  'by': 'Беларусь',
  'ua': 'Украина',
  'uz': 'Узбекистан',
  'ge': 'Грузия',
  'am': 'Армения',
  'rs': 'Сербия',
  'tr': 'Турция',
  'il': 'Израиль',
  'de': 'Германия',
  'fr': 'Франция',
  'es': 'Испания',
  'it': 'Италия',
  'gb': 'Великобритания',
  'us': 'США',
};

class PodcastCatalog {
  PodcastCatalog({http.Client? client, String? country, String? defaultCountry})
      : _client = client ?? http.Client(),
        defaultCountry = (defaultCountry ?? country ?? 'us').toLowerCase(),
        region = ValueNotifier((country ?? 'us').toLowerCase());

  final http.Client _client;

  /// Регион системы — используется, когда в настройках выбрано «как в системе».
  final String defaultCountry;

  /// Текущий регион; экран поиска перезагружает подборки при его смене.
  final ValueNotifier<String> region;

  /// Двухбуквенный код страны: влияет на «популярное» и порядок выдачи.
  String get country => region.value;

  /// Сменить регион ([code] = null — как в системе). Сохранённые чарты
  /// прежнего региона забываются.
  void setCountry(String? code) {
    final next = (code == null || code.isEmpty ? defaultCountry : code).toLowerCase();
    if (next == region.value) return;
    _charts.clear();
    region.value = next;
  }

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

  final _charts = <int?, Future<List<CatalogPodcast>>>{};

  /// Чарт рубрики [genreId] (`null` — все подкасты) без адресов фидов:
  /// быстро, для обложек в подборках. Адреса — через [withFeeds].
  /// Результат запоминается на время работы приложения.
  Future<List<CatalogPodcast>> chart({int? genreId, int limit = 50}) {
    final future = _charts.putIfAbsent(genreId, () => _chart(genreId, limit));
    // Ошибку не запоминаем: в следующий раз — новая попытка.
    future.catchError((Object _) {
      _charts.remove(genreId);
      return const <CatalogPodcast>[];
    });
    return future;
  }

  Future<List<CatalogPodcast>> _chart(int? genreId, int limit) async {
    // Старая лента iTunes: единственная, где есть чарты по рубрикам.
    final path = genreId == null
        ? '/$country/rss/toppodcasts/limit=$limit/json'
        : '/$country/rss/toppodcasts/limit=$limit/genre=$genreId/json';
    return parseChart(await _getJson(Uri.https('itunes.apple.com', path)));
  }

  /// Разбор старой ленты чартов iTunes: feed.entry — список (или один объект).
  static List<CatalogPodcast> parseChart(Object? data) {
    final feed = data is Map<String, Object?> ? data['feed'] : null;
    var entries = feed is Map<String, Object?> ? feed['entry'] : null;
    if (entries is Map) entries = [entries];
    if (entries is! List) return const [];
    String? label(Object? v) => v is Map ? _str(v['label']) : null;
    final out = <CatalogPodcast>[];
    for (final e in entries) {
      if (e is! Map) continue;
      final idAttr = e['id'] is Map ? (e['id'] as Map)['attributes'] : null;
      final id = idAttr is Map ? _str(idAttr['im:id']) : null;
      final title = label(e['im:name']);
      if (id == null || title == null) continue;
      final images = e['im:image'];
      final image = images is List && images.isNotEmpty ? label(images.last) : null;
      final cat = e['category'] is Map ? (e['category'] as Map)['attributes'] : null;
      out.add(CatalogPodcast(
        id: id,
        title: title,
        author: label(e['im:artist']),
        // Картинка чарта маленькая (170 px): просим крупнее.
        artworkUrl: image?.replaceFirst(RegExp(r'/\d+x\d+(bb)?\.(png|jpg)$'), '/600x600bb.jpg'),
        genre: cat is Map ? _str(cat['label']) : null,
      ));
    }
    return out;
  }

  /// Дополняет подкасты адресами фидов (одним запросом iTunes Lookup).
  Future<List<CatalogPodcast>> withFeeds(List<CatalogPodcast> items) async {
    final missing = [for (final p in items) if (p.feedUrl == null) p.id];
    if (missing.isEmpty) return items;
    final byId = <String, CatalogPodcast>{};
    for (var i = 0; i < missing.length; i += 150) {
      final ids = missing.sublist(i, i + 150 > missing.length ? missing.length : i + 150);
      final lookup = await _getJson(Uri.https('itunes.apple.com', '/lookup', {
        'id': ids.join(','),
        'entity': 'podcast',
        'country': country,
      }));
      for (final p in _parseItunesResults(lookup)) {
        byId[p.id] = p;
      }
    }
    return [
      for (final p in items)
        if (p.feedUrl != null)
          p
        else
          CatalogPodcast(
            id: p.id,
            title: p.title,
            author: p.author ?? byId[p.id]?.author,
            feedUrl: byId[p.id]?.feedUrl,
            artworkUrl: byId[p.id]?.artworkUrl ?? p.artworkUrl,
            genre: p.genre ?? byId[p.id]?.genre,
            episodeCount: byId[p.id]?.episodeCount,
          ),
    ];
  }

  void close() => _client.close();

  Future<Object?> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'user-agent': 'BasicCaster/0.8 (+https://bcaster.ru)'})
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
