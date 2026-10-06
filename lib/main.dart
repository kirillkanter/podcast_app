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
    this.refreshOnStart = true,
  });

  final AppDatabase db;
  final PodcastRepository repository;
  final PodcastAudioHandler? audio;
  final DownloadManager? downloads;
  final PodcastCatalog? catalog;
  final bool refreshOnStart;

  @override
  State<PodcastApp> createState() => _PodcastAppState();
}

class _PodcastAppState extends State<PodcastApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _errors;
  StreamSubscription<bool>? _playing;
  bool _notificationsChecked = false;

  @override
  void initState() {
    super.initState();
    final audio = widget.audio;
    _errors = audio?.errors.listen((message) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
    });
    _playing = audio?.playbackState.map((s) => s.playing).distinct().listen((playing) {
      if (playing) _checkNotifications();
    });
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
      child: MaterialApp(
        title: 'Подкасты',
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
