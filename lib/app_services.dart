// База, фиды, загрузки и синхронизация — общие для приложения и фоновых
// задач Android (там приложение может быть не запущено).
import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'books/book_library.dart';
import 'data/db/database.dart';
import 'data/podcast_repository.dart';
import 'download/download_manager.dart';
import 'feed/feed_fetcher.dart';
import 'sync/book_sync.dart';
import 'sync/sync_service.dart';

class AppServices {
  AppServices._(this.db, this.repository, this.downloads, this.sync, this.books, this.bookSync);

  /// Открыть базу и создать сервисы. Загрузки не запускаются: это делает
  /// тот, кто ими владеет (приложение или фоновая задача).
  /// [externalDownloads] — качает сервис загрузок (окно на Android):
  /// вызывается, когда в очереди что-то появилось.
  factory AppServices.open({void Function()? externalDownloads}) {
    final db = AppDatabase.defaults();
    final repository = PodcastRepository(db, FeedFetcher());
    final downloads = DownloadManager(
      db: db,
      directory: () async {
        // На Windows папку для загрузок можно выбрать в настройках.
        if (Platform.isWindows) {
          final custom = await db.setting(DownloadSettings.directory);
          if (custom != null && custom.isNotEmpty) return Directory(custom);
        }
        return getApplicationSupportDirectory();
      },
      isUnmetered: () async {
        final types = await Connectivity().checkConnectivity();
        return types.contains(ConnectivityResult.wifi) || types.contains(ConnectivityResult.ethernet);
      },
      external: externalDownloads,
    );
    final sync = SyncService(db: db, repository: repository);
    late final BookLibrary books;
    final bookSync = BookSync(
      db: db,
      sync: sync,
      booksDirectory: () => books.textDirectory(),
      onFilesChanged: (id) => books.completeDownloaded(id),
      saveCover: (book, bytes) => books.setCoverBytes(book, bytes),
    );
    books = BookLibrary(
      db: db,
      dataDirectory: getApplicationSupportDirectory,
      sync: bookSync,
      requestSync: () => sync.schedule(const Duration(seconds: 2)),
    );
    sync.books = bookSync;
    return AppServices._(db, repository, downloads, sync, books, bookSync);
  }

  final AppDatabase db;
  final PodcastRepository repository;
  final DownloadManager downloads;
  final SyncService sync;

  /// Аудиокниги и текстовые книги.
  final BookLibrary books;
  final BookSync bookSync;

  /// Проверить фиды подписок, синхронизироваться и поставить в очередь
  /// новые эпизоды по правилам автозагрузки. Ошибки отдельных шагов
  /// не мешают остальным.
  Future<void> refreshAndQueue() async {
    try {
      await repository.refreshAll();
    } catch (_) {}
    try {
      await sync.syncNow();
    } catch (_) {}
    try {
      await downloads.autoDownloadAll();
    } catch (_) {}
  }
}
