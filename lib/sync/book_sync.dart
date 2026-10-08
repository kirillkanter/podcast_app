/// Синхронизация книг через books.php: место в книге (аудио и текст)
/// и сами текстовые книги (файлы целиком, до 2 ГБ на аккаунт).
///
/// Место в книге — самое ценное, поэтому:
/// - перед запуском книги интерфейс спрашивает место на сервере
///   ([fetchRemote]) и, если на другом устройстве ушли дальше, предлагает
///   продолжить оттуда; если сервер не ответил — говорит об этом;
/// - изменения уходят на сервер вскоре после паузы и периодически во время
///   слушания ([pushSoon]);
/// - конфликт решается по времени изменения: более позднее побеждает.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../books/book_models.dart';
import '../data/db/books_dao.dart';
import '../data/db/database.dart';
import 'gpodder_client.dart';
import 'sync_service.dart';

/// Место в книге на сервере.
class RemoteBookProgress {
  const RemoteBookProgress({
    required this.locator,
    required this.positionMs,
    required this.percent,
    required this.changed,
    required this.deviceId,
    required this.deviceName,
  });

  final String locator;
  final int positionMs;
  final double percent;
  final DateTime changed;
  final String? deviceId;
  final String? deviceName;

  static RemoteBookProgress? fromJson(Map<String, Object?> j) {
    final locator = j['locator'];
    final changed = j['changed'];
    if (locator is! String || changed is! num) return null;
    final device = j['device'] is String ? j['device']! as String : '';
    final sep = device.indexOf('|');
    return RemoteBookProgress(
      locator: locator,
      positionMs: (j['position'] as num?)?.toInt() ?? 0,
      percent: (j['percent'] as num?)?.toDouble() ?? 0,
      changed: DateTime.fromMillisecondsSinceEpoch(changed.toInt()),
      deviceId: sep < 0 ? (device.isEmpty ? null : device) : device.substring(0, sep),
      deviceName: sep < 0 ? null : device.substring(sep + 1),
    );
  }
}

/// Не удалось узнать место на сервере.
class BookSyncException implements Exception {
  const BookSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BookSync {
  BookSync({
    required AppDatabase db,
    required SyncService sync,
    required Future<Directory> Function() booksDirectory,
    this.onFilesChanged,
  })  : _db = db,
        _sync = sync,
        _booksDirectory = booksDirectory;

  final AppDatabase _db;
  final SyncService _sync;
  final Future<Directory> Function() _booksDirectory;

  /// Скачана новая книга или удалена — разобрать обложку и т. п.
  final Future<void> Function(int bookId)? onFilesChanged;

  Timer? _pushTimer;
  Future<void>? _pushing;

  Future<bool> get isConfigured => _sync.isConfigured;

  /// Место в книге [key] на сервере. `null` — синхронизация выключена или
  /// на сервере этой книги нет. Сбой связи — [BookSyncException].
  Future<RemoteBookProgress?> fetchRemote(String key, {Duration timeout = const Duration(seconds: 8)}) async {
    final client = await _sync.openClient();
    if (client == null) return null;
    try {
      final j = await client.bookProgress(key, timeout: timeout);
      return j == null ? null : RemoteBookProgress.fromJson(j);
    } on SyncException catch (e) {
      if (e.notFound) {
        // На сервере нет books.php — сверять не с чем.
        await _db.setSetting(BookSettings.unsupported, 'true');
        return null;
      }
      throw BookSyncException(e.message);
    } on TimeoutException {
      throw const BookSyncException('Сервер синхронизации не ответил вовремя.');
    } catch (e) {
      throw BookSyncException('Ошибка связи с сервером: $e');
    } finally {
      client.close();
    }
  }

  /// Это устройство (чтобы не предлагать «продолжить» с самого себя).
  Future<String> deviceId() => _sync.deviceId();

  DateTime? _pushAt;

  /// Отправить изменения места не позже чем через [delay]. Уже назначенная
  /// более ранняя отправка остаётся: во время слушания место сохраняется
  /// часто, а на сервер уходит раз в [delay].
  void pushSoon([Duration delay = const Duration(seconds: 5)]) {
    final at = DateTime.now().add(delay);
    final planned = _pushAt;
    if (_pushTimer?.isActive == true && planned != null && !planned.isAfter(at)) return;
    _pushTimer?.cancel();
    _pushAt = at;
    _pushTimer = Timer(delay, () {
      _pushAt = null;
      unawaited(pushNow().catchError((Object _) {}));
    });
  }

  /// Отправить изменения места сейчас.
  Future<void> pushNow() {
    return _pushing ??= _push().whenComplete(() => _pushing = null);
  }

  Future<void> _push() async {
    final client = await _sync.openClient();
    if (client == null) return;
    try {
      await _uploadProgress(client, await _deviceTag());
    } finally {
      client.close();
    }
  }

  Future<String> _deviceTag() async => '${await _sync.deviceId()}|${_sync.deviceName}';

  Future<void> _uploadProgress(GpodderClient client, String device) async {
    final dirty = await _db.dirtyBookProgress();
    if (dirty.isEmpty) return;
    final newer = await client.uploadBookProgress([
      for (final d in dirty)
        {
          'id': d.key,
          'locator': d.locator,
          'position': d.positionMs,
          'percent': d.percent,
          'device': device,
          'changed': d.updatedAt.millisecondsSinceEpoch,
        },
    ]);
    for (final d in dirty) {
      await _db.markBookProgressSynced(d.bookId, d.updatedAt);
    }
    await _applyProgress(newer, ownDevice: await _sync.deviceId());
  }

  Future<int> _applyProgress(List<Map<String, Object?>> items, {required String ownDevice}) async {
    var applied = 0;
    for (final j in items) {
      final key = j['id'];
      final r = RemoteBookProgress.fromJson(j);
      if (key is! String || r == null) continue;
      final book = await _db.bookByKey(key);
      if (book == null) continue;
      final ok = await _db.applyRemoteBookProgress(
        book.id,
        locator: r.locator,
        positionMs: r.positionMs,
        percent: r.percent,
        changed: r.changed,
        device: r.deviceId == ownDevice ? null : r.deviceName,
      );
      if (ok) applied++;
    }
    return applied;
  }

  /// Полный проход: удаления, места, список книг, загрузка и скачивание
  /// текстовых книг. Вызывается из [SyncService] после подкастов.
  Future<void> syncWith(GpodderClient client) async {
    try {
      final device = await _deviceTag();
      final ownDevice = await _sync.deviceId();

      // 1. Удалённые здесь книги — удалить на сервере.
      for (final book in await _db.pendingBookDeletes()) {
        if (book.kind == BookKind.text) await client.deleteBook(book.key);
        await _db.deleteBookRow(book.id);
      }

      // 2. Места в книгах.
      await _uploadProgress(client, device);

      // 3. Что изменилось на сервере.
      final since = int.tryParse(await _db.setting(BookSettings.syncSince) ?? '') ?? 0;
      final changes = await client.bookChanges(since);
      final books = changes['books'];
      if (books is List) {
        for (final b in books.whereType<Map<String, Object?>>()) {
          await _applyRemoteBook(b);
        }
      }
      final progress = changes['progress'];
      if (progress is List) await _applyProgress(progress.whereType<Map<String, Object?>>().toList(), ownDevice: ownDevice);
      if (changes['rev'] is int) await _db.setSetting(BookSettings.syncSince, '${changes['rev']}');
      if (changes['used'] is int) await _db.setSetting(BookSettings.serverUsed, '${changes['used']}');
      if (changes['limit'] is int) await _db.setSetting(BookSettings.serverLimit, '${changes['limit']}');

      // 4. Текстовые книги этого устройства — на сервер.
      String? quotaError;
      for (final book in await _db.textBooksToUpload()) {
        final path = book.path;
        if (path == null || !await File(path).exists()) continue;
        try {
          await client.uploadBookFile(book.key, File(path), title: book.title, author: book.author, format: book.format);
          await _db.setBookUploaded(book.id, true);
        } on SyncException catch (e) {
          if (e.quota || e.status == 413) {
            quotaError = e.message;
            continue;
          }
          rethrow;
        }
      }

      // 5. Книги с других устройств — скачать.
      final dir = await _booksDirectory();
      for (final book in await _db.textBooksToDownload()) {
        await _download(client, book, dir);
      }

      await _db.setSetting(BookSettings.unsupported, '');
      await _db.setSetting(BookSettings.lastError, quotaError ?? '');
    } on SyncException catch (e) {
      if (e.notFound) {
        // Старый сервер без books.php: книги остаются на устройстве.
        await _db.setSetting(BookSettings.unsupported, 'true');
        return;
      }
      await _db.setSetting(BookSettings.lastError, e.message);
    } catch (e) {
      await _db.setSetting(BookSettings.lastError, 'Ошибка синхронизации книг: $e');
      debugPrint('Синхронизация книг: $e');
    }
  }

  Future<void> _applyRemoteBook(Map<String, Object?> j) async {
    final key = j['id'];
    if (key is! String || !key.startsWith('t:')) return;
    final local = await _db.bookByKey(key);
    if (j['deleted'] == true) {
      // Удалена на другом устройстве — удаляем и здесь.
      if (local != null) {
        await _deleteFile(local.path);
        await _deleteFile(local.coverPath);
        await _db.deleteBookRow(local.id);
      }
      return;
    }
    final title = j['title'];
    final format = j['format'];
    if (title is! String || format is! String) return;
    if (local == null) {
      await _db.saveTextBook(
        TextBookInfo(
          key: key,
          title: title,
          author: j['author'] is String ? j['author']! as String : null,
          format: format,
          sizeBytes: (j['size'] as num?)?.toInt() ?? 0,
        ),
        uploaded: true,
      );
    } else if (!local.uploaded) {
      await _db.setBookUploaded(local.id, true);
    }
  }

  Future<void> _download(GpodderClient client, Book book, Directory dir) async {
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, '${book.key.substring(2)}.${book.format}'));
    final tmp = File('${target.path}.part');
    try {
      await client.downloadBookFile(book.key, tmp);
      // Ключ книги — sha1 файла: так видно, что файл пришёл целым.
      final digest = await sha1.bind(tmp.openRead()).first;
      if ('t:$digest' != book.key) {
        await tmp.delete();
        throw const SyncException('Книга скачалась с ошибкой, попробую ещё раз при следующей синхронизации.');
      }
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      await _db.setBookFile(book.id, target.path);
      await onFilesChanged?.call(book.id);
    } on SyncException catch (e) {
      if (e.notFound) {
        // На сервере файла уже нет — книга удалена.
        await _db.deleteBookRow(book.id);
        return;
      }
      rethrow;
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  /// Удалить текстовую книгу везде: здесь — сразу, на сервере — сейчас
  /// или при следующей синхронизации (если сети нет).
  /// Возвращает `false`, если сервер пока не знает об удалении.
  Future<bool> deleteEverywhere(Book book) async {
    await _db.markBookDeletePending(book.id);
    await _deleteFile(book.path);
    await _deleteFile(book.coverPath);
    final client = await _sync.openClient();
    if (client == null) {
      await _db.deleteBookRow(book.id);
      return true;
    }
    try {
      await client.deleteBook(book.key);
      await _db.deleteBookRow(book.id);
      return true;
    } on SyncException catch (e) {
      if (e.notFound && e.status == 404) {
        await _db.deleteBookRow(book.id);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  static Future<void> _deleteFile(String? path) async {
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  void dispose() => _pushTimer?.cancel();
}
