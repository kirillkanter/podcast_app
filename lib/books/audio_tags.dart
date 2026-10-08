/// Теги и длительность аудиофайлов книг без сторонних библиотек:
/// MP3 (ID3v1, ID3v2.2–2.4, главы CHAP, длительность по заголовку Xing/VBRI
/// или по битрейту) и MP4/M4A/M4B (теги iTunes, главы Nero `chpl`
/// и текстовая дорожка глав QuickTime).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:typed_data';

import '../feed/feed_decoder.dart' show decodeWindows1251;

class TagChapter {
  const TagChapter(this.startMs, this.title);

  final int startMs;
  final String title;

  @override
  String toString() => 'TagChapter($startMs, $title)';
}

class AudioTags {
  String? title;
  String? artist;
  String? album;
  String? albumArtist;
  String? composer;
  String? comment;
  int? track;
  int? durationMs;
  Uint8List? cover;
  List<TagChapter> chapters = [];

  @override
  String toString() => 'AudioTags(title: $title, artist: $artist, album: $album, track: $track, '
      'duration: $durationMs, cover: ${cover?.length}, chapters: ${chapters.length})';
}

const audioExtensions = {'mp3', 'm4a', 'm4b', 'mp4', 'aac', 'ogg', 'opus', 'flac', 'wav'};

/// Прочитать теги файла. Ошибки разбора не бросаются: что прочиталось — то и есть.
Future<AudioTags> readAudioTags(String path, {bool withCover = true}) async {
  final tags = AudioTags();
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    final length = await f.length();
    final head = await _readAt(f, 0, 12);
    if (head.length >= 8 && _ascii(head, 4, 4) == 'ftyp') {
      await _readMp4(f, length, tags, withCover: withCover);
    } else {
      await _readMp3(f, length, tags, withCover: withCover);
    }
  } catch (_) {
    // Повреждённый или незнакомый файл — без тегов.
  } finally {
    await f?.close();
  }
  return tags;
}

Future<Uint8List> _readAt(RandomAccessFile f, int offset, int count) async {
  await f.setPosition(offset);
  return f.read(count);
}

String _ascii(List<int> b, int start, int len) =>
    start + len > b.length ? '' : String.fromCharCodes(b.sublist(start, start + len));

int _be32(List<int> b, int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
int _be24(List<int> b, int i) => (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
int _be16(List<int> b, int i) => (b[i] << 8) | b[i + 1];
int _be64(List<int> b, int i) => (_be32(b, i) * 0x100000000) + _be32(b, i + 4);
int _syncsafe(List<int> b, int i) => (b[i] << 21) | (b[i + 1] << 14) | (b[i + 2] << 7) | b[i + 3];

/// Однобайтовая строка тега: по стандарту latin1, но в русских файлах
/// там почти всегда windows-1251.
String _decodeSingleByte(List<int> bytes) {
  final high = bytes.where((b) => b >= 0xC0).length;
  final allHigh = bytes.where((b) => b >= 0x80).length;
  if (allHigh > 0 && high * 2 >= allHigh) return decodeWindows1251(bytes);
  return latin1.decode(bytes);
}

String _decodeUtf16(List<int> b, {bool? littleEndian}) {
  var start = 0;
  var le = littleEndian ?? false;
  if (b.length >= 2 && littleEndian == null) {
    if (b[0] == 0xFF && b[1] == 0xFE) {
      le = true;
      start = 2;
    } else if (b[0] == 0xFE && b[1] == 0xFF) {
      start = 2;
    }
  }
  final units = <int>[];
  for (var i = start; i + 1 < b.length; i += 2) {
    units.add(le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
  }
  return String.fromCharCodes(units);
}

String _decodeText(int encoding, List<int> b) {
  final s = switch (encoding) {
    0 => _decodeSingleByte(b),
    1 => _decodeUtf16(b),
    2 => _decodeUtf16(b, littleEndian: false),
    _ => utf8.decode(b, allowMalformed: true),
  };
  return s.replaceAll('\u0000', '').trim();
}

/// Конец строки с нулевым окончанием (для UTF-16 — два нуля по чётному адресу).
int _terminator(List<int> b, int start, int encoding) {
  if (encoding == 1 || encoding == 2) {
    for (var i = start; i + 1 < b.length; i += 2) {
      if (b[i] == 0 && b[i + 1] == 0) return i;
    }
    return b.length;
  }
  final i = b.indexOf(0, start);
  return i < 0 ? b.length : i;
}

int _termLength(int encoding) => encoding == 1 || encoding == 2 ? 2 : 1;

String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

// ---------------------------------------------------------------------------
// MP3
// ---------------------------------------------------------------------------

Future<void> _readMp3(RandomAccessFile f, int length, AudioTags tags, {required bool withCover}) async {
  var audioStart = 0;
  final header = await _readAt(f, 0, 10);
  if (header.length == 10 && _ascii(header, 0, 3) == 'ID3') {
    final major = header[3];
    final flags = header[5];
    final size = _syncsafe(header, 6);
    audioStart = 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
    // Огромный тег — почти наверняка большая обложка; без неё читаем
    // только начало, где текстовые кадры.
    final want = withCover ? size : (size > 512 * 1024 ? 512 * 1024 : size);
    var body = await _readAt(f, 10, min(max(want, 0), 64 * 1024 * 1024));
    if ((flags & 0x80) != 0 && major < 4) body = _unsync(body);
    var pos = 0;
    if ((flags & 0x40) != 0 && major >= 3 && body.length >= 4) {
      // Расширенный заголовок.
      final ext = major == 4 ? _syncsafe(body, 0) : _be32(body, 0) + 4;
      pos = ext;
    }
    _parseId3Frames(body, pos, major, tags, withCover: withCover);
  } else {
    await _readId3v1(f, length, tags);
  }
  if (tags.title == null || tags.artist == null) await _readId3v1(f, length, tags);
  tags.durationMs ??= await _mp3Duration(f, length, audioStart);
}

Uint8List _unsync(Uint8List b) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < b.length; i++) {
    out.addByte(b[i]);
    if (b[i] == 0xFF && i + 1 < b.length && b[i + 1] == 0x00) i++;
  }
  return out.toBytes();
}

void _parseId3Frames(Uint8List body, int start, int major, AudioTags tags, {required bool withCover}) {
  final v22 = major == 2;
  final headerSize = v22 ? 6 : 10;
  var pos = start;
  while (pos + headerSize <= body.length) {
    final id = _ascii(body, pos, v22 ? 3 : 4);
    if (id.isEmpty || id.codeUnitAt(0) == 0 || !RegExp(r'^[A-Z0-9]+$').hasMatch(id)) break;
    final size = v22
        ? _be24(body, pos + 3)
        : major == 4
            ? _syncsafe(body, pos + 4)
            : _be32(body, pos + 4);
    final flags = v22 ? 0 : _be16(body, pos + 8);
    final dataStart = pos + headerSize;
    final dataEnd = dataStart + size;
    if (size <= 0 || dataEnd > body.length) break;
    var data = Uint8List.sublistView(body, dataStart, dataEnd);
    if (major == 4 && (flags & 0x0002) != 0) data = _unsync(Uint8List.fromList(data));
    // Сжатые и зашифрованные кадры пропускаем.
    final skip = major == 3 ? (flags & 0x00C0) != 0 : major == 4 && (flags & 0x000C) != 0;
    if (!skip) _applyId3Frame(id, data, tags, withCover: withCover, major: major);
    pos = dataEnd;
  }
}

String _frameText(Uint8List d) => d.isEmpty ? '' : _decodeText(d[0], d.sublist(1));

void _applyId3Frame(String id, Uint8List d, AudioTags tags, {required bool withCover, required int major}) {
  switch (id) {
    case 'TIT2' || 'TT2':
      tags.title ??= _nonEmpty(_frameText(d));
    case 'TPE1' || 'TP1':
      tags.artist ??= _nonEmpty(_frameText(d));
    case 'TALB' || 'TAL':
      tags.album ??= _nonEmpty(_frameText(d));
    case 'TPE2' || 'TP2':
      tags.albumArtist ??= _nonEmpty(_frameText(d));
    case 'TCOM' || 'TCM':
      tags.composer ??= _nonEmpty(_frameText(d));
    case 'TRCK' || 'TRK':
      tags.track ??= int.tryParse(_frameText(d).split('/').first.trim());
    case 'TLEN' || 'TLE':
      final ms = int.tryParse(_frameText(d).trim());
      if (ms != null && ms > 0) tags.durationMs ??= ms;
    case 'COMM' || 'COM':
      if (d.length > 4 && tags.comment == null) {
        final enc = d[0];
        final descEnd = _terminator(d, 4, enc);
        final textStart = descEnd + _termLength(enc);
        if (textStart <= d.length) tags.comment = _nonEmpty(_decodeText(enc, d.sublist(textStart)));
      }
    case 'APIC':
      if (withCover && d.length > 4 && tags.cover == null) {
        final enc = d[0];
        final mimeEnd = d.indexOf(0, 1);
        if (mimeEnd < 0) return;
        final descStart = mimeEnd + 2; // тип картинки — один байт
        if (descStart > d.length) return;
        final descEnd = _terminator(d, descStart, enc);
        final dataStart = descEnd + _termLength(enc);
        if (dataStart < d.length) tags.cover = Uint8List.fromList(d.sublist(dataStart));
      }
    case 'PIC':
      if (withCover && d.length > 5 && tags.cover == null) {
        final enc = d[0];
        final descEnd = _terminator(d, 5, enc);
        final dataStart = descEnd + _termLength(enc);
        if (dataStart < d.length) tags.cover = Uint8List.fromList(d.sublist(dataStart));
      }
    case 'CHAP':
      final idEnd = d.indexOf(0);
      if (idEnd < 0 || idEnd + 17 > d.length) return;
      final startMs = _be32(d, idEnd + 1);
      final sub = AudioTags();
      _parseId3Frames(Uint8List.sublistView(d, idEnd + 17), 0, major, sub, withCover: false);
      tags.chapters.add(TagChapter(startMs, sub.title ?? ''));
  }
}

Future<void> _readId3v1(RandomAccessFile f, int length, AudioTags tags) async {
  if (length < 128) return;
  final b = await _readAt(f, length - 128, 128);
  if (_ascii(b, 0, 3) != 'TAG') return;
  String field(int start, int len) {
    final raw = b.sublist(start, start + len);
    final end = raw.indexOf(0);
    return _decodeSingleByte(end < 0 ? raw : raw.sublist(0, end)).trim();
  }

  tags.title ??= _nonEmpty(field(3, 30));
  tags.artist ??= _nonEmpty(field(33, 30));
  tags.album ??= _nonEmpty(field(63, 30));
  if (b[125] == 0 && b[126] != 0) tags.track ??= b[126];
}

const _bitratesV1 = [
  [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], // Layer I
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384], // Layer II
  [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320], // Layer III
];
const _bitratesV2 = [
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256], // Layer I
  [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160], // Layer II, III
];
const _sampleRates = {
  3: [44100, 48000, 32000], // MPEG 1
  2: [22050, 24000, 16000], // MPEG 2
  0: [11025, 12000, 8000], // MPEG 2.5
};

/// Длительность MP3: по счётчику кадров из заголовка Xing/Info или VBRI,
/// иначе по битрейту первого кадра.
Future<int?> _mp3Duration(RandomAccessFile f, int length, int audioStart) async {
  final buf = await _readAt(f, audioStart, 64 * 1024);
  for (var i = 0; i + 4 <= buf.length; i++) {
    if (buf[i] != 0xFF || (buf[i + 1] & 0xE0) != 0xE0) continue;
    final version = (buf[i + 1] >> 3) & 0x03; // 3 — MPEG1, 2 — MPEG2, 0 — MPEG2.5
    final layerBits = (buf[i + 1] >> 1) & 0x03; // 1 — III, 2 — II, 3 — I
    final bitrateIdx = (buf[i + 2] >> 4) & 0x0F;
    final rateIdx = (buf[i + 2] >> 2) & 0x03;
    if (version == 1 || layerBits == 0 || bitrateIdx == 0 || bitrateIdx == 15 || rateIdx == 3) continue;
    final layer = 4 - layerBits; // 1, 2, 3
    final sampleRate = _sampleRates[version]![rateIdx];
    final kbps = version == 3 ? _bitratesV1[layer - 1][bitrateIdx] : _bitratesV2[layer == 1 ? 0 : 1][bitrateIdx];
    final samplesPerFrame = layer == 1
        ? 384
        : layer == 2 || version == 3
            ? 1152
            : 576;
    final mono = ((buf[i + 3] >> 6) & 0x03) == 3;
    final sideInfo = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17);

    int? framesFrom(int at) {
      if (at + 16 > buf.length) return null;
      final tag = _ascii(buf, at, 4);
      if (tag == 'Xing' || tag == 'Info') {
        final flags = _be32(buf, at + 4);
        if ((flags & 0x01) != 0) return _be32(buf, at + 8);
      }
      return null;
    }

    var frames = framesFrom(i + 4 + sideInfo);
    if (frames == null && i + 36 + 18 <= buf.length && _ascii(buf, i + 36, 4) == 'VBRI') {
      frames = _be32(buf, i + 36 + 14);
    }
    if (frames != null && frames > 0) return (frames * samplesPerFrame * 1000 / sampleRate).round();
    var audioBytes = length - audioStart - i;
    if (length >= 128) {
      final tail = await _readAt(f, length - 128, 3);
      if (_ascii(tail, 0, 3) == 'TAG') audioBytes -= 128;
    }
    if (kbps <= 0 || audioBytes <= 0) return null;
    return (audioBytes * 8 / kbps).round(); // байты·8 / (кбит/с) = мс
  }
  return null;
}

// ---------------------------------------------------------------------------
// MP4 / M4A / M4B
// ---------------------------------------------------------------------------

class _Atom {
  _Atom(this.type, this.start, this.end);

  final String type;

  /// Начало и конец содержимого (после заголовка).
  final int start;
  final int end;
}

/// Дочерние атомы внутри [start, end) буфера [b].
List<_Atom> _children(Uint8List b, int start, int end) {
  final out = <_Atom>[];
  var pos = start;
  while (pos + 8 <= end) {
    var size = _be32(b, pos);
    final type = _ascii(b, pos + 4, 4);
    var header = 8;
    if (size == 1) {
      if (pos + 16 > end) break;
      size = _be64(b, pos + 8);
      header = 16;
    } else if (size == 0) {
      size = end - pos;
    }
    if (size < header || pos + size > end) break;
    out.add(_Atom(type, pos + header, pos + size));
    pos += size;
  }
  return out;
}

_Atom? _child(Uint8List b, _Atom parent, String type, {int skip = 0}) {
  for (final a in _children(b, parent.start + skip, parent.end)) {
    if (a.type == type) return a;
  }
  return null;
}

Future<void> _readMp4(RandomAccessFile f, int length, AudioTags tags, {required bool withCover}) async {
  // Ищем moov на верхнем уровне (бывает и в начале, и в конце файла).
  var pos = 0;
  Uint8List? moov;
  while (pos + 8 <= length) {
    final h = await _readAt(f, pos, 16);
    if (h.length < 8) break;
    var size = _be32(h, 0);
    final type = _ascii(h, 4, 4);
    var header = 8;
    if (size == 1 && h.length >= 16) {
      size = _be64(h, 8);
      header = 16;
    } else if (size == 0) {
      size = length - pos;
    }
    if (size < header) break;
    if (type == 'moov') {
      if (size > 64 * 1024 * 1024) return;
      moov = await _readAt(f, pos + header, size - header);
      break;
    }
    pos += size;
  }
  if (moov == null) return;
  final root = _Atom('moov', 0, moov.length);

  final mvhd = _child(moov, root, 'mvhd');
  if (mvhd != null) {
    final v = moov[mvhd.start];
    final int scale;
    final int duration;
    if (v == 1) {
      scale = _be32(moov, mvhd.start + 20);
      duration = _be64(moov, mvhd.start + 24);
    } else {
      scale = _be32(moov, mvhd.start + 12);
      duration = _be32(moov, mvhd.start + 16);
    }
    if (scale > 0) tags.durationMs = (duration * 1000 / scale).round();
  }

  final udta = _child(moov, root, 'udta');
  if (udta != null) {
    final meta = _child(moov, udta, 'meta');
    if (meta != null) {
      // meta — «полный» атом (4 байта версии), но у QuickTime бывает без них.
      final skip = _ascii(moov, meta.start + 4, 4) == 'hdlr' ? 0 : 4;
      final ilst = _child(moov, meta, 'ilst', skip: skip);
      if (ilst != null) _readIlst(moov, ilst, tags, withCover: withCover);
    }
    final chpl = _child(moov, udta, 'chpl');
    if (chpl != null) tags.chapters = _readChpl(moov, chpl);
  }

  if (tags.chapters.isEmpty) {
    try {
      tags.chapters = await _readQtChapters(f, moov, root);
    } catch (_) {}
  }
}

void _readIlst(Uint8List b, _Atom ilst, AudioTags tags, {required bool withCover}) {
  for (final item in _children(b, ilst.start, ilst.end)) {
    final data = _child(b, item, 'data');
    if (data == null || data.end - data.start < 8) continue;
    final value = Uint8List.sublistView(b, data.start + 8, data.end);
    String text() => utf8.decode(value, allowMalformed: true).trim();
    switch (item.type) {
      case '©nam':
        tags.title ??= _nonEmpty(text());
      case '©ART':
        tags.artist ??= _nonEmpty(text());
      case '©alb':
        tags.album ??= _nonEmpty(text());
      case 'aART':
        tags.albumArtist ??= _nonEmpty(text());
      case '©wrt':
        tags.composer ??= _nonEmpty(text());
      case '©cmt' || 'desc':
        tags.comment ??= _nonEmpty(text());
      case 'trkn':
        if (value.length >= 4) tags.track ??= _be16(value, 2);
      case 'covr':
        if (withCover && tags.cover == null && value.isNotEmpty) tags.cover = Uint8List.fromList(value);
    }
  }
}

List<TagChapter> _readChpl(Uint8List b, _Atom chpl) {
  final out = <TagChapter>[];
  var pos = chpl.start;
  if (chpl.end - pos < 5) return out;
  final version = b[pos];
  pos += 4;
  if (version == 1) pos += 4;
  if (pos >= chpl.end) return out;
  final count = b[pos++];
  for (var i = 0; i < count && pos + 9 <= chpl.end; i++) {
    final start = _be64(b, pos); // сотни наносекунд
    final len = b[pos + 8];
    pos += 9;
    if (pos + len > chpl.end) break;
    final title = utf8.decode(b.sublist(pos, pos + len), allowMalformed: true).trim();
    pos += len;
    out.add(TagChapter(start ~/ 10000, title));
  }
  return out;
}

/// Главы QuickTime: отдельная текстовая дорожка, на которую ссылается
/// аудиодорожка (tref/chap). Каждый образец — длина (2 байта) и текст.
Future<List<TagChapter>> _readQtChapters(RandomAccessFile f, Uint8List moov, _Atom root) async {
  final traks = [for (final a in _children(moov, root.start, root.end)) if (a.type == 'trak') a];
  final chapterIds = <int>{};
  final byId = <int, _Atom>{};
  for (final trak in traks) {
    final tkhd = _child(moov, trak, 'tkhd');
    if (tkhd == null) continue;
    final v = moov[tkhd.start];
    final id = _be32(moov, tkhd.start + (v == 1 ? 20 : 12));
    byId[id] = trak;
    final tref = _child(moov, trak, 'tref');
    final chap = tref == null ? null : _child(moov, tref, 'chap');
    if (chap != null) {
      for (var p = chap.start; p + 4 <= chap.end; p += 4) {
        chapterIds.add(_be32(moov, p));
      }
    }
  }
  for (final id in chapterIds) {
    final trak = byId[id];
    if (trak == null) continue;
    final mdia = _child(moov, trak, 'mdia');
    final mdhd = mdia == null ? null : _child(moov, mdia, 'mdhd');
    final minf = mdia == null ? null : _child(moov, mdia, 'minf');
    final stbl = minf == null ? null : _child(moov, minf, 'stbl');
    if (mdhd == null || stbl == null) continue;
    final mv = moov[mdhd.start];
    final scale = _be32(moov, mdhd.start + (mv == 1 ? 20 : 12));
    if (scale <= 0) continue;

    // Длительности образцов.
    final durations = <int>[];
    final stts = _child(moov, stbl, 'stts');
    if (stts == null) continue;
    final sttsCount = _be32(moov, stts.start + 4);
    for (var i = 0; i < sttsCount; i++) {
      final p = stts.start + 8 + i * 8;
      if (p + 8 > stts.end) break;
      final n = _be32(moov, p);
      final d = _be32(moov, p + 4);
      for (var k = 0; k < n && durations.length < 10000; k++) {
        durations.add(d);
      }
    }

    // Размеры образцов.
    final stsz = _child(moov, stbl, 'stsz');
    if (stsz == null) continue;
    final fixed = _be32(moov, stsz.start + 4);
    final sampleCount = _be32(moov, stsz.start + 8);
    final sizes = [
      for (var i = 0; i < sampleCount && stsz.start + 12 + i * 4 + 4 <= stsz.end; i++)
        fixed != 0 ? fixed : _be32(moov, stsz.start + 12 + i * 4),
    ];
    if (fixed != 0 && sizes.isEmpty) {
      for (var i = 0; i < sampleCount; i++) {
        sizes.add(fixed);
      }
    }

    // Смещения кусков и сколько образцов в каждом.
    final chunkOffsets = <int>[];
    final stco = _child(moov, stbl, 'stco');
    final co64 = _child(moov, stbl, 'co64');
    if (stco != null) {
      final n = _be32(moov, stco.start + 4);
      for (var i = 0; i < n && stco.start + 8 + i * 4 + 4 <= stco.end; i++) {
        chunkOffsets.add(_be32(moov, stco.start + 8 + i * 4));
      }
    } else if (co64 != null) {
      final n = _be32(moov, co64.start + 4);
      for (var i = 0; i < n && co64.start + 8 + i * 8 + 8 <= co64.end; i++) {
        chunkOffsets.add(_be64(moov, co64.start + 8 + i * 8));
      }
    }
    final stsc = _child(moov, stbl, 'stsc');
    final runs = <(int firstChunk, int perChunk)>[];
    if (stsc != null) {
      final n = _be32(moov, stsc.start + 4);
      for (var i = 0; i < n && stsc.start + 8 + i * 12 + 12 <= stsc.end; i++) {
        runs.add((_be32(moov, stsc.start + 8 + i * 12), _be32(moov, stsc.start + 12 + i * 12)));
      }
    }
    if (runs.isEmpty) runs.add((1, 1));

    final offsets = <int>[];
    var sample = 0;
    for (var c = 0; c < chunkOffsets.length && sample < sizes.length; c++) {
      var perChunk = 1;
      for (final r in runs) {
        if (r.$1 <= c + 1) perChunk = r.$2;
      }
      var at = chunkOffsets[c];
      for (var k = 0; k < perChunk && sample < sizes.length; k++) {
        offsets.add(at);
        at += sizes[sample];
        sample++;
      }
    }

    final out = <TagChapter>[];
    var time = 0;
    for (var i = 0; i < offsets.length && i < sizes.length; i++) {
      final raw = await _readAt(f, offsets[i], min(max(sizes[i], 0), 4096));
      var title = '';
      if (raw.length >= 2) {
        final len = _be16(raw, 0);
        final end = min(2 + len, raw.length);
        final bytes = raw.sublist(2, end);
        title = bytes.length >= 2 && ((bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0xFF && bytes[1] == 0xFE))
            ? _decodeUtf16(bytes)
            : utf8.decode(bytes, allowMalformed: true);
      }
      out.add(TagChapter((time * 1000 / scale).round(), title.trim()));
      if (i < durations.length) time += durations[i];
    }
    if (out.isNotEmpty) return out;
  }
  return const [];
}
