/// Книги на устройстве: папки-источники аудиокниг, добавление файлов,
/// обложки, открытие текстовых книг, удаление.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/db/books_dao.dart';
import '../data/db/database.dart';
import '../sync/book_sync.dart';
import 'book_metadata.dart';
import 'book_models.dart';
import 'book_scanner.dart';
import 'text/text_book.dart';
import 'text/text_parser.dart';

/// Разбор в отдельном изоляте: большая книга не подвешивает интерфейс.
TextBookContent _parse(({Uint8List bytes, String format, String title}) a) =>
    parseTextBook(a.bytes, a.format, fallbackTitle: a.title);

/// Скрытые из библиотеки аудиокниги папок-источников (ключи через перевод строки).
const _hiddenKey = 'books.hidden';

class BookLibrary {
  BookLibrary({
    required AppDatabase db,
    required Future<Directory> Function() dataDirectory,
    this.sync,
    this.requestSync,
    this.lookupCovers = true,
  })  : _db = db,
        _dataDirectory = dataDirectory;

  /// Искать обложки в Google Books и Open Library для книг без обложки.
  final bool lookupCovers;

  final AppDatabase _db;
  final Future<Directory> Function() _dataDirectory;

  /// Синхронизация книг; `null` — без сервера (тесты).
  BookSync? sync;

  /// Попросить полную синхронизацию (загрузить новую книгу на сервер).
  final void Function()? requestSync;

  /// Что сейчас делается («Ищу книги в папке…»), для индикатора.
  final status = ValueNotifier<String?>(null);

  Future<Directory> _dir(String name) async {
    final d = Directory(p.join((await _dataDirectory()).path, name));
    await d.create(recursive: true);
    return d;
  }

  /// Папка с текстовыми книгами.
  Future<Directory> textDirectory() => _dir('books');

  // -------------------------------------------------------------------------
  // Аудиокниги
  // -------------------------------------------------------------------------

  /// Добавить папку-источник и сразу найти в ней книги. Возвращает,
  /// сколько книг найдено.
  Future<int> addSource(String path) async {
    await _db.addBookSource(path);
    final n = await rescanSource(path);
    if (_watching) unawaited(watchSources());
    return n;
  }

  Future<void> removeSource(String path) async {
    await _db.removeBookSource(path);
    await _watchers.remove(path)?.cancel();
  }

  /// Когда папки проверялись в последний раз.
  DateTime? lastScan;
  Future<void>? _scanAll;

  /// Проверить все папки-источники: новые книги добавляются, исчезнувшие
  /// помечаются. Повторный вызов во время проверки ждёт текущую.
  Future<void> rescanAll() => _scanAll ??= () async {
        try {
          for (final s in await _db.bookSourceList()) {
            await rescanSource(s.path);
          }
          lastScan = DateTime.now();
        } finally {
          _scanAll = null;
        }
      }();

  // Слежение за папками (Windows, macOS, Linux): положили книгу в папку —
  // она появляется в приложении без нажатий.
  final _watchers = <String, StreamSubscription<FileSystemEvent>>{};
  final _pending = <String, Timer>{};
  bool _watching = false;

  Future<void> watchSources() async {
    _watching = true;
    for (final s in await _db.bookSourceList()) {
      if (_watchers.containsKey(s.path)) continue;
      final dir = Directory(s.path);
      if (!await dir.exists()) continue;
      try {
        final events = dir.watch(recursive: !Platform.isLinux);
        _watchers[s.path] = events.listen(
          (_) => _scheduleRescan(s.path),
          onError: (Object _) => _watchers.remove(s.path),
          cancelOnError: true,
        );
      } catch (_) {
        // Папка на сетевом диске и т. п. — остаётся ручное обновление.
      }
    }
  }

  void _scheduleRescan(String root) {
    _pending[root]?.cancel();
    // Копирование книги — много событий подряд: ждём, пока утихнет.
    _pending[root] = Timer(const Duration(seconds: 4), () {
      _pending.remove(root);
      if (_scanAll != null) {
        _scheduleRescan(root);
        return;
      }
      unawaited(rescanSource(root).then((_) {}, onError: (Object _) {}));
    });
  }

  void stopWatching() {
    _watching = false;
    for (final w in _watchers.values) {
      unawaited(w.cancel());
    }
    _watchers.clear();
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
  }

  Future<int> rescanSource(String root) async {
    status.value = 'Ищу книги в папке…';
    try {
      final hidden = await _hidden();
      final found = await BookScanner.scanRoot(root, onBook: (t) => status.value = 'Нашёл: $t');
      final keys = <String>{};
      for (final b in found) {
        keys.add(b.key);
        if (hidden.contains(b.key)) continue;
        final existing = await _db.bookByKey(b.key);
        final cover = existing?.coverPath != null && await File(existing!.coverPath!).exists()
            ? null
            : await _saveCover(b.key, b.cover, b.coverFile);
        await _db.saveAudioBook(b, sourceRoot: root, coverPath: cover);
      }
      if (await Directory(root).exists()) await _db.markMissingBooks(root, keys);
      fillMissingCovers();
      return found.where((b) => !hidden.contains(b.key)).length;
    } finally {
      status.value = null;
    }
  }

  /// Аудиокнига из выбранных файлов: файлы копируются в папку приложения
  /// (на Android выбранный файл — временная копия).
  Future<int?> addAudioFiles(List<String> paths) async {
    if (paths.isEmpty) return null;
    status.value = 'Копирую файлы книги…';
    try {
      final base = await _dir('audiobooks');
      final folder = Directory(p.join(base.path, '${DateTime.now().millisecondsSinceEpoch}'));
      await folder.create(recursive: true);
      for (final path in paths) {
        final target = p.join(folder.path, p.basename(path));
        // Временную копию (Android) переносим, остальное — копируем.
        if (path.contains('${Platform.pathSeparator}picked${Platform.pathSeparator}')) {
          try {
            await File(path).rename(target);
            continue;
          } catch (_) {}
        }
        await File(path).copy(target);
      }
      final book = paths.length == 1
          ? await BookScanner.scanFile(p.join(folder.path, p.basename(paths.single)))
          : await BookScanner.scanFolder(folder.path);
      if (book == null) {
        await folder.delete(recursive: true);
        return null;
      }
      final existing = await _db.bookByKey(book.key);
      if (existing != null && existing.path != null && !existing.missing) {
        // Такая книга уже есть — копия не нужна.
        await folder.delete(recursive: true);
        return existing.id;
      }
      final cover = await _saveCover(book.key, book.cover, book.coverFile);
      final id = await _db.saveAudioBook(book, coverPath: cover);
      fillMissingCovers();
      return id;
    } finally {
      status.value = null;
    }
  }

  Future<Set<String>> _hidden() async =>
      (await _db.setting(_hiddenKey) ?? '').split('\n').where((s) => s.isNotEmpty).toSet();

  // -------------------------------------------------------------------------
  // Текстовые книги
  // -------------------------------------------------------------------------

  /// Добавить текстовую книгу из файла. Возвращает id книги.
  /// Файл не читается — [FormatException].
  Future<int> importTextFile(String path) async {
    final format = textFormatOf(path);
    if (format == null) throw const FormatException('Этот формат не поддерживается: нужны EPUB, FB2 или TXT');
    status.value = 'Добавляю книгу…';
    try {
      final bytes = await File(path).readAsBytes();
      final key = 't:${sha1.convert(bytes)}';
      final fallback = p.basenameWithoutExtension(path).replaceAll('_', ' ');
      final content = await compute(_parse, (bytes: bytes, format: format, title: fallback));
      final dir = await textDirectory();
      final target = File(p.join(dir.path, '${key.substring(2)}.$format'));
      if (!await target.exists()) await target.writeAsBytes(bytes, flush: true);
      final cover = await _saveCover(key, content.cover, null);
      final id = await _db.saveTextBook(
        TextBookInfo(
          key: key,
          title: content.title,
          author: content.author,
          language: content.language,
          description: content.description,
          format: format,
          sizeBytes: bytes.length,
        ),
        path: target.path,
        coverPath: cover,
      );
      requestSync?.call();
      fillMissingCovers();
      return id;
    } finally {
      status.value = null;
    }
  }

  final _cache = <String, TextBookContent>{};
  final _order = <String>[];

  /// Разобранная книга (держим в памяти две последние).
  Future<TextBookContent> openText(Book book) async {
    final cached = _cache[book.key];
    if (cached != null) return cached;
    final path = book.path;
    if (path == null) throw const FormatException('Книга ещё не скачана с сервера');
    final bytes = await File(path).readAsBytes();
    final content = await compute(_parse, (bytes: bytes, format: book.format, title: book.title));
    _cache[book.key] = content;
    _order
      ..remove(book.key)
      ..add(book.key);
    while (_order.length > 2) {
      _cache.remove(_order.removeAt(0));
    }
    return content;
  }

  /// Книга пришла с другого устройства: обложка и описание из файла.
  Future<void> completeDownloaded(int bookId) async {
    final book = await _db.bookById(bookId);
    if (book == null || book.path == null) return;
    try {
      final content = await openText(book);
      final cover = await _saveCover(book.key, content.cover, null);
      await _db.saveTextBook(
        TextBookInfo(
          key: book.key,
          title: content.title,
          author: content.author,
          language: content.language,
          description: content.description,
          format: book.format,
          sizeBytes: book.sizeBytes,
        ),
        coverPath: cover,
      );
      fillMissingCovers();
    } catch (e) {
      debugPrint('Не удалось разобрать скачанную книгу: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Удаление
  // -------------------------------------------------------------------------

  /// Удалить книгу. Текстовая — везде (через сервер); возвращает `false`,
  /// если сервер пока не подтвердил (дойдёт при следующей синхронизации).
  /// Аудиокнига — только из библиотеки этого устройства; файлы в папке-
  /// источнике не трогаются, книга больше не появится при проверке папки.
  Future<bool> delete(Book book) async {
    _cache.remove(book.key);
    if (book.kind == BookKind.text) {
      final s = sync;
      if (s != null) return s.deleteEverywhere(book);
      await _deleteFile(book.path);
      await _deleteFile(book.coverPath);
      await _db.deleteBookRow(book.id);
      return true;
    }
    if (book.sourceRoot != null) {
      final hidden = await _hidden()
        ..add(book.key);
      await _db.setSetting(_hiddenKey, hidden.join('\n'));
    } else if (book.path != null) {
      // Добавлена файлами — копия в папке приложения больше не нужна.
      final base = (await _dir('audiobooks')).path;
      final target = File(book.path!).existsSync() && FileSystemEntity.isFileSync(book.path!)
          ? p.dirname(book.path!)
          : book.path!;
      if (p.isWithin(base, target)) {
        try {
          await Directory(target).delete(recursive: true);
        } catch (_) {}
      }
    }
    await _deleteFile(book.coverPath);
    await _db.deleteBookRow(book.id);
    return true;
  }

  /// Вернуть в библиотеку скрытые аудиокниги папок-источников.
  Future<void> unhideAll() async {
    await _db.setSetting(_hiddenKey, '');
    await rescanAll();
  }

  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // Обложки из каталогов
  // -------------------------------------------------------------------------

  bool _filling = false;

  /// Найти обложки для книг, у которых их нет. Каждую книгу ищем один раз
  /// (дальше — только вручную, «Найти обложку»).
  void fillMissingCovers() {
    if (!lookupCovers || _filling) return;
    _filling = true;
    unawaited(() async {
      final meta = BookMetadata();
      try {
        for (final book in await _db.booksWithoutCover()) {
          final tried = 'books.meta.${book.key}';
          if ((await _db.setting(tried) ?? '').isNotEmpty) continue;
          await _db.setSetting(tried, DateTime.now().toIso8601String());
          try {
            final found = await meta.search(book.title, author: book.author, limit: 1);
            if (found.isEmpty) continue;
            await _applyCover(meta, book, found.first);
          } catch (_) {
            // Нет сети — попробуем в другой раз.
            await _db.setSetting(tried, '');
            break;
          }
        }
      } catch (_) {
      } finally {
        meta.close();
        _filling = false;
      }
    }());
  }

  /// Варианты обложек для книги.
  Future<List<CoverCandidate>> findCovers(Book book, {String? query}) async {
    final meta = BookMetadata();
    try {
      return await meta.search(query ?? book.title, author: query == null ? book.author : null);
    } finally {
      meta.close();
    }
  }

  /// Поставить выбранную обложку. `false` — картинку скачать не удалось.
  Future<bool> setCoverFrom(Book book, CoverCandidate c) async {
    final meta = BookMetadata();
    try {
      final ok = await _applyCover(meta, book, c);
      // Выбрана вручную — и на другие устройства.
      if (ok) unawaited(sync?.coverChanged(book.key));
      return ok;
    } finally {
      meta.close();
    }
  }

  /// Обложка с сервера (выбрана на другом устройстве).
  Future<void> setCoverBytes(Book book, List<int> bytes) async {
    final path = await _saveCover('${book.key}-${DateTime.now().millisecondsSinceEpoch}', bytes, null);
    if (path == null) return;
    final fresh = await _db.bookById(book.id);
    final old = fresh?.coverPath;
    await _db.setBookCover(book.id, path);
    if (old != null && old != path) await _deleteFile(old);
  }

  /// Своя обложка из файла (картинка с устройства). `false` — не картинка.
  Future<bool> setCoverFromFile(Book book, String file) async {
    final bytes = await File(file).readAsBytes();
    final jpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    final png = bytes.length > 2 && bytes[0] == 0x89 && bytes[1] == 0x50;
    final webp = bytes.length > 12 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50;
    if (!jpeg && !png && !webp) return false;
    final path = await _saveCover('${book.key}-${DateTime.now().millisecondsSinceEpoch}', bytes, null);
    if (path == null) return false;
    final old = book.coverPath;
    await _db.setBookCover(book.id, path);
    if (old != null && old != path) await _deleteFile(old);
    // Временная копия выбранного файла (Android) больше не нужна.
    if (file.contains('${Platform.pathSeparator}picked${Platform.pathSeparator}')) await _deleteFile(file);
    unawaited(sync?.coverChanged(book.key));
    return true;
  }

  Future<bool> _applyCover(BookMetadata meta, Book book, CoverCandidate c) async {
    final bytes = await meta.download(c.imageUrl);
    if (bytes == null) return false;
    // Новое имя файла: иначе картинка со старым путём останется в кэше.
    final path = await _saveCover('${book.key}-${DateTime.now().millisecondsSinceEpoch}', bytes, null);
    if (path == null) return false;
    final old = book.coverPath;
    await _db.setBookCover(book.id, path);
    if (old != null && old != path) await _deleteFile(old);
    if ((book.description ?? '').trim().isEmpty && c.description != null) {
      await _db.setBookDescription(book.id, c.description);
    }
    return true;
  }

  // -------------------------------------------------------------------------

  Future<String?> _saveCover(String key, List<int>? bytes, String? file) async {
    try {
      Uint8List? data = bytes == null ? null : Uint8List.fromList(bytes);
      if (data == null && file != null) data = await File(file).readAsBytes();
      if (data == null || data.length < 64) return null;
      final dir = await _dir('book_covers');
      final ext = data[0] == 0x89 && data[1] == 0x50 ? 'png' : 'jpg';
      final out = File(p.join(dir.path, '${key.replaceAll(':', '_')}.$ext'));
      await out.writeAsBytes(data, flush: true);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _deleteFile(String? path) async {
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
