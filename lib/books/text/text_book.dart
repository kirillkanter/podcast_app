/// Текстовая книга после разбора: главы из абзацев, абзацы из кусков
/// текста с начертанием. Одинакова для EPUB, FB2 и TXT — читалка
/// работает только с ней.
library;

import 'dart:typed_data';

enum TextBlockKind {
  paragraph,

  /// Заголовок главы или раздела.
  heading,

  /// Подзаголовок внутри главы.
  subtitle,

  /// Строка стихотворения.
  verse,

  /// Эпиграф и цитата — с отступом, курсивом.
  quote,

  /// Пустая строка-разделитель.
  empty,
}

class TextRun {
  const TextRun(this.text, {this.bold = false, this.italic = false});

  final String text;
  final bool bold;
  final bool italic;

  TextRun withText(String t) => TextRun(t, bold: bold, italic: italic);
}

class TextBlock {
  TextBlock(this.kind, this.runs) : text = runs.map((r) => r.text).join();

  final TextBlockKind kind;
  final List<TextRun> runs;

  /// Весь текст абзаца.
  final String text;

  int get length => text.length;

  /// Куски с [start] по [end] символ (для разбивки на страницы).
  List<TextRun> slice(int start, int end) {
    final out = <TextRun>[];
    var pos = 0;
    for (final r in runs) {
      final rs = pos;
      final re = pos + r.text.length;
      pos = re;
      if (re <= start || rs >= end) continue;
      final a = start > rs ? start - rs : 0;
      final b = end < re ? end - rs : r.text.length;
      if (b > a) out.add(r.withText(r.text.substring(a, b)));
    }
    return out;
  }
}

class TextChapter {
  TextChapter(this.title, this.blocks) : length = blocks.fold(0, (s, b) => s + b.length);

  final String title;
  final List<TextBlock> blocks;

  /// Символов в главе.
  final int length;
}

class TextBookContent {
  TextBookContent({
    required this.title,
    required this.chapters,
    this.author,
    this.language,
    this.description,
    this.cover,
  }) : length = chapters.fold(0, (s, c) => s + c.length);

  final String title;
  final String? author;
  final String? language;
  final String? description;
  final Uint8List? cover;
  final List<TextChapter> chapters;

  /// Символов в книге.
  final int length;

  /// Символов до начала главы [chapter].
  int charsBefore(int chapter) {
    var n = 0;
    for (var i = 0; i < chapter && i < chapters.length; i++) {
      n += chapters[i].length;
    }
    return n;
  }
}

/// Собирает абзац из кусков: схлопывает пробелы, обрезает края.
class BlockBuilder {
  final _runs = <TextRun>[];

  bool get isEmpty => _runs.every((r) => r.text.trim().isEmpty);

  void add(String text, {bool bold = false, bool italic = false}) {
    if (text.isEmpty) return;
    // Неразрывный пробел (\u00A0) сохраняется.
    final normalized = text.replaceAll(RegExp(r'[ \t\r\n\f]+'), ' ');
    if (_runs.isNotEmpty && _runs.last.bold == bold && _runs.last.italic == italic) {
      _runs[_runs.length - 1] = _runs.last.withText(_runs.last.text + normalized);
    } else {
      _runs.add(TextRun(normalized, bold: bold, italic: italic));
    }
  }

  /// Готовый абзац или `null`, если в нём нет текста.
  TextBlock? build(TextBlockKind kind) {
    if (isEmpty) {
      _runs.clear();
      return null;
    }
    final runs = List<TextRun>.of(_runs);
    _runs.clear();
    // Пробелы по краям абзаца и двойные на стыках кусков.
    runs[0] = runs[0].withText(runs[0].text.trimLeft());
    runs[runs.length - 1] = runs.last.withText(runs.last.text.trimRight());
    for (var i = 1; i < runs.length; i++) {
      if (runs[i - 1].text.endsWith(' ') && runs[i].text.startsWith(' ')) {
        runs[i] = runs[i].withText(runs[i].text.substring(1));
      }
    }
    final clean = runs.where((r) => r.text.isNotEmpty).toList();
    if (clean.isEmpty) return null;
    return TextBlock(kind, clean);
  }
}
