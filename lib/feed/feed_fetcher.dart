/// Загрузка фидов по HTTP.
///
/// Редиректы обрабатываются вручную: нужно знать, был ли переезд постоянным
/// (301/308 — тогда подписку переводим на новый адрес) или временным.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

sealed class FetchResult {
  const FetchResult();
}

/// Сервер ответил 304: фид не изменился с прошлой загрузки.
class FeedNotModified extends FetchResult {
  const FeedNotModified();
}

class FeedFetched extends FetchResult {
  const FeedFetched({
    required this.bytes,
    required this.finalUrl,
    required this.movedPermanently,
    this.etag,
    this.lastModified,
    this.charset,
  });

  final Uint8List bytes;

  /// Адрес, с которого фид фактически получен после всех редиректов.
  final String finalUrl;

  /// Все редиректы по пути были постоянными: адрес фида сменился навсегда.
  final bool movedPermanently;
  final String? etag;
  final String? lastModified;

  /// charset из заголовка Content-Type.
  final String? charset;
}

class FeedFetchException implements Exception {
  const FeedFetchException(this.message, {this.statusCode});

  /// Текст для пользователя.
  final String message;
  final int? statusCode;

  @override
  String toString() => 'FeedFetchException: $message';
}

class FeedFetcher {
  FeedFetcher({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.maxBytes = 30 * 1024 * 1024,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;
  final int maxBytes;

  static const _maxRedirects = 6;
  static const userAgent = 'podcast_app/0.2 (+https://github.com/kirillkanter/podcast_app)';

  Future<FetchResult> fetch(String url, {String? etag, String? lastModified}) async {
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.hasScheme) {
      throw const FeedFetchException('Некорректная ссылка.');
    }
    var current = parsed;
    var permanent = true;

    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll({
          'user-agent': userAgent,
          'accept': 'application/rss+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.8',
          if (etag != null) 'if-none-match': etag,
          if (lastModified != null) 'if-modified-since': lastModified,
          if (current.userInfo.isNotEmpty)
            'authorization':
                'Basic ${base64.encode(utf8.encode(Uri.decodeComponent(current.userInfo)))}',
        });

      final response = await _guard(() => _client.send(request).timeout(timeout));
      final code = response.statusCode;

      if (const {301, 302, 303, 307, 308}.contains(code)) {
        _discard(response);
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw FeedFetchException('Сервер перенаправил запрос, но не указал куда (код $code).',
              statusCode: code);
        }
        if (code != 301 && code != 308) permanent = false;
        current = current.resolve(location.trim());
        continue;
      }

      if (code == 304) {
        _discard(response);
        return const FeedNotModified();
      }

      if (code >= 200 && code < 300) {
        final bytes = await _guard(() => _readLimited(response));
        return FeedFetched(
          bytes: bytes,
          finalUrl: current.toString(),
          movedPermanently: hop > 0 && permanent,
          etag: response.headers['etag'],
          lastModified: response.headers['last-modified'],
          charset: _charset(response.headers['content-type']),
        );
      }

      _discard(response);
      throw FeedFetchException(_statusMessage(code), statusCode: code);
    }

    throw const FeedFetchException('Слишком много перенаправлений.');
  }

  /// Адрес фида по id подкаста в Apple Podcasts.
  Future<String> resolveApplePodcast(String id) async {
    final uri = Uri.https('itunes.apple.com', '/lookup', {'id': id, 'entity': 'podcast'});
    final response = await _guard(
      () => _client.get(uri, headers: {'user-agent': userAgent}).timeout(timeout),
    );
    if (response.statusCode != 200) {
      throw FeedFetchException('Apple Podcasts не ответил (код ${response.statusCode}).',
          statusCode: response.statusCode);
    }
    final Object? data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const FeedFetchException('Apple Podcasts вернул некорректный ответ.');
    }
    final results = data is Map<String, Object?> ? data['results'] : null;
    if (results is! List || results.isEmpty) {
      throw const FeedFetchException('Подкаст с такой ссылкой не найден в Apple Podcasts.');
    }
    final first = results.first;
    final feedUrl = first is Map<String, Object?> ? first['feedUrl'] : null;
    if (feedUrl is! String || feedUrl.isEmpty) {
      throw const FeedFetchException(
          'У этого подкаста нет открытого RSS: он доступен только в Apple Podcasts.');
    }
    return feedUrl;
  }

  void close() => _client.close();

  Future<Uint8List> _readLimited(http.StreamedResponse response) async {
    final declared = response.contentLength;
    if (declared != null && declared > maxBytes) {
      _discard(response);
      throw const FeedFetchException('Файл фида слишком большой.');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw const FeedFetchException('Файл фида слишком большой.');
      }
    }
    return builder.takeBytes();
  }

  /// Переводит сетевые исключения в понятные сообщения.
  static Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FeedFetchException {
      rethrow;
    } on TimeoutException {
      throw const FeedFetchException('Сервер не ответил вовремя. Попробуйте позже.');
    } on HandshakeException {
      throw const FeedFetchException('Не удалось установить защищённое соединение с сайтом.');
    } on SocketException {
      throw const FeedFetchException('Нет соединения с сервером. Проверьте интернет и ссылку.');
    } on http.ClientException catch (e) {
      throw FeedFetchException('Ошибка соединения: ${e.message}');
    } on FormatException {
      throw const FeedFetchException('Некорректная ссылка.');
    }
  }

  static void _discard(http.StreamedResponse response) {
    response.stream.listen((_) {}, onError: (Object _) {}).cancel();
  }

  static String? _charset(String? contentType) {
    if (contentType == null) return null;
    final m = RegExp(r'''charset\s*=\s*["']?([^"';\s]+)''', caseSensitive: false)
        .firstMatch(contentType);
    return m?.group(1);
  }

  static String _statusMessage(int code) {
    if (code == 401 || code == 403) {
      return 'Доступ к фиду закрыт (код $code). Для платных фидов нужна персональная ссылка.';
    }
    if (code == 404) return 'Фид не найден (код 404). Проверьте ссылку.';
    if (code == 410) return 'Автор удалил фид (код 410).';
    if (code == 429) return 'Сервер временно ограничил запросы. Попробуйте позже.';
    if (code >= 500) return 'Ошибка на стороне сервера (код $code). Попробуйте позже.';
    return 'Сервер вернул ошибку (код $code).';
  }
}
