/// Каталог книг: LibriVox и подключённые каталоги OPDS вместе,
/// подборки по жанрам, поиск и скачивание в библиотеку.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../books/book_library.dart';
import '../../data/db/database.dart';
import 'catalog_models.dart';
import 'librivox_source.dart';
import 'opds_source.dart';

export 'catalog_models.dart';

/// Где лежат пароли каталогов OPDS.
abstract class CatalogPasswords {
  Future<String?> read(String catalogId);
  Future<void> write(String catalogId, String? password);
}

/// Системное хранилище (Keystore, DPAPI).
class SecureCatalogPasswords implements CatalogPasswords {
  const SecureCatalogPasswords([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String catalogId) async {
    try {
      return await _storage.read(key: 'opds.$catalogId');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String catalogId, String? password) async {
    try {
      if (password == null || password.isEmpty) {
        await _storage.delete(key: 'opds.$catalogId');
      } else {
        await _storage.write(key: 'opds.$catalogId', value: password);
      }
    } catch (_) {}
  }
}

/// Пароли в памяти (тесты).
class MemoryCatalogPasswords implements CatalogPasswords {
  final values = <String, String>{};

  @override
  Future<String?> read(String catalogId) async => values[catalogId];

  @override
  Future<void> write(String catalogId, String? password) async {
    if (password == null || password.isEmpty) {
      values.remove(catalogId);
    } else {
      values[catalogId] = password;
    }
  }
}

/// Фильтр подборок.
class CatalogFilter {
  const CatalogFilter({this.language = CatalogLanguage.all, this.kind = CatalogKind.all});

  final CatalogLanguage language;
  final CatalogKind kind;

  bool get audio => kind != CatalogKind.text;
  bool get text => kind != CatalogKind.audio;

  bool matches(CatalogBook b) =>
      (b.audio ? audio : text) && language.matches(b.language, title: b.title);

  String get key => '${language.name}/${kind.name}';

  @override
  bool operator ==(Object other) => other is CatalogFilter && other.language == language && other.kind == kind;

  @override
  int get hashCode => Object.hash(language, kind);
}

/// Как идёт скачивание книги из каталога.
class CatalogDownload {
  const CatalogDownload({this.received = 0, this.total, this.error});

  final int received;
  final int? total;

  /// Скачивание не удалось.
  final String? error;

  double? get fraction => total == null || total == 0 ? null : (received / total!).clamp(0.0, 1.0);
}

class BookCatalog {
  BookCatalog({
    required AppDatabase db,
    this.library,
    http.Client? client,
    CatalogPasswords? passwords,
    Future<Directory> Function()? tempDirectory,
  })  : _db = db,
        _client = client ?? http.Client(),
        _passwords = passwords ?? const SecureCatalogPasswords(),
        _tempDirectory = tempDirectory ?? (() async => Directory.systemTemp) {
    _librivox = LibriVoxSource(client: _client);
  }

  final AppDatabase _db;
  final BookLibrary? library;
  final http.Client _client;
  final CatalogPasswords _passwords;
  final Future<Directory> Function() _tempDirectory;
  late final LibriVoxSource _librivox;

  // ---------------------------------------------------------------------
  // Настройки

  Stream<CatalogConfig> watchConfig() => _db.watchSetting(BookCatalogSettings.config).map(CatalogConfig.decode).distinct(
        (a, b) => a.encode() == b.encode(),
      );

  Future<CatalogConfig> config() async => CatalogConfig.decode(await _db.setting(BookCatalogSettings.config));

  Future<void> _save(CatalogConfig c) async {
    await _db.setSetting(BookCatalogSettings.config, c.encode());
    _sources.clear();
    _cache.clear();
  }

  Future<void> setLibriVox(bool on) async => _save((await config()).copyWith(librivox: on));

  /// Проверить адрес каталога: вернёт название из ленты.
  Future<String> check(String url, {String? login, String? password}) async {
    final source = OpdsSource(
      OpdsCatalog(id: 'check', name: Uri.tryParse(url)?.host ?? url, url: url, login: login, password: password),
      client: _client,
    );
    final feed = await source.root();
    if (feed.books.isEmpty && feed.sections.isEmpty) throw const BookCatalogException('Каталог пуст');
    return feed.title;
  }

  /// Добавить каталог. [name] пустое — название из ленты.
  Future<OpdsCatalog> addOpds({required String url, String? name, String? login, String? password}) async {
    final normalized = normalizeCatalogUrl(url);
    final title = await check(normalized, login: login, password: password);
    final config = await this.config();
    if (config.opds.any((c) => c.url == normalized)) throw const BookCatalogException('Этот каталог уже добавлен');
    final id = '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 16).toRadixString(36)}';
    final catalog = OpdsCatalog(
      id: id,
      name: name != null && name.trim().isNotEmpty ? name.trim() : title,
      url: normalized,
      login: login != null && login.trim().isNotEmpty ? login.trim() : null,
    );
    if (catalog.private) await _passwords.write(id, password);
    await _save(config.copyWith(opds: [...config.opds, catalog]));
    return catalog;
  }

  Future<void> removeOpds(String id) async {
    final config = await this.config();
    await _passwords.write(id, null);
    await _save(config.copyWith(opds: config.opds.where((c) => c.id != id).toList()));
  }

  /// 'gutenberg.org/ebooks.opds' → 'https://gutenberg.org/ebooks.opds'.
  static String normalizeCatalogUrl(String url) {
    final t = url.trim();
    if (t.isEmpty) throw const BookCatalogException('Укажите адрес каталога');
    final full = t.contains('://') ? t : 'https://$t';
    final uri = Uri.tryParse(full);
    if (uri == null || uri.host.isEmpty || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const BookCatalogException('Неверный адрес каталога');
    }
    return full;
  }

  Future<CatalogLanguage> language() async => CatalogLanguage.from(await _db.setting(BookCatalogSettings.language));

  Future<void> setLanguage(CatalogLanguage l) => _db.setSetting(BookCatalogSettings.language, l.name);

  // ---------------------------------------------------------------------
  // Подборки

  final _sources = <String, OpdsSource>{};
  final _cache = <String, Future<List<CatalogBook>>>{};

  Future<List<OpdsSource>> _opds() async {
    final config = await this.config();
    final out = <OpdsSource>[];
    for (final c in config.opds) {
      out.add(_sources[c.id] ??= OpdsSource(
        c.private ? c.withPassword(await _passwords.read(c.id)) : c,
        client: _client,
      ));
    }
    return out;
  }

  Future<List<CatalogBook>> _cached(String key, Future<List<CatalogBook>> Function() load) {
    final f = _cache[key];
    if (f != null) return f;
    final future = load();
    _cache[key] = future;
    // Ошибку не запоминаем: в следующий раз — новая попытка.
    unawaited(future.then((_) {}, onError: (Object _) => _cache.remove(key)));
    return future;
  }

  /// Самое скачиваемое на LibriVox. Пусто, если LibriVox выключен
  /// или в фильтре только книги.
  Future<List<CatalogBook>> popularLibriVox(CatalogFilter filter) async {
    if (!filter.audio || !(await config()).librivox) return const [];
    return _cached('lv/popular/${filter.language.name}', () => _librivox.list(language: filter.language));
  }

  /// Подборка из корня каталога OPDS.
  Future<List<CatalogBook>> popularOpds(String catalogId, CatalogFilter filter) async {
    if (!filter.text) return const [];
    final source = (await _opds()).where((s) => s.catalog.id == catalogId).firstOrNull;
    if (source == null) return const [];
    final all = await _cached('opds/$catalogId/popular', source.popular);
    return all.where(filter.matches).toList();
  }

  /// Жанр по всем источникам: книги чередуются, чтобы ни один источник
  /// не занял весь ряд.
  Future<List<CatalogBook>> genre(BookGenre genre, CatalogFilter filter) async {
    final config = await this.config();
    final lists = <Future<List<CatalogBook>>>[
      if (filter.audio && config.librivox)
        _cached('lv/${genre.id}/${filter.language.name}', () => _librivox.list(genre: genre, language: filter.language)),
      if (filter.text)
        for (final s in await _opds()) _cached('opds/${s.catalog.id}/${genre.id}', () => s.genre(genre)),
    ];
    return _merge(lists, filter);
  }

  /// Поиск по всем источникам.
  Future<List<CatalogBook>> search(String query, CatalogFilter filter) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final config = await this.config();
    final lists = <Future<List<CatalogBook>>>[
      if (filter.audio && config.librivox)
        _cached('lv/search/${filter.language.name}/$q', () => _librivox.list(text: q, language: filter.language)),
      if (filter.text)
        for (final s in await _opds()) _cached('opds/${s.catalog.id}/search/$q', () => s.search(q)),
    ];
    return _merge(lists, filter);
  }

  /// Ошибка одного источника не прячет остальные; ошибка всех — видна.
  Future<List<CatalogBook>> _merge(List<Future<List<CatalogBook>>> lists, CatalogFilter filter) async {
    if (lists.isEmpty) return const [];
    Object? error;
    final results = await Future.wait(lists.map((f) => f.catchError((Object e) {
          error = e;
          return const <CatalogBook>[];
        })));
    final filtered = [for (final r in results) r.where(filter.matches).toList()];
    if (filtered.every((r) => r.isEmpty) && error != null) throw error!;
    final out = <CatalogBook>[];
    final seen = <String>{};
    for (var i = 0; filtered.any((r) => i < r.length); i++) {
      for (final r in filtered) {
        if (i < r.length && seen.add(r[i].id)) out.add(r[i]);
      }
    }
    return out;
  }

  final _details = <String, Future<CatalogDetails>>{};

  /// Файлы, главы и описание.
  Future<CatalogDetails> details(CatalogBook book) {
    return _details[book.id] ??= () async {
      if (book.source == CatalogSource.librivox) return _librivox.details(book);
      final source = (await _opds()).where((s) => s.catalog.id == book.catalogId).firstOrNull;
      if (source == null) return CatalogDetails(book: book, files: book.files);
      return source.details(book);
    }()
        .catchError((Object e) {
      _details.remove(book.id);
      throw e;
    });
  }

  // ---------------------------------------------------------------------
  // Скачивание

  /// Идущие скачивания: id в каталоге → прогресс.
  final downloads = ValueNotifier<Map<String, CatalogDownload>>(const {});
  final _cancelled = <String>{};

  /// Скачанное: id в каталоге → id книги в библиотеке.
  Stream<Map<String, int>> watchDownloaded() =>
      _db.watchSetting(BookCatalogSettings.downloaded).map(_decodeDownloaded);

  static Map<String, int> _decodeDownloaded(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const {};
      return {for (final e in json.entries) if (e.value is int) '${e.key}': e.value as int};
    } catch (_) {
      return const {};
    }
  }

  Future<void> _markDownloaded(String id, int bookId) async {
    final map = {..._decodeDownloaded(await _db.setting(BookCatalogSettings.downloaded)), id: bookId};
    await _db.setSetting(BookCatalogSettings.downloaded, jsonEncode(map));
  }

  void _progress(String id, CatalogDownload? d) {
    final map = {...downloads.value};
    if (d == null) {
      map.remove(id);
    } else {
      map[id] = d;
    }
    downloads.value = map;
  }

  void cancel(String id) {
    if (downloads.value.containsKey(id)) _cancelled.add(id);
  }

  /// Скачать книгу в библиотеку. Возвращает id книги; null — отменено.
  Future<int?> download(CatalogDetails details) async {
    final book = details.book;
    final lib = library;
    if (lib == null) throw const BookCatalogException('Библиотека недоступна');
    if (downloads.value.containsKey(book.id)) return null;
    if (details.files.isEmpty) throw const BookCatalogException('У этой книги нет файлов для скачивания');
    _cancelled.remove(book.id);
    _progress(book.id, CatalogDownload(total: details.size));
    try {
      final id = book.audio ? await _downloadAudio(lib, details) : await _downloadText(lib, details);
      if (id != null) await _markDownloaded(book.id, id);
      _progress(book.id, null);
      return id;
    } catch (e) {
      _progress(book.id, null);
      if (e is _Cancelled) return null;
      rethrow;
    } finally {
      _cancelled.remove(book.id);
    }
  }

  Future<int?> _downloadAudio(BookLibrary lib, CatalogDetails details) async {
    final book = details.book;
    final folder = await lib.newAudioFolder();
    try {
      var received = 0;
      final digits = '${details.files.length}'.length.clamp(2, 4);
      for (var i = 0; i < details.files.length; i++) {
        final f = details.files[i];
        final name = Uri.decodeComponent(Uri.parse(f.url).pathSegments.last);
        final target = File(p.join(folder.path, '${'${i + 1}'.padLeft(digits, '0')} ${_safeName(name)}'));
        final base = received;
        await _fetchTo(book.id, f.url, target, const {}, (n) {
          received = base + n;
          _progress(book.id, CatalogDownload(received: received, total: details.size));
        });
      }
      final cover = details.coverFile;
      if (cover != null) {
        try {
          await _fetchTo(book.id, cover, File(p.join(folder.path, 'cover.jpg')), const {}, (_) {});
        } on _Cancelled {
          rethrow;
        } catch (_) {
          // Без обложки книга всё равно слушается.
        }
      }
      return await lib.addAudioFolder(folder.path, author: book.author, title: book.title, description: book.description);
    } catch (e) {
      try {
        await folder.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<int?> _downloadText(BookLibrary lib, CatalogDetails details) async {
    final book = details.book;
    final file = details.best!;
    final source = (await _opds()).where((s) => s.catalog.id == book.catalogId).firstOrNull;
    final ext = file.format == 'fbz' ? 'fb2.zip' : file.format;
    final dir = Directory(p.join((await _tempDirectory()).path, 'catalog-${DateTime.now().microsecondsSinceEpoch}'));
    await dir.create(recursive: true);
    try {
      final target = File(p.join(dir.path, '${_safeName(book.title)}.$ext'));
      await _fetchTo(book.id, file.url, target, source?.headersFor(file.url) ?? const {}, (n) {
        _progress(book.id, CatalogDownload(received: n, total: file.size));
      });
      return await lib.importTextFile(target.path);
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _fetchTo(String id, String url, File target, Map<String, String> headers, void Function(int) onBytes) async {
    final request = http.Request('GET', Uri.parse(url))..headers.addAll(headers);
    final http.StreamedResponse res;
    try {
      res = await _client.send(request).timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const BookCatalogException('Не удалось скачать: нет связи');
    }
    if (res.statusCode != 200) {
      unawaited(res.stream.drain<void>().catchError((_) {}));
      throw BookCatalogException('Не удалось скачать: ошибка ${res.statusCode}');
    }
    final sink = target.openWrite();
    var n = 0;
    var last = 0;
    try {
      await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
        if (_cancelled.contains(id)) throw _Cancelled();
        sink.add(chunk);
        n += chunk.length;
        // Не чаще чем раз в 256 КБ — иначе перерисовка на каждый пакет.
        if (n - last >= 256 << 10) {
          last = n;
          onBytes(n);
        }
      }
      onBytes(n);
    } on _Cancelled {
      rethrow;
    } on TimeoutException {
      throw const BookCatalogException('Не удалось скачать: связь оборвалась');
    } finally {
      await sink.close();
    }
  }

  static String _safeName(String s) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final cut = t.length > 80 ? t.substring(0, 80).trim() : t;
    return cut.isEmpty ? 'book' : cut;
  }
}

class _Cancelled implements Exception {}
