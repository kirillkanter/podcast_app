import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:podcast_app/books/book_models.dart';
import 'package:podcast_app/books/locator.dart';
import 'package:podcast_app/data/db/books_dao.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/player/podcast_audio_handler.dart';

import '../player/podcast_audio_handler_test.dart' show FakeJustAudio;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FakeJustAudio platform;
  late PodcastAudioHandler handler;
  late int bookId;
  final pushes = <Duration>[];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    platform = FakeJustAudio();
    JustAudioPlatform.instance = platform;
    pushes.clear();
    handler = PodcastAudioHandler(
      db,
      player: AudioPlayer(handleAudioSessionActivation: false),
      onBookProgress: pushes.add,
    );
    // Фальшивый плеер сообщает длительность каждого файла — 1 час.
    bookId = await db.saveAudioBook(const ScannedAudioBook(
      key: 'a:00000000000000000000000000000001',
      title: 'Мастер и Маргарита',
      author: 'Булгаков',
      path: '/books/mm',
      format: 'mp3',
      tracks: [
        ScannedTrack(path: '/books/mm/01.mp3', durationMs: 3600000, sizeBytes: 1),
        ScannedTrack(path: '/books/mm/02.mp3', durationMs: 3600000, sizeBytes: 1),
      ],
      chapters: [
        ScannedChapter(title: 'Глава 1', trackIdx: 0, startMs: 0),
        ScannedChapter(title: 'Глава 2', trackIdx: 0, startMs: 1800000),
        ScannedChapter(title: 'Глава 3', trackIdx: 1, startMs: 0),
      ],
    ));
  });

  tearDown(() async {
    await handler.stop();
    await db.close();
  });

  String loadedUri() {
    final playlist = platform.lastLoad!.audioSourceMessage as ConcatenatingAudioSourceMessage;
    return (playlist.children.single as UriAudioSourceMessage).uri;
  }

  test('книга играет файл за файлом, место сохраняется от начала книги', () async {
    await handler.playBook(bookId);
    await pumpEventQueue();
    expect(handler.currentBookId, bookId);
    expect(handler.mediaItem.value?.extras?['bookId'], bookId);
    expect(handler.mediaItem.value?.title, 'Глава 1');
    expect(loadedUri(), endsWith('/books/mm/01.mp3'));
    expect(handler.bookTimeline.totalMs, 7200000);

    await handler.seek(const Duration(minutes: 40));
    await handler.pause();
    await pumpEventQueue();
    var p = await db.bookProgress(bookId);
    expect(p?.locator, const AudioLocator(0, 2400000).encode());
    expect(p?.positionMs, 2400000);
    expect(p?.percent, closeTo(1 / 3, 0.001));
    expect(p?.dirty, isTrue);
    expect(handler.currentChapter, 1, reason: '40 минут — уже вторая глава');
    expect(pushes, isNotEmpty, reason: 'пауза — место отправляется на сервер');

    // Конец первого файла — дальше второй.
    platform.player!.complete();
    await pumpEventQueue();
    expect(loadedUri(), endsWith('/books/mm/02.mp3'));
    p = await db.bookProgress(bookId);
    expect(p?.locator, const AudioLocator(1, 0).encode());
    expect(handler.currentChapter, 2);

    // Перемотка назад через границу файлов.
    await handler.seekBook(const Duration(minutes: 59));
    await pumpEventQueue();
    expect(loadedUri(), endsWith('/books/mm/01.mp3'));
    expect(handler.bookPosition.inMinutes, 59);
  });

  test('переход по главам', () async {
    await handler.playBook(bookId);
    await pumpEventQueue();
    await handler.nextChapter();
    await pumpEventQueue();
    expect(handler.currentChapter, 1);
    expect(handler.bookPosition, const Duration(minutes: 30));
    await handler.nextChapter();
    await pumpEventQueue();
    expect(handler.currentChapter, 2);
    expect(loadedUri(), endsWith('/books/mm/02.mp3'));
    // В начале главы «назад» — к предыдущей.
    await handler.previousChapter();
    await pumpEventQueue();
    expect(handler.currentChapter, 1);
  });

  test('запуск с сохранённого места; дослушанная книга — на полку «готово»', () async {
    await db.saveBookProgress(bookId, locator: const AudioLocator(1, 120000).encode(), positionMs: 3720000, percent: 0.51);
    await handler.playBook(bookId);
    await pumpEventQueue();
    expect(loadedUri(), endsWith('/books/mm/02.mp3'));
    expect(handler.bookPosition, const Duration(milliseconds: 3720000));

    platform.player!.complete();
    await pumpEventQueue();
    await pumpEventQueue();
    expect(handler.currentBookId, isNull);
    expect((await db.bookById(bookId))!.shelf, BookShelf.done);
    expect((await db.bookProgress(bookId))!.percent, 1);
  });

  test('эпизод после книги: книга сохраняет место и выходит из плеера', () async {
    await handler.playBook(bookId, at: const AudioLocator(0, 600000));
    await pumpEventQueue();
    await handler.stop();
    expect(handler.currentBookId, isNull);
    expect((await db.bookProgress(bookId))?.locator, const AudioLocator(0, 600000).encode());
  });
}
