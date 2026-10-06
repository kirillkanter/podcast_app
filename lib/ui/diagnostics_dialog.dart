import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_scope.dart';

/// Ошибка запуска плеера, если она была (заполняется в main).
String? audioStartupError;

/// Сведения для поиска проблем: версия системы, состояние плеера,
/// разрешение на уведомления. Текст можно скопировать и прислать.
Future<void> showDiagnosticsDialog(BuildContext context) {
  final audio = AppScope.of(context).audio;
  return showDialog<void>(
    context: context,
    builder: (context) => FutureBuilder<String>(
      future: _collect(audio?.playbackState.value),
      builder: (context, snapshot) {
        final text = snapshot.data ?? 'Собираю сведения…';
        return AlertDialog(
          title: const Text('Диагностика'),
          content: SingleChildScrollView(child: SelectableText(text)),
          actions: [
            TextButton(
              onPressed: snapshot.hasData
                  ? () => Clipboard.setData(ClipboardData(text: text))
                  : null,
              child: const Text('Скопировать'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    ),
  );
}

Future<String> _collect(PlaybackState? state) async {
  final lines = <String>[
    'Система: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'Плеер запущен: ${audioStartupError == null ? 'да' : 'нет — $audioStartupError'}',
    if (state != null)
      'Состояние плеера: ${state.processingState.name}, играет: ${state.playing ? 'да' : 'нет'}',
  ];
  if (Platform.isAndroid) {
    try {
      final status = await Permission.notification.status;
      lines.add('Уведомления: ${status.isGranted ? 'разрешены' : 'запрещены (${status.name})'}');
    } catch (e) {
      lines.add('Уведомления: не удалось проверить ($e)');
    }
  }
  return lines.join('\n');
}
