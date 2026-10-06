import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/feed/date_parser.dart';

void main() {
  final cases = <String, DateTime?>{
    // RFC 822 по стандарту
    'Tue, 06 Oct 2026 10:00:00 +0300': DateTime.utc(2026, 10, 6, 7),
    'Tue, 06 Oct 2026 10:00:00 GMT': DateTime.utc(2026, 10, 6, 10),
    'Tue, 6 Oct 2026 10:00:00 -0500': DateTime.utc(2026, 10, 6, 15),
    // без дня недели, без секунд, полное название дня
    '06 Oct 2026 10:00 +0000': DateTime.utc(2026, 10, 6, 10),
    'Tuesday, 06 October 2026 10:00:00 Z': DateTime.utc(2026, 10, 6, 10),
    // названия поясов
    'Tue, 06 Oct 2026 10:00:00 PDT': DateTime.utc(2026, 10, 6, 17),
    'Tue, 06 Oct 2026 10:00:00 MSK': DateTime.utc(2026, 10, 6, 7),
    // смещение с двоеточием, GMT+3, пояс в скобках
    'Tue, 06 Oct 2026 10:00:00 +03:00': DateTime.utc(2026, 10, 6, 7),
    'Tue, 06 Oct 2026 10:00:00 GMT+3': DateTime.utc(2026, 10, 6, 7),
    'Tue, 06 Oct 2026 10:00:00 +0300 (MSK)': DateTime.utc(2026, 10, 6, 7),
    // без пояса — UTC
    'Tue, 06 Oct 2026 10:00:00': DateTime.utc(2026, 10, 6, 10),
    // двузначный год, дефисы, лишние пробелы
    'Tue, 06 Oct 26 10:00:00 GMT': DateTime.utc(2026, 10, 6, 10),
    '06-Oct-2026 10:00:00 GMT': DateTime.utc(2026, 10, 6, 10),
    '  Tue,  06   Oct 2026   10:00:00   GMT ': DateTime.utc(2026, 10, 6, 10),
    // только дата
    '06 Oct 2026': DateTime.utc(2026, 10, 6),
    // по-русски
    'Вт, 06 окт 2026 10:00:00 +0300': DateTime.utc(2026, 10, 6, 7),
    '6 мая 2026 10:00': DateTime.utc(2026, 5, 6, 10),
    '6 окт. 2026 10:00': DateTime.utc(2026, 10, 6, 10),
    // ISO-8601
    '2026-10-06T10:00:00Z': DateTime.utc(2026, 10, 6, 10),
    '2026-10-06T10:00:00+03:00': DateTime.utc(2026, 10, 6, 7),
    '2026-10-06 10:00:00': DateTime.utc(2026, 10, 6, 10),
    // мусор
    '': null,
    'вчера': null,
    '31 Feb 2026 10:00:00 GMT': null,
    '06 Foo 2026 10:00:00 GMT': null,
    '06 Oct 2026 25:00:00 GMT': null,
  };

  for (final entry in cases.entries) {
    test('"${entry.key}"', () {
      expect(parseFeedDate(entry.key), entry.value);
    });
  }

  test('null', () => expect(parseFeedDate(null), isNull));
}
