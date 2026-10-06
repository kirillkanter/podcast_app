/// Загрузка эпизодов на устройство.
///
/// Очередь хранится в БД (таблица downloads), поэтому переживает перезапуск:
/// прерванные загрузки продолжаются с того же байта (HTTP Range).
/// Качает сам Dart-код через HTTP, одинаково на Android и Windows.
/// На Android загрузка идёт, пока жив процесс приложения (в том числе
/// в фоне во время воспроизведения); после закрытия продолжится при следующем
/// запуске.
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/db/database.dart';

/// Ключи настроек загрузок.
abstract final class DownloadSettings {
  /// Автозагрузка только по Wi-Fi (или проводной сети). По умолчанию — да.
  static const wifiOnly = 'downloads.wifiOnly';

  /// Сколько последних эпизодов держать загруженными для подкастов
  /// без своей настройки. По умолчанию 0 — автозагрузка выключена.
  static const autoCount = 'downloads.autoCount';

  /// Удалять файл, когда эпизод прослушан. По умолчанию — да.
  static const deletePlayed = 'downloads.deletePlayed';

  /// Предел места для автозагрузки в мегабайтах; 0 — без предела.
  static const limitMb = 'downloads.limitMb';
}

class DownloadManager {
  DownloadManager({
    required AppDatabase db,
    required Future<Directory> Function() directory,
    required Future<bool> Function() isUnmetered,
    http.Client Function()? clientFactory,
    this.parallel = 2,
  })  : _db = db,
        _directory = directory,
        _isUnmetered = isUnmetered,
        _clientFactory = clientFactory ?? http.Client.new;

  final AppDatabase _db;
  final Future<Directory> Function() _directory;
  final Future<bool> Function() _isUnmetered;
  final http.Client Function() _clientFactory;
  final int parallel;

  /// Активные загрузки: id эпизода → клиент (закрытие отменяет загрузку).
  final _active = <int, http.Client>{};
  final _cancelled = <int>{};
  bool _pumping = false;
  bool _pumpAgain = false;

  static const _progressInterval = Duration(milliseconds: 700);

  /// Возвращает в очередь загрузки, прерванные закрытием приложения,
  /// и запускает очередь.
  Future<void> start() async {
    for (final d in await _db.downloadsWithStatus([DownloadStatus.running])) {
      await _db.updateDownload(d.episodeId, const DownloadsCompanion(status: Value(DownloadStatus.queued)));
    }
    unawaited(_pump());
  }

  /// Поставить эпизод в очередь. Ручная загрузка не ждёт Wi-Fi.
  Future<void> enqueue(int episodeId, {bool auto = false}) async {
    final existing = await _db.download(episodeId);
    if (existing != null &&
        (existing.status == DownloadStatus.completed ||
            existing.status == DownloadStatus.running ||
            existing.status == DownloadStatus.queued)) {
      return;
    }
    await _db.saveDownload(DownloadsCompanion(
      episodeId: Value(episodeId),
      status: const Value(DownloadStatus.queued),
      auto: Value(auto),
      error: const Value(null),
      receivedBytes: const Value(0),
    ));
    unawaited(_pump());
  }

  /// Отменить загрузку или удалить загруженный файл. Эпизод помечается
  /// удалённым, чтобы автозагрузка не скачала его снова.
  Future<void> remove(int episodeId) async {
    _cancelled.add(episodeId);
    _active.remove(episodeId)?.close();
    final row = await _db.download(episodeId);
    await _deleteFiles(episodeId, row?.filePath);
    if (row != null) {
      await _db.updateDownload(
        episodeId,
        const DownloadsCompanion(
          status: Value(DownloadStatus.removed),
          filePath: Value(null),
          receivedBytes: Value(0),
          error: Value(null),
        ),
      );
    }
  }

  /// Эпизод прослушан: удалить файл, если так настроено.
  Future<void> onPlayed(int episodeId) async {
    if (!await _boolSetting(DownloadSettings.deletePlayed, true)) return;
    final row = await _db.download(episodeId);
    if (row?.status == DownloadStatus.completed) await remove(episodeId);
  }

  /// Путь к загруженному файлу, если он на месте.
  Future<String?> localFile(int episodeId) async {
    final row = await _db.download(episodeId);
    final path = row?.filePath;
    if (row?.status != DownloadStatus.completed || path == null) return null;
    if (await File(path).exists()) return path;
    // Файл удалили снаружи (очистка памяти и т. п.).
    await _db.updateDownload(
      episodeId,
      const DownloadsCompanion(status: Value(DownloadStatus.removed), filePath: Value(null)),
    );
    return null;
  }

  /// Поставить в очередь свежие эпизоды подкаста по правилу автозагрузки.
  Future<void> autoDownload(int podcastId) async {
    final count = await _db.podcastAutoDownloadCount(podcastId) ??
        await _intSetting(DownloadSettings.autoCount, 0);
    if (count <= 0) return;
    for (final item in await _db.latestEpisodes(podcastId, count)) {
      if (item.state?.played ?? false) continue;
      if (item.download != null) continue; // уже качали, качаем или удалено вручную
      await enqueue(item.episode.id, auto: true);
    }
  }

  /// Автозагрузка для всех подписок.
  Future<void> autoDownloadAll() async {
    for (final podcast in await _db.subscribedPodcasts()) {
      await autoDownload(podcast.id);
    }
  }

  /// Удалить все загруженные файлы прослушанных эпизодов.
  Future<int> removePlayed() async {
    var removed = 0;
    for (final d in await _db.downloadsWithStatus([DownloadStatus.completed])) {
      final state = await _db.episodeState(d.episodeId);
      if (state?.played ?? false) {
        await remove(d.episodeId);
        removed++;
      }
    }
    return removed;
  }

  /// Повторить неудачную загрузку.
  Future<void> retry(int episodeId) async {
    await _db.updateDownload(
      episodeId,
      const DownloadsCompanion(status: Value(DownloadStatus.queued), error: Value(null)),
    );
    unawaited(_pump());
  }

  /// Перепроверить очередь (например, после смены настроек или сети).
  void resume() => unawaited(_pump());

  void dispose() {
    for (final client in _active.values) {
      client.close();
    }
    _active.clear();
  }

  // -------------------------------------------------------------------------

  /// Запускает загрузки из очереди, пока есть свободные слоты.
  Future<void> _pump() async {
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        final queued = await _db.downloadsWithStatus([DownloadStatus.queued]);
        if (queued.isEmpty) break;
        final unmetered = queued.any((d) => d.auto) ? await _safeUnmetered() : true;
        final wifiOnly = await _boolSetting(DownloadSettings.wifiOnly, true);
        final limitBytes = await _intSetting(DownloadSettings.limitMb, 0) * 1024 * 1024;
        var used = limitBytes > 0 ? await _db.downloadedBytes() : 0;

        for (final d in queued) {
          if (_active.length >= parallel) break;
          if (_active.containsKey(d.episodeId)) continue;
          if (d.auto && wifiOnly && !unmetered) continue;
          if (d.auto && limitBytes > 0 && used >= limitBytes) continue;
          _cancelled.remove(d.episodeId);
          final client = _clientFactory();
          _active[d.episodeId] = client;
          unawaited(_download(d.episodeId, client).whenComplete(() {
            _active.remove(d.episodeId);
            _pump();
          }));
          used += d.totalBytes ?? 0;
        }
      } while (_pumpAgain);
    } finally {
      _pumping = false;
    }
  }

  Future<void> _download(int episodeId, http.Client client) async {
    final episode = await _db.episodeById(episodeId);
    if (episode == null) {
      await _db.deleteDownloadRow(episodeId);
      return;
    }
    if (_cancelled.contains(episodeId)) return;
    await _db.updateDownload(episodeId, const DownloadsCompanion(status: Value(DownloadStatus.running)));

    final dir = Directory(p.join((await _directory()).path, 'episodes', '${episode.podcastId}'));
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, '$episodeId${_extension(episode.enclosureUrl, episode.enclosureType)}'));
    final part = File('${target.path}.part');

    try {
      var offset = await part.exists() ? await part.length() : 0;
      final request = http.Request('GET', Uri.parse(episode.enclosureUrl))
        ..headers['user-agent'] = 'BasicCaster/0.7 (+https://bcaster.ru)';
      if (offset > 0) request.headers['range'] = 'bytes=$offset-';

      final response = await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode == 416 && offset > 0) {
        // Сервер считает, что докачивать нечего: файл уже целиком в .part.
        await response.stream.drain<void>();
        await part.rename(target.path);
        await _complete(episodeId, target, offset);
        return;
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.drain<void>();
        throw _DownloadError('Сервер вернул ошибку (код ${response.statusCode}).');
      }
      final type = response.headers['content-type'] ?? '';
      if (type.startsWith('text/html')) {
        await response.stream.drain<void>();
        throw const _DownloadError('Вместо аудиофайла сервер вернул веб-страницу.');
      }

      // 200 на запрос с Range — сервер не умеет докачку, начинаем заново.
      final append = response.statusCode == 206 && offset > 0;
      if (!append) offset = 0;
      final total = response.contentLength == null ? null : response.contentLength! + offset;

      final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      var received = offset;
      var lastReport = DateTime.now();
      try {
        await _db.updateDownload(
          episodeId,
          DownloadsCompanion(totalBytes: Value(total), receivedBytes: Value(received)),
        );
        await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
          // Отмена: закрытие клиента прерывает соединение, а эта проверка
          // срабатывает, даже если клиент закрытие не поддерживает.
          if (_cancelled.contains(episodeId)) throw const _DownloadError('Отменено');
          sink.add(chunk);
          received += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastReport) >= _progressInterval) {
            lastReport = now;
            await _db.updateDownload(episodeId, DownloadsCompanion(receivedBytes: Value(received)));
          }
        }
      } finally {
        await sink.close();
      }

      if (total != null && received < total) {
        throw const _DownloadError('Загрузка оборвалась. Она продолжится при следующей попытке.');
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      await _complete(episodeId, target, received);
    } catch (e) {
      if (_cancelled.remove(episodeId)) return; // отменено пользователем — remove() уже всё убрал
      final message = switch (e) {
        _DownloadError(:final message) => message,
        TimeoutException() => 'Сервер перестал отвечать. Загрузка продолжится при следующей попытке.',
        SocketException() => 'Нет соединения с сервером.',
        FileSystemException() => 'Не удалось записать файл. Возможно, мало свободного места.',
        _ => 'Не удалось загрузить: $e',
      };
      await _db.updateDownload(
        episodeId,
        DownloadsCompanion(status: const Value(DownloadStatus.failed), error: Value(message)),
      );
    }
  }

  Future<void> _complete(int episodeId, File file, int bytes) => _db.updateDownload(
        episodeId,
        DownloadsCompanion(
          status: const Value(DownloadStatus.completed),
          filePath: Value(file.path),
          totalBytes: Value(bytes),
          receivedBytes: Value(bytes),
          error: const Value(null),
        ),
      );

  Future<void> _deleteFiles(int episodeId, String? path) async {
    final files = <File>[if (path != null) File(path)];
    final episode = await _db.episodeById(episodeId);
    if (episode != null) {
      final base = p.join(
        (await _directory()).path,
        'episodes',
        '${episode.podcastId}',
        '$episodeId${_extension(episode.enclosureUrl, episode.enclosureType)}',
      );
      files
        ..add(File(base))
        ..add(File('$base.part'));
    }
    for (final f in files) {
      try {
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // Файл занят (например, играет на Windows) — удалится в следующий раз.
      }
    }
  }

  Future<bool> _safeUnmetered() async {
    try {
      return await _isUnmetered();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _boolSetting(String key, bool fallback) async {
    final v = await _db.setting(key);
    return v == null ? fallback : v == 'true';
  }

  Future<int> _intSetting(String key, int fallback) async =>
      int.tryParse(await _db.setting(key) ?? '') ?? fallback;

  static String _extension(String url, String? mime) {
    final path = Uri.tryParse(url)?.path ?? '';
    final ext = p.extension(path).toLowerCase();
    if (RegExp(r'^\.[a-z0-9]{2,4}$').hasMatch(ext)) return ext;
    return switch (mime) {
      'audio/mpeg' => '.mp3',
      'audio/mp4' || 'audio/x-m4a' => '.m4a',
      'audio/aac' => '.aac',
      'audio/ogg' || 'audio/opus' => '.ogg',
      'video/mp4' => '.mp4',
      _ => '.mp3',
    };
  }
}

class _DownloadError implements Exception {
  const _DownloadError(this.message);
  final String message;
}
