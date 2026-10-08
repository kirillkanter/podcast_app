import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/books/text/text_book.dart';
import 'package:podcast_app/ui/books/reader/paginator.dart';

TextChapter _chapter() {
  final blocks = <TextBlock>[
    TextBlock(TextBlockKind.heading, const [TextRun('Глава первая')]),
  ];
  for (var i = 0; i < 40; i++) {
    final words = List.generate(10 + (i * 7) % 60, (k) => 'слово$k').join(' ');
    blocks.add(TextBlock(TextBlockKind.paragraph, [TextRun('Абзац $i: '), TextRun(words, italic: i.isEven)]));
    if (i % 9 == 0) blocks.add(TextBlock(TextBlockKind.empty, const [TextRun(' ')]));
  }
  return TextChapter('Глава первая', blocks);
}

void main() {
  const base = TextStyle(fontSize: 16, height: 1.5);

  test('страницы покрывают весь текст по порядку, без потерь и повторов', () {
    final chapter = _chapter();
    final pages = paginateChapter(chapter, width: 320, height: 420, base: base, scaler: TextScaler.noScaling);
    expect(pages.length, greaterThan(3));

    // Собираем текст обратно из кусков.
    final rebuilt = <int, StringBuffer>{};
    var lastBlock = -1;
    var lastEnd = 0;
    for (final page in pages) {
      for (final f in page.fragments) {
        final block = chapter.blocks[f.block];
        if (block.kind == TextBlockKind.empty) continue;
        if (f.block == lastBlock) {
          // Продолжение абзаца: с того места, где закончился кусок (пробелы на стыке пропущены).
          expect(block.text.substring(lastEnd, f.start).trim(), isEmpty);
        } else {
          expect(f.block, greaterThan(lastBlock));
          expect(f.start, 0);
        }
        rebuilt.putIfAbsent(f.block, StringBuffer.new).write(block.text.substring(f.start, f.end));
        lastBlock = f.block;
        lastEnd = f.end;
      }
    }
    for (var i = 0; i < chapter.blocks.length; i++) {
      final b = chapter.blocks[i];
      if (b.kind == TextBlockKind.empty) continue;
      expect(rebuilt[i]?.toString().replaceAll(' ', ''), b.text.replaceAll(' ', ''), reason: 'абзац $i');
    }
  });

  test('каждая страница помещается по высоте', () {
    final chapter = _chapter();
    const height = 420.0;
    final pages = paginateChapter(chapter, width: 320, height: height, base: base, scaler: TextScaler.noScaling);
    for (final page in pages) {
      var y = 0.0;
      for (final (i, f) in page.fragments.indexed) {
        final block = chapter.blocks[f.block];
        final look = blockLook(block.kind, base);
        if (block.kind == TextBlockKind.empty) {
          y += 16 * 1.5 * 0.6;
          continue;
        }
        final painter = TextPainter(
          text: fragmentSpan(block, f.start, f.end, look, indent: f.indent),
          textAlign: look.align,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 320 - look.inset);
        y += (i == 0 ? 0 : look.before) + painter.height;
        expect(y, lessThanOrEqualTo(height + 0.5));
        y += look.after;
      }
    }
  });

  test('страница по месту в книге', () {
    final chapter = _chapter();
    final pages = paginateChapter(chapter, width: 320, height: 420, base: base, scaler: TextScaler.noScaling);
    for (var i = 0; i < pages.length; i++) {
      final f = pages[i].fragments.first;
      expect(pageOf(pages, f.block, f.start), i);
    }
    expect(pageOf(pages, 0, 0), 0);
    expect(pageOf(pages, 9999, 0), pages.length - 1);
  });
}
