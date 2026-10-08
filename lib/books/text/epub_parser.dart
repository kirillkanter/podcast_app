/// EPUB 2 и 3: zip-архив с OPF (метаданные, порядок файлов) и XHTML-главами.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../ui/format.dart' show htmlToText;
import 'text_book.dart';
import 'xml_helpers.dart';

const _italic = {'em', 'i', 'cite', 'var', 'dfn'};
const _bold = {'strong', 'b'};
const _skip = {'script', 'style', 'head', 'img', 'image', 'svg', 'math', 'audio', 'video', 'object', 'iframe', 'noscript'};
const _blocks = {
  'p', 'div', 'li', 'blockquote', 'pre', 'section', 'article', 'aside', 'header', 'footer', 'tr', 'dd', 'dt',
  'figcaption', 'figure', 'table', 'ul', 'ol', 'dl', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'body', 'main', 'nav', 'hr',
  'center', 'address',
};

/// HTML-сущности, которых нет в XML.
const _htmlEntities = {
  'nbsp': 0xA0, 'shy': 0xAD, 'mdash': 0x2014, 'ndash': 0x2013, 'laquo': 0xAB, 'raquo': 0xBB, 'hellip': 0x2026,
  'copy': 0xA9, 'reg': 0xAE, 'trade': 0x2122, 'rsquo': 0x2019, 'lsquo': 0x2018, 'ldquo': 0x201C, 'rdquo': 0x201D,
  'bdquo': 0x201E, 'sbquo': 0x201A, 'thinsp': 0x2009, 'ensp': 0x2002, 'emsp': 0x2003, 'middot': 0xB7, 'bull': 0x2022,
  'deg': 0xB0, 'times': 0xD7, 'minus': 0x2212, 'sect': 0xA7, 'para': 0xB6, 'dagger': 0x2020, 'Dagger': 0x2021,
  'prime': 0x2032, 'Prime': 0x2033, 'zwnj': 0x200C, 'zwj': 0x200D, 'euro': 0x20AC, 'iexcl': 0xA1, 'iquest': 0xBF,
  'frac12': 0xBD, 'frac14': 0xBC, 'frac34': 0xBE, 'acute': 0xB4, 'uml': 0xA8, 'cedil': 0xB8, 'ordm': 0xBA,
  'ordf': 0xAA, 'not': 0xAC, 'plusmn': 0xB1, 'micro': 0xB5, 'eacute': 0xE9, 'egrave': 0xE8, 'agrave': 0xE0,
  'aacute': 0xE1, 'ccedil': 0xE7, 'ouml': 0xF6, 'uuml': 0xFC, 'auml': 0xE4, 'szlig': 0xDF, 'Eacute': 0xC9,
};

String _fixEntities(String s) => s.replaceAllMapped(RegExp(r'&([A-Za-z][A-Za-z0-9]*);'), (m) {
      final name = m.group(1)!;
      if (const {'amp', 'lt', 'gt', 'quot', 'apos'}.contains(name)) return m.group(0)!;
      final code = _htmlEntities[name];
      return code == null ? ' ' : '&#$code;';
    });

String _decode(List<int> bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

XmlDocument? _parseXml(String text) {
  try {
    return XmlDocument.parse(_fixEntities(text));
  } catch (_) {
    return null;
  }
}

/// Путь внутри архива по ссылке [href] из файла в папке [dir].
String _resolve(String dir, String href) {
  final clean = href.split('#').first;
  String decoded;
  try {
    decoded = Uri.decodeFull(clean);
  } catch (_) {
    decoded = clean;
  }
  return p.posix.normalize(p.posix.join(dir, decoded));
}

TextBookContent parseEpub(Uint8List bytes, {required String fallbackTitle}) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final files = <String, ArchiveFile>{
    for (final f in archive.files)
      if (f.isFile) f.name: f,
  };
  final lower = {for (final k in files.keys) k.toLowerCase(): k};
  ArchiveFile? file(String path) => files[path] ?? files[lower[path.toLowerCase()] ?? ''];

  // container.xml → OPF.
  final container = file('META-INF/container.xml');
  String? opfPath;
  if (container != null) {
    final doc = _parseXml(_decode(container.content));
    final rootfile = doc?.descendants.whereType<XmlElement>().where((e) => e.name.local == 'rootfile').firstOrNull;
    opfPath = rootfile == null ? null : attr(rootfile, 'full-path');
  }
  opfPath ??= files.keys.where((k) => k.toLowerCase().endsWith('.opf')).firstOrNull;
  if (opfPath == null || file(opfPath) == null) throw const FormatException('Не найден OPF в EPUB');
  final opfDir = p.posix.dirname(opfPath) == '.' ? '' : p.posix.dirname(opfPath);
  final opf = _parseXml(_decode(file(opfPath)!.content));
  if (opf == null) throw const FormatException('Не удалось прочитать OPF');
  final pkg = opf.rootElement;

  final metadata = kid(pkg, 'metadata');
  String? meta(String local) {
    if (metadata == null) return null;
    final e = kids(metadata, local).firstOrNull;
    final t = e == null ? '' : textOf(e);
    return t.isEmpty ? null : t;
  }

  final creators = metadata == null
      ? const <String>[]
      : [for (final e in kids(metadata, 'creator')) textOf(e)].where((s) => s.isNotEmpty).toList();

  // manifest: id → (путь, тип, свойства).
  final manifest = <String, ({String path, String type, String props})>{};
  final manifestEl = kid(pkg, 'manifest');
  if (manifestEl != null) {
    for (final item in kids(manifestEl, 'item')) {
      final id = attr(item, 'id');
      final href = attr(item, 'href');
      if (id == null || href == null) continue;
      manifest[id] = (
        path: _resolve(opfDir, href),
        type: attr(item, 'media-type') ?? '',
        props: attr(item, 'properties') ?? '',
      );
    }
  }

  // Обложка.
  Uint8List? cover;
  String? coverId = manifest.entries.where((e) => e.value.props.contains('cover-image')).map((e) => e.key).firstOrNull;
  if (coverId == null && metadata != null) {
    for (final m in kids(metadata, 'meta')) {
      if (attr(m, 'name') == 'cover') coverId = attr(m, 'content');
    }
  }
  coverId ??= manifest.entries
      .where((e) => e.key.toLowerCase().contains('cover') && e.value.type.startsWith('image/'))
      .map((e) => e.key)
      .firstOrNull;
  final coverFile = coverId == null ? null : file(manifest[coverId]?.path ?? '');
  if (coverFile != null) cover = coverFile.content;

  // Оглавление: путь файла → название.
  final toc = <String, String>{};
  final navId = manifest.entries.where((e) => e.value.props.split(' ').contains('nav')).map((e) => e.key).firstOrNull;
  final spineEl = kid(pkg, 'spine');
  final ncxId = spineEl == null ? null : attr(spineEl, 'toc');
  if (navId != null) {
    final navPath = manifest[navId]!.path;
    final nav = file(navPath);
    final doc = nav == null ? null : _parseXml(_decode(nav.content));
    if (doc != null) {
      final navDir = p.posix.dirname(navPath) == '.' ? '' : p.posix.dirname(navPath);
      for (final a in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'a')) {
        final href = attr(a, 'href');
        final t = textOf(a);
        if (href == null || t.isEmpty) continue;
        toc.putIfAbsent(_resolve(navDir, href), () => t);
      }
    }
  }
  if (toc.isEmpty) {
    final ncxPath = (ncxId == null ? null : manifest[ncxId]?.path) ??
        manifest.values.where((v) => v.type == 'application/x-dtbncx+xml').map((v) => v.path).firstOrNull;
    final ncx = ncxPath == null ? null : file(ncxPath);
    final doc = ncx == null ? null : _parseXml(_decode(ncx.content));
    if (doc != null) {
      final ncxDir = p.posix.dirname(ncxPath!) == '.' ? '' : p.posix.dirname(ncxPath);
      for (final point in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'navPoint')) {
        final label = kid(point, 'navLabel');
        final content = kid(point, 'content');
        final src = content == null ? null : attr(content, 'src');
        final t = label == null ? '' : textOf(label);
        if (src == null || t.isEmpty) continue;
        toc.putIfAbsent(_resolve(ncxDir, src), () => t);
      }
    }
  }

  // Главы по порядку spine.
  final chapters = <TextChapter>[];
  if (spineEl != null) {
    for (final ref in kids(spineEl, 'itemref')) {
      if (attr(ref, 'linear') == 'no') continue;
      final item = manifest[attr(ref, 'idref') ?? ''];
      if (item == null) continue;
      final f = file(item.path);
      if (f == null) continue;
      final blocks = xhtmlToBlocks(_decode(f.content));
      if (blocks.isEmpty) continue;
      final title = toc[item.path] ??
          blocks.where((b) => b.kind == TextBlockKind.heading).map((b) => b.text).firstOrNull ??
          'Глава ${chapters.length + 1}';
      chapters.add(TextChapter(title, blocks));
    }
  }
  if (chapters.isEmpty) throw const FormatException('В EPUB нет текста');

  final description = meta('description');
  return TextBookContent(
    title: meta('title') ?? fallbackTitle,
    author: creators.isEmpty ? null : creators.join(', '),
    language: meta('language'),
    description: description == null ? null : htmlToText(description),
    cover: cover,
    chapters: chapters,
  );
}

/// XHTML-страница → абзацы.
List<TextBlock> xhtmlToBlocks(String html) {
  final doc = _parseXml(html);
  final out = <TextBlock>[];
  if (doc == null) {
    // Не XML (битая разметка) — хотя бы текст абзацами.
    for (final para in htmlToText(html).split(RegExp(r'\n+'))) {
      final b = BlockBuilder()..add(para);
      final block = b.build(TextBlockKind.paragraph);
      if (block != null) out.add(block);
    }
    return out;
  }
  final body = doc.descendants.whereType<XmlElement>().where((e) => e.name.local.toLowerCase() == 'body').firstOrNull ??
      doc.rootElement;
  final w = _Walker(out);
  w.walk(body, TextBlockKind.paragraph, false, false);
  w.flush(TextBlockKind.paragraph);
  return out;
}

class _Walker {
  _Walker(this.out);

  final List<TextBlock> out;
  final b = BlockBuilder();

  void flush(TextBlockKind kind) {
    final block = b.build(kind);
    if (block != null) out.add(block);
  }

  void walk(XmlElement e, TextBlockKind kind, bool bold, bool italic) {
    for (final c in e.children) {
      final text = dataOf(c);
      if (text != null) {
        b.add(text, bold: bold, italic: italic);
        continue;
      }
      if (c is! XmlElement) continue;
      final n = c.name.local.toLowerCase();
      if (_skip.contains(n)) continue;
      if (n == 'br') {
        flush(kind);
        continue;
      }
      if (_blocks.contains(n)) {
        flush(kind);
        final inner = switch (n) {
          'h1' || 'h2' => TextBlockKind.heading,
          'h3' || 'h4' || 'h5' || 'h6' => TextBlockKind.subtitle,
          'blockquote' => TextBlockKind.quote,
          _ => kind,
        };
        final cls = (attr(c, 'class') ?? '').toLowerCase();
        final verse = cls.contains('poem') || cls.contains('stanza') || cls.contains('verse');
        walk(c, verse && inner == TextBlockKind.paragraph ? TextBlockKind.verse : inner, bold || _bold.contains(n),
            italic || _italic.contains(n) || inner == TextBlockKind.quote);
        flush(verse && inner == TextBlockKind.paragraph ? TextBlockKind.verse : inner);
        continue;
      }
      walk(c, kind, bold || _bold.contains(n), italic || _italic.contains(n));
    }
  }
}
