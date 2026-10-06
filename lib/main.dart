import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'catalog/podcast_catalog.dart';
import 'data/db/database.dart';
import 'data/podcast_repository.dart';
import 'download/download_manager.dart';
import 'feed/feed_fetcher.dart';
import 'platform/notifications.dart';
import 'player/podcast_audio_handler.dart';
import 'sync/sync_service.dart';
import 'ui/app_scope.dart';
import 'ui/diagnostics_dialog.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.defaults();
  final repository = PodcastRepository(db, FeedFetcher());
  final downloads = DownloadManager(
    db: db,
    directory: getApplicationSupportDirectory,
    isUnmetered: () async {
      final types = await Connectivity().checkConnectivity();
      return types.contains(ConnectivityResult.wifi) || types.contains(ConnectivityResult.ethernet);
    },
  );
  unawaited(downloads.start());
  final sync = SyncService(db: db, repository: repository);
  // Страна каталога — из языка системы: ru_RU → ru.
  final region = Platform.localeName.split(RegExp('[_.-]')).elementAtOrNull(1);
  final catalog = PodcastCatalog(
    country: region != null && RegExp(r'^[A-Za-z]{2}$').hasMatch(region) ? region : 'us',
  );

  PodcastAudioHandler? audio;
  try {
    audio = await AudioService.init(
      builder: () => PodcastAudioHandler(
        db,
        localFile: downloads.localFile,
        onPlayed: downloads.onPlayed,
      ),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.podcast_app.audio',
        androidNotificationChannelName: 'Воспроизведение',
        androidNotificationOngoing: true,
        // Белый силуэт логотипа: цветная иконка в строке состояния стала бы белым кругом.
        androidNotificationIcon: 'drawable/ic_stat_bcaster',
        androidStopForegroundOnPause: true,
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

  runApp(PodcastApp(
    db: db,
    repository: repository,
    audio: audio,
    downloads: downloads,
    catalog: catalog,
    sync: sync,
  ));
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
  AppLifecycleListener? _lifecycle;
  Timer? _periodicSync;
  bool _notificationsChecked = false;

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
    if (sync != null) {
      sync.schedule(const Duration(seconds: 3));
      // Подписка или отписка — синхронизировать через несколько секунд.
      _dirtySubscriptions = widget.db
          .watchDirtySubscriptionCount()
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
      child: MaterialApp(
        title: 'Basic Caster',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _messenger,
        theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: HomeScreen(refreshOnStart: widget.refreshOnStart),
      ),
    );
  }
}
