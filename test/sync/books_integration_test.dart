// Синхронизация книг с настоящим сервером (oPodSync + books.php).
// В CI сервер запускается встроенным сервером PHP; локально тест
// пропускается без OPODSYNC_URL, OPODSYNC_USER, OPODSYNC_PASSWORD.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/books/book_library.dart';
import 'package:podcast_app/books/book_models.dart';
import 'package:podcast_app/books/locator.dart';
import 'package:podcast_app/books/reading_log.dart';
import 'package:podcast_app/data/db/books_dao.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/data/podcast_repository.dart';
import 'package:podcast_app/feed/feed_fetcher.dart';
import 'package:podcast_app/sync/book_sync.dart';
import 'package:podcast_app/sync/sync_service.dart';

final _server = Platform.environment['OPODSYNC_URL'];
final _user = Platform.environment['OPODSYNC_USER'] ?? '';
final _password = Platform.environment['OPODSYNC_PASSWORD'] ?? '';

class _Device {
  _Device(String name, Directory root) : db = AppDatabase(NativeDatabase.memory()) {
    final repo = PodcastRepository(db, FeedFetcher(client: MockClient((_) async => http.Response('', 404))));
    sync = SyncService(
      db: db,
      repository: repo,
      deviceCaption: name,
      deviceType: 'desktop',
    );
    final dir = Directory('${root.path}/$name');
    library = BookLibrary(db: db, dataDirectory: () async => dir, lookupCovers: false);
    books = BookSync(
      db: db,
      sync: sync,
      booksDirectory: () => library.textDirectory(),
      onFilesChanged: library.completeDownloaded,
      saveCover: library.setCoverBytes,
    );
    library.sync = books;
    sync.books = books;
  }

  final AppDatabase db;
  late final SyncService sync;
  late final BookLibrary library;
  late final BookSync books;

  Future<void> syncBooks() async {
    final client = await sync.openClient();
    try {
      await books.syncWith(client!);
    } finally {
      client?.close();
    }
    final error = await db.setting(BookSettings.lastError);
    expect(error ?? '', isEmpty, reason: 'ошибка синхронизации книг');
  }
}

void main() {
  test(
    'книги: текстовая книга и место переходят на другое устройство, удаление — везде',
    () async {
      final root = await Directory.systemTemp.createTemp('books_sync');
      final a = _Device('A', root);
      final b = _Device('B', root);
      addTearDown(() async {
        await a.db.close();
        await b.db.close();
        await root.delete(recursive: true);
      });
      await a.sync.signIn(server: _server!, username: _user, password: _password);
      await b.sync.signIn(server: _server!, username: _user, password: _password);

      // Уникальная книга на каждый запуск: сервер общий.
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${root.path}/Повесть $stamp.txt');
      await file.writeAsString('Глава 1\n\nНачало $stamp.\n\nГлава 2\n\nКонец.', encoding: utf8);
      final bookId = await a.library.importTextFile(file.path);
      final book = (await a.db.bookById(bookId))!;
      await a.db.saveBookProgress(bookId, locator: const TextLocator(1, 1, 0).encode(), percent: 0.6);
      await a.syncBooks();
      expect((await a.db.bookById(bookId))!.uploaded, isTrue);

      // B получает книгу целиком и место в ней.
      await b.syncBooks();
      final onB = await b.db.bookByKey(book.key);
      expect(onB, isNotNull);
      expect(onB!.path, isNotNull);
      expect(await File(onB.path!).readAsString(), contains('Начало $stamp'));
      expect(onB.title, 'Повесть $stamp');
      final progress = await b.db.bookProgress(onB.id);
      expect(progress?.locator, 'c1:b1:o0');
      expect(progress?.device, 'A');

      // Перед открытием B спрашивает место на сервере.
      final remote = await b.books.fetchRemote(book.key);
      expect(remote?.locator, 'c1:b1:o0');
      expect(remote?.deviceName, 'A');
      expect(remote?.deviceId, isNot(await b.books.deviceId()));

      // Аудиокнига: файлы у каждого свои, место — общее.
      final audio = ScannedAudioBook(
        key: 'a:${stamp.toRadixString(16).padLeft(32, '0')}',
        title: 'Аудио',
        path: '/нет',
        format: 'mp3',
        tracks: const [ScannedTrack(path: '/нет/1.mp3', durationMs: 60000, sizeBytes: 1)],
        chapters: const [ScannedChapter(title: 'Глава', trackIdx: 0, startMs: 0)],
      );
      final audioA = await a.db.saveAudioBook(audio);
      final audioB = await b.db.saveAudioBook(audio);
      await a.db.saveBookProgress(audioA, locator: const AudioLocator(0, 42000).encode(), positionMs: 42000, percent: 0.7);
      await a.books.pushNow();
      await b.syncBooks();
      expect((await b.db.bookProgress(audioB))?.positionMs, 42000);

      // Более старое место не затирает новое.
      await b.db.saveBookProgress(audioB,
          locator: const AudioLocator(0, 1000).encode(),
          positionMs: 1000,
          percent: 0.01,
          at: DateTime.now().subtract(const Duration(days: 1)));
      await b.books.pushNow();
      expect((await b.db.bookProgress(audioB))?.positionMs, 42000, reason: 'сервер вернул более новое место');

      // Удаление на B — книга исчезает и на A.
      expect(await b.library.delete(onB), isTrue);
      expect(await b.db.bookByKey(book.key), isNull);
      await a.syncBooks();
      expect(await a.db.bookByKey(book.key), isNull);
      expect(await File(book.path!).exists(), isFalse);
    },
    skip: _server == null ? 'Нет OPODSYNC_URL: интеграционный тест только в CI' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'статистика чтения: итоги складываются по устройствам',
    () async {
      final root = await Directory.systemTemp.createTemp('stats_sync');
      final c = _Device('C', root);
      final d = _Device('D', root);
      addTearDown(() async {
        await c.db.close();
        await d.db.close();
        await root.delete(recursive: true);
      });
      await c.sync.signIn(server: _server!, username: _user, password: _password);
      await d.sync.signIn(server: _server!, username: _user, password: _password);

      await addToToday(c.db, seconds: 120, pages: 3);
      await addToToday(d.db, seconds: 60, pages: 1);
      await c.books.syncStats();
      await d.books.syncStats();
      await c.books.syncStats();

      final own = (await loadDays(c.db, days: 1, others: false)).single;
      expect(own.seconds, 120);
      final all = (await loadDays(c.db, days: 1)).single;
      final onD = (await loadDays(d.db, days: 1)).single;
      // На сервере могут быть и другие устройства этого аккаунта — сумма не меньше.
      expect(all.seconds, greaterThanOrEqualTo(180));
      expect(all.pages, greaterThanOrEqualTo(4));
      expect(onD.seconds, all.seconds);

      // Повторная отправка не удваивает: уходит итог дня, а не прибавка.
      await c.books.syncStats();
      await d.books.syncStats();
      expect((await loadDays(d.db, days: 1)).single.seconds, all.seconds);
    },
    skip: _server == null ? 'Нет OPODSYNC_URL: интеграционный тест только в CI' : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'выделения и заметки: переходят на другое устройство, правки и удаление тоже',
    () async {
      final root = await Directory.systemTemp.createTemp('highlights_sync');
      final e = _Device('E', root);
      final f = _Device('F', root);
      addTearDown(() async {
        await e.db.close();
        await f.db.close();
        await root.delete(recursive: true);
      });
      await e.sync.signIn(server: _server!, username: _user, password: _password);
      await f.sync.signIn(server: _server!, username: _user, password: _password);

      final key = 't:${DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(40, '0')}';
      final id = await e.db.addHighlight(key, start: 'c0:b1:o0', end: 'c0:b1:o12', quote: 'Цитата', color: 1);
      await e.books.syncHighlights();
      await f.books.syncHighlights();
      var onF = (await f.db.watchHighlights(key).first).single;
      expect((onF.quote, onF.color, onF.startAt, onF.dirty), ('Цитата', 1, 'c0:b1:o0', false));

      // Заметка на F — видна на E.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await f.db.updateHighlight(onF.id, note: 'Мысль');
      await f.books.syncHighlights();
      await e.books.syncHighlights();
      expect((await e.db.highlightById(id))!.note, 'Мысль');

      // Удаление на E — пропадает и на F.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await e.db.deleteHighlight(id);
      await e.books.syncHighlights();
      await f.books.syncHighlights();
      expect(await f.db.watchHighlights(key).first, isEmpty);
      expect(await f.db.dirtyHighlights(), isEmpty);
    },
    skip: _server == null ? 'Нет OPODSYNC_URL: интеграционный тест только в CI' : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'своя обложка переходит на другое устройство',
    () async {
      final root = await Directory.systemTemp.createTemp('covers_sync');
      final g = _Device('G', root);
      final h = _Device('H', root);
      addTearDown(() async {
        await g.db.close();
        await h.db.close();
        await root.delete(recursive: true);
      });
      await g.sync.signIn(server: _server!, username: _user, password: _password);
      await h.sync.signIn(server: _server!, username: _user, password: _password);

      final stamp = DateTime.now().microsecondsSinceEpoch;
      final audio = ScannedAudioBook(
        key: 'a:${stamp.toRadixString(16).padLeft(32, '0')}',
        title: 'С обложкой',
        path: '/нет',
        format: 'mp3',
        tracks: const [ScannedTrack(path: '/нет/1.mp3', durationMs: 60000, sizeBytes: 1)],
        chapters: const [ScannedChapter(title: 'Глава', trackIdx: 0, startMs: 0)],
      );
      final onG = await g.db.saveAudioBook(audio);
      final onH = await h.db.saveAudioBook(audio);
      final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.generate(200, (i) => i % 256)];
      final file = File('${root.path}/cover.png');
      await file.writeAsBytes(png);
      await g.db.setBookCover(onG, file.path);
      await g.books.coverChanged(audio.key, schedule: false);

      Future<void> covers(_Device d) async {
        final client = await d.sync.openClient();
        try {
          await d.books.syncCoversWith(client!);
        } finally {
          client?.close();
        }
      }

      await covers(g);
      await covers(h);
      final cover = (await h.db.bookById(onH))!.coverPath;
      expect(cover, isNotNull);
      expect(await File(cover!).readAsBytes(), png);

      // Повторная синхронизация не скачивает ту же обложку заново.
      await covers(h);
      expect((await h.db.bookById(onH))!.coverPath, cover);
    },
    skip: _server == null ? 'Нет OPODSYNC_URL: интеграционный тест только в CI' : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
