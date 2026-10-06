import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/ui/podcast_screen.dart';

void main() {
  test('частота выхода по датам эпизодов', () {
    final start = DateTime(2026, 10, 6);
    List<DateTime> every(int days) => [for (var i = 0; i < 8; i++) start.subtract(Duration(days: i * days))];
    expect(releaseFrequency(every(1)), 'каждый день');
    expect(releaseFrequency(every(7)), 'раз в неделю');
    expect(releaseFrequency(every(14)), 'раз в две недели');
    expect(releaseFrequency(every(30)), 'раз в месяц');
    expect(releaseFrequency([start, null]), isNull, reason: 'мало данных');
  });
}
