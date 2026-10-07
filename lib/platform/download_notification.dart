// Текст уведомления сервиса загрузок на Android (DownloadService.kt).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/db/database.dart';
import '../ui/download_button.dart' show formatBytes;
import '../ui/format.dart' show plural;

/// Текст уведомления по списку загрузок; `null` — ничего не качается.
@visibleForTesting
({String title, String text, int progress})? downloadNotice(List<DownloadWithEpisode> items) {
  final running = [for (final i in items) if (i.download.status == DownloadStatus.running) i];
  if (running.isEmpty) return null;
  final queued = items.where((i) => i.download.status == DownloadStatus.queued).length;
  var received = 0;
  var total = 0;
  var known = true;
  for (final i in running) {
    received += i.download.receivedBytes;
    final t = i.download.totalBytes;
    if (t == null || t <= 0) {
      known = false;
    } else {
      total += t;
    }
  }
  final title = running.length == 1
      ? running.single.episode.title
      : 'Загружается ${running.length} ${plural(running.length, 'эпизод', 'эпизода', 'эпизодов')}';
  final parts = [
    if (known && total > 0) '${formatBytes(received)} из ${formatBytes(total)}' else formatBytes(received),
    if (queued > 0) 'ещё $queued в очереди',
  ];
  return (
    title: title,
    text: parts.join(' · '),
    progress: known && total > 0 ? (received * 100 ~/ total).clamp(0, 100) : -1,
  );
}

/// Обновляет уведомление сервиса загрузок по базе (не чаще раза в секунду).
class DownloadNotifier {
  DownloadNotifier(this._db, {required this.show});

  final AppDatabase _db;
  final Future<void> Function(String title, String text, int progress) show;
  StreamSubscription<List<DownloadWithEpisode>>? _sub;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    _sub = _db.watchDownloadList().listen((items) {
      final notice = downloadNotice(items);
      if (notice == null) return;
      final now = DateTime.now();
      if (now.difference(_last) < const Duration(seconds: 1)) return;
      _last = now;
      show(notice.title, notice.text, notice.progress).catchError((Object e) {
        debugPrint('Уведомление о загрузках: $e');
      });
    });
  }

  void dispose() => _sub?.cancel();
}
