/// Разбор того, что пользователь вставил в поле «Ссылка на RSS».
library;

sealed class FeedInput {
  const FeedInput();
}

/// Прямая ссылка на фид.
class DirectFeedUrl extends FeedInput {
  const DirectFeedUrl(this.url);
  final Uri url;
}

/// Ссылка на страницу подкаста в Apple Podcasts. Адрес фида узнаём через
/// iTunes Lookup API.
class ApplePodcastsLink extends FeedInput {
  const ApplePodcastsLink(this.id);
  final String id;
}

const _appSchemes = ['feed://', 'itpc://', 'pcast://', 'podcast://', 'podcasts://'];

/// `null` — строка не похожа на ссылку.
FeedInput? parseFeedInput(String raw) {
  var s = raw.trim();
  if (s.isEmpty || s.contains(RegExp(r'\s'))) return null;

  final lower = s.toLowerCase();
  if (lower.startsWith('feed:http')) {
    // feed:https://example.com/rss
    s = s.substring(5);
  } else {
    for (final scheme in _appSchemes) {
      if (lower.startsWith(scheme)) {
        s = 'https://${s.substring(scheme.length)}';
        break;
      }
    }
  }

  // Другая схема без «//» (mailto:, tel:) — не ссылка на фид.
  // «example.com:8080/rss» сюда не попадает: после двоеточия цифры порта.
  if (RegExp(r'^[a-z][a-z0-9+.-]*:(?!//|\d)', caseSensitive: false).hasMatch(s)) return null;

  if (!RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(s)) {
    s = 'https://$s';
  }

  final uri = Uri.tryParse(s);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (!uri.host.contains('.')) return null;

  final host = uri.host.toLowerCase();
  if (host == 'podcasts.apple.com' || host == 'itunes.apple.com') {
    final id = RegExp(r'/id(\d+)').firstMatch(uri.path)?.group(1) ??
        uri.queryParameters['id'];
    if (id != null && RegExp(r'^\d+$').hasMatch(id)) return ApplePodcastsLink(id);
  }
  return DirectFeedUrl(uri);
}

/// Ключ для сравнения адресов фидов: без схемы, «www.» и завершающего слэша.
/// Каталоги и другие устройства часто хранят http вместо https.
String feedKey(String url) => url
    .trim()
    .toLowerCase()
    .replaceFirst(RegExp(r'^https?://'), '')
    .replaceFirst(RegExp(r'^www\.'), '')
    .replaceFirst(RegExp(r'/+$'), '');
