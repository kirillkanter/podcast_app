/// Описание эпизода: текст со ссылками и таймкодами, главы.
///
/// Таймкоды — «12:40» или «1:02:03» в тексте описания: по нажатию плеер
/// перематывает на это место. Если в описании есть строки вида
/// «12:40 — Тема», из них получаются главы (когда у эпизода нет глав
/// Podcasting 2.0).
library;

import 'dart:convert';

import 'format.dart';

sealed class DescPart {
  const DescPart(this.text);

  final String text;
}

class DescText extends DescPart {
  const DescText(super.text);
}

class DescLink extends DescPart {
  const DescLink(super.text, this.url);

  final String url;
}

class DescTime extends DescPart {
  const DescTime(super.text, this.at);

  final Duration at;
}

class Chapter {
  const Chapter(this.start, this.title);

  final Duration start;
  final String title;

  @override
  bool operator ==(Object other) => other is Chapter && other.start == start && other.title == title;

  @override
  int get hashCode => Object.hash(start, title);

  @override
  String toString() => 'Chapter($start, $title)';
}

const _linkStart = '\u0001';
const _linkMid = '\u0002';
const _linkEnd = '\u0003';

final _anchor = RegExp(
  r'''<a\s[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a\s*>''',
  caseSensitive: false,
  dotAll: true,
);
final _timecode = RegExp(r'(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\d:])');
// После «//» нужен хотя бы один знак адреса: голое «https://» — не ссылка.
final _url = RegExp(r'''https?://[^\s<>"'«»/][^\s<>"'«»]*''');

/// «12:40» → 12 мин 40 с; «1:02:03» → 1 ч 2 мин 3 с. Неправильное — null.
Duration? parseTimecode(String text) {
  final m = _timecode.matchAsPrefix(text.trim());
  if (m == null || m.end != text.trim().length) return null;
  return _durationOf(m);
}

Duration? _durationOf(Match m) {
  final h = m.group(1) == null ? 0 : int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  final s = int.parse(m.group(3)!);
  if (s >= 60 || (m.group(1) != null && min >= 60)) return null;
  return Duration(hours: h, minutes: min, seconds: s);
}

/// HTML-описание → куски: текст, ссылки, таймкоды.
List<DescPart> parseDescription(String? html) {
  if (html == null || html.trim().isEmpty) return const [];
  // Ссылки помечаем служебными символами, чтобы они пережили снятие тегов.
  final marked = html.replaceAllMapped(_anchor, (m) {
    final label = m.group(2)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    final href = m.group(1)!.trim();
    return '$_linkStart${label.isEmpty ? href : label}$_linkMid$href$_linkEnd';
  });
  final text = htmlToText(marked);

  final parts = <DescPart>[];
  var i = 0;
  while (i < text.length) {
    final start = text.indexOf(_linkStart, i);
    if (start < 0) {
      _splitPlain(text.substring(i), parts);
      break;
    }
    _splitPlain(text.substring(i, start), parts);
    final mid = text.indexOf(_linkMid, start);
    final end = mid < 0 ? -1 : text.indexOf(_linkEnd, mid);
    if (mid < 0 || end < 0) {
      _splitPlain(text.substring(start + 1), parts);
      break;
    }
    final label = text.substring(start + 1, mid);
    final url = text.substring(mid + 1, end);
    final at = parseTimecode(label);
    if (at != null) {
      parts.add(DescTime(label, at));
    } else if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('mailto:')) {
      parts.add(DescLink(label, url));
    } else {
      _splitPlain(label, parts);
    }
    i = end + 1;
  }
  return _merge(parts);
}

/// Простой текст → текст, голые ссылки и таймкоды.
void _splitPlain(String text, List<DescPart> out) {
  if (text.isEmpty) return;
  final matches = <(int, int, DescPart)>[];
  for (final m in _url.allMatches(text)) {
    // Точка или скобка в конце ссылки — обычно знак препинания.
    var url = m.group(0)!;
    while (url.isNotEmpty && '.,;:!?)]'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    matches.add((m.start, m.start + url.length, DescLink(url, url)));
  }
  for (final m in _timecode.allMatches(text)) {
    if (matches.any((x) => m.start < x.$2 && m.end > x.$1)) continue; // внутри ссылки
    final at = _durationOf(m);
    if (at != null) matches.add((m.start, m.end, DescTime(m.group(0)!, at)));
  }
  matches.sort((a, b) => a.$1.compareTo(b.$1));
  var pos = 0;
  for (final (s, e, part) in matches) {
    if (s > pos) out.add(DescText(text.substring(pos, s)));
    out.add(part);
    pos = e;
  }
  if (pos < text.length) out.add(DescText(text.substring(pos)));
}

List<DescPart> _merge(List<DescPart> parts) {
  final out = <DescPart>[];
  for (final p in parts) {
    if (p is DescText && out.isNotEmpty && out.last is DescText) {
      out[out.length - 1] = DescText(out.last.text + p.text);
    } else {
      out.add(p);
    }
  }
  return out;
}

/// Плоский текст описания (для поиска глав).
String plainText(List<DescPart> parts) => parts.map((p) => p.text).join();

final _chapterLine = RegExp(
  r'^[\s•\-–—*\[(]*((?:\d{1,2}:)?\d{1,2}:\d{2})[\])]?\s*[-–—:.|)]?\s*(.+?)\s*$',
);
final _chapterLineEnd = RegExp(r'^[\s•\-–—*]*(.+?)\s*[-–—:(\[]?\s*((?:\d{1,2}:)?\d{1,2}:\d{2})[\])]?\s*$');

/// Главы из строк описания: «12:40 — Тема» или «Тема — 12:40».
/// Меньше двух строк или время не по порядку — глав нет.
List<Chapter> chaptersFromText(String text) {
  final chapters = <Chapter>[];
  for (final line in const LineSplitter().convert(text)) {
    final start = _chapterLine.firstMatch(line);
    final end = start == null ? _chapterLineEnd.firstMatch(line) : null;
    final time = start?.group(1) ?? end?.group(2);
    final title = start?.group(2) ?? end?.group(1);
    if (time == null || title == null) continue;
    final at = parseTimecode(time);
    if (at == null || title.trim().isEmpty) continue;
    chapters.add(Chapter(at, title.trim()));
  }
  if (chapters.length < 2) return const [];
  for (var i = 1; i < chapters.length; i++) {
    if (chapters[i].start <= chapters[i - 1].start) return const [];
  }
  return chapters;
}

/// Главы Podcasting 2.0 (JSON): {"chapters": [{"startTime": 0, "title": "…"}]}.
List<Chapter> parseChaptersJson(String body) {
  final Object? data;
  try {
    data = jsonDecode(body);
  } on FormatException {
    return const [];
  }
  if (data is! Map || data['chapters'] is! List) return const [];
  final out = <Chapter>[];
  for (final c in data['chapters'] as List) {
    if (c is! Map) continue;
    if (c['toc'] == false) continue; // служебные главы не для списка
    final start = c['startTime'];
    final title = c['title'];
    if (start is! num || title is! String || title.trim().isEmpty) continue;
    out.add(Chapter(Duration(milliseconds: (start * 1000).round()), title.trim()));
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Текущая глава для позиции [position]: последняя начавшаяся.
int currentChapter(List<Chapter> chapters, Duration position) {
  var index = -1;
  for (var i = 0; i < chapters.length; i++) {
    if (chapters[i].start <= position) index = i;
  }
  return index;
}
