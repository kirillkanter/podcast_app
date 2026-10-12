/// Каталог книг: модели для каталогов OPDS.
library;

import 'dart:convert';

/// Фильтр по языку.
enum CatalogLanguage {
  all('Все языки'),
  ru('Русский'),
  en('English');

  const CatalogLanguage(this.label);
  final String label;

  static CatalogLanguage from(String? name) =>
      CatalogLanguage.values.where((l) => l.name == name).firstOrNull ?? CatalogLanguage.all;

  /// Подходит ли книга с языком [code] (как в каталоге: 'ru', 'rus',
  /// 'Russian', 'en-US'…). Язык неизвестен — решаем по [title]: кириллица
  /// значит русский.
  bool matches(String? code, {String title = ''}) {
    if (this == CatalogLanguage.all) return true;
    final lang = normalizeLanguage(code) ?? (RegExp('[а-яА-ЯёЁ]').hasMatch(title) ? 'ru' : 'en');
    return lang == name;
  }
}

/// 'Russian', 'rus', 'ru-RU' → 'ru'; 'English', 'eng', 'en' → 'en';
/// остальное — двухбуквенный код или null.
String? normalizeLanguage(String? code) {
  if (code == null) return null;
  final c = code.trim().toLowerCase();
  if (c.isEmpty) return null;
  if (c.startsWith('ru') || c == 'russian' || c == 'русский') return 'ru';
  if (c.startsWith('en') || c == 'english') return 'en';
  if (c == 'german' || c == 'deu' || c == 'ger') return 'de';
  if (c == 'french' || c == 'fra' || c == 'fre') return 'fr';
  if (c == 'spanish' || c == 'spa') return 'es';
  if (c == 'italian' || c == 'ita') return 'it';
  return c.length >= 2 ? c.substring(0, 2) : c;
}

/// Жанр каталога: один список для всех источников.
class BookGenre {
  const BookGenre({
    required this.id,
    required this.name,
    required this.keywords,
    required this.searchTerm,
  });

  final String id;
  final String name;

  /// Начала слов в названиях разделов OPDS (русские и английские).
  final List<String> keywords;

  /// Запрос для поиска по каталогу OPDS, если подходящего раздела нет.
  final String searchTerm;

  /// Похоже ли название раздела каталога на этот жанр.
  bool matchesTitle(String title) {
    final t = title.toLowerCase();
    return keywords.any((k) => RegExp('(^|[^a-zа-яё])${RegExp.escape(k)}').hasMatch(t));
  }
}

const bookGenres = [
  BookGenre(
    id: 'classic',
    name: 'Классика',
    keywords: ['классик', 'классич', 'classic', 'литература', 'literature', 'русская проза', 'проза'],
    searchTerm: 'classic',
  ),
  BookGenre(
    id: 'scifi',
    name: 'Фантастика',
    keywords: ['фантаст', 'фэнтези', 'science fiction', 'sci-fi', 'fantasy'],
    searchTerm: 'science fiction',
  ),
  BookGenre(
    id: 'detective',
    name: 'Детективы',
    keywords: ['детектив', 'mystery', 'mysteries', 'detective', 'crime'],
    searchTerm: 'detective',
  ),
  BookGenre(
    id: 'adventure',
    name: 'Приключения',
    keywords: ['приключ', 'adventure'],
    searchTerm: 'adventure',
  ),
  BookGenre(
    id: 'poetry',
    name: 'Поэзия',
    keywords: ['поэз', 'стих', 'poetry', 'poems', 'verse'],
    searchTerm: 'poetry',
  ),
  BookGenre(
    id: 'children',
    name: 'Детям',
    keywords: ['детям', 'детск', 'для детей', 'сказк', 'children', 'juvenile', 'fairy tale', 'kids'],
    searchTerm: 'children',
  ),
  BookGenre(
    id: 'history',
    name: 'История',
    keywords: ['истор', 'history', 'historical'],
    searchTerm: 'history',
  ),
  BookGenre(
    id: 'philosophy',
    name: 'Философия',
    keywords: ['философ', 'philosophy'],
    searchTerm: 'philosophy',
  ),
  BookGenre(
    id: 'drama',
    name: 'Пьесы',
    keywords: ['пьес', 'драм', 'drama', 'plays', 'theatre', 'theater'],
    searchTerm: 'drama',
  ),
];

/// Ссылка на файл книги в каталоге OPDS.
class CatalogFile {
  const CatalogFile({required this.url, required this.format, this.size});

  final String url;

  /// 'epub', 'fb2', 'fbz' или 'txt'.
  final String format;
  final int? size;
}

/// Книга в каталоге (то, что видно в подборке, без файлов).
class CatalogBook {
  const CatalogBook({
    required this.id,
    required this.sourceName,
    required this.title,
    this.author,
    this.cover,
    this.thumbnail,
    this.language,
    this.description,
    this.webUrl,
    this.files = const [],
    this.detailsUrl,
    this.catalogId,
  });

  /// 'opds:<каталог>:<id записи>'.
  final String id;

  /// Название каталога OPDS.
  final String sourceName;
  final String title;
  final String? author;

  final String? cover;
  final String? thumbnail;
  final String? language;
  final String? description;

  /// Страница книги на сайте.
  final String? webUrl;

  /// Файлы, если каталог отдал их сразу (OPDS).
  final List<CatalogFile> files;

  /// Лента с подробностями (OPDS: книга в списке — ссылка на свою ленту).
  final String? detailsUrl;

  /// id каталога OPDS.
  final String? catalogId;

  String? get smallCover => thumbnail ?? cover;

  CatalogBook copyWith({
    String? author,
    String? cover,
    String? thumbnail,
    String? language,
    String? description,
    String? webUrl,
    List<CatalogFile>? files,
  }) =>
      CatalogBook(
        id: id,
        sourceName: sourceName,
        title: title,
        author: author ?? this.author,
        cover: cover ?? this.cover,
        thumbnail: thumbnail ?? this.thumbnail,
        language: language ?? this.language,
        description: description ?? this.description,
        webUrl: webUrl ?? this.webUrl,
        files: files ?? this.files,
        detailsUrl: detailsUrl,
        catalogId: catalogId,
      );
}

/// Подробности для страницы книги: файлы и размер.
class CatalogDetails {
  const CatalogDetails({required this.book, required this.files});

  final CatalogBook book;

  /// Варианты формата, лучший первым.
  final List<CatalogFile> files;

  int? get size => files.firstOrNull?.size;

  CatalogFile? get best => files.firstOrNull;
}

/// Подключённый каталог OPDS.
class OpdsCatalog {
  const OpdsCatalog({required this.id, required this.name, required this.url, this.login, this.password});

  final String id;
  final String name;
  final String url;
  final String? login;

  /// Пароль хранится отдельно (см. BookCatalog); здесь — только в памяти.
  final String? password;

  bool get private => login != null && login!.isNotEmpty;

  OpdsCatalog withPassword(String? password) =>
      OpdsCatalog(id: id, name: name, url: url, login: login, password: password);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'url': url, if (private) 'login': login};

  static OpdsCatalog? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'], url = json['url'], login = json['login'];
    if (id is! String || url is! String) return null;
    return OpdsCatalog(
      id: id,
      name: name is String && name.isNotEmpty ? name : Uri.tryParse(url)?.host ?? url,
      url: url,
      login: login is String ? login : null,
      password: json['password'] is String ? json['password'] as String : null,
    );
  }
}

/// Настройки каталога: всё в одной записи, чтобы видимость вкладки
/// менялась одним событием.
class CatalogConfig {
  const CatalogConfig({this.opds = const []});

  final List<OpdsCatalog> opds;

  /// Вкладка «Каталог» видна, только если добавлен хоть один каталог.
  bool get enabled => opds.isNotEmpty;

  CatalogConfig copyWith({List<OpdsCatalog>? opds}) => CatalogConfig(opds: opds ?? this.opds);

  String encode() => jsonEncode({'opds': [for (final c in opds) c.toJson()]});

  static CatalogConfig decode(String? raw) {
    if (raw == null || raw.isEmpty) return const CatalogConfig();
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const CatalogConfig();
      final list = json['opds'];
      return CatalogConfig(
        opds: [
          if (list is List)
            for (final item in list) ?OpdsCatalog.fromJson(item),
        ],
      );
    } catch (_) {
      return const CatalogConfig();
    }
  }
}

abstract final class BookCatalogSettings {
  /// [CatalogConfig] в JSON.
  static const config = 'bookCatalog.config';

  /// Выбранный язык каталога.
  static const language = 'bookCatalog.language';

  /// Что из каталога уже скачано: JSON {id в каталоге: id книги}.
  static const downloaded = 'bookCatalog.downloaded';
}

/// Каталоги, которые можно добавить одной кнопкой.
const opdsSuggestions = [
  (name: 'Project Gutenberg', url: 'https://www.gutenberg.org/ebooks.opds/'),
];

class BookCatalogException implements Exception {
  const BookCatalogException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// HTML из описания — в простой текст.
String catalogPlainText(String? html) {
  if (html == null) return '';
  var s = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
  return s.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n').trim();
}
