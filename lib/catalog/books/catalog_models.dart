/// Каталог книг и аудиокниг: общие модели для LibriVox и каталогов OPDS.
library;

import 'dart:convert';

/// Откуда книга в каталоге.
enum CatalogSource { librivox, opds }

/// Фильтр по типу.
enum CatalogKind {
  all('Все'),
  audio('Аудиокниги'),
  text('Книги');

  const CatalogKind(this.label);
  final String label;
}

/// Фильтр по языку. LibriVox почти весь на английском, поэтому язык
/// выбирается отдельно от жанра.
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
    required this.subjects,
    required this.keywords,
    required this.searchTerm,
  });

  final String id;
  final String name;

  /// Темы (subject) записей LibriVox в Internet Archive.
  final List<String> subjects;

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
    subjects: ['classic', 'classics', 'literary fiction', 'general fiction', 'literature'],
    keywords: ['классик', 'классич', 'classic', 'литература', 'literature', 'русская проза', 'проза'],
    searchTerm: 'classic',
  ),
  BookGenre(
    id: 'scifi',
    name: 'Фантастика',
    subjects: ['science fiction', 'fantasy', 'fantastic fiction', 'sci-fi'],
    keywords: ['фантаст', 'фэнтези', 'science fiction', 'sci-fi', 'fantasy'],
    searchTerm: 'science fiction',
  ),
  BookGenre(
    id: 'detective',
    name: 'Детективы',
    subjects: ['detective', 'mystery', 'detective fiction', 'crime'],
    keywords: ['детектив', 'mystery', 'mysteries', 'detective', 'crime'],
    searchTerm: 'detective',
  ),
  BookGenre(
    id: 'adventure',
    name: 'Приключения',
    subjects: ['adventure', 'action & adventure fiction', 'adventures'],
    keywords: ['приключ', 'adventure'],
    searchTerm: 'adventure',
  ),
  BookGenre(
    id: 'poetry',
    name: 'Поэзия',
    subjects: ['poetry', 'poems', 'poem'],
    keywords: ['поэз', 'стих', 'poetry', 'poems', 'verse'],
    searchTerm: 'poetry',
  ),
  BookGenre(
    id: 'children',
    name: 'Детям',
    subjects: ['children', "children's fiction", "children's literature", 'juvenile fiction', 'fairy tales'],
    keywords: ['детям', 'детск', 'для детей', 'сказк', 'children', 'juvenile', 'fairy tale', 'kids'],
    searchTerm: 'children',
  ),
  BookGenre(
    id: 'history',
    name: 'История',
    subjects: ['history', 'historical'],
    keywords: ['истор', 'history', 'historical'],
    searchTerm: 'history',
  ),
  BookGenre(
    id: 'philosophy',
    name: 'Философия',
    subjects: ['philosophy'],
    keywords: ['философ', 'philosophy'],
    searchTerm: 'philosophy',
  ),
  BookGenre(
    id: 'drama',
    name: 'Пьесы',
    subjects: ['drama', 'plays', 'play', 'dramatic readings', 'theatre'],
    keywords: ['пьес', 'драм', 'drama', 'plays', 'theatre', 'theater'],
    searchTerm: 'drama',
  ),
];

/// Ссылка на файл книги в каталоге OPDS.
class CatalogFile {
  const CatalogFile({required this.url, required this.format, this.size, this.title, this.duration});

  final String url;

  /// 'epub', 'fb2', 'fbz', 'txt' или 'mp3'.
  final String format;
  final int? size;

  /// Название главы (для аудио).
  final String? title;
  final Duration? duration;
}

/// Книга в каталоге (то, что видно в подборке, без файлов).
class CatalogBook {
  const CatalogBook({
    required this.id,
    required this.source,
    required this.sourceName,
    required this.title,
    required this.audio,
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

  /// 'lv:<идентификатор в Internet Archive>' или 'opds:<каталог>:<id записи>'.
  final String id;
  final CatalogSource source;

  /// «LibriVox» или название каталога OPDS.
  final String sourceName;
  final String title;
  final String? author;

  /// Аудиокнига (иначе — текстовая).
  final bool audio;
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
        source: source,
        sourceName: sourceName,
        title: title,
        audio: audio,
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

/// Подробности для страницы книги: файлы, главы, размер.
class CatalogDetails {
  const CatalogDetails({required this.book, required this.files, this.coverFile});

  final CatalogBook book;

  /// Аудиокнига — главы по порядку; текстовая — варианты формата,
  /// лучший первым.
  final List<CatalogFile> files;

  /// Картинка обложки для аудиокниги (кладётся в папку книги).
  final String? coverFile;

  int? get size {
    if (files.isEmpty) return null;
    if (!book.audio) return files.first.size;
    if (files.any((f) => f.size == null)) return null;
    return files.fold<int>(0, (s, f) => s + f.size!);
  }

  Duration? get duration {
    if (!book.audio || files.isEmpty || files.any((f) => f.duration == null)) return null;
    return files.fold<Duration>(Duration.zero, (s, f) => s + f.duration!);
  }

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
  const CatalogConfig({this.librivox = true, this.opds = const []});

  final bool librivox;
  final List<OpdsCatalog> opds;

  /// Вкладка «Каталог» видна, только если есть хоть один источник.
  bool get enabled => librivox || opds.isNotEmpty;

  CatalogConfig copyWith({bool? librivox, List<OpdsCatalog>? opds}) =>
      CatalogConfig(librivox: librivox ?? this.librivox, opds: opds ?? this.opds);

  String encode() => jsonEncode({'librivox': librivox, 'opds': [for (final c in opds) c.toJson()]});

  static CatalogConfig decode(String? raw) {
    if (raw == null || raw.isEmpty) return const CatalogConfig();
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const CatalogConfig();
      final list = json['opds'];
      return CatalogConfig(
        librivox: json['librivox'] != false,
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
