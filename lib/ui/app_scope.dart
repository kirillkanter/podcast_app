import 'package:flutter/widgets.dart';

import '../data/db/database.dart';
import '../data/podcast_repository.dart';
import '../player/podcast_audio_handler.dart';

/// Даёт экранам доступ к БД и репозиторию.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.db,
    required this.repository,
    this.audio,
    required super.child,
  });

  final AppDatabase db;
  final PodcastRepository repository;

  /// Плеер. `null` в тестах, где нет платформенного аудио.
  final PodcastAudioHandler? audio;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope не найден выше по дереву виджетов');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      db != oldWidget.db || repository != oldWidget.repository || audio != oldWidget.audio;
}
