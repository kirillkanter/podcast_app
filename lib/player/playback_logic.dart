/// Правила воспроизведения без зависимостей от плеера — их легко тестировать.
library;

/// Доступные скорости воспроизведения.
const playbackSpeeds = [0.8, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0, 2.5, 3.0];

/// Шаг перемотки назад и вперёд.
const rewindStep = Duration(seconds: 10);
const fastForwardStep = Duration(seconds: 30);

/// Как часто сохранять позицию во время воспроизведения.
const positionSaveInterval = Duration(seconds: 15);

/// С какого места начинать эпизод.
///
/// - Прослушанный эпизод начинается сначала.
/// - Если до конца осталось меньше 15 секунд, эпизод фактически дослушан —
///   тоже сначала.
/// - Иначе продолжаем с сохранённой позиции.
Duration resumePosition({
  required int positionMs,
  required bool played,
  int? durationMs,
}) {
  if (played || positionMs <= 0) return Duration.zero;
  if (durationMs != null && durationMs > 0 && durationMs - positionMs < 15000) {
    return Duration.zero;
  }
  return Duration(milliseconds: positionMs);
}

/// Позиция после перемотки на [delta], в пределах эпизода.
Duration seekRelative(Duration position, Duration delta, Duration? duration) {
  var target = position + delta;
  if (target < Duration.zero) target = Duration.zero;
  if (duration != null && duration > Duration.zero && target > duration) target = duration;
  return target;
}

/// «1:02:03» или «12:05».
String formatClock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// «1,5×», «1×».
String formatSpeed(double speed) {
  // Через сотые, а не сравнение double: 1.1 * 10 в double не равно 11.
  final hundredths = (speed * 100).round();
  final whole = hundredths ~/ 100;
  final fraction = hundredths % 100;
  if (fraction == 0) return '$whole×';
  if (fraction % 10 == 0) return '$whole,${fraction ~/ 10}×';
  return '$whole,${fraction.toString().padLeft(2, '0')}×';
}

/// Таймер сна: пауза в заданное время.
/// Вариант «в конце эпизода» появится вместе с очередью: сейчас плеер
/// и так останавливается после эпизода.
class SleepTimer {
  const SleepTimer.at(this.endsAt);

  final DateTime endsAt;

  Duration remaining(DateTime now) {
    final left = endsAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }
}
