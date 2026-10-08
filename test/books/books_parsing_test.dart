import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:podcast_app/books/audio_tags.dart';
import 'package:podcast_app/books/book_scanner.dart';
import 'package:podcast_app/books/book_timeline.dart';
import 'package:podcast_app/books/locator.dart';
import 'package:podcast_app/books/text/text_book.dart';
import 'package:podcast_app/books/text/text_parser.dart';

import 'book_test_files.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('books_test'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<String> write(String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, name));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f.path;
  }

  group('теги аудио', () {
    test('MP3: ID3v2.3, длительность по битрейту, главы CHAP', () async {
      final path = await write('a.mp3', mp3(frames: [
        id3Text('TIT2', 'Глава 1'),
        id3Text('TALB', 'Мастер и Маргарита'),
        id3Text('TPE1', 'Михаил Булгаков'),
        id3Text('TRCK', '1/32'),
        id3Chapter('ch0', 0, 500, 'Начало'),
        id3Chapter('ch1', 500, 1000, 'Продолжение'),
      ], audioBytes: 32000));
      final t = await readAudioTags(path);
      expect(t.title, 'Глава 1');
      expect(t.album, 'Мастер и Маргарита');
      expect(t.artist, 'Михаил Булгаков');
      expect(t.track, 1);
      expect(t.durationMs, 2000);
      expect(t.chapters.map((c) => (c.startMs, c.title)), [(0, 'Начало'), (500, 'Продолжение')]);
    });

    test('MP3 без тегов: ID3v1 в windows-1251', () async {
      final tag = List<int>.filled(128, 0)..setAll(0, ascii.encode('TAG'));
      tag.setAll(3, cp1251('Книга'));
      tag.setAll(33, cp1251('Автор'));
      final audio = List<int>.filled(16000, 0)..setAll(0, [0xFF, 0xFB, 0x90, 0x00]);
      final path = await write('b.mp3', [...audio, ...tag]);
      final t = await readAudioTags(path);
      expect(t.title, 'Книга');
      expect(t.artist, 'Автор');
      expect(t.durationMs, 1000);
    });

    test('M4B: длительность, теги iTunes, обложка, главы Nero', () async {
      final path = await write('c.m4b', m4b(
        durationMs: 3600000,
        title: 'Пикник на обочине',
        artist: 'Стругацкие',
        cover: List.filled(100, 7),
        chapters: [(0, 'Пролог'), (600000, 'Глава 1'), (1800000, 'Глава 2')],
      ));
      final t = await readAudioTags(path);
      expect(t.durationMs, 3600000);
      expect(t.title, 'Пикник на обочине');
      expect(t.artist, 'Стругацкие');
      expect(t.cover, hasLength(100));
      expect(t.chapters.map((c) => (c.startMs, c.title)), [(0, 'Пролог'), (600000, 'Глава 1'), (1800000, 'Глава 2')]);
    });

    test('повреждённый файл — пустые теги, без исключения', () async {
      final path = await write('bad.mp3', [1, 2, 3]);
      final t = await readAudioTags(path);
      expect(t.title, isNull);
    });
  });

  group('поиск аудиокниг', () {
    test('подпапка — книга, файлы по порядку, главы по файлам, общий ключ', () async {
      final root = p.join(tmp.path, 'Аудиокниги');
      for (final n in ['10', '2', '1']) {
        await write('Аудиокниги/Мастер и Маргарита/$n.mp3', mp3(frames: [
          id3Text('TALB', 'Мастер и Маргарита'),
          id3Text('TPE1', 'Булгаков'),
          id3Text('TIT2', 'Глава $n'),
        ]));
      }
      await write('Аудиокниги/Мастер и Маргарита/cover.jpg', List.filled(100, 1));
      await write('Аудиокниги/Пикник.m4b', m4b(durationMs: 5000, title: 'Пикник', chapters: [(0, 'А'), (2000, 'Б')]));
      await write('Аудиокниги/readme.txt', utf8.encode('не книга'));

      final books = await BookScanner.scanRoot(root);
      expect(books.map((b) => b.title), ['Мастер и Маргарита', 'Пикник']);
      final mm = books.first;
      expect(mm.tracks.map((t) => p.basename(t.path)), ['1.mp3', '2.mp3', '10.mp3']);
      expect(mm.chapters.map((c) => c.title), ['Глава 1', 'Глава 2', 'Глава 10']);
      expect(mm.author, 'Булгаков');
      expect(mm.durationMs, 3000);
      expect(mm.coverFile, endsWith('cover.jpg'));
      expect(mm.key, startsWith('a:'));

      final picnic = books.last;
      expect(picnic.tracks, hasLength(1));
      expect(picnic.chapters.map((c) => (c.trackIdx, c.startMs)), [(0, 0), (0, 2000)]);

      // Та же книга в папке с другим названием — тот же ключ.
      final copy = Directory(p.join(tmp.path, 'Другая папка'));
      await copy.create();
      for (final f in mm.tracks) {
        await File(f.path).copy(p.join(copy.path, p.basename(f.path)));
      }
      final again = await BookScanner.scanFolder(copy.path);
      expect(again!.key, mm.key);
    });

    test('сортировка имён по-человечески', () {
      final names = ['Глава 10.mp3', 'Глава 2.mp3', 'глава 1.mp3', 'CD2/01.mp3', 'CD1/02.mp3'];
      names.sort(naturalCompare);
      expect(names, ['CD1/02.mp3', 'CD2/01.mp3', 'глава 1.mp3', 'Глава 2.mp3', 'Глава 10.mp3']);
    });
  });

  group('время книги', () {
    final t = BookTimeline([1000, 2000, 3000], [
      (trackIdx: 0, startMs: 0),
      (trackIdx: 1, startMs: 0),
      (trackIdx: 1, startMs: 1500),
      (trackIdx: 2, startMs: 0),
    ]);

    test('файл и место по месту в книге', () {
      expect(t.totalMs, 6000);
      expect(t.locate(0), (track: 0, ms: 0));
      expect(t.locate(999), (track: 0, ms: 999));
      expect(t.locate(1000), (track: 1, ms: 0));
      expect(t.locate(5999), (track: 2, ms: 2999));
      expect(t.locate(99999), (track: 2, ms: 96999));
      expect(t.globalOf(2, 500), 3500);
    });

    test('главы', () {
      expect(t.chapterStarts, [0, 1000, 2500, 3000]);
      expect(t.chapterAt(2499), 1);
      expect(t.chapterAt(2500), 2);
      expect(t.chapterEnd(3), 6000);
    });
  });

  test('места в книге: запись и разбор', () {
    expect(AudioLocator.parse('t3:12500'), const AudioLocator(3, 12500));
    expect(AudioLocator.parse('мусор'), isNull);
    expect(TextLocator.parse(const TextLocator(2, 15, 40).encode()), const TextLocator(2, 15, 40));
    expect(const TextLocator(1, 5, 0).compareTo(const TextLocator(1, 4, 99)), greaterThan(0));
  });

  group('текстовые книги', () {
    test('FB2 в windows-1251: главы, вложенные разделы, курсив, стихи, обложка', () {
      final book = parseTextBook(Uint8List.fromList(cp1251(fb2Sample)), 'fb2', fallbackTitle: 'файл');
      expect(book.title, 'Рассказы');
      expect(book.author, 'Антон Чехов');
      expect(book.language, 'ru');
      expect(book.description, 'Сборник рассказов.');
      expect(book.cover, isNotNull);
      expect(book.chapters.map((c) => c.title), ['Дама с собачкой', 'Ионыч']);
      final first = book.chapters.first.blocks;
      // Заголовки книги и части — в начале первой главы.
      expect(first.where((b) => b.kind == TextBlockKind.heading).map((b) => b.text),
          ['Рассказы', 'Часть первая', 'Дама с собачкой']);
      final para = first.firstWhere((b) => b.text.startsWith('Говорили'));
      expect(para.text, 'Говорили, что на набережной появилось новое лицо.');
      expect(para.runs.where((r) => r.italic).map((r) => r.text), ['новое лицо']);
      expect(first.any((b) => b.kind == TextBlockKind.quote && b.text == 'Эпиграф'), isTrue);
      final verses = book.chapters[1].blocks.where((b) => b.kind == TextBlockKind.verse).map((b) => b.text);
      expect(verses, ['Строка один', 'Строка два']);
      // Примечания в главы не попадают.
      expect(book.chapters.expand((c) => c.blocks).any((b) => b.text == 'Примечание'), isFalse);
      // Ссылка на примечание — сноска по нажатию.
      final noted = first.firstWhere((b) => b.text.startsWith('Второй'));
      final ref = noted.runs.firstWhere((r) => r.note != null);
      expect(ref.text, '[1]');
      expect(book.notes[ref.note], 'Примечание');
    });

    test('EPUB 3: оглавление, главы, сущности HTML, обложка', () {
      final book = parseTextBook(epubSample(), 'epub', fallbackTitle: 'файл');
      expect(book.title, 'The Story');
      expect(book.author, 'Jane Doe');
      expect(book.language, 'en');
      expect(book.cover, hasLength(100));
      expect(book.chapters.map((c) => c.title), ['Chapter One', 'Chapter Two']);
      final blocks = book.chapters.first.blocks.map((b) => b.text).toList();
      expect(blocks, [
        'One',
        'It was a dark and stormy night—really.',
        'Nested bold text.',
        'Line one',
        'Line two',
      ]);
      final p1 = book.chapters.first.blocks[1];
      expect(p1.runs.where((r) => r.italic).map((r) => r.text), ['dark']);
      expect(book.chapters.first.blocks.first.kind, TextBlockKind.heading);
    });

    test('EPUB: сноска по ссылке, текст сноски не в главе', () {
      final book = parseTextBook(epubSample(), 'epub', fallbackTitle: 'файл');
      final second = book.chapters[1].blocks;
      expect(second.map((b) => b.text), ['Second chapter.1']);
      final ref = second.single.runs.firstWhere((r) => r.note != null);
      expect(ref.text, '1');
      expect(book.notes[ref.note], 'A short note.');
    });

    test('TXT: главы по строкам «Глава», windows-1251', () {
      const text = 'Глава 1\n\nПервый абзац.\nПродолжение строки.\n\nВторой абзац.\n\nГлава 2\n\nТретий.';
      final book = parseTextBook(Uint8List.fromList(cp1251(text)), 'txt', fallbackTitle: 'Повесть');
      expect(book.title, 'Повесть');
      expect(book.chapters.map((c) => c.title), ['Глава 1', 'Глава 2']);
      expect(book.chapters.first.blocks.map((b) => b.text), ['Глава 1', 'Первый абзац. Продолжение строки.', 'Второй абзац.']);
    });

    test('TXT без глав делится на части', () {
      final text = List.generate(450, (i) => 'Строка $i').join('\n');
      final book = parseTextBook(Uint8List.fromList(utf8.encode(text)), 'txt', fallbackTitle: 'x');
      expect(book.chapters.length, 3);
      expect(book.length, book.chapters.fold<int>(0, (s, c) => s + c.length));
      expect(book.charsBefore(1), book.chapters.first.length);
    });

    test('куски абзаца для страниц', () {
      final b = TextBlock(TextBlockKind.paragraph, const [TextRun('Раз '), TextRun('два', italic: true), TextRun(' три')]);
      expect(b.slice(2, 6).map((r) => (r.text, r.italic)), [('з ', false), ('дв', true)]);
      expect(b.slice(0, b.length).map((r) => r.text).join(), b.text);
    });

    test('формат по имени файла', () {
      expect(textFormatOf('/x/Книга.FB2'), 'fb2');
      expect(textFormatOf('книга.fb2.zip'), 'fbz');
      expect(textFormatOf('a.pdf'), isNull);
    });

    test('битый EPUB — понятная ошибка', () {
      expect(() => parseTextBook(Uint8List.fromList([1, 2, 3]), 'epub', fallbackTitle: 'x'), throwsFormatException);
    });
  });
}
