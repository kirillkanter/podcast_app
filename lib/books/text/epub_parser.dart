/// EPUB 2 и 3: zip-архив с OPF (метаданные, порядок файлов) и XHTML-главами.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../ui/format.dart' show htmlToText;
import 'image_size.dart';
import 'text_book.dart';
import 'xml_helpers.dart';

const _italic = {'em', 'i', 'cite', 'var', 'dfn'};
const _bold = {'strong', 'b'};
const _skip = {'script', 'style', 'head', 'math', 'audio', 'video', 'object', 'iframe', 'noscript'};
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

  // Все страницы spine (и нелинейные — там часто сноски): разбор и
  // указатель «путь#id → элемент» для сносок.
  final docs = <String, XmlDocument>{};
  final ids = <String, XmlElement>{};
  if (spineEl != null) {
    for (final ref in kids(spineEl, 'itemref')) {
      final item = manifest[attr(ref, 'idref') ?? ''];
      if (item == null || docs.containsKey(item.path)) continue;
      final f = file(item.path);
      final doc = f == null ? null : _parseXml(_decode(f.content));
      if (doc == null) continue;
      docs[item.path] = doc;
      for (final e in doc.descendants.whereType<XmlElement>()) {
        final id = attr(e, 'id');
        if (id != null && id.isNotEmpty) ids['${item.path}#$id'] = e;
      }
    }
  }
  final notes = <String, String>{};

  // Картинки внутри текста: путь в архиве → картинка.
  final images = <String, BookImage>{};
  String? imageRef(String dir, String href) {
    if (href.startsWith('data:') || href.contains('://')) return null;
    final path = _resolve(dir, href);
    if (images.containsKey(path)) return path;
    final f = file(path);
    if (f == null) return null;
    final image = bookImageFrom(Uint8List.fromList(f.content));
    if (image == null) return null;
    images[path] = image;
    return path;
  }

  // SVG прямо в тексте (узоры, виньетки): своя картинка на каждую.
  String? inlineSvg(String xml) {
    final image = bookImageFrom(Uint8List.fromList(utf8.encode(xml)));
    if (image == null) return null;
    final key = 'inline:${images.length}';
    images[key] = image;
    return key;
  }

  // Главы по порядку spine. Страницы только с картинками (обложка,
  // титул, иллюстрация на всю страницу) отдельными главами не становятся —
  // они идут в начало следующей главы: номера глав не сдвигаются, места в
  // книге и закладки остаются на своих местах.
  final chapters = <TextChapter>[];
  final coverPath = coverId == null ? null : manifest[coverId]?.path;
  final front = <TextBlock>[];
  if (spineEl != null) {
    for (final ref in kids(spineEl, 'itemref')) {
      final linear = attr(ref, 'linear') != 'no';
      // Нелинейные страницы (сноски и т. п.) не читаются подряд; кроме
      // обложки в самом начале.
      if (!linear && chapters.isNotEmpty) continue;
      final item = manifest[attr(ref, 'idref') ?? ''];
      if (item == null) continue;
      final f = file(item.path);
      if (f == null) continue;
      final doc = docs[item.path];
      final dir = p.posix.dirname(item.path) == '.' ? '' : p.posix.dirname(item.path);
      final blocks = doc == null
          ? xhtmlToBlocks(_decode(f.content))
          : _docToBlocks(doc,
              noteRef: (a) => _noteRef(a, item.path, dir, ids, notes),
              imageRef: (href) => imageRef(dir, href),
              inlineSvg: inlineSvg);
      if (blocks.isEmpty) continue;
      if (blocks.every((b) => b.kind == TextBlockKind.image)) {
        front.addAll(blocks);
        continue;
      }
      if (!linear) continue;
      final title = toc[item.path] ??
          blocks.where((b) => b.kind == TextBlockKind.heading).map((b) => b.text).firstOrNull ??
          'Глава ${chapters.length + 1}';
      chapters.add(TextChapter(title, [...front, ...blocks]));
      front.clear();
    }
  }
  if (chapters.isNotEmpty && front.isNotEmpty) {
    final last = chapters.removeLast();
    chapters.add(TextChapter(last.title, [...last.blocks, ...front]));
  }
  // Обложки нет среди страниц книги — ставим её в самое начало, как в Kindle.
  if (chapters.isNotEmpty && coverPath != null) {
    final shown = chapters.any((c) => c.blocks.any((b) => b.image == coverPath));
    final key = shown ? null : imageRef('', coverPath);
    if (key != null) {
      final first = chapters.removeAt(0);
      chapters.insert(0, TextChapter(first.title, [TextBlock(TextBlockKind.image, const [], image: key), ...first.blocks]));
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
    notes: notes,
    images: {
      for (final c in chapters)
        for (final b in c.blocks)
          if (b.image != null && images[b.image] != null) b.image!: images[b.image]!,
    },
  );
}

const _blockLike = {'p', 'li', 'aside', 'div', 'section', 'dd', 'td', 'blockquote', 'body'};
final _shortMark = RegExp(r'^[\[\(]?[0-9*†‡§a-zа-я]{1,4}[\]\)]?$', caseSensitive: false);

/// Ссылка [a] — сноска? Тогда ключ сноски (текст кладётся в [notes]).
String? _noteRef(XmlElement a, String path, String dir, Map<String, XmlElement> ids, Map<String, String> notes) {
  final href = attr(a, 'href');
  if (href == null || !href.contains('#')) return null;
  final hash = href.indexOf('#');
  final target = hash == 0 ? path : _resolve(dir, href.substring(0, hash));
  final key = '$target#${href.substring(hash + 1)}';
  if (notes.containsKey(key)) return key;
  final el = ids[key];
  if (el == null) return null;
  final type = '${attr(a, 'type') ?? ''} ${attr(a, 'role') ?? ''}'.toLowerCase();
  final inSup = a.ancestors.whereType<XmlElement>().any((e) => e.name.local.toLowerCase() == 'sup') ||
      a.descendants.whereType<XmlElement>().any((e) => e.name.local.toLowerCase() == 'sup');
  final isNote = type.contains('noteref') || type.contains('footnote') || inSup || _shortMark.hasMatch(textOf(a));
  if (!isNote) return null;
  // Цель — сам блок сноски или метка внутри него.
  var block = el;
  while (!_blockLike.contains(block.name.local.toLowerCase()) && block.parentElement != null) {
    block = block.parentElement!;
  }
  final blockName = block.name.local.toLowerCase();
  if (blockName == 'body') return null;
  var text = textOf(block);
  // Ссылка на начало главы, а не на сноску.
  if (text.length > 3000 && blockName != 'aside') return null;
  // Номер-ссылка обратно в начале сноски («1.», «[1]») не нужен.
  text = text.replaceFirst(RegExp(r'^[\[\(]?[0-9*†‡]{1,4}[\]\)\.]?\s+'), '');
  if (text.isEmpty) return null;
  notes[key] = text.length > 4000 ? '${text.substring(0, 4000)}…' : text;
  return key;
}

/// XHTML-страница → абзацы.
List<TextBlock> xhtmlToBlocks(String html) {
  final doc = _parseXml(html);
  if (doc == null) {
    final out = <TextBlock>[];
    // Не XML (битая разметка) — хотя бы текст абзацами.
    for (final para in htmlToText(html).split(RegExp(r'\n+'))) {
      final b = BlockBuilder()..add(para);
      final block = b.build(TextBlockKind.paragraph);
      if (block != null) out.add(block);
    }
    return out;
  }
  return _docToBlocks(doc);
}

/// Сноски (aside с epub:type footnote/endnote) в текст не идут — они
/// показываются по нажатию на ссылку.
bool _isNoteAside(XmlElement e) {
  final n = e.name.local.toLowerCase();
  if (n != 'aside') return false;
  final t = (attr(e, 'type') ?? '').toLowerCase();
  return t.contains('footnote') || t.contains('endnote') || t.contains('rearnote') || t.contains('note');
}

List<TextBlock> _docToBlocks(
  XmlDocument doc, {
  String? Function(XmlElement link)? noteRef,
  String? Function(String href)? imageRef,
  String? Function(String xml)? inlineSvg,
}) {
  final out = <TextBlock>[];
  final body = doc.descendants.whereType<XmlElement>().where((e) => e.name.local.toLowerCase() == 'body').firstOrNull ??
      doc.rootElement;
  final w = _Walker(out, noteRef, imageRef, inlineSvg);
  w.walk(body, TextBlockKind.paragraph, false, false);
  w.flush(TextBlockKind.paragraph);
  return out;
}

class _Walker {
  _Walker(this.out, this.noteRef, this.imageRef, this.inlineSvg);

  final String? Function(String xml)? inlineSvg;

  final List<TextBlock> out;
  final String? Function(XmlElement link)? noteRef;
  final String? Function(String href)? imageRef;

  /// Картинка — отдельным блоком между абзацами.
  void image(String? href, TextBlockKind kind) {
    if (href == null || imageRef == null) return;
    final key = imageRef!(href);
    if (key == null) return;
    flush(kind);
    // Издательства кладут одну картинку дважды (для разных читалок, лишнюю
    // прячут стилями) — показываем один раз.
    if (out.isNotEmpty && out.last.kind == TextBlockKind.image && out.last.image == key) return;
    out.add(TextBlock(TextBlockKind.image, const [], image: key));
  }
  final b = BlockBuilder();

  void flush(TextBlockKind kind) {
    final block = b.build(kind);
    if (block != null) out.add(block);
  }

  void walk(XmlElement e, TextBlockKind kind, bool bold, bool italic, [String? note]) {
    for (final c in e.children) {
      final text = dataOf(c);
      if (text != null) {
        b.add(text, bold: bold, italic: italic, note: note);
        continue;
      }
      if (c is! XmlElement) continue;
      final n = c.name.local.toLowerCase();
      if (_skip.contains(n)) continue;
      if (_isNoteAside(c)) continue;
      if (n == 'img') {
        image(attr(c, 'src'), kind);
        continue;
      }
      if (n == 'svg' || n == 'image') {
        // Картинка в SVG-обёртке (так часто делают иллюстрации и обложки).
        final img = n == 'image' ? c : c.descendants.whereType<XmlElement>().where((e) => e.name.local == 'image').firstOrNull;
        if (img != null) {
          image(attr(img, 'href'), kind);
        } else if (n == 'svg' && inlineSvg != null) {
          // Рисунок прямо в разметке — узор, виньетка.
          final key = inlineSvg!(c.toXmlString());
          if (key != null) {
            flush(kind);
            out.add(TextBlock(TextBlockKind.image, const [], image: key));
          }
        }
        continue;
      }
      if (n == 'a' && note == null && noteRef != null) {
        final ref = noteRef!(c);
        if (ref != null) {
          walk(c, kind, bold, italic, ref);
          continue;
        }
      }
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
      walk(c, kind, bold || _bold.contains(n), italic || _italic.contains(n), note);
    }
  }
}
