/// Статистика чтения: сколько минут в день и сколько страниц перелистано
/// вперёд. Хранится на устройстве (по ключу на день), не синхронизируется.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/db/database.dart';
import '../../app_scope.dart';
import '../../format.dart';
import '../../theme.dart';

const _prefix = 'reader.stats.';

/// Страница открыта дольше — значит, отошли от книги: считаем не больше.
const _maxPerPage = Duration(minutes: 3);

String _dayKey(DateTime d) =>
    '$_prefix${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class DayStat {
  const DayStat(this.day, this.seconds, this.pages);

  final DateTime day;
  final int seconds;
  final int pages;

  static DayStat parse(DateTime day, String? value) {
    final parts = (value ?? '').split('|');
    return DayStat(day, int.tryParse(parts.first) ?? 0, parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
  }
}

/// Счётчик в открытой книге.
class ReadingStats {
  ReadingStats(this._db);

  final AppDatabase _db;
  DateTime? _since;
  int _seconds = 0;
  int _pages = 0;

  /// Читаем (книга на экране, приложение не свёрнуто).
  void resume() => _since ??= DateTime.now();

  /// Свернули приложение или закрыли книгу.
  void pause() {
    _addTime();
    _since = null;
    flush();
  }

  /// Перелистнули страницу ([forward] — вперёд, она считается прочитанной).
  void turn({required bool forward}) {
    _addTime();
    _since = DateTime.now();
    if (forward) _pages++;
    if (_seconds >= 60 || _pages >= 5) flush();
  }

  void _addTime() {
    final since = _since;
    if (since == null) return;
    final d = DateTime.now().difference(since);
    _seconds += (d > _maxPerPage ? _maxPerPage : d).inSeconds;
  }

  Future<void> flush() async {
    if (_seconds == 0 && _pages == 0) return;
    final seconds = _seconds;
    final pages = _pages;
    _seconds = 0;
    _pages = 0;
    try {
      final key = _dayKey(DateTime.now());
      final old = DayStat.parse(DateTime.now(), await _db.setting(key));
      await _db.setSetting(key, '${old.seconds + seconds}|${old.pages + pages}');
    } catch (_) {}
  }

  /// Последние [days] дней, начиная с сегодняшнего (сегодня — последний).
  static Future<List<DayStat>> load(AppDatabase db, {int days = 30}) async {
    final today = DateTime.now();
    final out = <DayStat>[];
    for (var i = days - 1; i >= 0; i--) {
      final d = DateTime(today.year, today.month, today.day - i);
      out.add(DayStat.parse(d, await db.setting(_dayKey(d))));
    }
    return out;
  }
}

String _minutes(int seconds) {
  final m = (seconds / 60).round();
  if (m < 60) return '$m мин';
  return '${m ~/ 60} ч ${m % 60} мин';
}

Future<void> showReadingStats(BuildContext context) {
  final db = AppScope.of(context).db;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FutureBuilder<List<DayStat>>(
      future: ReadingStats.load(db),
      builder: (context, snap) {
        final c = BcColors.of(context);
        final days = snap.data;
        if (days == null) return const SizedBox(height: 320);
        final today = days.last;
        final week = days.sublist(days.length - 7);
        final weekSeconds = week.fold(0, (s, d) => s + d.seconds);
        final weekPages = week.fold(0, (s, d) => s + d.pages);
        final monthSeconds = days.fold(0, (s, d) => s + d.seconds);
        var streak = 0;
        for (var i = days.length - 1; i >= 0; i--) {
          if (days[i].seconds >= 60) {
            streak++;
          } else if (i != days.length - 1) {
            break;
          }
        }
        final maxSec = math.max(60, week.map((d) => d.seconds).reduce(math.max));
        const weekdays = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
        Widget tile(String value, String label) => Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(14)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(value, style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 18, color: c.text)),
                  const SizedBox(height: 2),
                  Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
                ]),
              ),
            );
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 40,
                height: 5,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            Text('Статистика чтения', style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 19, color: c.text)),
            const SizedBox(height: 14),
            Row(children: [
              tile(_minutes(today.seconds), 'сегодня'),
              const SizedBox(width: 10),
              tile('${today.pages}', '${plural(today.pages, 'страница', 'страницы', 'страниц')} сегодня'),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              tile(_minutes(weekSeconds), 'за 7 дней · $weekPages стр.'),
              const SizedBox(width: 10),
              tile('$streak', '${plural(streak, 'день', 'дня', 'дней')} подряд'),
            ]),
            const SizedBox(height: 20),
            Text('Минут в день', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
            const SizedBox(height: 10),
            SizedBox(
              height: 150,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (final d in week)
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text(d.seconds == 0 ? '' : '${(d.seconds / 60).round()}', style: TextStyle(fontSize: 11, color: c.muted)),
                      const SizedBox(height: 4),
                      Container(
                        height: math.max(3, 100 * d.seconds / maxSec),
                        margin: const EdgeInsets.symmetric(horizontal: 7),
                        decoration: BoxDecoration(
                          color: d.seconds == 0 ? c.line : c.bar,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(weekdays[d.day.weekday - 1],
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: d == today ? FontWeight.w600 : FontWeight.w400,
                              color: d == today ? c.text : c.muted)),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 16),
            Text('За 30 дней — ${_minutes(monthSeconds)}. Считается время, пока книга открыта на экране; '
                'страница дольше трёх минут засчитывается как три минуты.',
                style: TextStyle(fontSize: 12, height: 1.4, color: c.muted)),
          ]),
        );
      },
    ),
  );
}
