import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Поддельный сервер gPodder с поведением oPodSync: метки времени —
/// «время сервера», выборка изменений — `changed >= since`.
class FakeGpodderServer {
  FakeGpodderServer({this.users = const {'kirill': 'secret123'}});

  final Map<String, String> users;

  /// Часы сервера в секундах; каждый запрос сдвигает их на 1.
  int now = 1000;

  /// url фида → (удалён?, когда изменён).
  final subscriptions = <String, ({bool deleted, int changed})>{};
  final actions = <Map<String, Object?>>[];
  final devices = <String>{};
  final requests = <http.BaseRequest>[];

  http.Client client() => MockClient(handle);

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    now++;
    final auth = request.headers['authorization'] ?? '';
    final decoded = auth.startsWith('Basic ') ? utf8.decode(base64.decode(auth.substring(6))) : '';
    final sep = decoded.indexOf(':');
    final user = sep < 0 ? '' : decoded.substring(0, sep);
    final pass = sep < 0 ? '' : decoded.substring(sep + 1);
    if (users[user] != pass) return _json({'code': 401, 'message': 'Invalid username/password'}, 401);

    final path = request.url.path;
    final since = int.tryParse(request.url.queryParameters['since'] ?? '') ?? 0;

    if (RegExp(r'^/api/2/auth/\w+/login\.json$').hasMatch(path) && request.method == 'POST') {
      return _json({'code': 200, 'message': 'Logged in!'});
    }
    final device = RegExp(r'^/api/2/devices/\w+/([\w.-]+)\.json$').firstMatch(path);
    if (device != null && request.method == 'POST') {
      devices.add(device.group(1)!);
      return _json({'code': 200, 'message': 'Device updated'});
    }
    if (RegExp(r'^/api/2/subscriptions/\w+/[\w.-]+\.json$').hasMatch(path)) {
      if (request.method == 'GET') {
        return _json({
          'add': [for (final e in subscriptions.entries) if (!e.value.deleted && e.value.changed >= since) e.key],
          'remove': [for (final e in subscriptions.entries) if (e.value.deleted && e.value.changed >= since) e.key],
          'update_urls': <Object>[],
          'timestamp': now,
        });
      }
      final body = jsonDecode(request.body) as Map<String, Object?>;
      for (final url in (body['add'] as List? ?? const [])) {
        subscriptions[url as String] = (deleted: false, changed: now);
      }
      for (final url in (body['remove'] as List? ?? const [])) {
        subscriptions[url as String] = (deleted: true, changed: now);
      }
      return _json({'timestamp': now, 'update_urls': <Object>[]});
    }
    if (RegExp(r'^/api/2/episodes/\w+\.json$').hasMatch(path)) {
      if (request.method == 'GET') {
        return _json({
          'timestamp': now,
          'actions': [
            for (final a in actions)
              if ((a['changed']! as int) >= since)
                {
                  for (final e in a.entries)
                    if (e.key != 'changed') e.key: e.value,
                  'timestamp': DateTime.fromMillisecondsSinceEpoch((a['changed']! as int) * 1000, isUtc: true)
                      .toIso8601String()
                      .replaceFirst(RegExp(r'\.\d+Z$'), 'Z'),
                },
          ],
        });
      }
      final list = jsonDecode(request.body) as List;
      for (final a in list) {
        final action = Map<String, Object?>.from(a as Map);
        if (!subscriptions.containsKey(action['podcast'])) {
          subscriptions[action['podcast']! as String] = (deleted: false, changed: now);
        }
        actions.add({...action, 'changed': now});
      }
      return _json({'timestamp': now, 'update_urls': <Object>[]});
    }
    return _json({'code': 404, 'message': 'Unknown'}, 404);
  }

  static http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );
}
