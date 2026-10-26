import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/feed/feed_fetcher.dart';
import 'package:podcast_app/net/proxy.dart';

const _feed = '<rss version="2.0"><channel><title>T</title></channel></rss>';

void main() {
  late AppDatabase db;
  final requests = <Uri>[];

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    NetProxy.instance.attach(db);
    await NetProxy.instance.ready();
    await NetProxy.instance.configure(url: 'https://proxy.example.dev/', key: 'k1');
  });

  tearDownAll(() => db.close());

  final client = MockClient((r) async {
    requests.add(r.url);
    if (r.url.host == 'blocked.example.com') throw const SocketException('Connection reset');
    if (r.url.host == 'proxy.example.dev') {
      expect(r.url.queryParameters['key'], 'k1');
      return http.Response.bytes(utf8.encode(_feed), 200);
    }
    return http.Response('', 404);
  });

  test('недоступная напрямую лента загружается через прокси, сайт запоминается', () async {
    final fetcher = FeedFetcher(client: client, proxy: NetProxy.instance);
    final result = await fetcher.fetch('https://blocked.example.com/feed.xml');
    expect(result, isA<FeedFetched>());
    final fetched = result as FeedFetched;
    expect(fetched.viaProxy, isTrue);
    expect(fetched.finalUrl, 'https://blocked.example.com/feed.xml');
    expect(NetProxy.instance.isBlocked(Uri.parse('https://blocked.example.com/x')), isTrue);

    requests.clear();
    await fetcher.fetch('https://blocked.example.com/feed.xml');
    expect(requests.map((u) => u.host), ['proxy.example.dev'], reason: 'второй раз — сразу через прокси');
  });

  test('ответ сервера 404 — без прокси', () async {
    final fetcher = FeedFetcher(client: client, proxy: NetProxy.instance);
    await expectLater(fetcher.fetch('https://open.example.com/feed.xml'), throwsA(isA<FeedFetchException>()));
    expect(NetProxy.instance.isBlocked(Uri.parse('https://open.example.com/')), isFalse);
  });

  test('адрес аудио переписывается только для запомненных сайтов', () {
    final proxied = Uri.parse(NetProxy.instance.rewrite('https://blocked.example.com/a.mp3'));
    expect(proxied.host, 'proxy.example.dev');
    expect(proxied.queryParameters['url'], 'https://blocked.example.com/a.mp3');
    expect(NetProxy.instance.rewrite('https://cdn.example.org/a.mp3'), 'https://cdn.example.org/a.mp3');
  });
}
