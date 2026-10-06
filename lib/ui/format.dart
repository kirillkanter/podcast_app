/// Форматирование дат, длительностей и текста для интерфейса.
library;

const _monthsGenitive = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
];

/// «Сегодня», «Вчера», «5 октября», «12 марта 2024».
String formatEpisodeDate(DateTime? date, {DateTime? now}) {
  if (date == null) return '';
  final local = date.toLocal();
  final today = now ?? DateTime.now();
  final day = DateTime(local.year, local.month, local.day);
  final todayDay = DateTime(today.year, today.month, today.day);
  final diff = todayDay.difference(day).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  final base = '${local.day} ${_monthsGenitive[local.month - 1]}';
  return local.year == today.year ? base : '$base ${local.year}';
}

/// «1 ч 05 мин», «45 мин», «40 сек».
String formatDuration(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return '';
  final totalSeconds = (milliseconds / 1000).round();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  if (hours > 0) return '$hours ч ${minutes.toString().padLeft(2, '0')} мин';
  if (minutes > 0) return '$minutes мин';
  return '$totalSeconds сек';
}

/// «только что», «5 мин назад», «3 ч назад», «вчера», «5 октября».
String formatAgo(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final diff = current.difference(time);
  if (diff.inMinutes < 1) return 'только что';
  if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
  if (diff.inHours < 24 && current.day == time.toLocal().day) return '${diff.inHours} ч назад';
  return formatEpisodeDate(time, now: current).toLowerCase();
}

/// Сколько осталось дослушать: «осталось 23 мин»; без позиции — длительность.
String formatLeft(int? durationMs, int positionMs) {
  if (durationMs == null || durationMs <= 0) return '';
  if (positionMs <= 0) return formatDuration(durationMs);
  final left = durationMs - positionMs;
  return left <= 0 ? '' : 'осталось ${formatDuration(left)}';
}

/// Склонение: plural(5, 'эпизод', 'эпизода', 'эпизодов') → «эпизодов».
String plural(int n, String one, String few, String many) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}

const _entities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ',
  'laquo': '«', 'raquo': '»', 'mdash': '—', 'ndash': '–', 'hellip': '…',
};

/// Простое превращение HTML-описания в текст: абзацы и переносы
/// сохраняются, теги и сущности убираются.
String htmlToText(String? html) {
  if (html == null || html.isEmpty) return '';
  var s = html
      .replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', caseSensitive: false, dotAll: true), '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|li|h[1-6])\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
    final e = m.group(1)!;
    if (e.startsWith('#x') || e.startsWith('#X')) {
      final code = int.tryParse(e.substring(2), radix: 16);
      return code == null || code > 0x10FFFF ? m.group(0)! : String.fromCharCode(code);
    }
    if (e.startsWith('#')) {
      final code = int.tryParse(e.substring(1));
      return code == null || code > 0x10FFFF ? m.group(0)! : String.fromCharCode(code);
    }
    return _entities[e.toLowerCase()] ?? m.group(0)!;
  });
  return s
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
