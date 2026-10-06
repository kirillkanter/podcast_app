/// Превращает байты фида в строку с учётом кодировки.
///
/// Порядок определения: BOM → `encoding` в XML-декларации → charset из
/// HTTP-заголовка → UTF-8. Если UTF-8 оказался невалидным, пробуем
/// windows-1251 (частый случай у русскоязычных фидов со старых CMS).
library;

import 'dart:convert';

class DecodedFeed {
  const DecodedFeed(this.text, this.encoding, {this.warning});

  final String text;

  /// Кодировка, которой фактически декодирован текст.
  final String encoding;
  final String? warning;
}

final _declEncoding = RegExp(
  r'''^\s*<\?xml[^>]*?encoding\s*=\s*["']([A-Za-z0-9._-]+)["']''',
);

DecodedFeed decodeFeedBytes(List<int> bytes, {String? httpCharset}) {
  // BOM
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return DecodedFeed(utf8.decode(bytes.sublist(3), allowMalformed: true), 'utf-8');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return DecodedFeed(_decodeUtf16(bytes, 2, littleEndian: true), 'utf-16le');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return DecodedFeed(_decodeUtf16(bytes, 2, littleEndian: false), 'utf-16be');
  }

  // XML-декларация всегда в ASCII-совместимой части, читаем начало как latin1.
  final head = latin1.decode(bytes.take(256).toList());
  final declared = _declEncoding.firstMatch(head)?.group(1);
  final name = _normalize(declared ?? httpCharset ?? 'utf-8');

  switch (name) {
    case 'windows-1251':
      return DecodedFeed(decodeWindows1251(bytes), name);
    case 'iso-8859-1':
      return DecodedFeed(latin1.decode(bytes), name);
    case 'windows-1252':
      return DecodedFeed(_decodeWindows1252(bytes), name);
    case 'utf-8':
      return _decodeUtf8WithFallback(bytes);
    default:
      final result = _decodeUtf8WithFallback(bytes);
      return DecodedFeed(
        result.text,
        result.encoding,
        warning: 'Неподдерживаемая кодировка "$name", использована ${result.encoding}',
      );
  }
}

DecodedFeed _decodeUtf8WithFallback(List<int> bytes) {
  try {
    return DecodedFeed(utf8.decode(bytes), 'utf-8');
  } on FormatException {
    return DecodedFeed(
      decodeWindows1251(bytes),
      'windows-1251',
      warning: 'Фид объявлен как UTF-8, но содержит невалидные байты; '
          'декодирован как windows-1251',
    );
  }
}

String _normalize(String raw) {
  final n = raw.trim().toLowerCase().replaceAll('_', '-');
  switch (n) {
    case 'utf8':
    case 'utf-8':
    case 'us-ascii':
    case 'ascii':
      return 'utf-8';
    case 'cp1251':
    case 'windows-1251':
    case 'win-1251':
    case 'x-cp1251':
      return 'windows-1251';
    case 'latin1':
    case 'latin-1':
    case 'iso-8859-1':
    case 'iso8859-1':
      return 'iso-8859-1';
    case 'cp1252':
    case 'windows-1252':
      return 'windows-1252';
    default:
      return n;
  }
}

String _decodeUtf16(List<int> bytes, int start, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

/// windows-1251: 0x00–0x7F совпадает с ASCII, 0xC0–0xFF — А..я подряд,
/// 0x80–0xBF — таблица ниже. 0x98 в кодировке не определён.
const _cp1251High = <int>[
  0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, // 80–87
  0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F, // 88–8F
  0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90–97
  0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F, // 98–9F
  0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, // A0–A7
  0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407, // A8–AF
  0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, // B0–B7
  0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457, // B8–BF
];

String decodeWindows1251(List<int> bytes) {
  final codes = List<int>.filled(bytes.length, 0);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    if (b < 0x80) {
      codes[i] = b;
    } else if (b < 0xC0) {
      codes[i] = _cp1251High[b - 0x80];
    } else {
      codes[i] = 0x0410 + (b - 0xC0);
    }
  }
  return String.fromCharCodes(codes);
}

/// windows-1252 отличается от latin1 только диапазоном 0x80–0x9F.
const _cp1252High = <int>[
  0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, // 80–87
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD, // 88–8F
  0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90–97
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178, // 98–9F
];

String _decodeWindows1252(List<int> bytes) {
  final codes = List<int>.filled(bytes.length, 0);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    codes[i] = (b >= 0x80 && b < 0xA0) ? _cp1252High[b - 0x80] : b;
  }
  return String.fromCharCodes(codes);
}
