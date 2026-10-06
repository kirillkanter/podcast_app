import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/feed/duration_parser.dart';

void main() {
  final cases = <String, Duration?>{
    '3723': const Duration(seconds: 3723),
    '3723.5': const Duration(seconds: 3723, milliseconds: 500),
    '3723,5': const Duration(seconds: 3723, milliseconds: 500),
    '62:03': const Duration(minutes: 62, seconds: 3),
    '1:02:03': const Duration(hours: 1, minutes: 2, seconds: 3),
    '01:02:03.250': const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 250),
    ' 45:00 ': const Duration(minutes: 45),
    'PT1H2M3S': const Duration(hours: 1, minutes: 2, seconds: 3),
    'PT45M': const Duration(minutes: 45),
    '': null,
    '0': null,
    '00:00:00': null,
    '-5': null,
    '1:75:00': null,
    '1::00': null,
    '1:2:3:4': null,
    'abc': null,
    'PT': null,
    '3723000': null, // похоже на миллисекунды
  };

  for (final entry in cases.entries) {
    test('"${entry.key}"', () {
      expect(parseFeedDuration(entry.key), entry.value);
    });
  }
}
