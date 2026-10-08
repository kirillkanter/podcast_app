/// Обычный текст: UTF-8 или windows-1251, главы — по строкам вида
/// «Глава 5», «Часть вторая», «Chapter 3».
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../feed/feed_decoder.dart' show decodeWindows1251;
import 'text_book.dart';

final _chapterLine = RegExp(
  r'^\s*(глава|часть|книга|пролог|эпилог|предисловие|послесловие|chapter|part|book|prologue|epilogue)(?!\p{L})',
  caseSensitive: false,
  unicode: true,
);

/// Сколько абзацев в куске, если глав в тексте нет.
const _chunk = 200;

String decodeText(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    final le = bytes[0] == 0xFF;
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return decodeWindows1251(bytes);
  }
}

TextBookContent parseTxt(Uint8List bytes, {required String fallbackTitle}) {
  final text = decodeText(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = text.split('\n');
  final blankRuns = RegExp(r'\n[ \t]*\n').allMatches(text).length;
  final nonEmpty = lines.where((l) => l.trim().isNotEmpty).length;

  // Абзацы разделены пустыми строками — внутри абзаца переносы просто
  // строки на странице. Иначе абзац — каждая строка.
  final paragraphs = <String>[];
  if (blankRuns > nonEmpty / 4) {
    for (final para in text.split(RegExp(r'\n[ \t]*\n'))) {
      final t = para.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
      if (t.isNotEmpty) paragraphs.add(t);
    }
  } else {
    for (final l in lines) {
      final t = l.trim();
      if (t.isNotEmpty) paragraphs.add(t);
    }
  }

  bool isHeading(String s) => s.length <= 80 && _chapterLine.hasMatch(s);
  final headings = paragraphs.where(isHeading).length;

  final chapters = <TextChapter>[];
  var blocks = <TextBlock>[];
  String? title;
  void close() {
    if (blocks.isEmpty) return;
    chapters.add(TextChapter(title ?? 'Часть ${chapters.length + 1}', blocks));
    blocks = [];
    title = null;
  }

  for (final para in paragraphs) {
    if (headings >= 2 && isHeading(para)) {
      close();
      title = para;
      blocks.add(TextBlock(TextBlockKind.heading, [TextRun(para)]));
      continue;
    }
    if (headings < 2 && blocks.length >= _chunk) close();
    blocks.add(TextBlock(TextBlockKind.paragraph, [TextRun(para)]));
  }
  close();
  if (chapters.isEmpty) chapters.add(TextChapter('Текст', [TextBlock(TextBlockKind.paragraph, const [TextRun(' ')])]));
  return TextBookContent(title: fallbackTitle, chapters: chapters);
}
