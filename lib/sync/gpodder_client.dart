/// Клиент протокола gPodder (API v2) — им говорят oPodSync, gpodder.net
/// и Nextcloud gPodder Sync.
///
/// Используется только нужная часть: проверка входа, регистрация устройства,
/// изменения подписок и действия с эпизодами. Авторизация — Basic в каждом
/// запросе (cookie сессии не храним).
///
/// Справка: https://gpoddernet.readthedocs.io/en/latest/api/reference/
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

class SyncException implements Exception {
  const SyncException(this.message, {this.unauthorized = false});

  final String message;

  /// Неверный логин или пароль.
  final bool unauthorized;

  @override
  String toString() => message;
}

/// Изменения подписок с момента [timestamp] прошлого запроса.
class SubscriptionChanges {
  const SubscriptionChanges({required this.add, required this.remove, required this.timestamp});

  final List<String> add;
  final List<String> remove;
  final int timestamp;
}

/// Действие с эпизодом (play, download, delete, new).
class EpisodeAction {
  const EpisodeAction({
    required this.podcast,
    required this.episode,
    required this.action,
    this.position,
    this.started,
    this.total,
    this.timestamp,
    this.device,
  });

  /// Адрес фида.
  final String podcast;

  /// Адрес аудиофайла эпизода.
  final String episode;
  final String action;

  /// Секунды (для play).
  final int? position;
  final int? started;
  final int? total;

  /// Время действия по серверу (при получении).
  final DateTime? timestamp;
  final String? device;

  Map<String, Object?> toJson() => {
        'podcast': podcast,
        'episode': episode,
        'action': action,
        'position': ?position,
        'started': ?started,
        'total': ?total,
        'device': ?device,
      };

  static EpisodeAction? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final podcast = json['podcast'];
    final episode = json['episode'];
    final action = json['action'];
    if (podcast is! String || episode is! String || action is! String) return null;
    int? asInt(Object? v) => v is int ? v : (v is num ? v.round() : (v is String ? int.tryParse(v) : null));
    final ts = json['timestamp'];
    return EpisodeAction(
      podcast: podcast,
      episode: episode,
      action: action.toLowerCase(),
      position: asInt(json['position']),
      started: asInt(json['started']),
      total: asInt(json['total']),
      timestamp: ts is String ? DateTime.tryParse(ts.endsWith('Z') || ts.contains('+') ? ts : '${ts}Z') : null,
      device: json['device'] is String ? json['device']! as String : null,
    );
  }
}

class GpodderClient {
  GpodderClient({
    required String server,
    required this.username,
    required String password,
    http.Client? client,
  })  : baseUrl = normalizeServer(server),
        _auth = 'Basic ${base64.encode(utf8.encode('$username:$password'))}',
        _client = client ?? http.Client();

  final String baseUrl;
  final String username;
  final String _auth;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  /// «sync.bcaster.ru/» → «https://sync.bcaster.ru».
  static String normalizeServer(String raw) {
    var s = raw.trim();
    if (!s.contains('://')) s = 'https://$s';
    return s.replaceFirst(RegExp(r'/+$'), '');
  }

  String get _user => Uri.encodeComponent(username);

  /// Проверка логина и пароля.
  Future<void> login() => _send('POST', '/api/2/auth/$_user/login.json');

  Future<void> registerDevice(String deviceId, {required String caption, required String type}) =>
      _send('POST', '/api/2/devices/$_user/$deviceId.json', body: {'caption': caption, 'type': type});

  Future<SubscriptionChanges> subscriptionChanges(String deviceId, int since) async {
    final data = await _send('GET', '/api/2/subscriptions/$_user/$deviceId.json', query: {'since': '$since'});
    if (data is! Map<String, Object?>) throw const SyncException('Сервер вернул неожиданный ответ на запрос подписок.');
    List<String> urls(Object? v) => v is List ? [for (final u in v) if (u is String) u] : const [];
    return SubscriptionChanges(
      add: urls(data['add']),
      remove: urls(data['remove']),
      timestamp: data['timestamp'] is int ? data['timestamp']! as int : since,
    );
  }

  /// Отправляет изменения подписок.
  Future<void> uploadSubscriptionChanges(String deviceId, {List<String> add = const [], List<String> remove = const []}) =>
      _send('POST', '/api/2/subscriptions/$_user/$deviceId.json', body: {'add': add, 'remove': remove});

  Future<({List<EpisodeAction> actions, int timestamp})> episodeActions(int since) async {
    final data = await _send('GET', '/api/2/episodes/$_user.json', query: {'since': '$since'});
    if (data is! Map<String, Object?>) throw const SyncException('Сервер вернул неожиданный ответ на запрос эпизодов.');
    final list = data['actions'];
    return (
      actions: [
        if (list is List)
          for (final a in list) ?EpisodeAction.fromJson(a),
      ],
      timestamp: data['timestamp'] is int ? data['timestamp']! as int : since,
    );
  }

  Future<void> uploadEpisodeActions(List<EpisodeAction> actions) async {
    // Пачками, чтобы не упереться в лимит размера запроса на хостинге.
    for (var i = 0; i < actions.length; i += 200) {
      final chunk = actions.sublist(i, i + 200 > actions.length ? actions.length : i + 200);
      await _send('POST', '/api/2/episodes/$_user.json', body: [for (final a in chunk) a.toJson()]);
    }
  }

  void close() => _client.close();

  Future<Object?> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final Uri uri;
    try {
      uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    } on FormatException {
      throw const SyncException('Некорректный адрес сервера.');
    }
    final request = http.Request(method, uri)
      ..headers['authorization'] = _auth
      ..headers['accept'] = 'application/json'
      ..headers['user-agent'] = 'BasicCaster/0.8 (+https://bcaster.ru)';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(_timeout));
    } on TimeoutException {
      throw const SyncException('Сервер синхронизации не ответил вовремя.');
    } on SocketException {
      throw const SyncException('Нет соединения с сервером синхронизации.');
    } on http.ClientException catch (e) {
      throw SyncException('Ошибка соединения: ${e.message}');
    }

    final type = response.headers['content-type'] ?? '';
    if (response.statusCode == 401) {
      throw const SyncException('Неверный логин или пароль.', unauthorized: true);
    }
    if (type.contains('text/html')) {
      throw SyncException(
        'Сервер вернул веб-страницу вместо данных (код ${response.statusCode}). '
        'Проверьте адрес сервера; если сайт за Cloudflare — отключите для него защиту от ботов.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SyncException('Сервер синхронизации вернул ошибку (код ${response.statusCode}).');
    }
    final text = utf8.decode(response.bodyBytes).trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      throw const SyncException('Сервер синхронизации вернул некорректный ответ.');
    }
  }
}
