import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/notifications.dart';
import 'app_scope.dart';

/// Ошибка запуска плеера, если она была (заполняется в main).
String? audioStartupError;

/// Последние ошибки связи с системным плеером (audio_service). Они не
/// видны пользователю, но объясняют, почему нет уведомления.
final audioServiceErrors = <String>[];

void recordAudioServiceError(Object error) {
  audioServiceErrors.add('${DateTime.now().toIso8601String().substring(11, 19)} $error');
  if (audioServiceErrors.length > 10) audioServiceErrors.removeAt(0);
}

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
  lines.add(audioServiceErrors.isEmpty
      ? 'Ошибок системного плеера нет'
      : 'Ошибки системного плеера:\n${audioServiceErrors.join('\n')}');
  if (Platform.isAndroid) {
    final native = await notificationDiagnostics();
    if (native != null) lines.add(native);
    final enabled = await notificationsEnabled();
    lines.add('Уведомления: ${switch (enabled) {
      true => 'разрешены',
      false => 'запрещены',
      null => 'не удалось проверить',
    }}');
  }
  return lines.join('\n');
}
