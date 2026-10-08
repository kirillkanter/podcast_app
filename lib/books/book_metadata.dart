/// Обложки и описания книг из открытых каталогов: Google Books и Open Library.
/// Ищем по названию и автору; без ключей и регистрации.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Найденный вариант: обложка и что известно о книге.
class CoverCandidate {
  const CoverCandidate({
    required this.imageUrl,
    required this.source,
    this.title,
    this.author,
    this.description,
    this.year,
  });

  final String imageUrl;

  /// «Google Books» или «Open Library».
  final String source;
  final String? title;
  final String? author;
  final String? description;
  final int? year;
}

/// Название для поиска: без номеров, скобок, «аудиокнига», расширений.
String cleanSearchTitle(String title) {
  var t = title;
  t = t.replaceAll(RegExp(r'\.(mp3|m4b|m4a|epub|fb2|txt|zip)$', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'[\[\(\{][^\]\)\}]*[\]\)\}]'), ' ');
  t = t.replaceAll(RegExp(r'аудиокнига|audiobook|unabridged', caseSensitive: false), ' ');
  t = t.replaceAll(RegExp(r'^\s*\d{1,3}\s*[\.\-_]\s*'), '');
  t = t.replaceAll(RegExp(r'[_]+'), ' ');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

int? _year(Object? v) {
  final s = v?.toString();
  if (s == null) return null;
  final m = RegExp(r'\d{4}').firstMatch(s);
  return m == null ? null : int.parse(m.group(0)!);
}

/// Ответ Google Books → варианты (только с картинкой).
List<CoverCandidate> parseGoogleBooks(String body) {
  final out = <CoverCandidate>[];
  final json = jsonDecode(body);
  if (json is! Map || json['items'] is! List) return out;
  for (final item in json['items'] as List) {
    if (item is! Map) continue;
    final info = item['volumeInfo'];
    if (info is! Map) continue;
    final links = info['imageLinks'];
    if (links is! Map) continue;
    var url = _str(links['extraLarge']) ??
        _str(links['large']) ??
        _str(links['medium']) ??
        _str(links['thumbnail']) ??
        _str(links['smallThumbnail']);
    if (url == null) continue;
    url = url.replaceFirst('http://', 'https://').replaceAll('&edge=curl', '');
    if (!url.contains('fife=')) url = '$url&fife=w800';
    final authors = info['authors'];
    out.add(CoverCandidate(
      imageUrl: url,
      source: 'Google Books',
      title: _str(info['title']),
      author: authors is List && authors.isNotEmpty ? authors.whereType<String>().join(', ') : null,
      description: _str(info['description']),
      year: _year(info['publishedDate']),
    ));
  }
  return out;
}

/// Ответ поиска Open Library → варианты (только с обложкой).
List<CoverCandidate> parseOpenLibrary(String body) {
  final out = <CoverCandidate>[];
  final json = jsonDecode(body);
  if (json is! Map || json['docs'] is! List) return out;
  for (final doc in json['docs'] as List) {
    if (doc is! Map) continue;
    final id = doc['cover_i'];
    if (id is! int || id <= 0) continue;
    final authors = doc['author_name'];
    out.add(CoverCandidate(
      imageUrl: 'https://covers.openlibrary.org/b/id/$id-L.jpg',
      source: 'Open Library',
      title: _str(doc['title']),
      author: authors is List && authors.isNotEmpty ? authors.whereType<String>().take(2).join(', ') : null,
      year: _year(doc['first_publish_year']),
    ));
  }
  return out;
}

class BookMetadata {
  BookMetadata({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _timeout = Duration(seconds: 12);

  /// Варианты обложек из обоих каталогов: сначала Google Books.
  /// Ошибка одного каталога не мешает другому.
  Future<List<CoverCandidate>> search(String title, {String? author, int limit = 12}) async {
    final t = cleanSearchTitle(title);
    if (t.isEmpty) return const [];
    final a = author?.trim();
    final results = await Future.wait([
      _google(t, a).catchError((_) => const <CoverCandidate>[]),
      _openLibrary(t, a).catchError((_) => const <CoverCandidate>[]),
    ]);
    final seen = <String>{};
    final out = <CoverCandidate>[];
    // Чередуем источники, чтобы в первых вариантах были оба.
    for (var i = 0; out.length < limit; i++) {
      var added = false;
      for (final list in results) {
        if (i < list.length) {
          added = true;
          if (seen.add(list[i].imageUrl)) out.add(list[i]);
        }
      }
      if (!added) break;
    }
    return out.take(limit).toList();
  }

  Future<List<CoverCandidate>> _google(String title, String? author) async {
    final q = StringBuffer('intitle:$title');
    if (author != null && author.isNotEmpty) q.write(' inauthor:$author');
    final uri = Uri.https('www.googleapis.com', '/books/v1/volumes', {'q': q.toString(), 'maxResults': '10', 'printType': 'books'});
    final r = await _client.get(uri).timeout(_timeout);
    if (r.statusCode != 200) return const [];
    var list = parseGoogleBooks(utf8.decode(r.bodyBytes));
    if (list.isEmpty && author != null && author.isNotEmpty) {
      // Автор записан иначе — ищем только по названию.
      final r2 = await _client
          .get(Uri.https('www.googleapis.com', '/books/v1/volumes', {'q': 'intitle:$title', 'maxResults': '10'}))
          .timeout(_timeout);
      if (r2.statusCode == 200) list = parseGoogleBooks(utf8.decode(r2.bodyBytes));
    }
    return list;
  }

  Future<List<CoverCandidate>> _openLibrary(String title, String? author) async {
    final params = {'title': title, 'limit': '10', 'fields': 'title,author_name,cover_i,first_publish_year'};
    if (author != null && author.isNotEmpty) params['author'] = author;
    final r = await _client.get(Uri.https('openlibrary.org', '/search.json', params)).timeout(_timeout);
    if (r.statusCode != 200) return const [];
    return parseOpenLibrary(utf8.decode(r.bodyBytes));
  }

  /// Скачать картинку; `null` — не картинка или слишком маленькая
  /// (Open Library отдаёт пиксель-заглушку, если обложки нет).
  Future<Uint8List?> download(String url) async {
    final r = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return null;
    final b = r.bodyBytes;
    if (b.length < 2000) return null;
    final jpeg = b[0] == 0xFF && b[1] == 0xD8;
    final png = b[0] == 0x89 && b[1] == 0x50;
    final webp = b.length > 12 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;
    return jpeg || png || webp ? b : null;
  }

  void close() => _client.close();
}
