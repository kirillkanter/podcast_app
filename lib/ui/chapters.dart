import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/db/database.dart';
import '../feed/feed_fetcher.dart';
import 'description.dart';

/// Главы эпизода: из файла глав Podcasting 2.0, а если его нет —
/// из строк описания «12:40 — Тема». Результат запоминается.
class ChaptersLoader {
  ChaptersLoader({http.Client Function()? client}) : _client = client;

  final http.Client Function()? _client;
  final _cache = <int, Future<List<Chapter>>>{};

  static final instance = ChaptersLoader();

  Future<List<Chapter>> load(Episode episode) =>
      _cache.putIfAbsent(episode.id, () => _load(episode));

  Future<List<Chapter>> _load(Episode e) async {
    final url = e.chaptersUrl;
    if (url != null && (e.chaptersType == null || e.chaptersType!.contains('json'))) {
      final client = _client?.call() ?? http.Client();
      try {
        final response = await client
            .get(Uri.parse(url), headers: {'user-agent': FeedFetcher.userAgent})
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final chapters = parseChaptersJson(utf8.decode(response.bodyBytes, allowMalformed: true));
          if (chapters.isNotEmpty) return chapters;
        }
      } catch (_) {
        // Нет сети или файл недоступен — берём главы из описания.
      } finally {
        client.close();
      }
    }
    return chaptersFromText(plainText(parseDescription(e.description ?? e.summary)));
  }
}
