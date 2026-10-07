/// Воспроизведение эпизодов.
///
/// Обработчик подключается к audio_service: на Android он даёт фоновое
/// воспроизведение, уведомление и управление с экрана блокировки, на Windows
/// (через audio_service_win) — системную панель мультимедиа и медиа-клавиши.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../data/db/database.dart';
import 'playback_logic.dart';

class PodcastAudioHandler extends BaseAudioHandler with SeekHandler {
  PodcastAudioHandler(
    this._db, {
    AudioPlayer? player,
    Future<String?> Function(int episodeId)? localFile,
    Future<void> Function(int episodeId)? onPlayed,
    Future<void> Function(int episodeId)? beforePlay,
  })  : _player = player ?? AudioPlayer(),
        _localFile = localFile,
        _onPlayed = onPlayed,
        _beforePlay = beforePlay {
    // Нативные плееры сообщают «играет/не играет» отдельным сообщением,
    // которое меняет player.playing, но не порождает playback event.
    // Без подписки на playerStateStream состояние для системы и интерфейса
    // застревало: кнопка в приложении показывала «пауза» при идущем звуке,
    // а Android не показывал уведомление (он ждёт состояния «играет»).
    _player.playbackEventStream.listen(
      (_) => _broadcastState(),
      onError: (Object e, StackTrace _) => _broadcastState(),
    );
    _player.playerStateStream.listen((_) => _broadcastState());
    _player.errorStream.listen((e) {
      _errors.add('Не удалось воспроизвести эпизод: ${e.message ?? 'ошибка ${e.code}'}');
    });
    _player.playingStream.listen((playing) {
      _saveTimer?.cancel();
      if (playing) {
        _touched = true;
        if (!_activated) unawaited(_activate());
        _saveTimer = Timer.periodic(positionSaveInterval, (_) => _savePosition());
      } else {
        _savePosition();
      }
    });
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) _onCompleted();
    });
    unawaited(_loadSkipSteps());
  }

  /// Шаг перемотки (назад, вперёд) в секундах — из настроек.
  final skipSteps = ValueNotifier<(int, int)>((rewindStep.inSeconds, fastForwardStep.inSeconds));

  Future<void> _loadSkipSteps() async {
    try {
      final back = int.tryParse(await _db.setting(PlayerSettings.rewind) ?? '');
      final fwd = int.tryParse(await _db.setting(PlayerSettings.forward) ?? '');
      skipSteps.value = (back ?? skipSteps.value.$1, fwd ?? skipSteps.value.$2);
    } catch (_) {}
  }

  /// Сменить шаг перемотки (настройки).
  Future<void> setSkipSteps(int back, int forward) async {
    skipSteps.value = (back, forward);
    await _db.setSetting(PlayerSettings.rewind, '$back');
    await _db.setSetting(PlayerSettings.forward, '$forward');
  }

  final AppDatabase _db;
  final AudioPlayer _player;

  /// Путь к загруженному файлу эпизода, если он есть.
  final Future<String?> Function(int episodeId)? _localFile;

  /// Вызывается, когда эпизод дослушан до конца (удаление загрузки и т. п.).
  final Future<void> Function(int episodeId)? _onPlayed;

  /// Перед запуском: получить прогресс эпизода с других устройств.
  final Future<void> Function(int episodeId)? _beforePlay;
  final _errors = StreamController<String>.broadcast();

  int? _episodeId;
  int? _podcastId;
  Timer? _saveTimer;

  /// Эпизод запускали (а не только подготовили на паузе при восстановлении):
  /// только тогда он уходит из очереди и становится «последним».
  bool _activated = false;

  /// Позицию меняли слушанием или перемоткой. Пока нет — не записываем её:
  /// иначе восстановленный эпизод перезаписал бы свежий прогресс с другого
  /// устройства старым (или нулём, если плеер ещё не встал на место).
  bool _touched = false;

  /// С какого места эпизод загружен и перематывали ли его вручную.
  Duration _start = Duration.zero;
  bool _seeked = false;
  StreamSubscription<EpisodeState?>? _remoteState;
  Timer? _sleepTimer;

  /// Текущий таймер сна или `null`.
  final sleepTimer = ValueNotifier<SleepTimer?>(null);

  /// Сообщения об ошибках воспроизведения для показа пользователю.
  Stream<String> get errors => _errors.stream;

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<double> get volumeStream => _player.volumeStream;
  double get volume => _player.volume;

  /// Громкость приложения от 0 до 1 (на компьютере — ползунок в плеере).
  Future<void> setVolume(double volume) => _player.setVolume(volume.clamp(0.0, 1.0));
  Duration get position => _player.position;
  double get speed => _player.speed;

  /// id эпизода, который сейчас загружен в плеер.
  int? get currentEpisodeId => _episodeId;

  /// Запускает эпизод с сохранённой позиции или с [at] (таймкод
  /// в описании, глава). Если он уже загружен — продолжает воспроизведение.
  ///
  /// [autoplay] = false — только подготовить на паузе (восстановление
  /// последнего эпизода при запуске приложения).
  Future<void> playEpisode(int episodeId, {Duration? at, bool autoplay = true}) async {
    if (_episodeId == episodeId && _player.processingState != ProcessingState.idle) {
      if (!autoplay) return;
      if (at != null) {
        await seek(at);
        unawaited(_player.play());
      } else {
        await play();
      }
      return;
    }

    await _savePosition();
    final episode = await _db.episodeById(episodeId);
    if (episode == null) return;
    final previous = _episodeId;
    // Прерванный эпизод — в очередь, только если его действительно слушали
    // и переключение сделал человек (а не восстановление при запуске).
    if (autoplay && _activated && previous != null && previous != episodeId) await _requeue(previous);
    final podcast = await _db.podcastById(episode.podcastId);
    // Запуск человеком: сначала узнать, где остановились на другом устройстве.
    if (autoplay && at == null) await _pullProgress(episodeId);
    final state = await _db.episodeState(episodeId);
    final speed = await _db.podcastSpeed(episode.podcastId) ??
        double.tryParse(await _db.setting(PlayerSettings.speed) ?? '') ??
        1.0;

    _episodeId = episodeId;
    _podcastId = episode.podcastId;
    _activated = false;
    _touched = false;
    _seeked = false;
    _watchRemoteState(episodeId);

    final art = episode.imageUrl ?? podcast?.imageUrl;
    final item = MediaItem(
      id: episode.enclosureUrl,
      title: episode.title,
      album: podcast?.title,
      // Под названием эпизода в уведомлении и на экране блокировки —
      // название подкаста, а не автор.
      artist: podcast?.title,
      artUri: art == null ? null : Uri.tryParse(art),
      duration: episode.durationMs == null ? null : Duration(milliseconds: episode.durationMs!),
      extras: {'episodeId': episodeId, 'podcastId': episode.podcastId},
    );
    mediaItem.add(item);

    final start = at ?? resumePosition(
      positionMs: state?.positionMs ?? 0,
      played: state?.played ?? false,
      durationMs: episode.durationMs,
    );
    _start = start;
    if (at != null) _seeked = true;

    try {
      // Загруженный файл играет без интернета; иначе — поток по сети.
      final local = await _localFile?.call(episodeId);
      final duration = local != null
          ? await _player.setFilePath(local, initialPosition: start)
          : await _player.setUrl(episode.enclosureUrl, initialPosition: start);
      // Длительность из файла точнее, чем в фиде.
      if (duration != null && duration != item.duration && _episodeId == episodeId) {
        mediaItem.add(item.copyWith(duration: duration));
      }
    } on PlayerInterruptedException {
      // Пользователь успел запустить другой эпизод.
      return;
    } on PlayerException catch (e) {
      _errors.add('Не удалось загрузить аудио: ${e.message ?? 'ошибка ${e.code}'}');
      return;
    } catch (e) {
      _errors.add('Не удалось загрузить аудио: $e');
      return;
    }

    await _player.setSpeed(speed);
    if (autoplay) {
      // Запуск человеком: отмечаем сразу. Если до этого играл другой
      // эпизод, плеер так и остаётся «играющим» — события о начале
      // воспроизведения не будет.
      _touched = true;
      await _activate();
      unawaited(_player.play());
    }
  }

  /// Вернуть в плеер (на паузе, с сохранённого места) эпизод, который играл
  /// последним — на этом устройстве или на другом.
  Future<void> restoreLast() async {
    if (_player.playing) return;
    final id = int.tryParse(await _db.setting(PlayerSettings.last) ?? '');
    if (id == null || id == _episodeId) return;
    final state = await _db.episodeState(id);
    if (state?.played ?? false) return;
    if (await _db.episodeById(id) == null) return;
    if (_player.playing) return;
    await playEpisode(id, autoplay: false);
  }

  /// Остановить и закрыть плеер насовсем: при следующем запуске
  /// эпизод в мини-плеер не вернётся.
  Future<void> close() async {
    await stop();
    await _db.setSetting(PlayerSettings.last, '');
  }

  @override
  Future<void> play() async {
    final episodeId = _episodeId;
    if (episodeId != null && !_player.playing && _player.processingState == ProcessingState.ready) {
      // Пока здесь стояла пауза, эпизод могли слушать на другом устройстве.
      await _pullProgress(episodeId);
      final state = await _db.episodeState(episodeId);
      if (state != null && !state.played && _episodeId == episodeId && !_player.playing) {
        final target = Duration(milliseconds: state.positionMs);
        if ((target - _player.position).abs() >= const Duration(seconds: 3)) {
          await _player.seek(target);
          _start = target;
        }
      }
    }
    unawaited(_player.play());
  }

  Future<void> _pullProgress(int episodeId) async {
    final hook = _beforePlay;
    if (hook == null) return;
    // Позицию здесь не сохраняем: на паузе она уже записана, а новая
    // запись сделала бы местный прогресс «свежее» прогресса с другого
    // устройства, и он бы проиграл.
    try {
      await hook(episodeId);
    } catch (e) {
      debugPrint('Не удалось получить прогресс: $e');
    }
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _touched = true;
    _seeked = true;
    await _savePosition();
  }

  /// Эпизод начали слушать: он уходит из очереди и запоминается
  /// как последний (после перезапуска вернётся в мини-плеер, другие
  /// устройства подхватят его).
  Future<void> _activate() async {
    final episodeId = _episodeId;
    if (episodeId == null) return;
    _activated = true;
    try {
      await _db.removeFromQueue(episodeId);
      await _db.setSetting(PlayerSettings.last, '$episodeId');
      await _db.setSetting(PlayerSettings.lastAt, DateTime.now().toUtc().toIso8601String());
    } catch (e) {
      debugPrint('Не удалось отметить запуск эпизода: $e');
    }
  }

  /// Прогресс эпизода пришёл с другого устройства, а здесь он стоит на
  /// паузе — встаём на новое место, чтобы не продолжить со старого.
  void _watchRemoteState(int episodeId) {
    unawaited(_remoteState?.cancel());
    _remoteState = _db.watchEpisodeState(episodeId).listen((state) {
      if (state == null || state.dirty || state.played) return;
      if (_episodeId != episodeId || _player.playing) return;
      if (_player.processingState != ProcessingState.ready) return;
      final target = Duration(milliseconds: state.positionMs);
      if ((target - _player.position).abs() < const Duration(seconds: 3)) return;
      _start = target;
      _touched = false;
      unawaited(_player.seek(target));
    });
  }

  @override
  Future<void> rewind() =>
      seek(seekRelative(_player.position, Duration(seconds: -skipSteps.value.$1), _player.duration));

  @override
  Future<void> fastForward() =>
      seek(seekRelative(_player.position, Duration(seconds: skipSteps.value.$2), _player.duration));

  // Кнопки «следующий/предыдущий» на клавиатуре и наушниках перематывают:
  // в подкастах перемотка нужнее, чем переход по очереди.
  @override
  Future<void> skipToNext() => fastForward();

  @override
  Future<void> skipToPrevious() => rewind();

  @override
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    final podcastId = _podcastId;
    if (podcastId != null) await _db.setPodcastSpeed(podcastId, speed);
  }

  @override
  Future<void> stop() async {
    await _savePosition();
    unawaited(_remoteState?.cancel());
    _remoteState = null;
    _episodeId = null;
    _podcastId = null;
    _cancelSleepTimer();
    await _player.stop();
    mediaItem.add(null);
    await super.stop();
  }

  /// Смахнули приложение из списка недавних на Android. Если эпизод играет,
  /// воспроизведение продолжается в фоне (как в других подкаст-плеерах);
  /// если стоит на паузе — плеер закрывается.
  @override
  Future<void> onTaskRemoved() async {
    if (!_player.playing) await stop();
  }

  /// [duration] — через сколько поставить на паузу; `null` — выключить.
  void setSleepTimer(Duration? duration) {
    _cancelSleepTimer();
    if (duration == null) return;
    sleepTimer.value = SleepTimer.at(DateTime.now().add(duration));
    _sleepTimer = Timer(duration, () {
      sleepTimer.value = null;
      pause();
    });
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepTimer.value = null;
  }

  Future<void> _onCompleted() async {
    final episodeId = _episodeId;
    if (episodeId == null) return;
    // Сначала отвязываем эпизод, чтобы stop() не записал конечную позицию.
    _episodeId = null;
    try {
      await _db.setPlayed(episodeId, true);
    } catch (e) {
      debugPrint('Не удалось отметить эпизод прослушанным: $e');
    }
    final next = await _nextFromQueue(episodeId);
    if (next == null) {
      await stop();
    } else {
      // Плеер отпускает файл, но сервис и уведомление остаются:
      // следующий эпизод запустится сразу.
      await _player.stop();
    }
    // После остановки: на Windows файл занят, пока плеер его держит.
    try {
      await _onPlayed?.call(episodeId);
    } catch (e) {
      debugPrint('Ошибка после окончания эпизода: $e');
    }
    if (next != null) {
      await playEpisode(next);
    } else {
      // Дослушан, дальше ничего: возвращать его в мини-плеер не нужно.
      try {
        await _db.setSetting(PlayerSettings.last, '');
      } catch (_) {}
    }
  }

  /// Переключились с недослушанного эпизода — он встаёт первым в очередь,
  /// чтобы к нему было легко вернуться.
  Future<void> _requeue(int episodeId) async {
    try {
      if (await _db.setting(QueueSettings.requeueInterrupted) == 'false') return;
      final state = await _db.episodeState(episodeId);
      if (state?.played ?? false) return;
      if (await _db.isArchived(episodeId)) return;
      await _db.addToQueue(episodeId, next: true);
    } catch (e) {
      debugPrint('Не удалось вернуть эпизод в очередь: $e');
    }
  }

  /// Следующий эпизод очереди, если включено «Играть дальше по очереди».
  Future<int?> _nextFromQueue(int finished) async {
    try {
      if (await _db.setting(QueueSettings.continuePlayback) == 'false') return null;
      return await _db.nextInQueue(exclude: finished);
    } catch (e) {
      debugPrint('Не удалось прочитать очередь: $e');
      return null;
    }
  }

  Future<void> _savePosition() async {
    final episodeId = _episodeId;
    if (episodeId == null) return;
    if (!_touched) return;
    final state = _player.processingState;
    if (state == ProcessingState.idle || state == ProcessingState.loading) return;
    // Плеер не встал на сохранённое место (так бывает на Windows сразу после
    // загрузки), а человек не перематывал: ноль вместо прогресса не пишем.
    final position = _player.position;
    if (!_seeked && _start > const Duration(seconds: 10) && position < const Duration(seconds: 3)) return;
    try {
      await _db.savePosition(episodeId, position);
    } catch (e) {
      debugPrint('Не удалось сохранить позицию: $e');
    }
  }

  void _broadcastState() {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: switch (_player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    ));
  }
}
