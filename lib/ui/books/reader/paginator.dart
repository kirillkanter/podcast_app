/// Разбивка главы на страницы под размер экрана и настройки текста.
///
/// Каждый абзац измеряется тем же TextPainter и тем же стилем, что и при
/// отрисовке; абзац, который не влез, режется по концу последней влезшей
/// строки — продолжение начинается на следующей странице.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../books/locator.dart';
import '../../../books/text/text_book.dart';

/// Кусок абзаца на странице: символы [start, end) абзаца [block].
class PageFragment {
  const PageFragment(this.block, this.start, this.end, {required this.indent});

  final int block;
  final int start;
  final int end;

  /// Красная строка (начало абзаца).
  final bool indent;
}

class ReaderPage {
  const ReaderPage(this.fragments);

  final List<PageFragment> fragments;

  TextLocator locator(int chapter) =>
      fragments.isEmpty ? TextLocator(chapter, 0, 0) : TextLocator(chapter, fragments.first.block, fragments.first.start);
}

/// Оформление абзаца по его виду.
class BlockLook {
  const BlockLook({
    required this.style,
    this.align = TextAlign.justify,
    this.inset = 0,
    this.before = 0,
    this.after = 0,
  });

  final TextStyle style;
  final TextAlign align;

  /// Отступ слева (стихи, цитаты).
  final double inset;

  /// Отступы сверху (не в начале страницы) и снизу.
  final double before;
  final double after;
}

BlockLook blockLook(TextBlockKind kind, TextStyle base, {bool justify = true}) {
  final fs = base.fontSize ?? 18;
  final gap = fs * 0.3;
  return switch (kind) {
    TextBlockKind.heading => BlockLook(
        style: base.copyWith(fontSize: fs * 1.25, fontWeight: FontWeight.w700, height: 1.3),
        align: TextAlign.center,
        before: fs * 1.4,
        after: fs * 0.8,
      ),
    TextBlockKind.subtitle => BlockLook(
        style: base.copyWith(fontSize: fs * 1.05, fontWeight: FontWeight.w700),
        align: TextAlign.center,
        before: fs * 0.9,
        after: fs * 0.5,
      ),
    TextBlockKind.verse => BlockLook(style: base, align: TextAlign.left, inset: fs * 1.5),
    TextBlockKind.quote => BlockLook(
        style: base.copyWith(fontSize: fs * 0.95, fontStyle: FontStyle.italic),
        align: TextAlign.left,
        inset: fs * 1.5,
        before: gap,
        after: gap,
      ),
    TextBlockKind.empty => BlockLook(style: base),
    TextBlockKind.paragraph => BlockLook(style: base, after: gap, align: justify ? TextAlign.justify : TextAlign.left),
  };
}

/// Красная строка — широкий пробел в начале абзаца.
const indentChar = ' ';

/// Выделение цветом внутри абзаца: символы [start, end), цвет фона и
/// есть ли заметка (тогда текст подчёркнут).
typedef TextMark = ({int start, int end, Color color, bool note});

/// Текст куска абзаца с начертаниями. [highlight] — выделенные сейчас
/// символы абзаца (фон [highlightColor]), [marks] — сохранённые выделения.
TextSpan fragmentSpan(
  TextBlock block,
  int start,
  int end,
  BlockLook look, {
  required bool indent,
  ({int start, int end})? highlight,
  Color? highlightColor,
  Color? noteColor,
  List<TextMark> marks = const [],
}) {
  final fs = look.style.fontSize ?? 18;
  TextStyle? styleOf(TextRun r, Color? bg, bool underline) {
    if (!r.bold && !r.italic && bg == null && !underline && r.note == null) return null;
    return TextStyle(
      fontWeight: r.bold ? FontWeight.w700 : (r.note != null ? FontWeight.w600 : null),
      fontStyle: r.italic ? FontStyle.italic : null,
      backgroundColor: bg,
      decoration: underline ? TextDecoration.underline : null,
      decorationStyle: underline ? TextDecorationStyle.dotted : null,
      // Ссылка на сноску — мельче и цветом, как в бумажной книге.
      fontSize: r.note != null ? fs * 0.78 : null,
      color: r.note != null ? noteColor : null,
    );
  }

  final children = <InlineSpan>[if (indent) const TextSpan(text: indentChar)];
  final h = highlight;
  // Границы участков: края куска, выделения и сохранённых отметок.
  final cuts = <int>{start, end};
  for (final m in marks) {
    if (m.end > start && m.start < end) cuts.addAll([m.start.clamp(start, end), m.end.clamp(start, end)]);
  }
  if (h != null && h.end > start && h.start < end) cuts.addAll([h.start.clamp(start, end), h.end.clamp(start, end)]);
  final points = cuts.toList()..sort();
  for (var k = 0; k + 1 < points.length; k++) {
    final a = points[k];
    final b = points[k + 1];
    if (b <= a) continue;
    final lit = h != null && h.start <= a && h.end >= b;
    TextMark? mark;
    for (final m in marks) {
      if (m.start <= a && m.end >= b) mark = m;
    }
    final bg = lit ? highlightColor : mark?.color;
    for (final r in block.slice(a, b)) {
      children.add(TextSpan(text: r.text, style: styleOf(r, bg, mark?.note ?? false)));
    }
  }
  return TextSpan(style: look.style, children: children);
}

/// Размер картинки на странице: не больше страницы и не крупнее самой
/// картинки (мелкие украшения не растягиваются на всю ширину).
Size imageBoxSize(BookImage img, double maxWidth, double maxHeight) {
  var w = math.min(maxWidth, img.width.toDouble());
  var h = w * img.height / img.width;
  if (h > maxHeight) {
    h = maxHeight;
    w = h * img.width / img.height;
  }
  return Size(w, h);
}

/// Отступ над и под картинкой.
double imageGap(TextStyle base) => (base.fontSize ?? 18) * 0.6;

List<ReaderPage> paginateChapter(
  TextChapter chapter, {
  required double width,
  required double height,
  required TextStyle base,
  required TextScaler scaler,
  bool justify = true,
  Map<String, BookImage> images = const {},
}) {
  final pages = <ReaderPage>[];
  var frags = <PageFragment>[];
  var y = 0.0;
  final fs = base.fontSize ?? 18;
  final lineHeight = fs * (base.height ?? 1.5);

  void flush() {
    if (frags.isNotEmpty) pages.add(ReaderPage(frags));
    frags = [];
    y = 0;
  }

  for (var i = 0; i < chapter.blocks.length; i++) {
    final block = chapter.blocks[i];
    final look = blockLook(block.kind, base, justify: justify);
    if (block.kind == TextBlockKind.image) {
      final img = images[block.image];
      if (img == null) continue;
      final gap = imageGap(base);
      final size = imageBoxSize(img, width, height - gap);
      if (frags.isNotEmpty && y + gap + size.height > height) flush();
      y += (frags.isEmpty ? 0 : gap) + size.height + gap;
      frags.add(PageFragment(i, 0, 0, indent: false));
      continue;
    }
    if (block.kind == TextBlockKind.empty) {
      final h = lineHeight * 0.6;
      if (frags.isEmpty) continue; // пустая строка в начале страницы не нужна
      if (y + h > height) {
        flush();
        continue;
      }
      frags.add(PageFragment(i, 0, 0, indent: false));
      y += h;
      continue;
    }
    var start = 0;
    final text = block.text;
    while (start < text.length) {
      final indent = block.kind == TextBlockKind.paragraph && start == 0;
      final before = frags.isEmpty ? 0.0 : look.before;
      final painter = TextPainter(
        text: fragmentSpan(block, start, text.length, look, indent: indent),
        textAlign: look.align,
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width - look.inset);
      final h = painter.height;
      if (y + before + h <= height) {
        frags.add(PageFragment(i, start, text.length, indent: indent));
        y += before + h + look.after;
        painter.dispose();
        break;
      }
      final lines = painter.computeLineMetrics();
      final available = height - y - before;
      var n = 0;
      var used = 0.0;
      for (final line in lines) {
        if (used + line.height > available) break;
        used += line.height;
        n++;
      }
      // Заголовок не разрывается и не остаётся внизу страницы без текста.
      final keepTogether = block.kind == TextBlockKind.heading || block.kind == TextBlockKind.subtitle;
      if (keepTogether || n == 0 || (n == 1 && lines.length > 1 && frags.isNotEmpty)) {
        if (frags.isNotEmpty) {
          painter.dispose();
          flush();
          continue;
        }
        // Абзац выше целой страницы и начинается с неё — режем как есть.
        n = n == 0 ? 1 : n;
        if (keepTogether && n >= lines.length) {
          frags.add(PageFragment(i, start, text.length, indent: indent));
          painter.dispose();
          flush();
          break;
        }
      }
      if (n >= lines.length) {
        frags.add(PageFragment(i, start, text.length, indent: indent));
        y += before + h + look.after;
        painter.dispose();
        break;
      }
      var bottom = 0.0;
      for (var k = 0; k < n; k++) {
        bottom += lines[k].height;
      }
      final probe = painter.getPositionForOffset(Offset(1, bottom - lines[n - 1].height / 2));
      final boundary = painter.getLineBoundary(probe);
      painter.dispose();
      var cut = start + boundary.end - (indent ? indentChar.length : 0);
      if (cut <= start) cut = start + 1;
      if (cut > text.length) cut = text.length;
      frags.add(PageFragment(i, start, cut, indent: indent));
      flush();
      start = cut;
      while (start < text.length && text[start] == ' ') {
        start++;
      }
    }
  }
  flush();
  if (pages.isEmpty) pages.add(const ReaderPage([]));
  return pages;
}

/// Страница, на которой место [block]/[offset].
int pageOf(List<ReaderPage> pages, int block, int offset) {
  var result = 0;
  for (var i = 0; i < pages.length; i++) {
    final f = pages[i].fragments.firstOrNull;
    if (f == null) continue;
    if (f.block < block || (f.block == block && f.start <= offset)) {
      result = i;
    } else {
      break;
    }
  }
  return result;
}
