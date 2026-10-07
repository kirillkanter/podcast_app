import 'package:flutter/material.dart';

import '../data/db/database.dart';
import 'app_scope.dart';
import 'icons.dart';
import 'theme.dart';

/// Доля загруженного, если известен размер.
double? downloadFraction(Download d) {
  final total = d.totalBytes;
  if (total == null || total <= 0) return null;
  return (d.receivedBytes / total).clamp(0.0, 1.0);
}

/// «45 МБ», «1,2 ГБ».
String formatBytes(int bytes) {
  const mb = 1024 * 1024;
  if (bytes >= 1024 * mb) {
    return '${(bytes / (1024 * mb)).toStringAsFixed(1).replaceAll('.', ',')} ГБ';
  }
  return '${(bytes / mb).round()} МБ';
}

/// Короткое описание состояния загрузки для подписи в списке.
String? downloadLabel(Download? d) {
  if (d == null) return null;
  switch (d.status) {
    case DownloadStatus.queued:
      return 'в очереди на загрузку';
    case DownloadStatus.running:
      final f = downloadFraction(d);
      return f == null ? 'загружается' : 'загружено ${(f * 100).round()}%';
    case DownloadStatus.failed:
      return 'ошибка загрузки';
    case DownloadStatus.completed:
    case DownloadStatus.removed:
      return null;
  }
}

/// Кнопка загрузки эпизода в списке: скачать, отменить, удалить, повторить.
class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key, required this.episodeId, required this.download});

  final int episodeId;
  final Download? download;

  @override
  Widget build(BuildContext context) {
    final manager = AppScope.of(context).downloads;
    if (manager == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final d = download;

    switch (d?.status) {
      case null:
      case DownloadStatus.removed:
        return IconButton(
          tooltip: 'Скачать',
          icon: const BcIcon(BcIcons.download, size: 22),
          onPressed: () => manager.enqueue(episodeId),
        );
      case DownloadStatus.queued:
        return IconButton(
          tooltip: d!.auto ? 'Ждёт Wi-Fi или очереди. Нажмите, чтобы отменить' : 'В очереди. Нажмите, чтобы отменить',
          icon: const BcIcon(BcIcons.clock, size: 22),
          onPressed: () => manager.remove(episodeId),
        );
      case DownloadStatus.running:
        return IconButton(
          tooltip: 'Отменить загрузку',
          onPressed: () => manager.remove(episodeId),
          icon: SizedBox.square(
            dimension: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(value: downloadFraction(d!), strokeWidth: 2.5),
                const BcIcon(BcIcons.close, size: 12),
              ],
            ),
          ),
        );
      case DownloadStatus.completed:
        return IconButton(
          tooltip: 'Загружено. Нажмите, чтобы удалить файл',
          icon: BcIcon(BcIcons.downloaded, size: 22, color: BcColors.of(context).ink),
          onPressed: () => _confirmDelete(context, () => manager.remove(episodeId)),
        );
      case DownloadStatus.failed:
        return IconButton(
          tooltip: '${d!.error ?? 'Ошибка загрузки'} Нажмите, чтобы повторить',
          icon: BcIcon(BcIcons.alert, size: 22, color: scheme.error),
          onPressed: () => manager.retry(episodeId),
        );
    }
  }
}

Future<void> _confirmDelete(BuildContext context, VoidCallback onDelete) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Удалить загруженный файл?'),
      content: const Text('Эпизод останется в списке, его можно будет слушать по сети или скачать снова.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Удалить')),
      ],
    ),
  );
  if (ok == true) onDelete();
}
