/// Книги в базе: список, место в книге, закладки, папки-источники.
library;

import 'dart:math' show Random;

import 'package:drift/drift.dart';

import '../../books/book_models.dart';
import 'database.dart';

typedef BookItem = ({Book book, BookProgress? progress});

/// Место в книге, изменённое здесь и ещё не отправленное на сервер.
typedef DirtyBookProgress = ({
  int bookId,
  String key,
  String locator,
  int positionMs,
  double percent,
  DateTime updatedAt,
});

/// Ключи настроек книг.
abstract final class BookSettings {
  /// Отматывать назад после паузы в аудиокниге ('false' — нет).
  static const smartResume = 'books.smartResume';

  /// Ревизия выделений на сервере, до которой всё получено.
  static const highlightsSince = 'books.highlightsSince';

  /// Ревизия books.php, до которой всё получено.
  static const syncSince = 'books.since';

  /// Сколько места занято и доступно на сервере (байты), для настроек.
  static const serverUsed = 'books.serverUsed';
  static const serverLimit = 'books.serverLimit';

  /// 'true' — на сервере нет books.php.
  static const unsupported = 'books.unsupported';

  /// Последняя ошибка синхронизации книг.
  static const lastError = 'books.lastError';

  /// Читалка: размер шрифта (индекс), шрифт, фон, интервал.
  static const readerSize = 'reader.size';
  static const readerFont = 'reader.font';
  static const readerPaper = 'reader.paper';
  static const readerSpacing = 'reader.spacing';

  /// На какой язык переводить.
  static const translateTo = 'reader.translateTo';
}

/// Случайный идентификатор (32 шестнадцатеричных знака).
String newUid() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

extension BooksDao on AppDatabase {
  // -------------------------------------------------------------------------
  // Список
  // -------------------------------------------------------------------------

  /// Все книги, сначала те, что открывали недавно.
  Stream<List<BookItem>> watchBooks() {
    final q = select(books).join([
      leftOuterJoin(bookProgresses, bookProgresses.bookId.equalsExp(books.id)),
    ])
      ..where(books.deletePending.equals(false));
    return q.watch().map((rows) {
      final items = [
        for (final r in rows) (book: r.readTable(books), progress: r.readTableOrNull(bookProgresses)),
      ];
      DateTime at(BookItem i) => [
            i.progress?.updatedAt,
            i.book.openedAt,
            i.book.addedAt,
          ].whereType<DateTime>().reduce((a, b) => a.isAfter(b) ? a : b);
      items.sort((a, b) => at(b).compareTo(at(a)));
      return items;
    });
  }

  Stream<BookItem?> watchBook(int id) {
    final q = select(books).join([
      leftOuterJoin(bookProgresses, bookProgresses.bookId.equalsExp(books.id)),
    ])
      ..where(books.id.equals(id));
    return q.watchSingleOrNull().map(
          (r) => r == null ? null : (book: r.readTable(books), progress: r.readTableOrNull(bookProgresses)),
        );
  }

  Future<Book?> bookById(int id) => (select(books)..where((b) => b.id.equals(id))).getSingleOrNull();

  Future<Book?> bookByKey(String key) => (select(books)..where((b) => b.key.equals(key))).getSingleOrNull();

  Future<List<BookTrack>> tracksOfBook(int bookId) =>
      (select(bookTracks)..where((t) => t.bookId.equals(bookId))..orderBy([(t) => OrderingTerm.asc(t.idx)])).get();

  Future<List<BookChapter>> bookChaptersOf(int bookId) => (select(bookChapters)
        ..where((c) => c.bookId.equals(bookId))
        ..orderBy([(c) => OrderingTerm.asc(c.idx)]))
      .get();

  // -------------------------------------------------------------------------
  // Добавление и изменение
  // -------------------------------------------------------------------------

  /// Записать найденную аудиокнигу. Уже известная (тот же ключ) —
  /// обновляется: путь, файлы, главы; место в книге сохраняется.
  Future<int> saveAudioBook(ScannedAudioBook b, {String? sourceRoot, String? coverPath}) {
    return transaction(() async {
      final existing = await bookByKey(b.key);
      final companion = BooksCompanion(
        key: Value(b.key),
        kind: const Value(BookKind.audio),
        title: Value(b.title),
        author: Value(b.author),
        narrator: Value(b.narrator),
        description: Value(b.description),
        format: Value(b.format),
        path: Value(b.path),
        sourceRoot: Value(sourceRoot),
        sizeBytes: Value(b.sizeBytes),
        durationMs: Value(b.durationMs),
        missing: const Value(false),
        deletePending: const Value(false),
        coverPath: coverPath == null ? const Value.absent() : Value(coverPath),
      );
      final int id;
      if (existing == null) {
        id = await into(books).insert(companion);
      } else {
        id = existing.id;
        await (update(books)..where((x) => x.id.equals(id))).write(companion);
        await (delete(bookTracks)..where((t) => t.bookId.equals(id))).go();
        await (delete(bookChapters)..where((c) => c.bookId.equals(id))).go();
      }
      await batch((batch) {
        batch.insertAll(bookTracks, [
          for (var i = 0; i < b.tracks.length; i++)
            BookTracksCompanion(
              bookId: Value(id),
              idx: Value(i),
              path: Value(b.tracks[i].path),
              durationMs: Value(b.tracks[i].durationMs),
              title: Value(b.tracks[i].title),
            ),
        ]);
        batch.insertAll(bookChapters, [
          for (var i = 0; i < b.chapters.length; i++)
            BookChaptersCompanion(
              bookId: Value(id),
              idx: Value(i),
              title: Value(b.chapters[i].title),
              trackIdx: Value(b.chapters[i].trackIdx),
              startMs: Value(b.chapters[i].startMs),
            ),
        ]);
      });
      return id;
    });
  }

  /// Аудиокниги папки [sourceRoot], которых не нашлось при проверке, —
  /// помечаются (не удаляются: место в книге и закладки сохраняются,
  /// если папку просто не видно — например, карта памяти не вставлена).
  Future<void> markMissingBooks(String sourceRoot, Set<String> foundKeys) =>
      (update(books)..where((b) => b.sourceRoot.equals(sourceRoot) & b.key.isNotIn(foundKeys)))
          .write(const BooksCompanion(missing: Value(true)));

  /// Записать текстовую книгу. [path] — `null`, если файл ещё на сервере.
  Future<int> saveTextBook(TextBookInfo info, {String? path, String? coverPath, bool uploaded = false}) {
    return transaction(() async {
      final existing = await bookByKey(info.key);
      final companion = BooksCompanion(
        key: Value(info.key),
        kind: const Value(BookKind.text),
        title: Value(info.title),
        author: Value(info.author),
        language: Value(info.language),
        description: Value(info.description),
        format: Value(info.format),
        sizeBytes: Value(info.sizeBytes),
        deletePending: const Value(false),
        path: path == null ? const Value.absent() : Value(path),
        coverPath: coverPath == null ? const Value.absent() : Value(coverPath),
        uploaded: uploaded ? const Value(true) : const Value.absent(),
      );
      if (existing == null) return into(books).insert(companion);
      await (update(books)..where((b) => b.id.equals(existing.id))).write(companion);
      return existing.id;
    });
  }

  Future<void> _updateBook(int id, BooksCompanion c) => (update(books)..where((b) => b.id.equals(id))).write(c);

  Future<void> setBookFile(int id, String? path, {String? coverPath}) => _updateBook(
        id,
        BooksCompanion(path: Value(path), coverPath: coverPath == null ? const Value.absent() : Value(coverPath)),
      );

  Future<void> setBookUploaded(int id, bool uploaded) => _updateBook(id, BooksCompanion(uploaded: Value(uploaded)));

  Future<void> setBookShelf(int id, BookShelf shelf) => _updateBook(id, BooksCompanion(shelf: Value(shelf)));

  Future<void> setBookSpeed(int id, double? speed) => _updateBook(id, BooksCompanion(speed: Value(speed)));

  Future<void> markBookOpened(int id) => _updateBook(id, BooksCompanion(openedAt: Value(DateTime.now())));

  Future<void> setBookCover(int id, String? coverPath) => _updateBook(id, BooksCompanion(coverPath: Value(coverPath)));

  Future<void> setBookDescription(int id, String? description) =>
      _updateBook(id, BooksCompanion(description: Value(description)));

  /// Книги без обложки (кроме удаляемых) — для поиска обложек в каталогах.
  Future<List<Book>> booksWithoutCover() =>
      (select(books)..where((b) => b.coverPath.isNull() & b.deletePending.equals(false))).get();

  /// Книга удалена здесь; сервер узнает при следующей синхронизации.
  Future<void> markBookDeletePending(int id) => _updateBook(id, const BooksCompanion(deletePending: Value(true)));

  Future<void> deleteBookRow(int id) => (delete(books)..where((b) => b.id.equals(id))).go();

  Future<List<Book>> pendingBookDeletes() =>
      (select(books)..where((b) => b.deletePending.equals(true))).get();

  /// Текстовые книги этого устройства, которых ещё нет на сервере.
  Future<List<Book>> textBooksToUpload() => (select(books)
        ..where((b) =>
            b.kind.equalsValue(BookKind.text) &
            b.uploaded.equals(false) &
            b.deletePending.equals(false) &
            b.path.isNotNull()))
      .get();

  /// Текстовые книги, которые есть только на сервере.
  Future<List<Book>> textBooksToDownload() => (select(books)
        ..where((b) => b.kind.equalsValue(BookKind.text) & b.deletePending.equals(false) & b.path.isNull()))
      .get();

  // -------------------------------------------------------------------------
  // Место в книге
  // -------------------------------------------------------------------------

  Future<BookProgress?> bookProgress(int bookId) =>
      (select(bookProgresses)..where((p) => p.bookId.equals(bookId))).getSingleOrNull();

  Stream<BookProgress?> watchBookProgress(int bookId) =>
      (select(bookProgresses)..where((p) => p.bookId.equals(bookId))).watchSingleOrNull();

  /// Место изменилось здесь — уйдёт на сервер.
  Future<void> saveBookProgress(
    int bookId, {
    required String locator,
    int positionMs = 0,
    required double percent,
    DateTime? at,
  }) async {
    await into(bookProgresses).insertOnConflictUpdate(BookProgressesCompanion(
      bookId: Value(bookId),
      locator: Value(locator),
      positionMs: Value(positionMs),
      percent: Value(percent < 0 ? 0.0 : (percent > 1 ? 1.0 : percent)),
      updatedAt: Value(at ?? DateTime.now()),
      dirty: const Value(true),
      device: const Value(null),
    ));
    // Отложенную книгу начали — она снова «в процессе».
    await (update(books)..where((b) => b.id.equals(bookId) & b.shelf.equalsValue(BookShelf.later)))
        .write(const BooksCompanion(shelf: Value(BookShelf.reading)));
  }

  /// Место с другого устройства. Применяется, если оно новее здешнего
  /// (или [force] — человек выбрал «продолжить с того места»).
  /// Возвращает, применено ли.
  Future<bool> applyRemoteBookProgress(
    int bookId, {
    required String locator,
    required int positionMs,
    required double percent,
    required DateTime changed,
    String? device,
    bool force = false,
  }) async {
    final local = await bookProgress(bookId);
    if (!force && local != null && !local.updatedAt.isBefore(changed)) return false;
    await into(bookProgresses).insertOnConflictUpdate(BookProgressesCompanion(
      bookId: Value(bookId),
      locator: Value(locator),
      positionMs: Value(positionMs),
      percent: Value(percent < 0 ? 0.0 : (percent > 1 ? 1.0 : percent)),
      updatedAt: Value(changed),
      dirty: const Value(false),
      device: Value(device),
    ));
    return true;
  }

  Future<List<DirtyBookProgress>> dirtyBookProgress() async {
    final q = select(bookProgresses).join([innerJoin(books, books.id.equalsExp(bookProgresses.bookId))])
      ..where(bookProgresses.dirty.equals(true) & books.deletePending.equals(false));
    final rows = await q.get();
    return [
      for (final r in rows)
        (
          bookId: r.readTable(bookProgresses).bookId,
          key: r.readTable(books).key,
          locator: r.readTable(bookProgresses).locator,
          positionMs: r.readTable(bookProgresses).positionMs,
          percent: r.readTable(bookProgresses).percent,
          updatedAt: r.readTable(bookProgresses).updatedAt,
        ),
    ];
  }

  Stream<int> watchDirtyBookProgressCount() {
    final count = bookProgresses.bookId.count();
    return (selectOnly(bookProgresses)
          ..addColumns([count])
          ..where(bookProgresses.dirty.equals(true)))
        .map((r) => r.read(count) ?? 0)
        .watchSingle();
  }

  /// Отправлено на сервер: снять отметку, если с тех пор место не менялось.
  Future<void> markBookProgressSynced(int bookId, DateTime updatedAt) => (update(bookProgresses)
        ..where((p) => p.bookId.equals(bookId) & p.updatedAt.isSmallerOrEqualValue(updatedAt)))
      .write(const BookProgressesCompanion(dirty: Value(false)));

  // -------------------------------------------------------------------------
  // Закладки
  // -------------------------------------------------------------------------

  Stream<List<BookBookmark>> watchBookmarks(int bookId) => (select(bookBookmarks)
        ..where((b) => b.bookId.equals(bookId))
        ..orderBy([(b) => OrderingTerm.asc(b.positionMs), (b) => OrderingTerm.asc(b.locator)]))
      .watch();

  Future<int> addBookmark(int bookId, {required String locator, int? positionMs, required String label}) =>
      into(bookBookmarks).insert(BookBookmarksCompanion(
        bookId: Value(bookId),
        locator: Value(locator),
        positionMs: Value(positionMs),
        label: Value(label),
      ));

  Future<void> deleteBookmark(int id) => (delete(bookBookmarks)..where((b) => b.id.equals(id))).go();

  // -------------------------------------------------------------------------
  // Выделения и заметки
  // -------------------------------------------------------------------------

  /// Выделения книги (кроме удалённых).
  Stream<List<BookHighlight>> watchHighlights(String bookKey) => (select(bookHighlights)
        ..where((h) => h.bookKey.equals(bookKey) & h.deleted.equals(false))
        ..orderBy([(h) => OrderingTerm.asc(h.createdAt)]))
      .watch();

  Future<int> addHighlight(
    String bookKey, {
    required String start,
    required String end,
    required String quote,
    int color = 0,
    String note = '',
  }) {
    final now = DateTime.now();
    return into(bookHighlights).insert(BookHighlightsCompanion.insert(
      bookKey: bookKey,
      uid: newUid(),
      startAt: start,
      endAt: end,
      quote: quote,
      note: Value(note),
      color: Value(color),
      createdAt: now,
      updatedAt: now,
    ));
  }

  Future<void> updateHighlight(int id, {int? color, String? note}) =>
      (update(bookHighlights)..where((h) => h.id.equals(id))).write(BookHighlightsCompanion(
        color: color == null ? const Value.absent() : Value(color),
        note: note == null ? const Value.absent() : Value(note),
        updatedAt: Value(DateTime.now()),
        dirty: const Value(true),
      ));

  /// Удалить везде: запись остаётся с пометкой, пока удаление не уйдёт на сервер.
  Future<void> deleteHighlight(int id) =>
      (update(bookHighlights)..where((h) => h.id.equals(id))).write(BookHighlightsCompanion(
        deleted: const Value(true),
        updatedAt: Value(DateTime.now()),
        dirty: const Value(true),
      ));

  Future<BookHighlight?> highlightById(int id) =>
      (select(bookHighlights)..where((h) => h.id.equals(id))).getSingleOrNull();

  Future<List<BookHighlight>> dirtyHighlights() => (select(bookHighlights)..where((h) => h.dirty.equals(true))).get();

  /// Отправлено: снять пометку, если с тех пор не меняли.
  Future<void> markHighlightSynced(String uid, DateTime updatedAt) => (update(bookHighlights)
        ..where((h) => h.uid.equals(uid) & h.updatedAt.equals(updatedAt)))
      .write(const BookHighlightsCompanion(dirty: Value(false)));

  /// Выделение с сервера: побеждает более позднее изменение.
  Future<void> applyRemoteHighlight({
    required String uid,
    required String bookKey,
    required String start,
    required String end,
    required String quote,
    required String note,
    required int color,
    required bool deleted,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) async {
    final local = await (select(bookHighlights)..where((h) => h.uid.equals(uid))).getSingleOrNull();
    if (local != null && !local.updatedAt.isBefore(updatedAt)) return;
    final row = BookHighlightsCompanion(
      bookKey: Value(bookKey),
      uid: Value(uid),
      startAt: Value(start),
      endAt: Value(end),
      quote: Value(quote),
      note: Value(note),
      color: Value(color),
      deleted: Value(deleted),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      dirty: const Value(false),
    );
    if (local == null) {
      await into(bookHighlights).insert(row);
    } else {
      await (update(bookHighlights)..where((h) => h.id.equals(local.id))).write(row);
    }
  }

  // -------------------------------------------------------------------------
  // Папки с аудиокнигами
  // -------------------------------------------------------------------------

  Stream<List<BookSource>> watchBookSources() =>
      (select(bookSources)..orderBy([(s) => OrderingTerm.asc(s.addedAt)])).watch();

  Future<List<BookSource>> bookSourceList() => select(bookSources).get();

  Future<void> addBookSource(String path) =>
      into(bookSources).insert(BookSourcesCompanion(path: Value(path)), mode: InsertMode.insertOrIgnore);

  /// Убрать папку: её книги уходят из библиотеки (файлы на диске остаются).
  Future<void> removeBookSource(String path) => transaction(() async {
        await (delete(bookSources)..where((s) => s.path.equals(path))).go();
        await (delete(books)..where((b) => b.sourceRoot.equals(path))).go();
      });
}
