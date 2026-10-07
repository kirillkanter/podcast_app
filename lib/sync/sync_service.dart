/// Синхронизация подписок и прогресса прослушивания через сервер gPodder.
///
/// Порядок за один проход:
/// 1. регистрация устройства (один раз для аккаунта);
/// 2. отправка локальных изменений подписок, затем получение чужих;
/// 3. отправка позиций и отметок «прослушано», затем получение чужих;
/// 4. очередь и архив — через bcaster.php рядом с oPodSync (в протоколе
///    gPodder их нет). Если этого файла на сервере нет, шаг пропускается.
///
/// Правило конфликтов: неотправленное локальное изменение важнее серверного
/// (оно уйдёт на сервер следующим), иначе применяется последнее действие
/// с сервера. Применённые с сервера изменения не помечаются dirty, чтобы
/// не отправлять их обратно.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/db/database.dart';
import '../data/podcast_repository.dart';
import '../feed/feed_url.dart';
import 'gpodder_client.dart';

/// Ключи настроек синхронизации в таблице app_settings.
abstract final class SyncSettings {
  static const server = 'sync.server';
  static const username = 'sync.username';
  static const password = 'sync.password';
  static const deviceId = 'sync.deviceId';
  static const deviceRegistered = 'sync.deviceRegistered';
  static const subscriptionsSince = 'sync.subscriptionsSince';
  static const episodesSince = 'sync.episodesSince';
  static const lastSync = 'sync.lastSync';
  static const lastError = 'sync.lastError';
  static const stateSince = 'sync.stateSince';

  /// 'true' — сервер не умеет синхронизировать очередь и архив.
  static const stateUnsupported = 'sync.stateUnsupported';

  static const defaultServer = 'https://sync.bcaster.ru';
}

/// Итог одного прохода синхронизации.
class SyncResult {
  const SyncResult({
    this.subscriptionsAdded = 0,
    this.subscriptionsRemoved = 0,
    this.episodesUpdated = 0,
    this.stateUpdated = 0,
    this.feedErrors = const [],
  });

  final int subscriptionsAdded;
  final int subscriptionsRemoved;
  final int episodesUpdated;

  /// Сколько изменений очереди и архива пришло с других устройств.
  final int stateUpdated;

  /// Фиды с сервера, которые не удалось загрузить.
  final List<String> feedErrors;
}

/// Сколько секунд до конца считать «дослушано».
const _playedThresholdSeconds = 15;

class SyncService {
  SyncService({
    required AppDatabase db,
    required PodcastRepository repository,
    http.Client Function()? clientFactory,
    String? deviceCaption,
    String? deviceType,
  })  : _db = db,
        _repository = repository,
        _clientFactory = clientFactory,
        _caption = deviceCaption ?? _defaultCaption(),
        _type = deviceType ?? _defaultType();

  final AppDatabase _db;
  final PodcastRepository _repository;
  final http.Client Function()? _clientFactory;
  final String _caption;
  final String _type;

  /// Идёт ли синхронизация (для индикатора в интерфейсе).
  final syncing = ValueNotifier<bool>(false);

  Future<SyncResult>? _running;
  Timer? _scheduled;

  Future<bool> get isConfigured async =>
      (await _db.setting(SyncSettings.username))?.isNotEmpty == true &&
      (await _db.setting(SyncSettings.password))?.isNotEmpty == true;

  /// Проверяет логин и пароль и сохраняет их. Счётчики «с какого момента»
  /// сбрасываются: первая синхронизация отправит и получит всё.
  Future<void> signIn({required String server, required String username, required String password}) async {
    final client = GpodderClient(
      server: server,
      username: username.trim(),
      password: password,
      client: _clientFactory?.call(),
    );
    try {
      await client.login();
    } finally {
      client.close();
    }
    await _db.setSetting(SyncSettings.server, client.baseUrl);
    await _db.setSetting(SyncSettings.username, username.trim());
    await _db.setSetting(SyncSettings.password, password);
    await _resetProgress();
  }

  /// Выход: забываем логин и пароль. Подписки и прогресс на устройстве остаются.
  Future<void> signOut() async {
    _scheduled?.cancel();
    for (final key in [SyncSettings.username, SyncSettings.password, SyncSettings.lastError]) {
      await _db.setSetting(key, '');
    }
    await _resetProgress();
  }

  /// Синхронизация через [delay], если не придут новые запросы раньше.
  void schedule([Duration delay = const Duration(seconds: 10)]) {
    _scheduled?.cancel();
    _scheduled = Timer(delay, () => unawaited(syncNow().catchError((Object _) => const SyncResult())));
  }

  /// Синхронизировать сейчас. Если синхронизация уже идёт, возвращает её.
  Future<SyncResult> syncNow() {
    return _running ??= _sync().whenComplete(() => _running = null);
  }

  /// Быстро получить прогресс с других устройств — перед запуском
  /// воспроизведения, чтобы не продолжить со старого места и не затереть
  /// свежий прогресс. Только позиции, без подписок и очереди; не дольше
  /// [timeout] (без сети воспроизведение не ждёт).
  Future<void> pullProgress({Duration timeout = const Duration(seconds: 3)}) async {
    try {
      if (!await isConfigured) return;
      await (_running ??= _sync(progressOnly: true).whenComplete(() => _running = null)).timeout(timeout);
    } catch (_) {
      // Нет сети или сервер долго отвечает — играем с того, что знаем.
    }
  }

  void dispose() => _scheduled?.cancel();

  // -------------------------------------------------------------------------

  Future<SyncResult> _sync({bool progressOnly = false}) async {
    final username = await _db.setting(SyncSettings.username);
    final password = await _db.setting(SyncSettings.password);
    if (username == null || username.isEmpty || password == null || password.isEmpty) {
      return const SyncResult();
    }
    final server = await _db.setting(SyncSettings.server) ?? SyncSettings.defaultServer;
    final client = GpodderClient(
      server: server,
      username: username,
      password: password,
      client: _clientFactory?.call(),
    );
    syncing.value = true;
    try {
      final deviceId = await _deviceId();
      if (await _db.setting(SyncSettings.deviceRegistered) != 'true') {
        await client.registerDevice(deviceId, caption: _caption, type: _type);
        await _db.setSetting(SyncSettings.deviceRegistered, 'true');
      }

      if (progressOnly) {
        return SyncResult(episodesUpdated: await _syncEpisodes(client, deviceId));
      }
      final subs = await _syncSubscriptions(client, deviceId);
      final episodes = await _syncEpisodes(client, deviceId);
      final state = await _syncState(client);

      await _db.setSetting(SyncSettings.lastSync, DateTime.now().toIso8601String());
      await _db.setSetting(SyncSettings.lastError, '');
      return SyncResult(
        subscriptionsAdded: subs.added,
        subscriptionsRemoved: subs.removed,
        episodesUpdated: episodes,
        stateUpdated: state,
        feedErrors: subs.errors,
      );
    } on SyncException catch (e) {
      await _db.setSetting(SyncSettings.lastError, e.message);
      rethrow;
    } catch (e) {
      await _db.setSetting(SyncSettings.lastError, 'Ошибка синхронизации: $e');
      rethrow;
    } finally {
      client.close();
      syncing.value = false;
    }
  }

  Future<({int added, int removed, List<String> errors})> _syncSubscriptions(
    GpodderClient client,
    String deviceId,
  ) async {
    // 1. Отправка.
    final startedAt = DateTime.now();
    final dirty = await _db.dirtySubscriptions();
    if (dirty.isNotEmpty) {
      await client.uploadSubscriptionChanges(
        deviceId,
        add: [for (final s in dirty) if (s.subscribed) s.feedUrl],
        remove: [for (final s in dirty) if (!s.subscribed) s.feedUrl],
      );
      await _db.markSubscriptionsSynced(dirty.map((s) => s.podcastId), startedAt);
    }

    // 2. Получение.
    final since = int.tryParse(await _db.setting(SyncSettings.subscriptionsSince) ?? '') ?? 0;
    final changes = await client.subscriptionChanges(deviceId, since);
    final local = await _db.select(_db.podcasts).get();
    final byKey = {for (final p in local) feedKey(p.feedUrl): p};
    final subscribed = {for (final p in await _db.subscribedPodcasts()) p.id};

    var added = 0;
    var removed = 0;
    final errors = <String>[];
    for (final url in changes.add) {
      final known = byKey[feedKey(url)];
      if (known != null) {
        if (!subscribed.contains(known.id)) {
          await _db.applyRemoteSubscription(known.id, true);
          added++;
        }
        continue;
      }
      try {
        final id = await _repository.add(url, subscribe: false);
        await _db.applyRemoteSubscription(id, true);
        added++;
      } on PodcastException catch (e) {
        // Фид сейчас не загрузился (сайт недоступен, сбой сети). Подписку
        // всё равно сохраняем: подкаст появится в библиотеке с ошибкой,
        // а обновление фидов будет пробовать снова. Иначе подписка
        // терялась: сервер второй раз её не пришлёт.
        errors.add('$url: ${e.message}');
        final id = await _db.addPodcastPlaceholder(url, error: e.message);
        await _db.applyRemoteSubscription(id, true);
        added++;
      }
    }
    for (final url in changes.remove) {
      final known = byKey[feedKey(url)];
      if (known != null && subscribed.contains(known.id)) {
        await _db.applyRemoteSubscription(known.id, false);
        removed++;
      }
    }
    await _db.setSetting(SyncSettings.subscriptionsSince, '${changes.timestamp}');
    return (added: added, removed: removed, errors: errors);
  }

  Future<int> _syncEpisodes(GpodderClient client, String deviceId) async {
    // 1. Отправка.
    final startedAt = DateTime.now();
    final dirty = await _db.dirtyEpisodeStates();
    if (dirty.isNotEmpty) {
      await client.uploadEpisodeActions([for (final s in dirty) _toAction(s, deviceId)]);
      await _db.markEpisodeStatesSynced(dirty.map((s) => s.episodeId), startedAt);
    }

    // 2. Получение: по каждому эпизоду берём последнее действие.
    final since = int.tryParse(await _db.setting(SyncSettings.episodesSince) ?? '') ?? 0;
    final result = await client.episodeActions(since);
    final latest = <String, EpisodeAction>{};
    for (final a in result.actions) {
      if (a.action != 'play' && a.action != 'new') continue;
      // Свои же действия, вернувшиеся с сервера, — не новость.
      if (a.device == deviceId) continue;
      final previous = latest[a.episode];
      if (previous == null || _isLater(a, previous)) latest[a.episode] = a;
    }

    var updated = 0;
    for (final a in latest.values) {
      final episode = await _db.findEpisodeByEnclosure(a.episode, feedUrl: a.podcast);
      if (episode == null) continue; // эпизода нет в локальном фиде
      final applied = a.action == 'new'
          ? await _db.applyRemoteEpisodeState(episode.id, positionMs: 0, played: false, changed: a.effectiveTime)
          : await _db.applyRemoteEpisodeState(
              episode.id,
              positionMs: (a.position ?? 0) * 1000,
              played: _isPlayed(a),
              changed: a.effectiveTime,
            );
      if (applied) updated++;
    }
    await _applyRemoteLast(result.actions, deviceId);
    await _db.setSetting(SyncSettings.episodesSince, '${result.timestamp}');
    return updated;
  }

  /// Последний эпизод с другого устройства: если там слушали позже, чем
  /// здесь запускали свой, он становится «последним» и здесь — плеер
  /// покажет его в мини-плеере на паузе с того же места.
  Future<void> _applyRemoteLast(List<EpisodeAction> actions, String deviceId) async {
    EpisodeAction? newest;
    for (final a in actions) {
      if (a.action != 'play' || a.effectiveTime == null || _isPlayed(a) || a.device == deviceId) continue;
      if (newest == null || a.effectiveTime!.isAfter(newest.effectiveTime!)) newest = a;
    }
    if (newest == null) return;
    final at = newest.effectiveTime!;
    final localAt = DateTime.tryParse(await _db.setting(PlayerSettings.lastAt) ?? '');
    if (localAt != null && !at.isAfter(localAt)) return;
    final episode = await _db.findEpisodeByEnclosure(newest.episode, feedUrl: newest.podcast);
    if (episode == null) return;
    await _db.setSetting(PlayerSettings.lastAt, at.toUtc().toIso8601String());
    if (await _db.setting(PlayerSettings.last) != '${episode.id}') {
      await _db.setSetting(PlayerSettings.last, '${episode.id}');
    }
  }

  /// Очередь и архив. Правило конфликтов — более позднее изменение
  /// (по времени изменения на устройстве); неотправленное локальное
  /// изменение новее серверного не перезаписывается.
  Future<int> _syncState(GpodderClient client) async {
    final startedAt = DateTime.now();
    try {
      final since = int.tryParse(await _db.setting(SyncSettings.stateSince) ?? '') ?? 0;
      if (since == 0) {
        // Первая синхронизация очереди на этом устройстве. Если другие
        // устройства уже ведут общую очередь, местная (возможно, давно
        // устаревшая) в неё не подмешивается: очередь берётся с сервера.
        final server = await client.stateChanges(0);
        if (server.items.any((i) => i['kind'] == 'queue')) await _db.dropUnsyncedQueue();
      }
      final dirty = await _db.dirtyStateItems();
      if (dirty.isNotEmpty) {
        await client.uploadState([
          for (final item in dirty)
            {
              'kind': item.kind,
              'podcast': item.feedUrl,
              'episode': item.enclosureUrl,
              'value': ?item.value,
              'removed': item.removed,
              'changed': item.changed.millisecondsSinceEpoch,
            },
        ]);
        for (final kind in ['queue', 'archive']) {
          await _db.markStateSynced(
            kind,
            [for (final item in dirty) if (item.kind == kind) item.episodeId],
            startedAt,
          );
        }
      }

      final changes = await client.stateChanges(since);
      var updated = 0;
      for (final item in changes.items) {
        final kind = item['kind'];
        final episodeUrl = item['episode'];
        final changed = item['changed'];
        if (episodeUrl is! String || changed is! int) continue;
        final podcastUrl = item['podcast'];
        final episode = await _db.findEpisodeByEnclosure(
          episodeUrl,
          feedUrl: podcastUrl is String ? podcastUrl : null,
        );
        if (episode == null) continue; // эпизода нет в локальном фиде
        final removed = item['removed'] == true;
        final at = DateTime.fromMillisecondsSinceEpoch(changed);
        final value = item['value'];
        final applied = switch (kind) {
          'queue' => await _db.applyRemoteQueue(
              episode.id,
              order: value is num ? value.toDouble() : 0,
              removed: removed,
              changed: at,
            ),
          'archive' => await _db.applyRemoteArchive(episode.id, archived: !removed, changed: at),
          _ => false,
        };
        if (applied) updated++;
      }
      await _db.setSetting(SyncSettings.stateSince, '${changes.rev}');
      await _db.setSetting(SyncSettings.stateUnsupported, '');
      return updated;
    } on SyncException catch (e) {
      if (!e.notFound) rethrow;
      // Старый сервер без bcaster.php: подписки и прогресс синхронизируются,
      // очередь и архив остаются на устройстве.
      await _db.setSetting(SyncSettings.stateUnsupported, 'true');
      return 0;
    }
  }

  /// Локальное состояние → действие gPodder. «Прослушано» передаётся как
  /// позиция, равная длительности (так делают AntennaPod и другие клиенты),
  /// «не прослушано с начала» — как действие new.
  static EpisodeAction _toAction(DirtyEpisodeState s, String deviceId) {
    final totalSec = s.durationMs == null ? null : (s.durationMs! / 1000).round();
    if (s.played) {
      final total = (totalSec != null && totalSec > 0) ? totalSec : 1;
      return EpisodeAction(
        podcast: s.feedUrl,
        episode: s.enclosureUrl,
        action: 'play',
        started: 0,
        position: total,
        total: total,
        device: deviceId,
        changed: s.updatedAt,
      );
    }
    if (s.positionMs <= 0) {
      return EpisodeAction(
        podcast: s.feedUrl,
        episode: s.enclosureUrl,
        action: 'new',
        device: deviceId,
        changed: s.updatedAt,
      );
    }
    final position = (s.positionMs / 1000).round();
    return EpisodeAction(
      podcast: s.feedUrl,
      episode: s.enclosureUrl,
      action: 'play',
      started: 0,
      position: position,
      total: totalSec != null && totalSec >= position ? totalSec : position,
      device: deviceId,
      changed: s.updatedAt,
    );
  }

  static bool _isPlayed(EpisodeAction a) {
    final total = a.total;
    final position = a.position;
    if (total == null || position == null || total <= 0) return false;
    return position >= total - min(_playedThresholdSeconds, total ~/ 2);
  }

  static bool _isLater(EpisodeAction a, EpisodeAction b) {
    final ta = a.effectiveTime;
    final tb = b.effectiveTime;
    if (ta == null) return false;
    if (tb == null) return true;
    // При равном времени — более позднее в ответе сервера.
    return !ta.isBefore(tb);
  }

  Future<String> _deviceId() async {
    final existing = await _db.setting(SyncSettings.deviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final suffix = List.generate(8, (_) => random.nextInt(36).toRadixString(36)).join();
    final id = 'bcaster-$_type-$suffix';
    await _db.setSetting(SyncSettings.deviceId, id);
    return id;
  }

  Future<void> _resetProgress() async {
    for (final key in [
      SyncSettings.subscriptionsSince,
      SyncSettings.episodesSince,
      SyncSettings.stateSince,
      SyncSettings.deviceRegistered,
      SyncSettings.lastSync,
    ]) {
      await _db.setSetting(key, '');
    }
    // Первая синхронизация с новым аккаунтом отправит всё, что есть на устройстве.
    await _db.customStatement('UPDATE subscriptions SET dirty = 1');
    await _db.customStatement('UPDATE episode_states SET dirty = 1');
    await _db.customStatement('UPDATE queue_entries SET dirty = 1');
    await _db.customStatement('UPDATE episode_archives SET dirty = 1');
  }

  static String _defaultCaption() {
    if (kIsWeb) return 'Basic Caster';
    if (Platform.isAndroid) return 'Basic Caster (Android)';
    if (Platform.isWindows) return 'Basic Caster (Windows)';
    return 'Basic Caster';
  }

  static String _defaultType() {
    if (kIsWeb) return 'other';
    return Platform.isAndroid || Platform.isIOS ? 'mobile' : 'desktop';
  }
}
