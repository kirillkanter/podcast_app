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
  PodcastAudioHandler(this._db, {AudioPlayer? player}) : _player = player ?? AudioPlayer() {
    // playbackEventStream не срабатывает на play/pause: флаг «играет» в него
    // не входит, а поток пропускает повторяющиеся события. Без второй подписки
    // системный плеер и кнопки в приложении не узнают о смене паузы, а Android
    // не показывает уведомление (он ждёт состояния «играет»).
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
        _saveTimer = Timer.periodic(positionSaveInterval, (_) => _savePosition());
      } else {
        _savePosition();
      }
    });
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) _onCompleted();
    });
  }

  final AppDatabase _db;
  final AudioPlayer _player;
  final _errors = StreamController<String>.broadcast();

  int? _episodeId;
  int? _podcastId;
  Timer? _saveTimer;
  Timer? _sleepTimer;

  /// Текущий таймер сна или `null`.
  final sleepTimer = ValueNotifier<SleepTimer?>(null);

  /// Сообщения об ошибках воспроизведения для показа пользователю.
  Stream<String> get errors => _errors.stream;

  Stream<Duration> get positionStream => _player.positionStream;
  Duration get position => _player.position;
  double get speed => _player.speed;

  /// id эпизода, который сейчас загружен в плеер.
  int? get currentEpisodeId => _episodeId;

  /// Запускает эпизод с сохранённой позиции. Если он уже загружен —
  /// продолжает воспроизведение.
  Future<void> playEpisode(int episodeId) async {
    if (_episodeId == episodeId && _player.processingState != ProcessingState.idle) {
      unawaited(_player.play());
      return;
    }

    await _savePosition();
    final episode = await _db.episodeById(episodeId);
    if (episode == null) return;
    final podcast = await _db.podcastById(episode.podcastId);
    final state = await _db.episodeState(episodeId);
    final speed = await _db.podcastSpeed(episode.podcastId) ?? 1.0;

    _episodeId = episodeId;
    _podcastId = episode.podcastId;

    final art = episode.imageUrl ?? podcast?.imageUrl;
    final item = MediaItem(
      id: episode.enclosureUrl,
      title: episode.title,
      album: podcast?.title,
      artist: podcast?.author ?? podcast?.title,
      artUri: art == null ? null : Uri.tryParse(art),
      duration: episode.durationMs == null ? null : Duration(milliseconds: episode.durationMs!),
      extras: {'episodeId': episodeId, 'podcastId': episode.podcastId},
    );
    mediaItem.add(item);

    final start = resumePosition(
      positionMs: state?.positionMs ?? 0,
      played: state?.played ?? false,
      durationMs: episode.durationMs,
    );

    try {
      final duration = await _player.setUrl(episode.enclosureUrl, initialPosition: start);
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
    unawaited(_player.play());
  }

  @override
  Future<void> play() async => unawaited(_player.play());

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    await _savePosition();
  }

  @override
  Future<void> rewind() => seek(seekRelative(_player.position, -rewindStep, _player.duration));

  @override
  Future<void> fastForward() =>
      seek(seekRelative(_player.position, fastForwardStep, _player.duration));

  // Кнопки «следующий/предыдущий» на клавиатуре и наушниках перематывают:
  // очереди пока нет, а перемотка в подкастах нужнее.
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
    _episodeId = null;
    _podcastId = null;
    _cancelSleepTimer();
    await _player.stop();
    mediaItem.add(null);
    await super.stop();
  }

  /// Смахнули приложение из списка недавних на Android.
  @override
  Future<void> onTaskRemoved() => stop();

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
    await stop();
  }

  Future<void> _savePosition() async {
    final episodeId = _episodeId;
    if (episodeId == null) return;
    final state = _player.processingState;
    if (state == ProcessingState.idle || state == ProcessingState.loading) return;
    try {
      await _db.savePosition(episodeId, _player.position);
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
