/// LibriVox: бесплатные аудиокниги из общественного достояния.
///
/// Записи LibriVox лежат в Internet Archive (коллекция librivoxaudio):
/// там есть поиск с сортировкой по числу скачиваний, темы для жанров,
/// обложки и MP3 по главам. Ключ API не нужен.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../books/book_scanner.dart' show naturalCompare;
import 'catalog_models.dart';

class LibriVoxSource {
  LibriVoxSource({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _host = 'archive.org';
  static const name = 'LibriVox';

  /// Запрос к поиску Internet Archive.
  static String query({BookGenre? genre, String? text, CatalogLanguage language = CatalogLanguage.all}) {
    final parts = ['collection:librivoxaudio'];
    if (genre != null) {
      parts.add('subject:(${genre.subjects.map((s) => '"$s"').join(' OR ')})');
    }
    switch (language) {
      case CatalogLanguage.ru:
        parts.add('language:(Russian OR rus)');
      case CatalogLanguage.en:
        parts.add('language:(English OR eng)');
      case CatalogLanguage.all:
        break;
    }
    final words = (text ?? '')
        .replaceAll(RegExp(r'[+\-&|!(){}\[\]^"~*?:\\/]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !const {'AND', 'OR', 'NOT'}.contains(w))
        .toList();
    if (words.isNotEmpty) {
      final w = words.join(' AND ');
      parts.add('(title:($w) OR creator:($w))');
    }
    return parts.join(' AND ');
  }

  static Uri searchUri(String q, {int rows = 30, int page = 1}) => Uri.https(_host, '/advancedsearch.php', {
        'q': q,
        'fl[]': ['identifier', 'title', 'creator', 'language', 'downloads'],
        'sort[]': 'downloads desc',
        'rows': '$rows',
        'page': '$page',
        'output': 'json',
      });

  /// Книги по жанру, запросу и языку — самые скачиваемые первыми.
  Future<List<CatalogBook>> list({
    BookGenre? genre,
    String? text,
    CatalogLanguage language = CatalogLanguage.all,
    int rows = 30,
    int page = 1,
  }) async {
    final body = await _get(searchUri(query(genre: genre, text: text, language: language), rows: rows, page: page));
    return parseSearch(body);
  }

  static List<CatalogBook> parseSearch(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      throw const BookCatalogException('LibriVox ответил непонятно');
    }
    final docs = json is Map && json['response'] is Map ? (json['response'] as Map)['docs'] : null;
    if (docs is! List) return const [];
    final out = <CatalogBook>[];
    for (final d in docs) {
      if (d is! Map) continue;
      final id = _str(d['identifier']);
      final title = _str(d['title']);
      if (id == null || title == null) continue;
      out.add(CatalogBook(
        id: 'lv:$id',
        source: CatalogSource.librivox,
        sourceName: name,
        title: cleanTitle(title),
        author: _str(d['creator']),
        audio: true,
        cover: 'https://$_host/services/img/$id',
        language: normalizeLanguage(_str(d['language'])),
        webUrl: 'https://$_host/details/$id',
      ));
    }
    return out;
  }

  /// Главы, размер, описание и обложка книги.
  Future<CatalogDetails> details(CatalogBook book) async {
    final id = book.id.substring(3);
    final body = await _get(Uri.https(_host, '/metadata/$id'));
    return parseMetadata(book, body);
  }

  static CatalogDetails parseMetadata(CatalogBook book, String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      throw const BookCatalogException('LibriVox ответил непонятно');
    }
    if (json is! Map) throw const BookCatalogException('Книга не найдена');
    final id = book.id.substring(3);
    final meta = json['metadata'] is Map ? json['metadata'] as Map : const {};
    final files = json['files'] is List ? (json['files'] as List).whereType<Map>().toList() : const <Map>[];

    // MP3 одного качества: 64 кбит/с (как в архивах LibriVox), иначе VBR,
    // иначе любые MP3.
    List<Map> mp3(bool Function(String format) ok) =>
        files.where((f) => ok((_str(f['format']) ?? '').toLowerCase()) && (_str(f['name']) ?? '').toLowerCase().endsWith('.mp3')).toList();
    var tracks = mp3((f) => f == '64kbps mp3');
    if (tracks.isEmpty) tracks = mp3((f) => f == 'vbr mp3');
    if (tracks.isEmpty) tracks = mp3((f) => f.contains('mp3'));
    if (tracks.isEmpty) tracks = mp3((_) => true);
    int? track(Map f) => int.tryParse((_str(f['track']) ?? '').split('/').first.trim());
    tracks.sort((a, b) {
      final ta = track(a), tb = track(b);
      if (ta != null && tb != null && ta != tb) return ta.compareTo(tb);
      return naturalCompare(_str(a['name'])!, _str(b['name'])!);
    });

    String download(String name) => Uri.https(_host, '/download/$id/$name').toString();

    final chapters = [
      for (final f in tracks)
        CatalogFile(
          url: download(_str(f['name'])!),
          format: 'mp3',
          size: int.tryParse(_str(f['size']) ?? ''),
          title: _str(f['title']),
          duration: parseLength(_str(f['length'])),
        ),
    ];
    // Обложка: самая большая JPEG, не миниатюра.
    final images = files.where((f) {
      final n = (_str(f['name']) ?? '').toLowerCase();
      return (n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png')) && !n.contains('thumb') && !n.startsWith('__ia_thumb');
    }).toList()
      ..sort((a, b) => (int.tryParse(_str(b['size']) ?? '') ?? 0).compareTo(int.tryParse(_str(a['size']) ?? '') ?? 0));
    final description = catalogPlainText(_str(meta['description']));
    return CatalogDetails(
      book: book.copyWith(
        author: _str(meta['creator']),
        language: normalizeLanguage(_str(meta['language'])),
        description: description.isEmpty ? null : description,
      ),
      files: chapters,
      coverFile: images.isEmpty ? book.cover : download(_str(images.first['name'])!),
    );
  }

  /// '1234.56' (секунды) или '20:34' / '1:02:03'.
  static Duration? parseLength(String? s) {
    if (s == null || s.isEmpty) return null;
    if (s.contains(':')) {
      var total = 0.0;
      for (final part in s.split(':')) {
        final v = double.tryParse(part);
        if (v == null) return null;
        total = total * 60 + v;
      }
      return Duration(milliseconds: (total * 1000).round());
    }
    final v = double.tryParse(s);
    return v == null ? null : Duration(milliseconds: (v * 1000).round());
  }

  /// «Twenty Thousand Leagues Under the Sea (version 2)» → без пометки версии.
  static String cleanTitle(String t) =>
      t.replaceAll(RegExp(r'\s*\((version|dramatic reading|abridged)[^)]*\)\s*$', caseSensitive: false), '').trim();

  Future<String> _get(Uri uri) async {
    final http.Response res;
    try {
      res = await _client.get(uri, headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const BookCatalogException('LibriVox не отвечает');
    } catch (_) {
      throw const BookCatalogException('Нет связи с LibriVox');
    }
    if (res.statusCode != 200) throw BookCatalogException('LibriVox: ошибка ${res.statusCode}');
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  static String? _str(Object? v) {
    if (v is List) v = v.isEmpty ? null : v.first;
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }
}
