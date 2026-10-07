// База, фиды, загрузки и синхронизация — общие для приложения и фоновых
// задач Android (там приложение может быть не запущено).
import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'data/db/database.dart';
import 'data/podcast_repository.dart';
import 'download/download_manager.dart';
import 'feed/feed_fetcher.dart';
import 'sync/sync_service.dart';

class AppServices {
  AppServices._(this.db, this.repository, this.downloads, this.sync);

  /// Открыть базу и создать сервисы. Загрузки не запускаются: это делает
  /// тот, кто ими владеет (приложение или фоновая задача).
  factory AppServices.open() {
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
    );
    final sync = SyncService(db: db, repository: repository);
    return AppServices._(db, repository, downloads, sync);
  }

  final AppDatabase db;
  final PodcastRepository repository;
  final DownloadManager downloads;
  final SyncService sync;

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
