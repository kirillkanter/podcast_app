import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';

import 'data/db/database.dart';
import 'data/podcast_repository.dart';
import 'feed/feed_fetcher.dart';
import 'player/podcast_audio_handler.dart';
import 'ui/app_scope.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.defaults();
  final repository = PodcastRepository(db, FeedFetcher());

  PodcastAudioHandler? audio;
  try {
    audio = await AudioService.init(
      builder: () => PodcastAudioHandler(db),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.podcast_app.audio',
        androidNotificationChannelName: 'Воспроизведение',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        rewindInterval: Duration(seconds: 10),
        fastForwardInterval: Duration(seconds: 30),
      ),
    );
    if (Platform.isAndroid) {
      // Речевой профиль: пауза при звонке, приглушение под уведомления,
      // пауза при отключении наушников.
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
    }
  } catch (e) {
    // Без плеера приложение всё равно полезно: подписки и списки работают.
    debugPrint('Не удалось запустить плеер: $e');
  }

  runApp(PodcastApp(db: db, repository: repository, audio: audio));
}

class PodcastApp extends StatefulWidget {
  const PodcastApp({
    super.key,
    required this.db,
    required this.repository,
    this.audio,
    this.refreshOnStart = true,
  });

  final AppDatabase db;
  final PodcastRepository repository;
  final PodcastAudioHandler? audio;
  final bool refreshOnStart;

  @override
  State<PodcastApp> createState() => _PodcastAppState();
}

class _PodcastAppState extends State<PodcastApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _errors;

  @override
  void initState() {
    super.initState();
    _errors = widget.audio?.errors.listen((message) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void dispose() {
    _errors?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      db: widget.db,
      repository: widget.repository,
      audio: widget.audio,
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
