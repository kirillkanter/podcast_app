import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/download/download_manager.dart';
import 'package:podcast_app/feed/rss_parser.dart';
import 'package:podcast_app/platform/download_notification.dart';

/// Фид из [count] эпизодов: эпизод 1 самый новый.
String feed(int count) => '''
<rss version="2.0"><channel><title>Подкаст</title>
${List.generate(count, (i) => '''
<item><guid>${i + 1}</guid><title>Эпизод ${i + 1}</title>
  <pubDate>${10 - i} Oct 2026 10:00:00 GMT</pubDate>
  <enclosure url="https://cdn.example.com/${i + 1}.mp3" type="audio/mpeg"/></item>''').join()}
</channel></rss>''';

final audioBytes = List<int>.generate(1000, (i) => i % 256);

/// Ждёт выполнения условия (загрузки идут асинхронно).
Future<void> waitFor(Future<bool> Function() condition, {String? reason}) async {
  for (var i = 0; i < 500; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Не дождались: ${reason ?? 'условия'}');
}

void main() {
  late AppDatabase db;
  late Directory dir;
  late int podcastId;
  late Map<int, int> ids; // номер эпизода в фиде → id в БД
  late List<http.BaseRequest> requests;
  late Future<http.StreamedResponse> Function(http.BaseRequest) server;
  var unmetered = true;

  DownloadManager manager() => DownloadManager(
        db: db,
        directory: () async => dir,
        isUnmetered: () async => unmetered,
        clientFactory: () => MockClient.streaming((request, _) {
          requests.add(request);
          return server(request);
        }),
      );

  http.StreamedResponse ok(List<int> bytes, {int status = 200, String type = 'audio/mpeg'}) =>
      http.StreamedResponse(
        Stream.value(bytes),
        status,
        contentLength: bytes.length,
        headers: {'content-type': type},
      );

  Future<Download?> row(int n) => db.download(ids[n]!);

  Future<bool> hasStatus(int n, DownloadStatus status) async => (await row(n))?.status == status;

  String partPath(int n) => p.join(dir.path, 'episodes', '$podcastId', '${ids[n]}.mp3.part');

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('podcast_downloads_test');
    final saved = await db.saveParsedFeed('https://example.com/feed', parseFeed(feed(5)));
    podcastId = saved.podcastId;
    await db.setSubscribed(podcastId, true);
    ids = {
      for (final e in await db.watchEpisodes(podcastId).first) int.parse(e.guid!): e.id,
    };
    requests = [];
    unmetered = true;
    server = (_) async => ok(audioBytes);
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('ручная загрузка: файл, статус, путь для плеера', () async {
    final m = manager();
    await m.enqueue(ids[1]!);
    await waitFor(() => hasStatus(1, DownloadStatus.completed), reason: 'загрузки');

    final d = (await row(1))!;
    expect(await File(d.filePath!).readAsBytes(), audioBytes);
    expect(d.totalBytes, 1000);
    expect(d.auto, isFalse);
    expect(await m.localFile(ids[1]!), d.filePath);
    expect(File(partPath(1)).existsSync(), isFalse);
    expect(requests.single.headers['user-agent'], startsWith('BasicCaster/'));
  });

  test('веб-страница вместо аудио — ошибка', () async {
    server = (_) async => ok('<html>404</html>'.codeUnits, type: 'text/html; charset=utf-8');
    await manager().enqueue(ids[1]!);
    await waitFor(() => hasStatus(1, DownloadStatus.failed));
    expect((await row(1))!.error, contains('веб-страницу'));
  });

  test('ошибка сервера — понятное сообщение и повтор', () async {
    server = (_) async => http.StreamedResponse(const Stream.empty(), 404);
    final m = manager();
    await m.enqueue(ids[1]!);
    await waitFor(() => hasStatus(1, DownloadStatus.failed));
    expect((await row(1))!.error, contains('404'));

    server = (_) async => ok(audioBytes);
    await m.retry(ids[1]!);
    await waitFor(() => hasStatus(1, DownloadStatus.completed));
  });

  test('докачка: прерванная загрузка продолжается с нужного байта', () async {
    await Directory(p.dirname(partPath(1))).create(recursive: true);
    await File(partPath(1)).writeAsBytes(audioBytes.sublist(0, 400));
    await db.saveDownload(DownloadsCompanion(
      episodeId: Value(ids[1]!),
      status: const Value(DownloadStatus.running), // приложение закрыли во время загрузки
      receivedBytes: const Value(400),
    ));
    server = (request) async {
      expect(request.headers['range'], 'bytes=400-');
      return ok(audioBytes.sublist(400), status: 206);
    };

    await manager().start();
    await waitFor(() => hasStatus(1, DownloadStatus.completed));
    expect(await File((await row(1))!.filePath!).readAsBytes(), audioBytes);
  });

  test('сервер без докачки: файл скачивается заново, а не дописывается', () async {
    await Directory(p.dirname(partPath(1))).create(recursive: true);
    await File(partPath(1)).writeAsBytes(List.filled(400, 7));
    server = (_) async => ok(audioBytes); // Range проигнорирован, 200 и весь файл

    await manager().enqueue(ids[1]!);
    await waitFor(() => hasStatus(1, DownloadStatus.completed));
    expect(await File((await row(1))!.filePath!).readAsBytes(), audioBytes);
  });

  test('отмена во время загрузки: файлов нет, эпизод помечен удалённым', () async {
    final body = StreamController<List<int>>();
    server = (_) async => http.StreamedResponse(body.stream, 200,
        contentLength: 1000, headers: {'content-type': 'audio/mpeg'});
    final m = manager();
    await m.enqueue(ids[1]!);
    body.add(audioBytes.sublist(0, 100));
    await waitFor(() => hasStatus(1, DownloadStatus.running));

    await m.remove(ids[1]!);
    body.add(audioBytes.sublist(100, 200));
    await body.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect((await row(1))!.status, DownloadStatus.removed);
    expect(File(partPath(1)).existsSync(), isFalse);
  });

  group('автозагрузка', () {
    test('последние N эпизодов, кроме прослушанных и удалённых вручную', () async {
      await db.setSetting(DownloadSettings.autoCount, '3');
      await db.setPlayed(ids[2]!, true);
      await db.saveDownload(DownloadsCompanion(
        episodeId: Value(ids[3]!),
        status: const Value(DownloadStatus.removed),
      ));

      final m = manager();
      await m.autoDownloadAll();
      await waitFor(() => hasStatus(1, DownloadStatus.completed));

      expect((await row(1))!.auto, isTrue);
      expect(await row(2), isNull, reason: 'прослушан');
      expect((await row(3))!.status, DownloadStatus.removed, reason: 'удалён вручную');
      expect(await row(4), isNull, reason: 'не входит в 3 последних');
    });

    test('настройка подкаста важнее общей', () async {
      await db.setSetting(DownloadSettings.autoCount, '3');
      await db.setPodcastAutoDownloadCount(podcastId, 0);
      await manager().autoDownload(podcastId);
      expect(await row(1), isNull);
    });

    test('только по Wi-Fi: автозагрузка ждёт, ручная идёт сразу', () async {
      unmetered = false;
      await db.setSetting(DownloadSettings.autoCount, '1');
      final m = manager();
      await m.autoDownloadAll();
      await m.enqueue(ids[2]!);
      await waitFor(() => hasStatus(2, DownloadStatus.completed));
      expect((await row(1))!.status, DownloadStatus.queued);

      await db.setSetting(DownloadSettings.wifiOnly, 'false');
      m.resume();
      await waitFor(() => hasStatus(1, DownloadStatus.completed));
    });

    test('предел места останавливает автозагрузку', () async {
      await db.setSetting(DownloadSettings.limitMb, '1');
      await db.setSetting(DownloadSettings.autoCount, '1');
      await db.saveDownload(DownloadsCompanion(
        episodeId: Value(ids[5]!),
        status: const Value(DownloadStatus.completed),
        totalBytes: const Value(2 * 1024 * 1024),
      ));
      final m = manager();
      await m.autoDownloadAll();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await row(1))!.status, DownloadStatus.queued);
    });
  });

  group('прослушанные', () {
    test('файл удаляется после прослушивания', () async {
      final m = manager();
      await m.enqueue(ids[1]!);
      await waitFor(() => hasStatus(1, DownloadStatus.completed));
      final path = (await row(1))!.filePath!;

      await m.onPlayed(ids[1]!);
      expect(File(path).existsSync(), isFalse);
      expect((await row(1))!.status, DownloadStatus.removed);
    });

    test('если удаление прослушанных выключено — файл остаётся', () async {
      await db.setSetting(DownloadSettings.deletePlayed, 'false');
      final m = manager();
      await m.enqueue(ids[1]!);
      await waitFor(() => hasStatus(1, DownloadStatus.completed));
      await m.onPlayed(ids[1]!);
      expect((await row(1))!.status, DownloadStatus.completed);
    });

    test('«удалить прослушанные» на экране загрузок', () async {
      final m = manager();
      await m.enqueue(ids[1]!);
      await m.enqueue(ids[2]!);
      await waitFor(() async =>
          await hasStatus(1, DownloadStatus.completed) && await hasStatus(2, DownloadStatus.completed));
      await db.setPlayed(ids[1]!, true);

      expect(await m.removePlayed(), 1);
      expect((await row(1))!.status, DownloadStatus.removed);
      expect((await row(2))!.status, DownloadStatus.completed);
    });
  });

  test('файл удалён снаружи — плеер играет по сети, статус обновляется', () async {
    final m = manager();
    await m.enqueue(ids[1]!);
    await waitFor(() => hasStatus(1, DownloadStatus.completed));
    await File((await row(1))!.filePath!).delete();

    expect(await m.localFile(ids[1]!), isNull);
    expect((await row(1))!.status, DownloadStatus.removed);
  });

  test('настройки: чтение и запись', () async {
    expect(await db.setting('x'), isNull);
    await db.setSetting('x', '1');
    await db.setSetting('x', '2');
    expect(await db.setting('x'), '2');
  });

  test('фон: без зарядки только в очередь, потом задача докачивает всё', () async {
    final m = manager()..hold = true;
    await m.enqueue(ids[1]!);
    await m.enqueue(ids[2]!);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, isEmpty, reason: 'проверка фидов ничего не качает');
    expect(await m.hasPending(), isTrue);

    final worker = manager();
    await worker.runUntilIdle(max: const Duration(seconds: 20));
    expect(await hasStatus(1, DownloadStatus.completed), isTrue);
    expect(await hasStatus(2, DownloadStatus.completed), isTrue);
    expect(await worker.hasPending(), isFalse);
  });

  test('фон: открыли приложение — задача отдаёт загрузки обратно в очередь', () async {
    final gate = Completer<void>();
    server = (_) async => http.StreamedResponse(
          (() async* {
            yield audioBytes.sublist(0, 100);
            await gate.future;
            yield audioBytes.sublist(100);
          })(),
          200,
          contentLength: audioBytes.length,
          headers: {'content-type': 'audio/mpeg'},
        );
    final worker = manager();
    await worker.enqueue(ids[1]!);
    await waitFor(() => hasStatus(1, DownloadStatus.running), reason: 'загрузка началась');

    await worker.suspend();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await hasStatus(1, DownloadStatus.queued), isTrue, reason: 'не ошибка, а снова в очереди');
  });

  test('уведомление о загрузках: название, объём и очередь', () async {
    Future<void> put(int n, DownloadStatus status, {int received = 0, int? total}) => db.saveDownload(DownloadsCompanion(
          episodeId: Value(ids[n]!),
          status: Value(status),
          receivedBytes: Value(received),
          totalBytes: Value(total),
        ));
    expect(downloadNotice(await db.watchDownloadList().first), isNull);

    await put(1, DownloadStatus.running, received: 5 * 1024 * 1024, total: 20 * 1024 * 1024);
    await put(2, DownloadStatus.queued);
    final one = downloadNotice(await db.watchDownloadList().first)!;
    expect(one.title, 'Эпизод 1');
    expect(one.text, contains('ещё 1 в очереди'));
    expect(one.progress, 25);

    await put(2, DownloadStatus.running, received: 100);
    final two = downloadNotice(await db.watchDownloadList().first)!;
    expect(two.title, 'Загружается 2 эпизода');
    expect(two.progress, -1, reason: 'размер второго неизвестен');
  });
}
