import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/books/text/image_size.dart';
import 'package:podcast_app/books/text/text_book.dart';
import 'package:podcast_app/data/db/books_dao.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/ui/books/reader/paginator.dart';

Uint8List _png(int w, int h) => Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
      (w >> 24) & 255, (w >> 16) & 255, (w >> 8) & 255, w & 255,
      (h >> 24) & 255, (h >> 16) & 255, (h >> 8) & 255, h & 255,
      8, 2, 0, 0, 0, 0, 0, 0, 0,
    ]);

Uint8List _jpeg(int w, int h) => Uint8List.fromList([
      0xFF, 0xD8, //
      0xFF, 0xE0, 0, 16, ...List.filled(14, 0),
      0xFF, 0xC0, 0, 17, 8, (h >> 8) & 255, h & 255, (w >> 8) & 255, w & 255, 3, ...List.filled(9, 0),
    ]);

void main() {
  group('картинки', () {
    test('размер по заголовку файла', () {
      expect(imageSize(_png(400, 300)), (width: 400, height: 300));
      expect(imageSize(_jpeg(1200, 900)), (width: 1200, height: 900));
      final gif = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 40, 1, 30, 0, ...List.filled(20, 0)]);
      expect(imageSize(gif), (width: 296, height: 30));
      expect(imageSize(Uint8List.fromList(List.filled(40, 7))), isNull);
    });

    test('картинка вписывается в страницу и не растягивается', () {
      final empty = Uint8List(0);
      final big = BookImage(empty, 2000, 1000);
      expect(imageBoxSize(big, 300, 500), const Size(300, 150));
      final tall = BookImage(empty, 500, 2000);
      expect(imageBoxSize(tall, 300, 400), const Size(100, 400));
      final small = BookImage(empty, 40, 20);
      expect(imageBoxSize(small, 300, 400), const Size(40, 20));
    });

    test('картинка, которая не помещается, — на следующей странице', () {
      final text = List.generate(10, (k) => 'слово$k').join(' ');
      final chapter = TextChapter('Глава', [
        TextBlock(TextBlockKind.paragraph, [TextRun(text)]),
        TextBlock(TextBlockKind.image, const [], image: 'p'),
        TextBlock(TextBlockKind.paragraph, const [TextRun('После картинки.')]),
      ]);
      final pages = paginateChapter(
        chapter,
        width: 300,
        height: 400,
        base: const TextStyle(fontSize: 16, height: 1.5),
        scaler: TextScaler.noScaling,
        images: {'p': BookImage(_png(600, 600), 600, 600)},
      );
      // Абзац занимает часть страницы, квадратная картинка 300×300 туда не входит.
      expect(pages.first.fragments.map((f) => f.block), [0]);
      expect(pages[1].fragments.first.block, 1);
      expect(pages.expand((p) => p.fragments).map((f) => f.block).toSet(), {0, 1, 2});
    });
  });

  group('выделения', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('добавить, сменить цвет, заметка, удалить', () async {
      final id = await db.addHighlight('t:1', start: 'c0:b1:o2', end: 'c0:b1:o9', quote: 'цитата', color: 2);
      var list = await db.watchHighlights('t:1').first;
      expect(list.single.color, 2);
      expect(list.single.dirty, isTrue);
      expect(list.single.uid, hasLength(32));

      await db.markHighlightSynced(list.single.uid, list.single.updatedAt);
      expect((await db.highlightById(id))!.dirty, isFalse);

      await db.updateHighlight(id, color: 0, note: 'мысль');
      final h = (await db.highlightById(id))!;
      expect((h.color, h.note, h.dirty), (0, 'мысль', true));

      await db.deleteHighlight(id);
      expect(await db.watchHighlights('t:1').first, isEmpty);
      // Удаление ждёт отправки на сервер.
      expect((await db.dirtyHighlights()).single.deleted, isTrue);
    });

    test('с сервера: более позднее изменение побеждает', () async {
      final id = await db.addHighlight('t:1', start: 'c0:b0:o0', end: 'c0:b0:o5', quote: 'x');
      final local = (await db.highlightById(id))!;
      Future<void> remote(int color, DateTime at) => db.applyRemoteHighlight(
            uid: local.uid,
            bookKey: 't:1',
            start: 'c0:b0:o0',
            end: 'c0:b0:o5',
            quote: 'x',
            note: '',
            color: color,
            deleted: false,
            createdAt: local.createdAt,
            updatedAt: at,
          );
      await remote(3, local.updatedAt.subtract(const Duration(minutes: 1)));
      expect((await db.highlightById(id))!.color, 0, reason: 'старое изменение не затирает');
      await remote(3, local.updatedAt.add(const Duration(minutes: 1)));
      expect((await db.highlightById(id))!.color, 3);

      // Новое с другого устройства.
      await db.applyRemoteHighlight(
        uid: 'ab' * 16,
        bookKey: 't:1',
        start: 'c1:b0:o0',
        end: 'c1:b0:o3',
        quote: 'y',
        note: 'н',
        color: 1,
        deleted: false,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(await db.watchHighlights('t:1').first, hasLength(2));
    });
  });
}

