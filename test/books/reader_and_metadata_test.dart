import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/books/book_metadata.dart';
import 'package:podcast_app/books/text/text_book.dart';
import 'package:podcast_app/ui/books/reader/reader_selection.dart';

void main() {
  group('выделение', () {
    test('слово под пальцем', () {
      const t = 'Он сказал: «Привет, мир-сосед!»';
      final w = wordAt(t, t.indexOf('ивет'));
      expect(t.substring(w.start, w.end), 'Привет');
      final h = wordAt(t, t.indexOf('сосед'));
      expect(t.substring(h.start, h.end), 'мир-сосед');
      // В пробел после слова — берём слово слева.
      final s = wordAt(t, t.indexOf(':'));
      expect(t.substring(s.start, s.end), 'сказал');
    });

    test('диапазон по абзацам и текст выделения', () {
      final chapter = TextChapter('Глава', [
        TextBlock(TextBlockKind.paragraph, const [TextRun('Первый абзац.')]),
        TextBlock(TextBlockKind.paragraph, const [TextRun('Второй абзац.')]),
      ]);
      final sel = TextSelectionRange(const ChapterPos(1, 6), const ChapterPos(0, 7));
      expect(sel.start, const ChapterPos(0, 7));
      expect(sel.rangeIn(0, 13), (start: 7, end: 13));
      expect(sel.rangeIn(1, 13), (start: 0, end: 6));
      expect(selectedText(chapter, sel), 'абзац.\nВторой');
    });

    test('предложение вокруг слова', () {
      const t = 'Шёл дождь. Кот спал на окне! А потом ушёл.';
      final i = t.indexOf('спал');
      expect(sentenceAround(t, i, i + 4), 'Кот спал на окне!');
    });
  });

  group('обложки', () {
    test('название для поиска очищается', () {
      expect(cleanSearchTitle('01 - Мастер и Маргарита (аудиокнига) [2010].mp3'), 'Мастер и Маргарита');
      expect(cleanSearchTitle('Dune_Unabridged'), 'Dune');
    });

    test('Google Books: картинка по https, крупнее, без загиба', () {
      final body = jsonEncode({
        'items': [
          {
            'volumeInfo': {
              'title': 'Мастер и Маргарита',
              'authors': ['Михаил Булгаков'],
              'publishedDate': '1967-05',
              'description': 'Роман.',
              'imageLinks': {'thumbnail': 'http://books.google.com/books/content?id=x&printsec=frontcover&img=1&zoom=1&edge=curl'},
            },
          },
          {'volumeInfo': {'title': 'Без обложки'}},
        ],
      });
      final list = parseGoogleBooks(body);
      expect(list, hasLength(1));
      expect(list.single.imageUrl, startsWith('https://'));
      expect(list.single.imageUrl, isNot(contains('edge=curl')));
      expect(list.single.imageUrl, endsWith('&fife=w800'));
      expect(list.single.author, 'Михаил Булгаков');
      expect(list.single.year, 1967);
      expect(list.single.description, 'Роман.');
    });

    test('Open Library: обложка по номеру', () {
      final body = jsonEncode({
        'docs': [
          {'title': 'Dune', 'author_name': ['Frank Herbert'], 'cover_i': 12345, 'first_publish_year': 1965},
          {'title': 'No cover'},
        ],
      });
      final list = parseOpenLibrary(body);
      expect(list, hasLength(1));
      expect(list.single.imageUrl, 'https://covers.openlibrary.org/b/id/12345-L.jpg');
      expect(list.single.year, 1965);
    });

    test('поиск: оба каталога вперемешку, ошибка одного не мешает', () async {
      final client = MockClient((r) async {
        if (r.url.host == 'www.googleapis.com') return http.Response('oops', 500);
        return http.Response(
          jsonEncode({
            'docs': [
              {'title': 'Dune', 'cover_i': 1},
              {'title': 'Dune Messiah', 'cover_i': 2},
            ],
          }),
          200,
        );
      });
      final meta = BookMetadata(client: client);
      final found = await meta.search('Dune', author: 'Frank Herbert');
      expect(found.map((c) => c.title), ['Dune', 'Dune Messiah']);
    });

    test('скачивание отбрасывает заглушки и не картинки', () async {
      final jpeg = [0xFF, 0xD8, ...List.filled(3000, 0)];
      final client = MockClient((r) async => switch (r.url.path) {
            '/big.jpg' => http.Response.bytes(jpeg, 200),
            '/tiny.jpg' => http.Response.bytes([0xFF, 0xD8, 0, 0], 200),
            _ => http.Response('<html>' * 1000, 200),
          });
      final meta = BookMetadata(client: client);
      expect(await meta.download('https://x/big.jpg'), isNotNull);
      expect(await meta.download('https://x/tiny.jpg'), isNull);
      expect(await meta.download('https://x/page'), isNull);
    });
  });
}
