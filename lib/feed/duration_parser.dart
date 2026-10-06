/// Разбор `itunes:duration`.
///
/// Встречаются форматы: `3723`, `3723.5`, `62:03`, `1:02:03`, `01:02:03.500`,
/// а также `PT1H2M3S` (ISO-8601). Нулевая или отрицательная длительность — `null`.
library;

final _iso = RegExp(
  r'^P(?:(\d+)D)?T?(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$',
  caseSensitive: false,
);

Duration? parseFeedDuration(String? input) {
  if (input == null) return null;
  final text = input.trim().replaceAll(',', '.');
  if (text.isEmpty) return null;

  double? seconds;
  if (text.contains(':')) {
    seconds = _parseClock(text);
  } else if (_iso.hasMatch(text)) {
    seconds = _parseIso(_iso.firstMatch(text)!);
  } else {
    seconds = double.tryParse(text);
  }

  if (seconds == null || seconds.isNaN || seconds <= 0) return null;
  // Больше недели — почти наверняка мусор (например, миллисекунды).
  if (seconds > const Duration(days: 7).inSeconds) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}

double? _parseClock(String text) {
  final parts = text.split(':');
  if (parts.length > 3 || parts.any((p) => p.isEmpty)) return null;

  var total = 0.0;
  for (var i = 0; i < parts.length; i++) {
    final isLast = i == parts.length - 1;
    final value = isLast ? double.tryParse(parts[i]) : int.tryParse(parts[i])?.toDouble();
    if (value == null || value < 0) return null;
    // Минуты и секунды не первой позиции не должны превышать 59.
    if (i > 0 && value >= 60) return null;
    total = total * 60 + value;
  }
  return total;
}

double? _parseIso(RegExpMatch m) {
  if (m.group(1) == null && m.group(2) == null && m.group(3) == null && m.group(4) == null) {
    return null;
  }
  double g(int i) => m.group(i) == null ? 0 : double.parse(m.group(i)!);
  return g(1) * 86400 + g(2) * 3600 + g(3) * 60 + g(4);
}
