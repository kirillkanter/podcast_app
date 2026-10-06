/// Парсер RSS 2.0 с расширениями `itunes:`, `podcast:` (Podcasting 2.0),
/// `content:`, `media:`, `googleplay:` и `dc:`.
///
/// Рассчитан на реальные фиды: необъявленные префиксы, HTML-сущности
/// (`&nbsp;`), голые `&`, управляющие символы, дубли guid, эпизоды без аудио,
/// относительные URL.
library;

import 'package:xml/xml.dart';

import 'date_parser.dart';
import 'duration_parser.dart';
import 'episode_identity.dart';
import 'feed_decoder.dart';
import 'models.dart';

/// Разбирает фид из байтов (как пришёл по HTTP).
///
/// [feedUrl] нужен для разрешения относительных ссылок.
/// [httpCharset] — charset из заголовка `Content-Type`, если был.
ParsedFeed parseFeedBytes(List<int> bytes, {String? feedUrl, String? httpCharset}) {
  final decoded = decodeFeedBytes(bytes, httpCharset: httpCharset);
  final feed = parseFeed(decoded.text, feedUrl: feedUrl);
  if (decoded.warning == null) return feed;
  return _withWarnings(feed, [decoded.warning!]);
}

/// Разбирает фид из уже декодированной строки.
ParsedFeed parseFeed(String source, {String? feedUrl}) {
  final document = _parseXml(source);
  final root = document.rootElement;
  final rootName = root.name.local.toLowerCase();

  switch (rootName) {
    case 'rss':
      break;
    case 'feed':
      throw const FeedParseException('Это Atom-фид. Поддерживается только RSS.');
    case 'rdf':
      throw const FeedParseException('Это RSS 1.0 (RDF). Поддерживается только RSS 2.0.');
    case 'html':
      throw const FeedParseException('По адресу находится веб-страница, а не RSS-фид.');
    default:
      throw FeedParseException('Неизвестный корневой элемент <${root.name.qualified}>.');
  }

  final channel = _child(root, _Ns.none, 'channel');
  if (channel == null) {
    throw const FeedParseException('В фиде нет элемента <channel>.');
  }
  return _ChannelParser(channel, feedUrl).parse();
}

XmlDocument _parseXml(String source) {
  final cleaned = _stripInvalidXmlChars(source);
  try {
    return XmlDocument.parse(cleaned, entityMapping: const XmlDefaultEntityMapping.html5());
  } on XmlException catch (e) {
    throw FeedParseException('Документ не является корректным XML.', cause: e);
  }
}

/// Убирает BOM и управляющие символы, запрещённые в XML 1.0.
/// Они регулярно попадают в описания эпизодов из копипасты.
String _stripInvalidXmlChars(String s) {
  var text = s;
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]'), '');
}

ParsedFeed _withWarnings(ParsedFeed f, List<String> extra) => ParsedFeed(
      title: f.title,
      episodes: f.episodes,
      description: f.description,
      link: f.link,
      imageUrl: f.imageUrl,
      author: f.author,
      ownerName: f.ownerName,
      ownerEmail: f.ownerEmail,
      language: f.language,
      categories: f.categories,
      explicit: f.explicit,
      type: f.type,
      newFeedUrl: f.newFeedUrl,
      podcastGuid: f.podcastGuid,
      locked: f.locked,
      funding: f.funding,
      warnings: [...extra, ...f.warnings],
    );

// ---------------------------------------------------------------------------
// Пространства имён
// ---------------------------------------------------------------------------

enum _Ns { none, itunes, podcast, content, media, atom, googleplay, dc, other }

/// Определяет пространство имён элемента. Сначала по URI (префикс может быть
/// любым), затем — если URI неизвестен или не объявлен — по префиксу.
_Ns _nsOf(XmlName name) {
  final uri = name.namespaceUri;
  if (uri != null) {
    final byUri = _nsByUri(uri);
    if (byUri != null) return byUri;
  }
  final prefix = name.prefix?.toLowerCase();
  if (prefix == null) return _Ns.none;
  return switch (prefix) {
    'itunes' => _Ns.itunes,
    'podcast' => _Ns.podcast,
    'content' => _Ns.content,
    'media' => _Ns.media,
    'atom' => _Ns.atom,
    'googleplay' => _Ns.googleplay,
    'dc' => _Ns.dc,
    _ => _Ns.other,
  };
}

_Ns? _nsByUri(String raw) {
  final uri = raw.trim().toLowerCase().replaceFirst(RegExp(r'^https?://'), '');
  if (uri.contains('itunes.com/dtds/podcast-1.0.dtd')) return _Ns.itunes;
  if (uri.startsWith('podcastindex.org/namespace') ||
      uri.contains('podcastindex-org/podcast-namespace')) {
    return _Ns.podcast;
  }
  if (uri.startsWith('purl.org/rss/1.0/modules/content')) return _Ns.content;
  if (uri.startsWith('search.yahoo.com/mrss')) return _Ns.media;
  if (uri.startsWith('www.w3.org/2005/atom')) return _Ns.atom;
  if (uri.contains('google.com/schemas/play-podcasts')) return _Ns.googleplay;
  if (uri.startsWith('purl.org/dc/elements/1.1')) return _Ns.dc;
  return null;
}

// ---------------------------------------------------------------------------
// Хелперы доступа к XML
// ---------------------------------------------------------------------------

bool _is(XmlElement e, _Ns ns, String local) =>
    e.name.local.toLowerCase() == local && _nsOf(e.name) == ns;

XmlElement? _child(XmlElement parent, _Ns ns, String local) {
  for (final e in parent.childElements) {
    if (_is(e, ns, local)) return e;
  }
  return null;
}

Iterable<XmlElement> _children(XmlElement parent, _Ns ns, String local) =>
    parent.childElements.where((e) => _is(e, ns, local));

/// Текст элемента (включая CDATA), обрезанный; пустой → `null`.
String? _text(XmlElement? e) {
  if (e == null) return null;
  final t = e.innerText.trim();
  return t.isEmpty ? null : t;
}

String? _childText(XmlElement parent, _Ns ns, String local) => _text(_child(parent, ns, local));

/// Значение атрибута без учёта регистра имени (встречается `URL=`).
String? _attr(XmlElement? e, String local) {
  if (e == null) return null;
  for (final a in e.attributes) {
    final prefix = a.name.prefix;
    if (prefix == 'xmlns' || a.name.qualified == 'xmlns') continue;
    if (a.name.local.toLowerCase() == local) {
      final v = a.value.trim();
      return v.isEmpty ? null : v;
    }
  }
  return null;
}

int? _int(String? s) {
  if (s == null) return null;
  final t = s.trim();
  return int.tryParse(t) ?? double.tryParse(t)?.toInt();
}

/// `yes`/`true`/`explicit` → true, `no`/`false`/`clean` → false.
bool? _bool(String? s) {
  switch (s?.trim().toLowerCase()) {
    case 'yes':
    case 'true':
    case 'explicit':
      return true;
    case 'no':
    case 'false':
    case 'clean':
      return false;
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Канал
// ---------------------------------------------------------------------------

class _ChannelParser {
  _ChannelParser(this.channel, String? feedUrl)
      : base = feedUrl == null ? null : Uri.tryParse(feedUrl.trim());

  final XmlElement channel;
  final Uri? base;
  final warnings = <String>[];

  ParsedFeed parse() {
    final title = _childText(channel, _Ns.none, 'title') ??
        _childText(channel, _Ns.itunes, 'title');
    if (title == null) warnings.add('У подкаста нет названия.');
    final owner = _child(channel, _Ns.itunes, 'owner');

    return ParsedFeed(
      title: title ?? '',
      description: _childText(channel, _Ns.none, 'description') ??
          _childText(channel, _Ns.itunes, 'summary') ??
          _childText(channel, _Ns.content, 'encoded'),
      link: _url(_childText(channel, _Ns.none, 'link')),
      imageUrl: _url(_attr(_child(channel, _Ns.itunes, 'image'), 'href')) ??
          _url(_attr(_child(channel, _Ns.googleplay, 'image'), 'href')) ??
          _url(_imageElementUrl()),
      author: _childText(channel, _Ns.itunes, 'author') ??
          _childText(channel, _Ns.googleplay, 'author') ??
          _childText(channel, _Ns.none, 'managingeditor') ??
          _childText(channel, _Ns.dc, 'creator'),
      ownerName: owner == null ? null : _childText(owner, _Ns.itunes, 'name'),
      ownerEmail: owner == null ? null : _childText(owner, _Ns.itunes, 'email'),
      language: _childText(channel, _Ns.none, 'language'),
      categories: _categories(),
      explicit: _bool(_childText(channel, _Ns.itunes, 'explicit')),
      type: _childText(channel, _Ns.itunes, 'type')?.toLowerCase() == 'serial'
          ? PodcastType.serial
          : PodcastType.episodic,
      newFeedUrl: _url(_childText(channel, _Ns.itunes, 'new-feed-url')),
      podcastGuid: _childText(channel, _Ns.podcast, 'guid'),
      locked: _bool(_childText(channel, _Ns.podcast, 'locked')) ?? false,
      funding: [
        for (final f in _children(channel, _Ns.podcast, 'funding'))
          if (_url(_attr(f, 'url')) case final url?) FundingLink(url: url, label: _text(f)),
      ],
      episodes: _episodes(),
      warnings: warnings,
    );
  }

  String? _imageElementUrl() {
    final image = _child(channel, _Ns.none, 'image');
    return image == null ? null : _childText(image, _Ns.none, 'url');
  }

  List<String> _categories() {
    final result = <String>[];
    void walk(XmlElement parent, String? path) {
      for (final c in _children(parent, _Ns.itunes, 'category')) {
        final name = _attr(c, 'text');
        if (name == null) continue;
        final full = path == null ? name : '$path › $name';
        if (!result.contains(full)) result.add(full);
        walk(c, full);
      }
    }

    walk(channel, null);
    if (result.isEmpty) {
      for (final c in _children(channel, _Ns.none, 'category')) {
        final t = _text(c);
        if (t != null && !result.contains(t)) result.add(t);
      }
    }
    return result;
  }

  List<ParsedEpisode> _episodes() {
    final episodes = <ParsedEpisode>[];
    final usedKeys = <String>{};
    final usedUrls = <String>{};
    var withoutMedia = 0;
    var duplicateGuids = 0;

    for (final item in _children(channel, _Ns.none, 'item')) {
      final parsed = _ItemParser(item, this).parse();
      if (parsed == null) {
        withoutMedia++;
        continue;
      }

      var episode = parsed;
      if (usedKeys.contains(episode.key)) {
        duplicateGuids++;
        // Тот же guid и тот же файл — повтор одного эпизода, пропускаем.
        if (usedUrls.contains(episode.enclosure.url)) continue;
        // Тот же guid, но другой файл — отдельный эпизод с ключом по URL.
        final alt = fallbackEpisodeKey(
          enclosureUrl: episode.enclosure.url,
          title: episode.title,
          pubDate: episode.pubDate,
        );
        if (usedKeys.contains(alt)) continue;
        episode = _rekey(episode, alt);
      }
      usedKeys.add(episode.key);
      usedUrls.add(episode.enclosure.url);
      episodes.add(episode);
    }

    if (withoutMedia > 0) {
      warnings.add('Пропущено эпизодов без аудио или видео: $withoutMedia.');
    }
    if (duplicateGuids > 0) {
      warnings.add('Эпизодов с повторяющимся guid: $duplicateGuids.');
    }
    return episodes;
  }

  /// Нормализует URL: обрезает, кодирует пробелы, разрешает относительные
  /// ссылки относительно адреса фида. Невалидный URL → `null`.
  String? _url(String? raw) {
    if (raw == null) return null;
    var trimmed = raw.trim().replaceAll(' ', '%20');
    if (trimmed.isEmpty) return null;
    var uri = Uri.tryParse(trimmed);
    if (uri == null) {
      // Недопустимые символы в URL (кириллица, `|`, `[` и т. п.).
      trimmed = Uri.encodeFull(trimmed);
      uri = Uri.tryParse(trimmed);
      if (uri == null) return null;
    }
    if (uri.hasScheme) {
      final scheme = uri.scheme.toLowerCase();
      return (scheme == 'http' || scheme == 'https') ? trimmed : null;
    }
    // Относительная ссылка или "//cdn.example.com/...".
    if (base == null || !base!.hasScheme) return null;
    return base!.resolveUri(uri).toString();
  }
}

ParsedEpisode _rekey(ParsedEpisode e, String key) => ParsedEpisode(
      key: key,
      guid: e.guid,
      title: e.title,
      enclosure: e.enclosure,
      description: e.description,
      summary: e.summary,
      link: e.link,
      pubDate: e.pubDate,
      duration: e.duration,
      imageUrl: e.imageUrl,
      season: e.season,
      episodeNumber: e.episodeNumber,
      type: e.type,
      explicit: e.explicit,
      chapters: e.chapters,
      transcripts: e.transcripts,
      persons: e.persons,
    );

// ---------------------------------------------------------------------------
// Эпизод
// ---------------------------------------------------------------------------

class _ItemParser {
  _ItemParser(this.item, this.channel);

  final XmlElement item;
  final _ChannelParser channel;

  /// `null`, если у эпизода нет воспроизводимого файла.
  ParsedEpisode? parse() {
    final enclosure = _enclosure();
    if (enclosure == null) return null;

    final title = _childText(item, _Ns.none, 'title') ??
        _childText(item, _Ns.itunes, 'title') ??
        '';
    final guid = _childText(item, _Ns.none, 'guid');
    final pubDate = parseFeedDate(_childText(item, _Ns.none, 'pubdate')) ??
        parseFeedDate(_childText(item, _Ns.dc, 'date'));

    return ParsedEpisode(
      key: episodeKey(
        guid: guid,
        enclosureUrl: enclosure.url,
        title: title,
        pubDate: pubDate,
      ),
      guid: guid,
      title: title,
      enclosure: enclosure,
      description: _childText(item, _Ns.content, 'encoded') ??
          _childText(item, _Ns.none, 'description') ??
          _childText(item, _Ns.itunes, 'summary'),
      summary: _childText(item, _Ns.itunes, 'subtitle') ?? _childText(item, _Ns.itunes, 'summary'),
      link: channel._url(_childText(item, _Ns.none, 'link')),
      pubDate: pubDate,
      duration: parseFeedDuration(_childText(item, _Ns.itunes, 'duration')) ??
          _mediaDuration(enclosure.url),
      imageUrl: channel._url(_attr(_child(item, _Ns.itunes, 'image'), 'href')) ??
          channel._url(_attr(_child(item, _Ns.media, 'thumbnail'), 'url')),
      season: _int(_childText(item, _Ns.itunes, 'season')) ??
          _int(_childText(item, _Ns.podcast, 'season')),
      episodeNumber: _int(_childText(item, _Ns.itunes, 'episode')) ??
          _int(_childText(item, _Ns.podcast, 'episode')),
      type: switch (_childText(item, _Ns.itunes, 'episodetype')?.toLowerCase()) {
        'trailer' => EpisodeType.trailer,
        'bonus' => EpisodeType.bonus,
        _ => EpisodeType.full,
      },
      explicit: _bool(_childText(item, _Ns.itunes, 'explicit')),
      chapters: _chapters(),
      transcripts: [
        for (final t in _children(item, _Ns.podcast, 'transcript'))
          if (channel._url(_attr(t, 'url')) case final url?)
            TranscriptRef(
              url: url,
              mimeType: _attr(t, 'type'),
              language: _attr(t, 'language'),
              rel: _attr(t, 'rel'),
            ),
      ],
      persons: [
        for (final p in _children(item, _Ns.podcast, 'person'))
          if (_text(p) case final name?)
            Person(
              name: name,
              role: _attr(p, 'role'),
              group: _attr(p, 'group'),
              href: channel._url(_attr(p, 'href')),
              img: channel._url(_attr(p, 'img')),
            ),
      ],
    );
  }

  ChaptersRef? _chapters() {
    final c = _child(item, _Ns.podcast, 'chapters');
    final url = channel._url(_attr(c, 'url'));
    return url == null ? null : ChaptersRef(url: url, mimeType: _attr(c, 'type'));
  }

  /// Длительность из `media:content@duration`: сначала у того же файла,
  /// что выбран как enclosure, затем у любого.
  Duration? _mediaDuration(String enclosureUrl) {
    final media = _mediaContents();
    final same = media.where((m) => channel._url(_attr(m, 'url')) == enclosureUrl);
    for (final m in [...same, ...media]) {
      final d = parseFeedDuration(_attr(m, 'duration'));
      if (d != null) return d;
    }
    return null;
  }

  /// `media:content`, в том числе внутри `media:group`.
  List<XmlElement> _mediaContents() => [
        ..._children(item, _Ns.media, 'content'),
        for (final g in _children(item, _Ns.media, 'group')) ..._children(g, _Ns.media, 'content'),
      ];

  Enclosure? _enclosure() {
    final candidates = <Enclosure>[
      for (final e in _children(item, _Ns.none, 'enclosure'))
        if (_build(_attr(e, 'url'), _attr(e, 'type'), _attr(e, 'length')) case final enc?) enc,
      for (final m in _mediaContents())
        if (_build(_attr(m, 'url'), _attr(m, 'type'), _attr(m, 'filesize')) case final enc?) enc,
    ];

    // Изображение в <enclosure> — не эпизод.
    final playable = candidates.where((c) => !(c.mimeType?.startsWith('image/') ?? false));
    return playable.where((c) => c.mimeType?.startsWith('audio/') ?? false).firstOrNull ??
        playable.where((c) => c.isVideo).firstOrNull ??
        playable.firstOrNull;
  }

  Enclosure? _build(String? rawUrl, String? rawType, String? rawLength) {
    final url = channel._url(rawUrl);
    if (url == null) return null;
    final type = _normalizeMime(rawType) ?? _mimeFromUrl(url);
    final length = _int(rawLength);
    return Enclosure(url: url, mimeType: type, length: (length ?? 0) > 0 ? length : null);
  }
}

String? _normalizeMime(String? raw) {
  final t = raw?.split(';').first.trim().toLowerCase();
  if (t == null || t.isEmpty || !t.contains('/')) return null;
  // Встречающиеся нестандартные варианты.
  return switch (t) {
    'audio/mp3' || 'audio/mpeg3' || 'audio/x-mp3' || 'audio/x-mpeg' => 'audio/mpeg',
    'audio/x-m4a' || 'audio/m4a' => 'audio/mp4',
    _ => t,
  };
}

String? _mimeFromUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (path.substring(dot + 1)) {
    'mp3' => 'audio/mpeg',
    'm4a' || 'm4b' => 'audio/mp4',
    'aac' => 'audio/aac',
    'ogg' || 'oga' => 'audio/ogg',
    'opus' => 'audio/opus',
    'flac' => 'audio/flac',
    'wav' => 'audio/wav',
    'mp4' || 'm4v' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    _ => null,
  };
}
