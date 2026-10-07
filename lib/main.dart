import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_services.dart';
import 'catalog/podcast_catalog.dart';
import 'data/db/database.dart';
import 'data/podcast_repository.dart';
import 'download/download_manager.dart';
import 'platform/background.dart';
import 'platform/desktop.dart';
import 'platform/notifications.dart';
import 'player/podcast_audio_handler.dart';
import 'sync/sync_service.dart';
import 'ui/scrolling.dart';
import 'ui/app_scope.dart';
import 'ui/diagnostics_dialog.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

/// Сервис загрузок Android (DownloadService.kt) запускает свой движок отсюда.
@pragma('vm:entry-point')
Future<void> downloadServiceMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await runDownloadService();
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // На Android качает отдельный сервис (переживает закрытие окна);
  // окно только будит его, когда в очереди что-то появилось.
  Timer? wake;
  final services = AppServices.open(
    externalDownloads: Platform.isAndroid
        ? () {
            wake?.cancel();
            wake = Timer(const Duration(milliseconds: 300), () => unawaited(requestDownloadService()));
          }
        : null,
  );
  final db = services.db;
  final repository = services.repository;
  final downloads = services.downloads;
  final sync = services.sync;
  attachRunningApp(services);
  unawaited(downloads.start());
  unawaited(initBackground().catchError((Object e) => debugPrint('Фоновая работа: $e')));
  if (Platform.isWindows) {
    // Свёрнутое в трей приложение раз в два часа проверяет фиды
    // и скачивает новое по правилам автозагрузки.
    Timer.periodic(const Duration(hours: 2), (_) => unawaited(services.refreshAndQueue()));
  }
  // Страна каталога — из языка системы: ru_RU → ru.
  final region = Platform.localeName.split(RegExp('[_.-]')).elementAtOrNull(1);
  final systemCountry = region != null && RegExp(r'^[A-Za-z]{2}$').hasMatch(region) ? region : 'us';
  // Регион можно выбрать в настройках; иначе — как в системе.
  final savedCountry = await db.setting(CatalogSettings.country);
  final catalog = PodcastCatalog(
    country: savedCountry != null && savedCountry.isNotEmpty ? savedCountry : systemCountry,
    defaultCountry: systemCountry,
    // Подборки и чарты — на диске: открываются сразу и без сети.
    cacheDirectory: () async => Directory(p.join((await getApplicationCacheDirectory()).path, 'catalog')),
  );
  // Обложки в памяти: больше места — реже перечитывать их с диска.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 200 << 20;

  PodcastAudioHandler? audio;
  try {
    audio = await AudioService.init(
      builder: () => PodcastAudioHandler(
        db,
        localFile: downloads.localFile,
        onPlayed: downloads.onPlayed,
        // Перед запуском — прогресс с других устройств (не дольше 3 секунд).
        beforePlay: (_) => sync.pullProgress(),
      ),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'ru.bcaster.app.playback',
        androidNotificationChannelName: 'Воспроизведение',
        // Белый силуэт логотипа: цветная иконка в строке состояния стала бы белым кругом.
        androidNotificationIcon: 'drawable/ic_stat_bcaster',
        // Сервис остаётся «на переднем плане» и на паузе. Иначе каждая
        // короткая пауза (звук уведомления, кнопка наушников) снимала его
        // с переднего плана, а вернуть его из фона Android 12+ не даёт
        // (startForegroundService not allowed): звук шёл без сервиса,
        // и система через несколько минут замораживала приложение.
        androidStopForegroundOnPause: false,
        rewindInterval: Duration(seconds: 10),
        fastForwardInterval: Duration(seconds: 30),
      ),
    );
  } catch (e) {
    // Без плеера приложение всё равно полезно: подписки и списки работают.
    debugPrint('Не удалось запустить плеер: $e');
    audioStartupError = '$e';
  }

  if (audio != null) AudioService.asyncError.listen(recordAudioServiceError);

  if (audio != null && Platform.isAndroid) {
    try {
      // Речевой профиль: пауза при звонке, приглушение под уведомления,
      // пауза при отключении наушников.
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
    } catch (e) {
      debugPrint('Не удалось настроить аудиосессию: $e');
    }
  }

  if (Platform.isWindows) {
    try {
      await DesktopWindow(db, audio).init(startHidden: args.contains(trayLaunchArgument));
    } catch (e) {
      debugPrint('Не удалось настроить окно: $e');
    }
  }

  runApp(PodcastApp(
    db: db,
    repository: repository,
    audio: audio,
    downloads: downloads,
    catalog: catalog,
    sync: sync,
  ));
  // Эпизод, который играл перед закрытием, — снова в мини-плеере.
  unawaited(audio?.restoreLast());
}

class PodcastApp extends StatefulWidget {
  const PodcastApp({
    super.key,
    required this.db,
    required this.repository,
    this.audio,
    this.downloads,
    this.catalog,
    this.sync,
    this.refreshOnStart = true,
  });

  final AppDatabase db;
  final PodcastRepository repository;
  final PodcastAudioHandler? audio;
  final DownloadManager? downloads;
  final PodcastCatalog? catalog;
  final SyncService? sync;
  final bool refreshOnStart;

  @override
  State<PodcastApp> createState() => _PodcastAppState();
}

class _PodcastAppState extends State<PodcastApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _errors;
  StreamSubscription<bool>? _playing;
  StreamSubscription<int>? _dirtySubscriptions;
  StreamSubscription<int>? _dirtyState;
  StreamSubscription<String?>? _lastEpisode;
  StreamSubscription<String?>? _rotate;
  AppLifecycleListener? _lifecycle;
  Timer? _periodicSync;
  bool _notificationsChecked = false;
  late final Stream<String?> _themeSetting = widget.db.watchSetting(themeSettingKey);
  static final _light = buildTheme(Brightness.light);
  static final _dark = buildTheme(Brightness.dark);

  @override
  void initState() {
    super.initState();
    final audio = widget.audio;
    final sync = widget.sync;
    _errors = audio?.errors.listen((message) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
    });
    _playing = audio?.playbackState.map((s) => s.playing).distinct().skip(1).listen((playing) {
      if (playing) {
        _checkNotifications();
      } else {
        // Пауза или конец эпизода — отправить позицию на другие устройства.
        sync?.schedule(const Duration(seconds: 5));
      }
    });
    // Поворот экрана: по умолчанию разрешён, в настройках можно запретить.
    if (Platform.isAndroid) {
      _rotate = widget.db.watchSetting(rotateSettingKey).listen((value) {
        SystemChrome.setPreferredOrientations(
          value == 'false' ? const [DeviceOrientation.portraitUp] : const [],
        );
      });
    }
    // Последний эпизод сменился на другом устройстве (пришёл с синхронизацией):
    // если здесь ничего не играет, он появляется в мини-плеере на паузе.
    _lastEpisode = widget.db.watchSetting(PlayerSettings.last).skip(1).listen((value) {
      final id = int.tryParse(value ?? '');
      if (id != null && audio != null && audio.currentEpisodeId != id && !audio.playbackState.value.playing) {
        audio.restoreLast();
      }
    });
    if (sync != null) {
      sync.schedule(const Duration(seconds: 3));
      // Подписка или отписка — синхронизировать через несколько секунд.
      _dirtySubscriptions = widget.db
          .watchDirtySubscriptionCount()
          .where((count) => count > 0)
          .listen((_) => sync.schedule(const Duration(seconds: 5)));
      // Очередь и архив — так же.
      _dirtyState = widget.db
          .watchDirtyStateCount()
          .where((count) => count > 0)
          .listen((_) => sync.schedule(const Duration(seconds: 5)));
      _lifecycle = AppLifecycleListener(
        onResume: () => sync.schedule(const Duration(seconds: 2)),
        // Перед уходом в фон — сразу, пока система не приостановила приложение.
        onPause: () => sync.syncNow().ignore(),
      );
      _periodicSync = Timer.periodic(const Duration(minutes: 10), (_) => sync.syncNow().ignore());
    }
  }

  /// При первом запуске эпизода на Android проверяем, разрешены ли
  /// уведомления: без них плеер может не появиться в шторке и на экране
  /// блокировки (часть прошивок не соблюдает исключение для медиа).
  Future<void> _checkNotifications() async {
    if (_notificationsChecked || !Platform.isAndroid) return;
    _notificationsChecked = true;
    try {
      var enabled = await notificationsEnabled();
      if (enabled == false) enabled = await requestNotifications();
      if (enabled != false) return;
      _messenger.currentState?.showSnackBar(SnackBar(
        duration: const Duration(seconds: 10),
        content: const Text(
          'Уведомления для приложения выключены, поэтому Android может не показывать '
          'плеер в шторке и на экране блокировки.',
        ),
        action: SnackBarAction(label: 'Настройки', onPressed: openNotificationSettings),
      ));
    } catch (e) {
      debugPrint('Не удалось проверить разрешение на уведомления: $e');
    }
  }

  @override
  void dispose() {
    _errors?.cancel();
    _playing?.cancel();
    _dirtySubscriptions?.cancel();
    _dirtyState?.cancel();
    _lastEpisode?.cancel();
    _rotate?.cancel();
    _lifecycle?.dispose();

    _periodicSync?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      db: widget.db,
      repository: widget.repository,
      audio: widget.audio,
      downloads: widget.downloads,
      catalog: widget.catalog,
      sync: widget.sync,
      child: StreamBuilder<String?>(
        stream: _themeSetting,
        builder: (context, theme) => MaterialApp(
          title: 'Basic Caster',
          debugShowCheckedModeBanner: false,
          // На компьютере списки тянутся мышью (ряды подборок, пилюли).
          scrollBehavior: const AppScrollBehavior(),
          scaffoldMessengerKey: _messenger,
          theme: _light,
          darkTheme: _dark,
          themeMode: themeModeFrom(theme.data),
          home: AppShell(refreshOnStart: widget.refreshOnStart),
          builder: Platform.isWindows
              ? (context, child) => PlayerHotkeys(audio: widget.audio, child: child!)
              : null,
        ),
      ),
    );
  }
}
