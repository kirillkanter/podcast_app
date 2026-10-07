// Уведомление о загрузках на Android: прогресс в шторке, и пока оно
// показано, система не останавливает загрузки, даже если приложение
// закрыли из списка недавних (сервис DownloadService в MainActivity).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/db/database.dart';
import '../ui/download_button.dart' show formatBytes;
import '../ui/format.dart' show plural;

const _system = MethodChannel('basic_caster/system');

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

class DownloadNotifier {
  DownloadNotifier(this._db);

  final AppDatabase _db;
  StreamSubscription<List<DownloadWithEpisode>>? _sub;
  Timer? _hide;
  DateTime _lastShown = DateTime.fromMillisecondsSinceEpoch(0);
  bool _visible = false;

  void start() {
    if (!Platform.isAndroid) return;
    _sub = _db.watchDownloadList().listen(_onChange);
  }

  void _onChange(List<DownloadWithEpisode> items) {
    final notice = downloadNotice(items);
    if (notice == null) {
      // Между двумя загрузками очереди — короткая пауза: не мигаем.
      _hide ??= Timer(const Duration(seconds: 3), () {
        _hide = null;
        if (!_visible) return;
        _visible = false;
        _call('downloadsDone');
      });
      return;
    }
    _hide?.cancel();
    _hide = null;
    final now = DateTime.now();
    if (_visible && now.difference(_lastShown) < const Duration(seconds: 1)) return;
    _lastShown = now;
    _visible = true;
    _call('downloadsProgress', {'title': notice.title, 'text': notice.text, 'progress': notice.progress});
  }

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _system.invokeMethod<Object?>(method, args);
    } catch (e) {
      debugPrint('Уведомление о загрузках: $e');
    }
  }

  void dispose() {
    _sub?.cancel();
    _hide?.cancel();
  }
}
