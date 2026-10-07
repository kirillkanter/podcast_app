// Фоновая работа на Android: проверка фидов и загрузка эпизодов, когда
// приложение закрыто. Задачи планирует WorkManager (Android сам выбирает
// время, объединяя их с задачами других приложений).
//
// Задача может выполниться в трёх положениях:
// - в работающем приложении (WorkManager запускает её в его движке) —
//   работают сервисы приложения;
// - в отдельном движке, пока в том же процессе живёт приложение (например,
//   играет звук) — задача просит приложение сделать работу само, чтобы два
//   загрузчика не качали один файл;
// - приложение не запущено — задача открывает свою базу и качает сама.
//   Если в это время открыть приложение, оно попросит задачу остановиться
//   и продолжит загрузки само.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';

import '../app_services.dart';
import '../data/db/database.dart';

/// Ключи настроек фоновой работы.
abstract final class BackgroundSettings {
  /// Скачивать в фоне только на зарядке. По умолчанию — да.
  static const chargingOnly = 'background.chargingOnly';
}

const refreshTask = 'bcaster.refresh';
const downloadsTask = 'bcaster.downloads';

const _appPortName = 'bcaster.app';
const _backgroundPortName = 'bcaster.background';

/// Сервисы работающего приложения (в его изоляте).
AppServices? runningApp;

bool get backgroundSupported => !kIsWeb && Platform.isAndroid;

@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    try {
      await runBackgroundTask(task);
    } catch (e) {
      debugPrint('Фоновая задача $task: $e');
    }
    // Ошибки (нет сети, сайт недоступен) не повторяем сразу: следующая
    // проверка будет по расписанию.
    return true;
  });
}

Future<void> runBackgroundTask(String task) async {
  final app = runningApp;
  if (app != null) return _work(app, task, background: false);

  // Приложение живёт в этом же процессе — работу делает оно.
  final appPort = IsolateNameServer.lookupPortByName(_appPortName);
  if (appPort != null) {
    final reply = ReceivePort();
    appPort.send([task, reply.sendPort]);
    try {
      await reply.first.timeout(const Duration(minutes: 55));
    } on TimeoutException {
      // Пусть WorkManager завершит задачу; продолжим в следующий раз.
    } finally {
      reply.close();
    }
    return;
  }

  final services = AppServices.open();
  final control = ReceivePort();
  IsolateNameServer.removePortNameMapping(_backgroundPortName);
  IsolateNameServer.registerPortWithName(control.sendPort, _backgroundPortName);
  control.listen((message) async {
    // Открылось приложение: отдаём ему загрузки.
    if (message is SendPort) {
      await services.downloads.suspend();
      message.send(true);
    }
  });
  try {
    await _work(services, task, background: true);
  } finally {
    IsolateNameServer.removePortNameMapping(_backgroundPortName);
    control.close();
  }
}

Future<void> _work(AppServices s, String task, {required bool background}) async {
  switch (task) {
    case refreshTask:
      // В фоне проверка только ставит эпизоды в очередь; качает отдельная
      // задача — со своими условиями (Wi‑Fi, зарядка) и уведомлением.
      if (background) s.downloads.hold = true;
      await s.refreshAndQueue();
      if (await s.downloads.hasPending()) await scheduleDownloads(s.db);
    case downloadsTask:
      await s.downloads.runUntilIdle();
  }
}

/// Приложение запущено: принимать работу от фоновых задач и забрать
/// загрузки у задачи, если она сейчас качает сама.
Future<void> attachRunningApp(AppServices services) async {
  runningApp = services;
  if (!backgroundSupported) return;
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(_appPortName);
  IsolateNameServer.registerPortWithName(port.sendPort, _appPortName);
  port.listen((message) async {
    if (message is List && message.length == 2 && message[0] is String && message[1] is SendPort) {
      try {
        await _work(services, message[0] as String, background: false);
      } catch (e) {
        debugPrint('Фоновая задача в приложении: $e');
      }
      (message[1] as SendPort).send(true);
    }
  });

  final background = IsolateNameServer.lookupPortByName(_backgroundPortName);
  if (background != null) {
    final reply = ReceivePort();
    background.send(reply.sendPort);
    try {
      await reply.first.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Задача не ответила — скорее всего, уже завершилась.
    } finally {
      reply.close();
    }
  }
}

/// Запустить WorkManager и запланировать проверку фидов: примерно раз
/// в три часа, при подключённой сети и не севшей батарее.
Future<void> initBackground() async {
  if (!backgroundSupported) return;
  await Workmanager().initialize(backgroundDispatcher);
  await Workmanager().registerPeriodicTask(
    refreshTask,
    refreshTask,
    frequency: const Duration(hours: 3),
    constraints: Constraints(
      networkType: NetworkType.connected,
      requiresBatteryNotLow: true,
    ),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}

/// Докачать очередь в фоне. [userInitiated] — загрузки, запущенные
/// человеком (приложение закрыли, пока они шли): им зарядка не нужна.
Future<void> scheduleDownloads(AppDatabase db, {bool userInitiated = false, bool replace = false}) async {
  if (!backgroundSupported) return;
  final chargingOnly = !userInitiated && await db.setting(BackgroundSettings.chargingOnly) != 'false';
  try {
    await Workmanager().registerOneOffTask(
      downloadsTask,
      downloadsTask,
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
        requiresCharging: chargingOnly,
      ),
      existingWorkPolicy: userInitiated || replace ? ExistingWorkPolicy.replace : ExistingWorkPolicy.keep,
      foregroundServiceConfig: ForegroundServiceConfig(
        notificationTitle: 'Загрузка эпизодов',
        notificationText: 'Basic Caster скачивает новые эпизоды',
        notificationChannelId: 'ru.bcaster.app.downloads',
        notificationChannelName: 'Загрузки',
        notificationId: 2001,
        foregroundServiceType: ForegroundServiceType.dataSync,
      ),
    );
  } catch (e) {
    debugPrint('Не удалось запланировать загрузки: $e');
  }
}

const _system = MethodChannel('basic_caster/system');

/// Снято ли с приложения ограничение батареи. `null` — узнать не удалось.
Future<bool?> batteryUnrestricted() async {
  if (!backgroundSupported) return null;
  try {
    return await _system.invokeMethod<bool>('batteryUnrestricted');
  } catch (_) {
    return null;
  }
}

/// Попросить систему не ограничивать работу приложения в фоне.
Future<void> requestBatteryUnrestricted() async {
  if (!backgroundSupported) return;
  try {
    await _system.invokeMethod<void>('requestBatteryUnrestricted');
  } catch (_) {}
}
