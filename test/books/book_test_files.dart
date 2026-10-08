// Маленькие файлы книг для тестов: MP3 с ID3, M4B с главами, FB2, EPUB.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

List<int> _be32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> _be64(int v) => [..._be32(v ~/ 0x100000000), ..._be32(v % 0x100000000)];
List<int> _syncsafe(int v) => [(v >> 21) & 0x7F, (v >> 14) & 0x7F, (v >> 7) & 0x7F, v & 0x7F];

List<int> _id3Frame(String id, List<int> data) => [...ascii.encode(id), ..._be32(data.length), 0, 0, ...data];

/// Текстовый кадр ID3 в UTF-8.
List<int> id3Text(String id, String text) => _id3Frame(id, [3, ...utf8.encode(text)]);

/// Глава ID3 (CHAP) с названием.
List<int> id3Chapter(String elementId, int startMs, int endMs, String title) => _id3Frame('CHAP', [
      ...ascii.encode(elementId), 0,
      ..._be32(startMs), ..._be32(endMs), ..._be32(0xFFFFFFFF), ..._be32(0xFFFFFFFF),
      ...id3Text('TIT2', title),
    ]);

/// MP3: тег ID3v2.3 с кадрами [frames] и [audioBytes] байт аудио
/// 128 кбит/с, 44,1 кГц (1000 мс на каждые 16 000 байт).
Uint8List mp3({List<List<int>> frames = const [], int audioBytes = 16000}) {
  final body = [for (final f in frames) ...f];
  final header = [...ascii.encode('ID3'), 3, 0, 0, ..._syncsafe(body.length)];
  final audio = List<int>.filled(audioBytes, 0);
  audio.setAll(0, [0xFF, 0xFB, 0x90, 0x00]);
  return Uint8List.fromList([...header, ...body, ...audio]);
}

/// Атом MP4.
List<int> atom(String type, List<int> content) => [..._be32(content.length + 8), ...latin1.encode(type), ...content];

List<int> _ilstText(String type, String text) =>
    atom(type, atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(text)]));

/// M4B: длительность [durationMs], теги и главы Nero (chpl).
Uint8List m4b({
  required int durationMs,
  String? title,
  String? artist,
  List<(int, String)> chapters = const [],
  List<int>? cover,
}) {
  final mvhd = atom('mvhd', [0, 0, 0, 0, ..._be32(0), ..._be32(0), ..._be32(1000), ..._be32(durationMs), ...List.filled(80, 0)]);
  final ilst = atom('ilst', [
    if (title != null) ..._ilstText('©nam', title),
    if (artist != null) ..._ilstText('©ART', artist),
    if (cover != null) ...atom('covr', atom('data', [0, 0, 0, 13, 0, 0, 0, 0, ...cover])),
  ]);
  final meta = atom('meta', [0, 0, 0, 0, ...atom('hdlr', List.filled(25, 0)), ...ilst]);
  final chpl = atom('chpl', [
    1, 0, 0, 0, 0, 0, 0, 0, chapters.length,
    for (final (start, name) in chapters) ...[..._be64(start * 10000), utf8.encode(name).length, ...utf8.encode(name)],
  ]);
  final moov = atom('moov', [...mvhd, ...atom('udta', [...meta, ...chpl])]);
  final ftyp = atom('ftyp', [...ascii.encode('M4B '), 0, 0, 2, 0, ...ascii.encode('isomM4B ')]);
  return Uint8List.fromList([...ftyp, ...atom('mdat', List.filled(100, 0)), ...moov]);
}

/// windows-1251 для русских букв (в тестах FB2 и TXT).
List<int> cp1251(String s) => [
      for (final c in s.runes)
        if (c < 0x80)
          c
        else if (c >= 0x0410 && c <= 0x044F)
          0xC0 + (c - 0x0410)
        else if (c == 0x0401)
          0xA8
        else if (c == 0x0451)
          0xB8
        else
          0x3F,
    ];

const fb2Sample = '''<?xml version="1.0" encoding="windows-1251"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<description><title-info>
  <author><first-name>Антон</first-name><last-name>Чехов</last-name></author>
  <book-title>Рассказы</book-title>
  <annotation><p>Сборник рассказов.</p></annotation>
  <lang>ru</lang>
  <coverpage><image l:href="#cover.jpg"/></coverpage>
</title-info></description>
<body>
  <title><p>Рассказы</p></title>
  <section>
    <title><p>Часть первая</p></title>
    <section>
      <title><p>Дама с собачкой</p></title>
      <epigraph><p>Эпиграф</p></epigraph>
      <p>Говорили, что на набережной появилось <emphasis>новое лицо</emphasis>.</p>
      <empty-line/>
      <p>Второй <strong>абзац</strong>.</p>
    </section>
    <section>
      <title><p>Ионыч</p></title>
      <p>Когда в губернском городе С.</p>
      <poem><stanza><v>Строка один</v><v>Строка два</v></stanza></poem>
    </section>
  </section>
</body>
<body name="notes"><section id="n1"><p>Примечание</p></section></body>
<binary id="cover.jpg" content-type="image/jpeg">AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9Q</binary>
</FictionBook>''';

/// EPUB 3 с двумя главами и оглавлением nav.
Uint8List epubSample() {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(ArchiveFile.string('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''))
    ..addFile(ArchiveFile.string('OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>The Story</dc:title>
    <dc:creator>Jane Doe</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="c0" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="text/ch%201.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c0"/><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>'''))
    ..addFile(ArchiveFile.string('OEBPS/nav.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
<nav epub:type="toc"><ol>
  <li><a href="text/ch%201.xhtml">Chapter One</a></li>
  <li><a href="text/ch2.xhtml#start">Chapter Two</a></li>
</ol></nav></body></html>'''))
    ..addFile(ArchiveFile.bytes('OEBPS/images/cover.jpg', List.generate(100, (i) => i)))
    ..addFile(ArchiveFile.string('OEBPS/text/cover.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml"><body><img src="../images/cover.jpg"/></body></html>'))
    ..addFile(ArchiveFile.string('OEBPS/text/ch 1.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title><style>p{}</style></head><body>
<h1>One</h1>
<p>It was a <em>dark</em> and&nbsp;stormy night&mdash;really.</p>
<div><p>Nested <b>bold</b> text.</p></div>
<p>Line one<br/>Line two</p>
</body></html>'''))
    ..addFile(ArchiveFile.string('OEBPS/text/ch2.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml"><body><p id="start">Second chapter.</p></body></html>'));
  return ZipEncoder().encodeBytes(archive);
}
