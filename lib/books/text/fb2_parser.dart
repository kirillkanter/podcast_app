/// FB2 (FictionBook) — самый распространённый формат русских электронных книг.
/// FBZ — тот же FB2 в zip-архиве.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../feed/feed_decoder.dart' show decodeFeedBytes;
import 'text_book.dart';
import 'xml_helpers.dart';

const _italic = {'emphasis', 'i'};
const _bold = {'strong', 'b'};

TextBookContent parseFbz(Uint8List bytes, {required String fallbackTitle}) {
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final f in archive.files) {
    if (f.isFile && f.name.toLowerCase().endsWith('.fb2')) {
      return parseFb2(f.content, fallbackTitle: fallbackTitle);
    }
  }
  throw const FormatException('В архиве нет файла FB2');
}

TextBookContent parseFb2(Uint8List bytes, {required String fallbackTitle}) {
  final text = decodeFeedBytes(bytes).text;
  final doc = XmlDocument.parse(text);
  final root = doc.rootElement;

  final description = kid(root, 'description');
  final info = description == null ? null : kid(description, 'title-info');
  final title = info == null ? null : kid(info, 'book-title');
  final authors = info == null
      ? const <String>[]
      : [
          for (final a in kids(info, 'author'))
            [
              for (final part in ['first-name', 'middle-name', 'last-name'])
                if (kid(a, part) != null) textOf(kid(a, part)!),
            ].where((s) => s.isNotEmpty).join(' '),
        ].where((s) => s.isNotEmpty).toList();
  final lang = info == null ? null : kid(info, 'lang');
  final annotation = info == null ? null : kid(info, 'annotation');

  // Обложка: ссылка из coverpage на <binary id="…">.
  Uint8List? cover;
  final coverImage = info == null ? null : kid(info, 'coverpage');
  final href = coverImage == null
      ? null
      : coverImage.childElements.where((e) => e.name.local == 'image').map((e) => attr(e, 'href')).firstOrNull;
  if (href != null && href.startsWith('#')) {
    for (final b in kids(root, 'binary')) {
      if (attr(b, 'id') == href.substring(1)) {
        try {
          cover = base64.decode(b.innerText.replaceAll(RegExp(r'\s+'), ''));
        } catch (_) {}
        break;
      }
    }
  }

  // Сноски: отдельные body «notes»/«comments», раздел с id — одна сноска.
  final notes = <String, String>{};
  for (final body in kids(root, 'body')) {
    final name = attr(body, 'name');
    if (name != 'notes' && name != 'comments' && name != 'footnotes') continue;
    for (final sec in body.descendants.whereType<XmlElement>().where((e) => e.name.local == 'section')) {
      final id = attr(sec, 'id');
      if (id == null || id.isEmpty) continue;
      final text = [
        for (final c in sec.childElements)
          if (c.name.local != 'title' && c.name.local != 'section') textOf(c),
      ].where((t) => t.isNotEmpty).join('\n');
      if (text.isNotEmpty) notes[id] = text.length > 4000 ? '${text.substring(0, 4000)}…' : text;
    }
  }
  _noteRef = (a) {
    final href = attr(a, 'href');
    if (href == null || !href.startsWith('#')) return null;
    final id = href.substring(1);
    return notes.containsKey(id) ? id : null;
  };

  final chapters = <TextChapter>[];
  for (final body in kids(root, 'body')) {
    // Примечания и комментарии — отдельные body; в главы не идут.
    final name = attr(body, 'name');
    if (name == 'notes' || name == 'comments' || name == 'footnotes') continue;
    final sections = kids(body, 'section').toList();
    if (sections.isEmpty) {
      final blocks = <TextBlock>[];
      _content(body, blocks, skipSections: true);
      if (blocks.isNotEmpty) chapters.add(TextChapter(_title(body) ?? 'Текст', blocks));
      continue;
    }
    // Эпиграф и заголовок книги перед первой главой — в первую главу.
    final intro = <TextBlock>[];
    for (final c in body.childElements) {
      if (c.name.local == 'section') break;
      _element(c, intro);
    }
    for (var i = 0; i < sections.length; i++) {
      _section(sections[i], chapters, i == 0 ? intro : const []);
    }
  }
  if (chapters.isEmpty) chapters.add(TextChapter('Текст', [TextBlock(TextBlockKind.paragraph, const [TextRun('')])]));

  return TextBookContent(
    title: title == null || textOf(title).isEmpty ? fallbackTitle : textOf(title),
    author: authors.isEmpty ? null : authors.join(', '),
    language: lang == null ? null : textOf(lang),
    description: annotation == null ? null : textOf(annotation),
    cover: cover,
    chapters: chapters,
    notes: notes,
  );
}

/// Ссылка на сноску текущей книги (разбор идёт в одном потоке, по книге за раз).
String? Function(XmlElement link)? _noteRef;

String? _title(XmlElement section) {
  final t = kid(section, 'title');
  if (t == null) return null;
  final parts = [for (final p in t.childElements) textOf(p)].where((s) => s.isNotEmpty).toList();
  final s = parts.isEmpty ? textOf(t) : parts.join('. ');
  return s.isEmpty ? null : s;
}

/// Глава — раздел с текстом. Раздел только из подразделов («Часть первая»)
/// главой не становится: его заголовок открывает первую вложенную главу.
void _section(XmlElement section, List<TextChapter> chapters, List<TextBlock> pending) {
  final subs = kids(section, 'section').toList();
  final title = _title(section);
  if (subs.isEmpty) {
    final blocks = <TextBlock>[...pending];
    _content(section, blocks);
    if (blocks.isEmpty) return;
    chapters.add(TextChapter(title ?? _firstHeading(pending) ?? 'Глава ${chapters.length + 1}', blocks));
    return;
  }
  final head = <TextBlock>[...pending];
  for (final c in section.childElements) {
    if (c.name.local == 'section') break;
    _element(c, head);
  }
  for (var i = 0; i < subs.length; i++) {
    _section(subs[i], chapters, i == 0 ? head : const []);
  }
}

String? _firstHeading(List<TextBlock> blocks) =>
    blocks.where((b) => b.kind == TextBlockKind.heading).map((b) => b.text).firstOrNull;

void _content(XmlElement e, List<TextBlock> out, {bool skipSections = false}) {
  for (final c in e.childElements) {
    if (skipSections && c.name.local == 'section') continue;
    _element(c, out);
  }
}

void _element(XmlElement c, List<TextBlock> out, {TextBlockKind kind = TextBlockKind.paragraph, bool italic = false}) {
  final b = BlockBuilder();
  void para(XmlElement p, TextBlockKind k, {bool it = false}) {
    addInline(b, p, italicTags: _italic, boldTags: _bold, italic: it, noteRef: _noteRef);
    final block = b.build(k);
    if (block != null) out.add(block);
  }

  switch (c.name.local) {
    case 'title':
      for (final p in c.childElements) {
        if (p.name.local == 'p') para(p, TextBlockKind.heading);
      }
      if (c.childElements.isEmpty) para(c, TextBlockKind.heading);
    case 'subtitle':
      para(c, TextBlockKind.subtitle);
    case 'p':
      para(c, kind, it: italic);
    case 'v':
      para(c, TextBlockKind.verse);
    case 'empty-line':
      out.add(TextBlock(TextBlockKind.empty, const [TextRun(' ')]));
    case 'epigraph' || 'cite' || 'annotation':
      for (final p in c.childElements) {
        if (p.name.local == 'text-author') {
          para(p, TextBlockKind.quote, it: false);
        } else {
          _element(p, out, kind: TextBlockKind.quote, italic: true);
        }
      }
    case 'poem' || 'stanza':
      for (final p in c.childElements) {
        _element(p, out);
      }
      if (c.name.local == 'stanza') out.add(TextBlock(TextBlockKind.empty, const [TextRun(' ')]));
    case 'text-author':
      para(c, TextBlockKind.quote);
    case 'table':
      for (final tr in c.childElements) {
        addInline(b, tr, italicTags: _italic, boldTags: _bold, noteRef: _noteRef);
        final block = b.build(TextBlockKind.paragraph);
        if (block != null) out.add(block);
      }
    case 'section':
      // Вложенный раздел внутри текста (когда главы не делятся дальше).
      _content(c, out);
  }
}
