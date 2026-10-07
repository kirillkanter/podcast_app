// Фоновая работа на Android.
//
// Загрузки качает не окно приложения, а сервис DownloadService со своим
// движком Flutter (точка входа downloadServiceMain в main.dart): Android
// выгружает движок окна, когда приложение закрывают из списка недавних,
// а сервис с уведомлением продолжает работать. Окно только ставит эпизоды
// в очередь (в базе) и будит сервис.
//
// Проверку фидов по расписанию и загрузки, когда приложение вообще не
// запускали, делает WorkManager. Одновременно качает только один
// «загрузчик» (сервис или задача WorkManager): он регистрирует свой порт
// под общим именем, а новый загрузчик просит старого остановиться.
//
// Все они пишут в одну базу через разные соединения, поэтому окно
// получает сообщение «таблицы изменились» и перечитывает списки.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';

import '../app_services.dart';
import '../data/db/database.dart';
import 'download_notification.dart';

/// Ключи настроек фоновой работы.
abstract final class BackgroundSettings {
  /// Скачивать в фоне только на зарядке. По умолчанию — да.
  static const chargingOnly = 'background.chargingOnly';
}

const refreshTask = 'bcaster.refresh';
const downloadsTask = 'bcaster.downloads';

const _appPortName = 'bcaster.app';
const _downloaderPortName = 'bcaster.downloader';

/// Сервисы работающего приложения (в изоляте окна).
AppServices? runningApp;

bool get backgroundSupported => !kIsWeb && Platform.isAndroid;

const _system = MethodChannel('basic_caster/system');
const _serviceChannel = MethodChannel('basic_caster/download_service');

// ---------------------------------------------------------------------------
// Окно приложения
// ---------------------------------------------------------------------------

/// Окно запущено: слушать сообщения загрузчиков об изменениях в базе.
void attachRunningApp(AppServices services) {
  runningApp = services;
  if (!backgroundSupported) return;
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(_appPortName);
  IsolateNameServer.registerPortWithName(port.sendPort, _appPortName);
  port.listen((message) {
    // Другое соединение с базой что-то записало — обновить списки.
    final db = services.db;
    if (message == 'downloads') db.markTablesUpdated([db.downloads]);
    if (message == 'all') db.markTablesUpdated(db.allTables);
  });
}

/// Разбудить сервис загрузок (окно на Android): он сам возьмёт очередь.
Future<void> requestDownloadService() async {
  if (!backgroundSupported) return;
  try {
    final started = await _system.invokeMethod<bool>('downloadsStart') ?? false;
    if (!started) {
      // Android не дал запустить сервис (приложение в фоне) — пусть
      // докачает WorkManager, когда сможет.
      final app = runningApp;
      if (app != null) await scheduleDownloads(app.db, userInitiated: true);
    }
  } catch (e) {
    debugPrint('Не удалось запустить загрузки: $e');
  }
}

/// Сообщить окну, что в базе что-то поменялось: 'downloads' — только
/// загрузки (каждую секунду, пока качаем), 'all' — всё (после проверки фидов).
void _notifyApp([String what = 'downloads']) => IsolateNameServer.lookupPortByName(_appPortName)?.send(what);

// ---------------------------------------------------------------------------
// Загрузчик: один на устройство
// ---------------------------------------------------------------------------

/// Жив ли другой загрузчик (отвечает ли его порт).
Future<SendPort?> _liveDownloader() async {
  final port = IsolateNameServer.lookupPortByName(_downloaderPortName);
  if (port == null) return null;
  final reply = ReceivePort();
  try {
    port.send(['ping', reply.sendPort]);
    await reply.first.timeout(const Duration(seconds: 2));
    return port;
  } catch (_) {
    // Изолят завершился, а имя осталось.
    IsolateNameServer.removePortNameMapping(_downloaderPortName);
    return null;
  } finally {
    reply.close();
  }
}

/// Стать загрузчиком: прежний (если есть) возвращает загрузки в очередь.
Future<ReceivePort> _becomeDownloader(AppServices s, {void Function()? onPoke}) async {
  final previous = await _liveDownloader();
  if (previous != null) {
    final reply = ReceivePort();
    try {
      previous.send(['suspend', reply.sendPort]);
      await reply.first.timeout(const Duration(seconds: 5));
    } catch (_) {
    } finally {
      reply.close();
    }
  }
  final own = ReceivePort();
  IsolateNameServer.removePortNameMapping(_downloaderPortName);
  IsolateNameServer.registerPortWithName(own.sendPort, _downloaderPortName);
  own.listen((message) async {
    if (message is! List || message.length != 2 || message[1] is! SendPort) return;
    final reply = message[1] as SendPort;
    switch (message[0]) {
      case 'ping':
        reply.send(true);
      case 'suspend':
        await s.downloads.suspend();
        reply.send(true);
    }
  });
  return own;
}

void _leaveDownloader(ReceivePort own) {
  if (IsolateNameServer.lookupPortByName(_downloaderPortName) == own.sendPort) {
    IsolateNameServer.removePortNameMapping(_downloaderPortName);
  }
  own.close();
}

/// Качать очередь, пока есть что, сообщая окну об изменениях.
Future<void> _download(AppServices s, {bool Function()? again}) async {
  final ticker = Timer.periodic(const Duration(seconds: 1), (_) => _notifyApp());
  try {
    do {
      await s.downloads.runUntilIdle();
    } while (again?.call() ?? false);
  } finally {
    ticker.cancel();
    _notifyApp();
  }
}

/// Точка входа сервиса загрузок (свой движок Flutter, см. DownloadService.kt).
Future<void> runDownloadService() async {
  final services = AppServices.open();
  var poked = false;
  _serviceChannel.setMethodCallHandler((call) async {
    if (call.method == 'poke') {
      // Окно поставило ещё что-то в очередь.
      poked = true;
      services.downloads.resume();
    }
    return null;
  });
  final notifier = DownloadNotifier(
    services.db,
    show: (title, text, progress) =>
        _serviceChannel.invokeMethod<void>('progress', {'title': title, 'text': text, 'progress': progress}),
  )..start();
  final lock = await _becomeDownloader(services);
  try {
    await _download(services, again: () {
      final repeat = poked;
      poked = false;
      return repeat;
    });
  } catch (e) {
    debugPrint('Сервис загрузок: $e');
  } finally {
    notifier.dispose();
    _leaveDownloader(lock);
    await services.db.close();
    // Сервис убирает уведомление и останавливается.
    await _serviceChannel.invokeMethod<void>('done');
  }
}

// ---------------------------------------------------------------------------
// WorkManager
// ---------------------------------------------------------------------------

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
  switch (task) {
    case refreshTask:
      final app = runningApp;
      final s = app ?? AppServices.open();
      // Проверка только ставит эпизоды в очередь; качает отдельная задача —
      // со своими условиями (Wi‑Fi, зарядка) и уведомлением.
      s.downloads.hold = true;
      try {
        await s.refreshAndQueue();
        _notifyApp('all');
        if (await s.downloads.hasPending() && await _liveDownloader() == null) await scheduleDownloads(s.db);
      } finally {
        if (app == null) {
          await s.db.close();
        } else {
          s.downloads.hold = false;
        }
      }
    case downloadsTask:
      // Уже качает сервис — ему не мешаем.
      if (await _liveDownloader() != null) return;
      final s = AppServices.open();
      final lock = await _becomeDownloader(s);
      try {
        await _download(s);
      } finally {
        _leaveDownloader(lock);
        await s.db.close();
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

/// Докачать очередь в фоне через WorkManager. [userInitiated] — загрузки,
/// запущенные человеком: им зарядка не нужна.
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

// ---------------------------------------------------------------------------
// Батарея
// ---------------------------------------------------------------------------

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
