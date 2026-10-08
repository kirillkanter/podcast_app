/// Выделение текста в читалке: место в главе, слово под пальцем,
/// выделенный текст и предложение вокруг него.
library;

import '../../../books/text/text_book.dart';

/// Место в главе: абзац и символ в нём.
class ChapterPos implements Comparable<ChapterPos> {
  const ChapterPos(this.block, this.offset);

  final int block;
  final int offset;

  @override
  int compareTo(ChapterPos o) => block != o.block ? block.compareTo(o.block) : offset.compareTo(o.offset);

  bool operator <(ChapterPos o) => compareTo(o) < 0;

  @override
  bool operator ==(Object o) => o is ChapterPos && o.block == block && o.offset == offset;

  @override
  int get hashCode => Object.hash(block, offset);

  @override
  String toString() => 'ChapterPos($block, $offset)';
}

/// Выделение: от [start] до [end] (не включая).
class TextSelectionRange {
  TextSelectionRange(ChapterPos a, ChapterPos b)
      : start = a < b ? a : b,
        end = a < b ? b : a;

  final ChapterPos start;
  final ChapterPos end;

  bool get isEmpty => start == end;

  /// Выделенные символы абзаца [block] длиной [length] или `null`.
  ({int start, int end})? rangeIn(int block, int length) {
    if (block < start.block || block > end.block) return null;
    final s = block == start.block ? start.offset : 0;
    final e = block == end.block ? end.offset : length;
    return e > s ? (start: s, end: e) : null;
  }
}

final _wordChar = RegExp(r"[\p{L}\p{N}'’\-]", unicode: true);

/// Слово вокруг символа [offset] в [text]: границы [start, end).
({int start, int end}) wordAt(String text, int offset) {
  if (text.isEmpty) return (start: 0, end: 0);
  var i = offset.clamp(0, text.length - 1);
  // Попали в пробел или знак — берём ближайшее слово слева.
  if (!_wordChar.hasMatch(text[i]) && i > 0 && _wordChar.hasMatch(text[i - 1])) i--;
  if (!_wordChar.hasMatch(text[i])) return (start: i, end: i + 1);
  var s = i;
  var e = i + 1;
  while (s > 0 && _wordChar.hasMatch(text[s - 1])) {
    s--;
  }
  while (e < text.length && _wordChar.hasMatch(text[e])) {
    e++;
  }
  // Дефис или апостроф по краям — не часть слова.
  while (e > s + 1 && RegExp(r"['’\-]").hasMatch(text[e - 1])) {
    e--;
  }
  while (s < e - 1 && RegExp(r"['’\-]").hasMatch(text[s])) {
    s++;
  }
  return (start: s, end: e);
}

/// Выделенный текст главы.
String selectedText(TextChapter chapter, TextSelectionRange sel) {
  final parts = <String>[];
  for (var b = sel.start.block; b <= sel.end.block && b < chapter.blocks.length; b++) {
    final text = chapter.blocks[b].text;
    final r = sel.rangeIn(b, text.length);
    if (r != null) parts.add(text.substring(r.start, r.end));
  }
  return parts.join('\n').trim();
}

/// Предложение, в котором стоит выделение (для перевода слова в контексте).
String sentenceAround(String text, int start, int end) {
  if (text.isEmpty) return '';
  var s = start.clamp(0, text.length);
  var e = end.clamp(0, text.length);
  const stops = '.!?…';
  while (s > 0 && !stops.contains(text[s - 1])) {
    s--;
  }
  while (e < text.length && !stops.contains(text[e])) {
    e++;
  }
  if (e < text.length) e++;
  return text.substring(s, e).trim();
}
