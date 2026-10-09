/// Каталоги OPDS 1.x (Atom): разделы, книги с файлами, поиск, страницы.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'catalog_models.dart';

/// Ссылка на раздел каталога.
class OpdsNav {
  const OpdsNav(this.title, this.url);
  final String title;
  final String url;
}

/// Разобранная лента OPDS.
class OpdsFeed {
  const OpdsFeed({
    required this.title,
    required this.books,
    required this.sections,
    this.next,
    this.search,
    this.searchDescription,
  });

  final String title;
  final List<CatalogBook> books;
  final List<OpdsNav> sections;

  /// Следующая страница.
  final String? next;

  /// Шаблон поиска с {searchTerms}.
  final String? search;

  /// Адрес описания OpenSearch (шаблон внутри).
  final String? searchDescription;
}

const _acquisition = 'http://opds-spec.org/acquisition';

/// Формат файла по MIME-типу: 'epub', 'fb2', 'fbz', 'txt' или null.
String? opdsFormat(String? type) {
  if (type == null) return null;
  final t = type.toLowerCase().split(';').first.trim();
  if (t == 'application/epub+zip') return 'epub';
  if (t.contains('fb2') && t.contains('zip')) return 'fbz';
  if (t == 'application/fb2' || t.contains('fictionbook') || t == 'text/fb2+xml' || t == 'application/fb2+xml') {
    return 'fb2';
  }
  if (t == 'text/plain') return 'txt';
  return null;
}

const _formatRank = {'epub': 0, 'fb2': 1, 'fbz': 2, 'txt': 3};

OpdsFeed parseOpdsFeed(String body, Uri base, {required String catalogId, required String catalogName}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } catch (_) {
    throw const BookCatalogException('Это не каталог OPDS: ответ не похож на ленту Atom');
  }
  final feed = doc.rootElement;
  if (feed.localName != 'feed') {
    throw const BookCatalogException('Это не каталог OPDS: ответ не похож на ленту Atom');
  }
  String? abs(String? href) {
    if (href == null || href.trim().isEmpty) return null;
    try {
      return base.resolve(href.trim()).toString();
    } catch (_) {
      return null;
    }
  }

  String? text(XmlElement e, String name) {
    final child = e.childElements.where((c) => c.localName == name).firstOrNull;
    final t = child?.innerText.trim();
    return t == null || t.isEmpty ? null : t;
  }

  String? next, search, searchDescription;
  for (final link in feed.childElements.where((c) => c.localName == 'link')) {
    final rel = link.getAttribute('rel');
    final type = link.getAttribute('type') ?? '';
    final href = link.getAttribute('href');
    if (rel == 'next') next = abs(href);
    if (rel == 'search') {
      if (type.contains('opensearchdescription')) {
        searchDescription = abs(href);
      } else if (href != null && href.contains('{searchTerms}')) {
        // Шаблон нельзя прогонять через Uri: фигурные скобки закодируются.
        search = resolveTemplate(base, href);
      }
    }
  }

  final books = <CatalogBook>[];
  final sections = <OpdsNav>[];
  for (final entry in feed.childElements.where((c) => c.localName == 'entry')) {
    final title = text(entry, 'title');
    if (title == null) continue;
    final id = text(entry, 'id') ?? title;
    final files = <CatalogFile>[];
    String? cover, thumbnail, nav, web;
    for (final link in entry.childElements.where((c) => c.localName == 'link')) {
      final rel = link.getAttribute('rel') ?? '';
      final type = link.getAttribute('type') ?? '';
      final href = abs(link.getAttribute('href'));
      if (href == null) continue;
      if (rel.startsWith(_acquisition)) {
        final format = opdsFormat(type);
        if (format != null) {
          files.add(CatalogFile(url: href, format: format, size: int.tryParse(link.getAttribute('length') ?? '')));
        }
      } else if (rel == 'http://opds-spec.org/image' || rel == 'http://opds-spec.org/cover' || rel == 'x-stanza-cover-image') {
        cover = href;
      } else if (rel == 'http://opds-spec.org/image/thumbnail' ||
          rel == 'http://opds-spec.org/thumbnail' ||
          rel == 'x-stanza-cover-image-thumbnail') {
        thumbnail = href;
      } else if (type.contains('atom+xml') || type.contains('opds-catalog')) {
        if (rel != 'alternate' || nav == null) nav ??= href;
      } else if (rel == 'alternate' && type.contains('html')) {
        web = href;
      }
    }
    final author = entry.childElements
        .where((c) => c.localName == 'author')
        .map((a) => text(a, 'name') ?? a.innerText.trim())
        .where((s) => s.isNotEmpty)
        .join(', ');
    final language = text(entry, 'language');
    final summary = text(entry, 'summary') ?? text(entry, 'content');
    files.sort((a, b) => (_formatRank[a.format] ?? 9).compareTo(_formatRank[b.format] ?? 9));
    // Книга: есть файлы. Запись-ссылка с автором или обложкой — тоже
    // книга (Project Gutenberg так отдаёт результаты поиска), файлы
    // будут в её ленте. Остальное — разделы.
    final isBook = files.isNotEmpty || (nav != null && (author.isNotEmpty || cover != null || thumbnail != null));
    if (isBook) {
      books.add(CatalogBook(
        id: 'opds:$catalogId:$id',
        source: CatalogSource.opds,
        sourceName: catalogName,
        title: title,
        author: author.isEmpty ? (files.isEmpty ? _authorFromContent(summary) : null) : author,
        audio: false,
        cover: cover,
        thumbnail: thumbnail,
        language: normalizeLanguage(language),
        description: files.isEmpty && _authorFromContent(summary) != null ? null : _clean(summary),
        webUrl: web,
        files: files,
        detailsUrl: files.isEmpty ? nav : null,
        catalogId: catalogId,
      ));
    } else if (nav != null) {
      sections.add(OpdsNav(title, nav));
    }
  }
  return OpdsFeed(
    title: text(feed, 'title') ?? catalogName,
    books: books,
    sections: sections,
    next: next,
    search: search,
    searchDescription: searchDescription,
  );
}

/// У Project Gutenberg в результатах поиска в content — только автор.
String? _authorFromContent(String? s) {
  if (s == null) return null;
  final t = s.trim();
  return t.isNotEmpty && t.length < 80 && !t.contains('\n') ? t : null;
}

String? _clean(String? s) {
  final t = catalogPlainText(s);
  return t.isEmpty ? null : t;
}

/// Относительный шаблон поиска — в полный адрес. Через Uri целиком его
/// не провести: фигурные скобки закодируются.
String resolveTemplate(Uri base, String t) {
  if (t.startsWith('http://') || t.startsWith('https://')) return t;
  final i = t.indexOf('{');
  final head = i < 0 ? t : t.substring(0, i);
  final tail = i < 0 ? '' : t.substring(i);
  return base.resolve(head).toString() + tail;
}

/// Шаблон из описания OpenSearch.
String? parseOpenSearch(String body, Uri base) {
  try {
    final doc = XmlDocument.parse(body);
    final urls = doc.findAllElements('Url', namespace: '*').toList();
    urls.sort((a, b) => _searchRank(a.getAttribute('type')).compareTo(_searchRank(b.getAttribute('type'))));
    for (final u in urls) {
      final t = u.getAttribute('template');
      if (t == null || !t.contains('{searchTerms}')) continue;
      if (_searchRank(u.getAttribute('type')) > 1) continue;
      return resolveTemplate(base, t);
    }
  } catch (_) {}
  return null;
}

int _searchRank(String? type) {
  final t = type ?? '';
  if (t.contains('opds-catalog')) return 0;
  if (t.contains('atom')) return 1;
  return 2;
}

/// Подставить запрос в шаблон: {searchTerms} — текст, прочие {параметры} — пусто.
String fillSearchTemplate(String template, String query) => template
    .replaceAll('{searchTerms}', Uri.encodeQueryComponent(query))
    .replaceAll(RegExp(r'\{[^}]*\?\}'), '')
    .replaceAll(RegExp(r'\{startPage\}'), '1')
    .replaceAll(RegExp(r'\{startIndex\}'), '0')
    .replaceAll(RegExp(r'\{count\}'), '30')
    .replaceAll(RegExp(r'\{[^}]*\}'), '');

class OpdsSource {
  OpdsSource(this.catalog, {http.Client? client}) : _client = client ?? http.Client();

  final OpdsCatalog catalog;
  final http.Client _client;

  Future<OpdsFeed>? _root;
  Future<String?>? _template;

  Map<String, String> get authHeaders => catalog.private
      ? {'Authorization': 'Basic ${base64Encode(utf8.encode('${catalog.login}:${catalog.password ?? ''}'))}'}
      : const {};

  /// Заголовки для скачивания файла по [url]: пароль — только своему сайту.
  Map<String, String> headersFor(String url) {
    final host = Uri.tryParse(url)?.host;
    return host != null && host == Uri.tryParse(catalog.url)?.host ? authHeaders : const {};
  }

  Future<OpdsFeed> root() => _root ??= fetch(catalog.url).catchError((Object e) {
        _root = null;
        throw e;
      });

  Future<OpdsFeed> fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) throw const BookCatalogException('Неверный адрес каталога');
    final body = await _get(uri, accept: 'application/atom+xml;profile=opds-catalog, application/atom+xml, */*;q=0.5');
    return parseOpdsFeed(body, uri, catalogId: catalog.id, catalogName: catalog.name);
  }

  /// Подборка для главной: раздел «Популярное»/«Новое», иначе книги
  /// из корня каталога.
  Future<List<CatalogBook>> popular() async {
    final root = await this.root();
    if (root.books.isNotEmpty) return root.books;
    final nav = _find(root.sections, const ['популяр', 'popular', 'top', 'лучш', 'best', 'нов', 'new', 'recent', 'latest']);
    if (nav == null) return const [];
    return (await fetch(nav.url)).books;
  }

  /// Книги жанра: раздел с подходящим названием (в корне или в разделе
  /// «Жанры»), иначе — поиск по названию жанра.
  Future<List<CatalogBook>> genre(BookGenre genre) async {
    final root = await this.root();
    var nav = root.sections.where((s) => genre.matchesTitle(s.title)).firstOrNull;
    if (nav == null) {
      final folder = _find(root.sections,
          const ['жанр', 'genre', 'subject', 'категор', 'categor', 'рубрик', 'тем', 'bookshel', 'полк', 'collection', 'коллекц']);
      if (folder != null) {
        try {
          final sub = await fetch(folder.url);
          nav = sub.sections.where((s) => genre.matchesTitle(s.title)).firstOrNull;
        } catch (_) {}
      }
    }
    if (nav != null) {
      final feed = await fetch(nav.url);
      if (feed.books.isNotEmpty) return feed.books;
      // Раздел жанра бывает списком подразделов: берём первый с книгами.
      for (final sub in feed.sections.take(3)) {
        try {
          final books = (await fetch(sub.url)).books;
          if (books.isNotEmpty) return books;
        } catch (_) {}
      }
    }
    if (await _searchTemplate() != null) return search(genre.searchTerm);
    return const [];
  }

  Future<List<CatalogBook>> search(String query) async {
    final template = await _searchTemplate();
    if (template == null) return const [];
    return (await fetch(fillSearchTemplate(template, query))).books;
  }

  Future<String?> _searchTemplate() => _template ??= () async {
        final root = await this.root();
        if (root.search != null) return root.search;
        if (root.searchDescription != null) {
          try {
            final uri = Uri.parse(root.searchDescription!);
            return parseOpenSearch(await _get(uri, accept: 'application/opensearchdescription+xml, */*'), uri);
          } catch (_) {}
        }
        return null;
      }();

  /// Файлы книги: если в списке их не было — из ленты книги.
  Future<CatalogDetails> details(CatalogBook book) async {
    var b = book;
    if (b.files.isEmpty && b.detailsUrl != null) {
      final feed = await fetch(b.detailsUrl!);
      final full = feed.books.where((x) => x.files.isNotEmpty).firstOrNull;
      if (full != null) {
        b = b.copyWith(
          author: full.author,
          cover: full.cover,
          thumbnail: full.thumbnail,
          language: full.language,
          description: full.description,
          webUrl: full.webUrl,
          files: full.files,
        );
      }
    }
    return CatalogDetails(book: b, files: b.files);
  }

  OpdsNav? _find(List<OpdsNav> sections, List<String> words) {
    for (final w in words) {
      final hit = sections.where((s) => s.title.toLowerCase().contains(w)).firstOrNull;
      if (hit != null) return hit;
    }
    return null;
  }

  Future<String> _get(Uri uri, {required String accept}) async {
    final http.Response res;
    try {
      res = await _client
          .get(uri, headers: {'Accept': accept, ...headersFor(uri.toString())})
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw BookCatalogException('${catalog.name}: каталог не отвечает');
    } catch (_) {
      throw BookCatalogException('${catalog.name}: нет связи с каталогом');
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw BookCatalogException(
          catalog.private ? '${catalog.name}: неверный логин или пароль' : '${catalog.name}: каталог просит логин и пароль');
    }
    if (res.statusCode == 404) throw BookCatalogException('${catalog.name}: адрес не найден');
    if (res.statusCode != 200) throw BookCatalogException('${catalog.name}: ошибка ${res.statusCode}');
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }
}
