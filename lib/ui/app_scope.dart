import 'package:flutter/widgets.dart';

import '../books/book_library.dart';
import '../catalog/books/book_catalog.dart';
import '../catalog/podcast_catalog.dart';
import '../data/db/database.dart';
import '../data/podcast_repository.dart';
import '../download/download_manager.dart';
import '../player/podcast_audio_handler.dart';
import '../sync/book_sync.dart';
import '../sync/sync_service.dart';

/// Даёт экранам доступ к БД и репозиторию.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.db,
    required this.repository,
    this.audio,
    this.downloads,
    this.catalog,
    this.sync,
    this.books,
    this.bookSync,
    this.bookCatalog,
    required super.child,
  });

  final AppDatabase db;
  final PodcastRepository repository;

  /// Плеер. `null` в тестах, где нет платформенного аудио.
  final PodcastAudioHandler? audio;

  /// Загрузки. `null` в тестах интерфейса.
  final DownloadManager? downloads;

  /// Каталог для поиска. `null` в тестах интерфейса.
  final PodcastCatalog? catalog;

  /// Синхронизация. `null` в тестах интерфейса.
  final SyncService? sync;

  /// Книги. `null` в тестах интерфейса.
  final BookLibrary? books;
  final BookSync? bookSync;

  /// Каталог книг (LibriVox, OPDS). `null` в тестах интерфейса.
  final BookCatalog? bookCatalog;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope не найден выше по дереву виджетов');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      db != oldWidget.db || repository != oldWidget.repository ||
      audio != oldWidget.audio ||
      downloads != oldWidget.downloads ||
      catalog != oldWidget.catalog ||
      sync != oldWidget.sync ||
      books != oldWidget.books ||
      bookSync != oldWidget.bookSync ||
      bookCatalog != oldWidget.bookCatalog;
}
