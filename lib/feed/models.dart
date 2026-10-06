/// Модели результата разбора RSS-фида.
///
/// Это «сырые» данные фида, не привязанные к БД. В БД их переносит
/// [AppDatabase.saveParsedFeed].
library;

enum PodcastType { episodic, serial }

enum EpisodeType { full, trailer, bonus }

class ParsedFeed {
  const ParsedFeed({
    required this.title,
    required this.episodes,
    this.description,
    this.link,
    this.imageUrl,
    this.author,
    this.ownerName,
    this.ownerEmail,
    this.language,
    this.categories = const [],
    this.explicit,
    this.type = PodcastType.episodic,
    this.newFeedUrl,
    this.podcastGuid,
    this.locked = false,
    this.funding = const [],
    this.warnings = const [],
  });

  /// Может быть пустой строкой, если в фиде нет названия (см. [warnings]).
  final String title;
  final String? description;
  final String? link;
  final String? imageUrl;
  final String? author;
  final String? ownerName;
  final String? ownerEmail;
  final String? language;
  final List<String> categories;
  final bool? explicit;
  final PodcastType type;

  /// `itunes:new-feed-url`: фид переехал, подписку надо перевести на этот адрес.
  final String? newFeedUrl;

  /// `podcast:guid` — стабильный идентификатор подкаста (Podcasting 2.0).
  final String? podcastGuid;

  /// `podcast:locked` — автор запретил импорт фида на другие хостинги.
  final bool locked;
  final List<FundingLink> funding;

  /// Эпизоды в порядке следования в фиде. Ключи [ParsedEpisode.key] уникальны.
  final List<ParsedEpisode> episodes;

  /// Некритичные проблемы фида: пропущенные эпизоды, дубли guid и т. п.
  final List<String> warnings;
}

class ParsedEpisode {
  const ParsedEpisode({
    required this.key,
    required this.title,
    required this.enclosure,
    this.guid,
    this.description,
    this.summary,
    this.link,
    this.pubDate,
    this.duration,
    this.imageUrl,
    this.season,
    this.episodeNumber,
    this.type = EpisodeType.full,
    this.explicit,
    this.chapters,
    this.transcripts = const [],
    this.persons = const [],
  });

  /// Стабильный ключ эпизода внутри фида, см. `episode_identity.dart`.
  final String key;

  /// Исходный `guid` из фида, если был.
  final String? guid;
  final String title;

  /// HTML-описание: `content:encoded`, иначе `description`, иначе `itunes:summary`.
  final String? description;

  /// Короткое описание: `itunes:subtitle` или `itunes:summary`.
  final String? summary;
  final String? link;

  /// Дата публикации в UTC.
  final DateTime? pubDate;
  final Enclosure enclosure;
  final Duration? duration;
  final String? imageUrl;
  final int? season;
  final int? episodeNumber;
  final EpisodeType type;
  final bool? explicit;
  final ChaptersRef? chapters;
  final List<TranscriptRef> transcripts;
  final List<Person> persons;
}

class Enclosure {
  const Enclosure({required this.url, this.mimeType, this.length});

  final String url;
  final String? mimeType;

  /// Размер файла в байтах по данным фида. Часто неточен или равен нулю.
  final int? length;

  bool get isVideo => mimeType?.startsWith('video/') ?? false;
}

class ChaptersRef {
  const ChaptersRef({required this.url, this.mimeType});

  final String url;
  final String? mimeType;
}

class TranscriptRef {
  const TranscriptRef({
    required this.url,
    this.mimeType,
    this.language,
    this.rel,
  });

  final String url;
  final String? mimeType;
  final String? language;

  /// `captions`, если транскрипт синхронизирован с аудио.
  final String? rel;
}

class Person {
  const Person({required this.name, this.role, this.group, this.href, this.img});

  final String name;
  final String? role;
  final String? group;
  final String? href;
  final String? img;
}

class FundingLink {
  const FundingLink({required this.url, this.label});

  final String url;
  final String? label;
}

/// Документ не удалось разобрать как RSS-фид подкаста.
class FeedParseException implements Exception {
  const FeedParseException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() =>
      cause == null ? 'FeedParseException: $message' : 'FeedParseException: $message ($cause)';
}
