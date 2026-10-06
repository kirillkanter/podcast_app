/// Разбор дат из RSS.
///
/// Формально `pubDate` — RFC 822, на практике встречается что угодно:
/// без дня недели, без секунд, с двузначным годом, с названием часового пояса,
/// со смещением `+03:00`, на русском, в ISO-8601. Возвращает время в UTC
/// или `null`, если дату распознать не удалось.
library;

const _months = <String, int>{
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  'янв': 1, 'фев': 2, 'мар': 3, 'апр': 4, 'май': 5, 'мая': 5,
  'июн': 6, 'июл': 7, 'авг': 8, 'сен': 9, 'окт': 10, 'ноя': 11, 'дек': 12,
};

/// Смещения часовых поясов в минутах.
const _zones = <String, int>{
  'ut': 0, 'utc': 0, 'gmt': 0, 'z': 0,
  'est': -5 * 60, 'edt': -4 * 60,
  'cst': -6 * 60, 'cdt': -5 * 60,
  'mst': -7 * 60, 'mdt': -6 * 60,
  'pst': -8 * 60, 'pdt': -7 * 60,
  'bst': 60, 'cet': 60, 'cest': 2 * 60,
  'eet': 2 * 60, 'eest': 3 * 60, 'msk': 3 * 60,
};

final _rfc822 = RegExp(
  // необязательный день недели: "Tue," / "Tuesday" / "Вт,"
  r'^(?:[^\d\s,]+,?\s+)?'
  // день, месяц, год: "6 Oct 2026", "06-Oct-26", "6 окт. 2026"
  r'(\d{1,2})[\s-]+([^\d\s.,-]+)\.?,?[\s-]+(\d{2,4})'
  // время: "10:00", "10:00:00", "10:00:00.123", допускается "T"
  r'(?:[\sT,]+(\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.,]\d+)?)?'
  // остаток — часовой пояс
  r'\s*(.*)$',
);

final _numericZone = RegExp(r'^(?:gmt|utc|ut)?\s*([+-])(\d{1,2}):?(\d{2})?$');

DateTime? parseFeedDate(String? input) {
  if (input == null) return null;
  final text = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty) return null;

  final m = _rfc822.firstMatch(text);
  if (m != null) {
    final result = _fromRfc822Match(m);
    if (result != null) return result;
  }

  // ISO-8601 и прочее, что понимает DateTime.
  final iso = DateTime.tryParse(text);
  if (iso == null) return null;
  // Без указания пояса DateTime.tryParse вернёт локальное время;
  // для фидов считаем такие даты UTC.
  return iso.isUtc
      ? iso
      : DateTime.utc(iso.year, iso.month, iso.day, iso.hour, iso.minute,
          iso.second, iso.millisecond);
}

DateTime? _fromRfc822Match(RegExpMatch m) {
  final day = int.parse(m.group(1)!);
  final month = _months[_monthKey(m.group(2)!)];
  if (month == null) return null;

  var year = int.parse(m.group(3)!);
  if (m.group(3)!.length == 2) {
    year += year < 50 ? 2000 : 1900;
  } else if (m.group(3)!.length == 3) {
    return null;
  }

  final hour = m.group(4) == null ? 0 : int.parse(m.group(4)!);
  final minute = m.group(5) == null ? 0 : int.parse(m.group(5)!);
  final second = m.group(6) == null ? 0 : int.parse(m.group(6)!);
  if (hour > 23 || minute > 59 || second > 60) return null;

  final offset = _parseZone(m.group(7)!);
  if (offset == null) return null;

  final local = DateTime.utc(year, month, day, hour, minute, second == 60 ? 59 : second);
  // DateTime нормализует 31 февраля в 3 марта — такие даты отбрасываем.
  if (local.day != day || local.month != month) return null;
  return local.subtract(Duration(minutes: offset));
}

String _monthKey(String raw) {
  final lower = raw.toLowerCase();
  // "мая" должна совпасть целиком, остальное — по первым трём буквам.
  if (_months.containsKey(lower)) return lower;
  return lower.length >= 3 ? lower.substring(0, 3) : lower;
}

/// Смещение пояса в минутах; `null`, если остаток строки не похож на пояс.
int? _parseZone(String raw) {
  final zone = raw.trim().toLowerCase();
  if (zone.isEmpty) return 0;

  final named = _zones[zone];
  if (named != null) return named;

  final n = _numericZone.firstMatch(zone);
  if (n != null) {
    final sign = n.group(1) == '-' ? -1 : 1;
    final hours = int.parse(n.group(2)!);
    final minutes = n.group(3) == null ? 0 : int.parse(n.group(3)!);
    if (hours > 14 || minutes > 59) return null;
    return sign * (hours * 60 + minutes);
  }

  // Встречается "+0300 (MSK)" — берём первую часть.
  final firstPart = zone.split(RegExp(r'[\s(]')).first;
  if (firstPart != zone) return _parseZone(firstPart);

  // Неизвестное название пояса — лучше дата с ошибкой в несколько часов,
  // чем отсутствие даты.
  if (RegExp(r'^[a-z]{1,5}$').hasMatch(zone)) return 0;
  return null;
}
