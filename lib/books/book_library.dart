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
  })  : _db = db,
        _dataDirectory = dataDirectory;

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
    return rescanSource(path);
  }

  Future<void> removeSource(String path) => _db.removeBookSource(path);

  /// Проверить все папки-источники: новые книги добавляются, исчезнувшие
  /// помечаются.
  Future<void> rescanAll() async {
    for (final s in await _db.bookSourceList()) {
      await rescanSource(s.path);
    }
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
        await File(path).copy(p.join(folder.path, p.basename(path)));
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
      return _db.saveAudioBook(book, coverPath: cover);
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
