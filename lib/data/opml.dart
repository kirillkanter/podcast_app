// OPML — общий формат списка подписок: его понимают почти все подкаст-плееры.
import 'package:xml/xml.dart';

import 'db/database.dart';
import 'podcast_repository.dart';

/// Подкаст из OPML-файла.
typedef OpmlEntry = ({String title, String url});

/// Достаёт фиды из OPML. Вложенные группы раскрываются, повторы убираются.
/// Бросает [FormatException], если это не OPML.
List<OpmlEntry> parseOpml(String text) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text.startsWith('﻿') ? text.substring(1) : text);
  } on XmlException {
    throw const FormatException('Файл повреждён или это не OPML.');
  }
  final root = doc.rootElement;
  if (root.name.local.toLowerCase() != 'opml') {
    throw const FormatException('Это не OPML-файл.');
  }
  String? attr(XmlElement e, String name) {
    for (final a in e.attributes) {
      if (a.name.local.toLowerCase() == name.toLowerCase()) {
        final v = a.value.trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
  }

  final seen = <String>{};
  final result = <OpmlEntry>[];
  for (final o in root.descendantElements) {
    if (o.name.local.toLowerCase() != 'outline') continue;
    final url = attr(o, 'xmlUrl');
    if (url == null) continue;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https') || uri.isScheme('feed'))) continue;
    final normalized = uri.isScheme('feed') ? url.replaceFirst(RegExp('^feed:(//)?', caseSensitive: false), 'https://') : url;
    if (!seen.add(normalized)) continue;
    result.add((title: attr(o, 'title') ?? attr(o, 'text') ?? normalized, url: normalized));
  }
  return result;
}

/// OPML со списком подписок.
String buildOpml(List<Podcast> podcasts, {DateTime? now}) {
  final b = XmlBuilder()..processing('xml', 'version="1.0" encoding="UTF-8"');
  b.element('opml', attributes: {'version': '2.0'}, nest: () {
    b.element('head', nest: () {
      b.element('title', nest: 'Подписки Basic Caster');
      b.element('dateCreated', nest: _rfc822((now ?? DateTime.now()).toUtc()));
    });
    b.element('body', nest: () {
      for (final p in podcasts) {
        b.element('outline', attributes: {
          'type': 'rss',
          'text': p.title,
          'title': p.title,
          'xmlUrl': p.feedUrl,
          if (p.link != null && p.link!.isNotEmpty) 'htmlUrl': p.link!,
        });
      }
    });
  });
  return b.buildDocument().toXmlString(pretty: true, indent: '  ');
}

String _rfc822(DateTime t) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${days[t.weekday - 1]}, ${two(t.day)} ${months[t.month - 1]} ${t.year} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)} GMT';
}

/// Итог импорта.
class OpmlImportResult {
  OpmlImportResult();

  int added = 0;
  int already = 0;
  final failed = <(OpmlEntry, String)>[];
}

/// Подписывается на подкасты из OPML, не больше [parallel] одновременно.
/// [onProgress] получает число обработанных подкастов.
Future<OpmlImportResult> importOpml(
  AppDatabase db,
  PodcastRepository repository,
  List<OpmlEntry> entries, {
  int parallel = 4,
  void Function(int done)? onProgress,
  bool Function()? cancelled,
}) async {
  final result = OpmlImportResult();
  final subscribed = {for (final p in await db.subscribedPodcasts()) p.feedUrl};
  final queue = [...entries.reversed];
  var done = 0;

  Future<void> worker() async {
    while (queue.isNotEmpty && !(cancelled?.call() ?? false)) {
      final e = queue.removeLast();
      if (subscribed.contains(e.url)) {
        result.already++;
      } else {
        try {
          await repository.addAndSubscribe(e.url);
          result.added++;
        } on PodcastException catch (err) {
          result.failed.add((e, err.message));
        } catch (err) {
          result.failed.add((e, '$err'));
        }
      }
      onProgress?.call(++done);
    }
  }

  await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
  return result;
}
