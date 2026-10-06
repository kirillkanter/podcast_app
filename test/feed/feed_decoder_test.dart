import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/feed/feed_decoder.dart';

void main() {
  test('windows-1251: вся кириллица и спецсимволы', () {
    // А..я = 0xC0..0xFF, Ёё = A8/B8, «» = AB/BB, № = B9, — = 97, € = 88
    final bytes = [
      for (var b = 0xC0; b <= 0xFF; b++) b,
      0xA8, 0xB8, 0xAB, 0xBB, 0xB9, 0x97, 0x88,
    ];
    final expected = '${String.fromCharCodes([for (var c = 0x0410; c <= 0x044F; c++) c])}'
        'Ёё«»№—€';
    expect(decodeWindows1251(bytes), expected);
  });

  test('кодировка из XML-декларации важнее HTTP-заголовка', () {
    final bytes = [
      ...ascii.encode('<?xml version="1.0" encoding="windows-1251"?><t>'),
      0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, // "Привет"
      ...ascii.encode('</t>'),
    ];
    final r = decodeFeedBytes(bytes, httpCharset: 'utf-8');
    expect(r.encoding, 'windows-1251');
    expect(r.text, contains('Привет'));
    expect(r.warning, isNull);
  });

  test('charset из HTTP, если в декларации кодировки нет', () {
    final bytes = [...ascii.encode('<t>'), 0xCF, 0xF0, ...ascii.encode('</t>')];
    final r = decodeFeedBytes(bytes, httpCharset: 'CP1251');
    expect(r.text, '<t>Пр</t>');
  });

  test('невалидный UTF-8 — откат на windows-1251 с предупреждением', () {
    final bytes = [...ascii.encode('<?xml version="1.0" encoding="UTF-8"?><t>'), 0xCF, 0xF0];
    final r = decodeFeedBytes(bytes);
    expect(r.encoding, 'windows-1251');
    expect(r.text, endsWith('Пр'));
    expect(r.warning, isNotNull);
  });

  test('UTF-16 LE с BOM', () {
    const text = '<rss>Тест</rss>';
    final bytes = <int>[0xFF, 0xFE];
    for (final unit in text.codeUnits) {
      bytes..add(unit & 0xFF)..add(unit >> 8);
    }
    expect(decodeFeedBytes(bytes).text, text);
  });

  test('неизвестная кодировка — UTF-8 с предупреждением', () {
    final bytes = utf8.encode('<?xml version="1.0" encoding="koi8-r"?><t>ok</t>');
    final r = decodeFeedBytes(bytes);
    expect(r.encoding, 'utf-8');
    expect(r.warning, contains('koi8-r'));
  });
}
