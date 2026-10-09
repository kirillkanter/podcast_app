import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/sync/gpodder_client.dart';

// Страница регистрации oPodSync: настоящие цифры — в <i>, ложные — в <b>.
const _form = '''
<form method="post" action=""><fieldset><dl>
<dd class="ca"><label for="captcha">Введите это число: <b>7</b><i>4</i><b>1</b><i>0</i><b>9</b><i>2</i><b>3</b><i>8</i><input type="hidden" name="cc" value="abc123" /></label></dd>
<dd><input type="text" name="captcha" required id="captcha" /></dd>
</dl></fieldset></form>''';

void main() {
  test('регистрация: число с проверки отправляется вместе с логином и паролем', () async {
    Map<String, String>? sent;
    final client = MockClient((r) async {
      if (r.method == 'GET') return http.Response(_form, 200, headers: {'content-type': 'text/html; charset=utf-8'});
      sent = Uri.splitQueryString(r.body);
      return http.Response('', 302, headers: {'location': './'});
    });
    await GpodderClient.register(server: 'sync.example.com/', username: ' kirill ', password: 'secret-123', client: client);
    expect(sent, {'login': 'kirill', 'password': 'secret-123', 'captcha': '4028', 'cc': 'abc123'});
  });

  test('регистрация: ошибка сервера показывается как есть', () async {
    final client = MockClient((r) async => r.method == 'GET'
        ? http.Response.bytes(_utf8(_form), 200)
        : http.Response.bytes(_utf8('<p class="error center">Такое имя пользователя уже есть.</p>$_form'), 200));
    await expectLater(
      GpodderClient.register(server: 'https://sync.example.com', username: 'kirill', password: 'secret-123', client: client),
      throwsA(isA<SyncException>().having((e) => e.message, 'message', 'Такое имя пользователя уже есть.')),
    );
  });

  test('регистрация закрыта или страницы нет — понятная ошибка', () async {
    final closed = MockClient((r) async => http.Response.bytes(_utf8('<p class="error center">Регистрация новых аккаунтов закрыта.</p>'), 200));
    await expectLater(
      GpodderClient.register(server: 'https://a.example.com', username: 'kirill', password: 'secret-123', client: closed),
      throwsA(isA<SyncException>().having((e) => e.message, 'message', contains('закрыта'))),
    );
    final missing = MockClient((r) async => http.Response('', 404));
    await expectLater(
      GpodderClient.register(server: 'https://b.example.com', username: 'kirill', password: 'secret-123', client: missing),
      throwsA(isA<SyncException>().having((e) => e.notFound, 'notFound', isTrue)),
    );
  });
}

List<int> _utf8(String s) => utf8.encode(s);
