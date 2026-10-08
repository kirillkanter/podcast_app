/// Статистика чтения по дням: свои минуты и страницы (на этом устройстве)
/// и итоги других устройств (приходят с сервера). Хранится в настройках,
/// по ключу на день.
library;

import '../data/db/database.dart';

const _ownPrefix = 'reader.stats.';
const _othersPrefix = 'reader.statsOther.';

/// «2026-10-08».
String dayId(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class DayStat {
  const DayStat(this.day, this.seconds, this.pages);

  final DateTime day;
  final int seconds;
  final int pages;

  static DayStat parse(DateTime day, String? value) {
    final parts = (value ?? '').split('|');
    return DayStat(day, int.tryParse(parts.first) ?? 0, parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
  }

  String encode() => '$seconds|$pages';

  DayStat operator +(DayStat o) => DayStat(day, seconds + o.seconds, pages + o.pages);
}

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// Добавить к сегодняшнему дню этого устройства.
Future<void> addToToday(AppDatabase db, {required int seconds, required int pages}) async {
  final key = '$_ownPrefix${dayId(_today())}';
  final old = DayStat.parse(_today(), await db.setting(key));
  await db.setSetting(key, DayStat(old.day, old.seconds + seconds, old.pages + pages).encode());
}

/// Последние [days] дней (сегодня — последний). [others] — прибавить
/// другие устройства.
Future<List<DayStat>> loadDays(AppDatabase db, {int days = 30, bool others = true}) async {
  final today = _today();
  final out = <DayStat>[];
  for (var i = days - 1; i >= 0; i--) {
    final d = DateTime(today.year, today.month, today.day - i);
    var stat = DayStat.parse(d, await db.setting('$_ownPrefix${dayId(d)}'));
    if (others) stat = stat + DayStat.parse(d, await db.setting('$_othersPrefix${dayId(d)}'));
    out.add(stat);
  }
  return out;
}

/// Итоги других устройств с [since] (дни без записей — ноль).
Future<void> saveOthers(AppDatabase db, DateTime since, Map<String, DayStat> byDay) async {
  final today = _today();
  for (var d = DateTime(since.year, since.month, since.day); !d.isAfter(today); d = DateTime(d.year, d.month, d.day + 1)) {
    final id = dayId(d);
    final key = '$_othersPrefix$id';
    final value = byDay[id]?.encode() ?? '';
    if ((await db.setting(key) ?? '') != value) await db.setSetting(key, value);
  }
}
