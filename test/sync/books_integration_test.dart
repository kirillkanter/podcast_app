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
}
