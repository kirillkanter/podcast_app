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
import 'dart:io' show File, SocketException;

import 'package:http/http.dart' as http;

class SyncException implements Exception {
  const SyncException(this.message, {this.unauthorized = false, this.notFound = false, this.quota = false, this.status});

  final String message;

  /// Неверный логин или пароль.
  final bool unauthorized;

  /// Адреса нет на сервере (код 404).
  final bool notFound;

  /// На сервере не хватает места для книг.
  final bool quota;

  /// Код ответа сервера, если ответ был.
  final int? status;

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
    this.changed,
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

  /// Время действия по серверу (при получении): когда его отправили.
  final DateTime? timestamp;

  /// Когда изменение сделано на устройстве. Сервер хранит его в данных
  /// действия; по нему решаются конфликты — иначе устаревшая позиция,
  /// отправленная позже, перезаписала бы свежую.
  final DateTime? changed;
  final String? device;

  /// Время для сравнения действий: на устройстве, а если его нет
  /// (другие приложения) — на сервере.
  DateTime? get effectiveTime => changed ?? timestamp;

  Map<String, Object?> toJson() => {
        'podcast': podcast,
        'episode': episode,
        'action': action,
        'position': ?position,
        'started': ?started,
        'total': ?total,
        'device': ?device,
        if (changed != null) 'bcaster_changed': changed!.millisecondsSinceEpoch,
      };

  static EpisodeAction? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final podcast = json['podcast'];
    final episode = json['episode'];
    final action = json['action'];
    if (podcast is! String || episode is! String || action is! String) return null;
    int? asInt(Object? v) => v is int ? v : (v is num ? v.round() : (v is String ? int.tryParse(v) : null));
    final ts = json['timestamp'];
    final changedMs = asInt(json['bcaster_changed']);
    return EpisodeAction(
      podcast: podcast,
      episode: episode,
      action: action.toLowerCase(),
      position: asInt(json['position']),
      started: asInt(json['started']),
      total: asInt(json['total']),
      timestamp: ts is String ? DateTime.tryParse(ts.endsWith('Z') || ts.contains('+') ? ts : '${ts}Z') : null,
      changed: changedMs == null ? null : DateTime.fromMillisecondsSinceEpoch(changedMs, isUtc: true),
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

  /// Заголовок Authorization для своих запросов к серверу.
  String get authorizationHeader => _auth;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  /// «sync.bcaster.ru/» → «https://sync.bcaster.ru».
  static String normalizeServer(String raw) {
    var s = raw.trim();
    if (!s.contains('://')) s = 'https://$s';
    return s.replaceFirst(RegExp(r'/+$'), '');
  }

  String get _user => Uri.encodeComponent(username);

  /// Создать аккаунт на сервере oPodSync (страница register.php), не открывая
  /// браузер. Проверочное число на странице — защита от простейших роботов,
  /// оно лежит в самой странице; приложение читает его оттуда же.
  /// Ошибку сервера («имя занято», «пароль короткий») отдаёт как [SyncException].
  static Future<void> register({
    required String server,
    required String username,
    required String password,
    http.Client? client,
  }) async {
    final http.Client c = client ?? http.Client();
    final page = Uri.parse('${normalizeServer(server)}/register.php');
    const headers = {'user-agent': _userAgent};
    try {
      final form = await c.get(page, headers: headers).timeout(_timeout);
      if (form.statusCode == 404) {
        throw const SyncException('На этом сервере нельзя создать аккаунт из приложения. '
            'Зарегистрируйтесь на сайте сервера.', notFound: true);
      }
      final html = utf8.decode(form.bodyBytes, allowMalformed: true);
      final closed = _pageError(html);
      final check = RegExp(r'name="cc"\s+value="([0-9a-f]+)"').firstMatch(html)?.group(1);
      final label = RegExp(r'class="ca".*?</dd>', dotAll: true).firstMatch(html)?.group(0) ?? '';
      final digits = [for (final m in RegExp(r'<i>(\d)</i>').allMatches(label)) m.group(1)!].join();
      if (check == null || digits.isEmpty) {
        throw SyncException(closed ?? 'Не удалось открыть страницу регистрации на сервере (код ${form.statusCode}).',
            status: form.statusCode);
      }
      final response = await c
          .post(page, headers: headers, body: {
            'login': username.trim(),
            'password': password,
            'captcha': digits,
            'cc': check,
          })
          .timeout(_timeout);
      // Успех — переход на главную страницу сервера.
      if (response.statusCode == 302 || response.statusCode == 303) return;
      final error = _pageError(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (error != null) throw SyncException(error, status: response.statusCode);
      // http по умолчанию сам идёт по переходу: главная без ошибки — тоже успех.
      if (response.statusCode == 200) return;
      throw SyncException('Сервер не создал аккаунт (код ${response.statusCode}).', status: response.statusCode);
    } on TimeoutException {
      throw const SyncException('Сервер не ответил. Проверьте интернет и попробуйте ещё раз.');
    } on SocketException {
      throw const SyncException('Нет связи с сервером. Проверьте интернет и адрес сервера.');
    } on http.ClientException catch (e) {
      throw SyncException('Нет связи с сервером: ${e.message}');
    } finally {
      if (client == null) c.close();
    }
  }

  /// Текст ошибки со страницы сервера oPodSync, если он там есть.
  static String? _pageError(String html) {
    final m = RegExp(r'<p class="error[^"]*">(.*?)</p>', dotAll: true).firstMatch(html);
    if (m == null) return null;
    final text = m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    return text.isEmpty
        ? null
        : text
            .replaceAll('&quot;', '"')
            .replaceAll('&#039;', "'")
            .replaceAll('&laquo;', '«')
            .replaceAll('&raquo;', '»')
            .replaceAll('&amp;', '&');
  }

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

  /// Изменения очереди и архива после ревизии [since] (bcaster.php рядом
  /// с oPodSync). Если файла на сервере нет — [SyncException.notFound].
  Future<({List<Map<String, Object?>> items, int rev})> stateChanges(int since) async {
    final data = await _send('GET', '/bcaster.php', query: {'since': '$since'});
    if (data is! Map<String, Object?>) throw const SyncException('Сервер вернул неожиданный ответ на запрос очереди.');
    final list = data['items'];
    return (
      items: [
        if (list is List)
          for (final item in list)
            if (item is Map<String, Object?>) item,
      ],
      rev: data['rev'] is int ? data['rev']! as int : since,
    );
  }

  Future<void> uploadState(List<Map<String, Object?>> items) async {
    for (var i = 0; i < items.length; i += 500) {
      final chunk = items.sublist(i, i + 500 > items.length ? items.length : i + 500);
      await _send('POST', '/bcaster.php', body: {'items': chunk});
    }
  }

  // -------------------------------------------------------------------------
  // Книги (books.php рядом с oPodSync)
  // -------------------------------------------------------------------------

  /// Изменения книг и мест в книгах после ревизии [since].
  /// Нет books.php на сервере — [SyncException.notFound].
  Future<Map<String, Object?>> bookChanges(int since) async {
    final data = await _send('GET', '/books.php', query: {'since': '$since'});
    if (data is! Map<String, Object?>) throw const SyncException('Сервер вернул неожиданный ответ на запрос книг.');
    return data;
  }

  /// Место в одной книге на сервере (или `null`, если его там нет).
  Future<Map<String, Object?>?> bookProgress(String key, {Duration? timeout}) async {
    final data = await _send('GET', '/books.php', query: {'progress': key}, timeout: timeout);
    if (data is! Map<String, Object?>) throw const SyncException('Сервер вернул неожиданный ответ на запрос места в книге.');
    final p = data['progress'];
    return p is Map<String, Object?> ? p : null;
  }

  /// Отправить места в книгах. Возвращает записи, которые на сервере новее.
  Future<List<Map<String, Object?>>> uploadBookProgress(List<Map<String, Object?>> items, {Duration? timeout}) async {
    final newer = <Map<String, Object?>>[];
    for (var i = 0; i < items.length; i += 500) {
      final chunk = items.sublist(i, i + 500 > items.length ? items.length : i + 500);
      final data = await _send('POST', '/books.php', body: {'progress': chunk}, timeout: timeout);
      final list = data is Map<String, Object?> ? data['progress'] : null;
      if (list is List) newer.addAll(list.whereType<Map<String, Object?>>());
    }
    return newer;
  }

  /// Обмен выделениями: свои изменения уходят, приходит всё новее [since].
  Future<({int rev, List<Map<String, Object?>> items})> syncHighlights({
    required int since,
    required List<Map<String, Object?>> items,
  }) async {
    final data = await _send('POST', '/books.php',
        query: {'highlights': '1'}, body: {'since': since, 'items': items}, timeout: const Duration(seconds: 20));
    if (data is! Map<String, Object?>) throw const SyncException('Сервер вернул неожиданный ответ на запрос выделений.');
    final list = data['items'];
    return (
      rev: (data['rev'] as num?)?.toInt() ?? since,
      items: list is List ? list.whereType<Map<String, Object?>>().toList() : <Map<String, Object?>>[],
    );
  }

  /// Обмен статистикой чтения: свои дни уходят, приходят итоги других
  /// устройств по дням с [since] («2026-09-01»).
  Future<List<Map<String, Object?>>> syncReadingStats({
    required String device,
    required String since,
    required List<Map<String, Object?>> days,
  }) async {
    final data = await _send('POST', '/books.php',
        query: {'stats': '1'}, body: {'device': device, 'since': since, 'days': days}, timeout: const Duration(seconds: 15));
    final list = data is Map<String, Object?> ? data['others'] : null;
    return list is List ? list.whereType<Map<String, Object?>>().toList() : const [];
  }

  /// Загрузить файл книги. Сначала PUT (на него не действует лимит размера
  /// POST в PHP), если хостинг его не пропускает — POST.
  Future<void> uploadBookFile(
    String key,
    File file, {
    required String title,
    String? author,
    required String format,
  }) async {
    final query = {'upload': key, 'title': title, 'format': format, 'author': ?author};
    for (final method in ['PUT', 'POST']) {
      final uri = Uri.parse('$baseUrl/books.php').replace(queryParameters: query);
      final request = http.StreamedRequest(method, uri)
        ..headers['authorization'] = _auth
        ..headers['accept'] = 'application/json'
        ..headers['content-type'] = 'application/octet-stream'
        ..headers['user-agent'] = _userAgent
        ..contentLength = await file.length();
      final sending = _client.send(request);
      // Тело — потоком из файла; закрытие потока завершает запрос.
      final sink = request.sink;
      file.openRead().listen(sink.add, onError: sink.addError, onDone: sink.close);
      final http.Response response;
      try {
        response = await http.Response.fromStream(await sending.timeout(const Duration(minutes: 10)));
      } on TimeoutException {
        throw const SyncException('Сервер синхронизации не ответил вовремя.');
      } on SocketException {
        throw const SyncException('Нет соединения с сервером синхронизации.');
      } on http.ClientException catch (e) {
        throw SyncException('Ошибка соединения: ${e.message}');
      }
      // Метод запрещён хостингом — пробуем POST.
      if (method == 'PUT' && const {403, 405, 501}.contains(response.statusCode)) continue;
      _check(response);
      return;
    }
  }

  /// Скачать файл книги в [target].
  Future<void> downloadBookFile(String key, File target) async {
    final uri = Uri.parse('$baseUrl/books.php').replace(queryParameters: {'download': key});
    final request = http.Request('GET', uri)
      ..headers['authorization'] = _auth
      ..headers['user-agent'] = _userAgent;
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const SyncException('Сервер синхронизации не ответил вовремя.');
    } on SocketException {
      throw const SyncException('Нет соединения с сервером синхронизации.');
    } on http.ClientException catch (e) {
      throw SyncException('Ошибка соединения: ${e.message}');
    }
    if (response.statusCode != 200) {
      _check(await http.Response.fromStream(response));
      throw SyncException('Не удалось скачать книгу (код ${response.statusCode}).', status: response.statusCode);
    }
    final sink = target.openWrite();
    try {
      await sink.addStream(response.stream.timeout(const Duration(minutes: 2)));
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      throw SyncException('Загрузка книги прервалась: $e');
    }
  }

  /// Загрузить свою обложку книги [key]. Возвращает время изменения на сервере.
  Future<int> uploadCover(String key, List<int> bytes) async {
    final uri = Uri.parse('$baseUrl/books.php').replace(queryParameters: {'cover': key});
    final request = http.Request('POST', uri)
      ..headers['authorization'] = _auth
      ..headers['accept'] = 'application/json'
      ..headers['content-type'] = 'application/octet-stream'
      ..headers['user-agent'] = _userAgent
      ..bodyBytes = bytes;
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(const Duration(minutes: 1)));
    } on TimeoutException {
      throw const SyncException('Сервер синхронизации не ответил вовремя.');
    } on SocketException {
      throw const SyncException('Нет соединения с сервером синхронизации.');
    } on http.ClientException catch (e) {
      throw SyncException('Ошибка соединения: ${e.message}');
    }
    _check(response);
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return data is Map && data['changed'] is num ? (data['changed'] as num).toInt() : 0;
  }

  /// Свои обложки на сервере: ключ книги → время изменения.
  Future<Map<String, int>> covers() async {
    final data = await _send('GET', '/books.php', query: {'covers': '1'});
    final list = data is Map<String, Object?> ? data['covers'] : null;
    return {
      if (list is List)
        for (final c in list.whereType<Map<String, Object?>>())
          if (c['id'] is String && c['changed'] is num) c['id']! as String: (c['changed']! as num).toInt(),
    };
  }

  /// Скачать свою обложку книги [key].
  Future<List<int>> downloadCover(String key) async {
    final uri = Uri.parse('$baseUrl/books.php').replace(queryParameters: {'cover': key});
    final request = http.Request('GET', uri)
      ..headers['authorization'] = _auth
      ..headers['user-agent'] = _userAgent;
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
    if (response.statusCode != 200) {
      _check(response);
      throw SyncException('Не удалось скачать обложку (код ${response.statusCode}).', status: response.statusCode);
    }
    return response.bodyBytes;
  }

  /// Удалить книгу с сервера (и со всех устройств).
  Future<void> deleteBook(String key) async {
    try {
      await _send('DELETE', '/books.php', query: {'id': key});
    } on SyncException catch (e) {
      if (!const {403, 405, 501}.contains(e.status)) rethrow;
      await _send('POST', '/books.php', query: {'delete': key});
    }
  }

  void close() => _client.close();

  static const _userAgent = 'BasicCaster/0.9 (+https://bcaster.ru)';

  void _check(http.Response response) {
    final type = response.headers['content-type'] ?? '';
    final code = response.statusCode;
    if (code == 401) throw const SyncException('Неверный логин или пароль.', unauthorized: true, status: 401);
    if (code == 404) {
      throw const SyncException('Сервер синхронизации не нашёл адрес (код 404). Проверьте адрес сервера.',
          notFound: true, status: 404);
    }
    if (code == 507) {
      throw const SyncException('На сервере закончилось место для книг (2 ГБ). Удалите ненужные книги.',
          quota: true, status: 507);
    }
    if (code == 413) {
      throw const SyncException('Файл книги слишком большой для сервера (больше 200 МБ).', status: 413);
    }
    if (type.contains('text/html') && (code < 200 || code >= 300)) {
      throw SyncException('Сервер вернул веб-страницу вместо данных (код $code). Проверьте адрес сервера.', status: code);
    }
    if (code < 200 || code >= 300) {
      throw SyncException('Сервер синхронизации вернул ошибку (код $code).', status: code);
    }
  }

  Future<Object?> _send(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout}) async {
    final Uri uri;
    try {
      uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    } on FormatException {
      throw const SyncException('Некорректный адрес сервера.');
    }
    final request = http.Request(method, uri)
      ..headers['authorization'] = _auth
      ..headers['accept'] = 'application/json'
      ..headers['user-agent'] = _userAgent;
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(timeout ?? _timeout));
    } on TimeoutException {
      throw const SyncException('Сервер синхронизации не ответил вовремя.');
    } on SocketException {
      throw const SyncException('Нет соединения с сервером синхронизации.');
    } on http.ClientException catch (e) {
      throw SyncException('Ошибка соединения: ${e.message}');
    }

    final type = response.headers['content-type'] ?? '';
    if (response.statusCode == 401) {
      throw const SyncException('Неверный логин или пароль.', unauthorized: true, status: 401);
    }
    if (response.statusCode == 404) {
      throw const SyncException('Сервер синхронизации не нашёл адрес (код 404). Проверьте адрес сервера.',
          notFound: true, status: 404);
    }
    if (response.statusCode == 507 || response.statusCode == 413) _check(response);
    if (type.contains('text/html')) {
      throw SyncException(
        'Сервер вернул веб-страницу вместо данных (код ${response.statusCode}). '
        'Проверьте адрес сервера; если сайт за Cloudflare — отключите для него защиту от ботов.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SyncException('Сервер синхронизации вернул ошибку (код ${response.statusCode}).', status: response.statusCode);
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
