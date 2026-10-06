/// Стабильный ключ эпизода внутри фида.
///
/// От ключа зависит синхронизация: если он изменится при следующем
/// обновлении фида, пользователь увидит «новый» эпизод и потеряет позицию.
///
/// Приоритет:
/// 1. `guid` — так делают все клиенты и gPodder API;
/// 2. URL аудиофайла — если guid нет;
/// 3. название + дата — если нет и URL (такой эпизод всё равно будет
///    отброшен парсером, но функция остаётся тотальной).
///
/// Префикс фиксирует происхождение ключа, чтобы guid, случайно совпавший
/// с чьим-то URL, не склеил разные эпизоды.
library;

String episodeKey({
  required String? guid,
  required String? enclosureUrl,
  required String title,
  required DateTime? pubDate,
}) {
  final g = guid?.trim();
  if (g != null && g.isNotEmpty) return 'g:$g';

  final u = enclosureUrl?.trim();
  if (u != null && u.isNotEmpty) return 'u:$u';

  return 't:${title.trim()}|${pubDate?.toUtc().toIso8601String() ?? ''}';
}

/// Ключ для эпизода, чей guid уже занят другим эпизодом того же фида.
/// Такие дубли встречаются у фидов, где guid генерируется по шаблону.
String fallbackEpisodeKey({
  required String enclosureUrl,
  required String title,
  required DateTime? pubDate,
}) =>
    episodeKey(guid: null, enclosureUrl: enclosureUrl, title: title, pubDate: pubDate);
