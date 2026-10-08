/// Воспроизведение эпизодов.
///
/// Обработчик подключается к audio_service: на Android он даёт фоновое
/// воспроизведение, уведомление и управление с экрана блокировки, на Windows
/// (через audio_service_win) — системную панель мультимедиа и медиа-клавиши.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../books/book_timeline.dart';
import '../books/locator.dart';
import '../data/db/books_dao.dart';
import '../data/db/database.dart';
import 'playback_logic.dart';

class PodcastAudioHandler extends BaseAudioHandler with SeekHandler {
  PodcastAudioHandler(
    this._db, {
    AudioPlayer? player,
    Future<String?> Function(int episodeId)? localFile,
    Future<void> Function(int episodeId)? onPlayed,
    Future<void> Function(int episodeId)? beforePlay,
    this.onBookProgress,
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
        _pausedAt = DateTime.now();
        _savePosition();
        // Пауза в книге — место сразу на сервер (другое устройство может
        // понадобиться через минуту).
        if (_bookId != null) onBookProgress?.call(const Duration(seconds: 3));
      }
    });
    _player.positionStream.listen(_checkChapterEnd);
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

  /// Место в книге изменилось — отправить на сервер через [delay].
  final void Function(Duration delay)? onBookProgress;

  // Аудиокнига.
  int? _bookId;
  Book? _book;
  List<BookTrack> _tracks = const [];
  List<BookChapter> _chapters = const [];
  BookTimeline _timeline = BookTimeline(const [], const []);
  int _track = 0;

  /// Пауза в конце текущей главы (таймер сна «до конца главы»).
  final sleepAtChapterEnd = ValueNotifier<bool>(false);
  int? _sleepChapter;

  /// Главы и файлы книги поменялись (книга запущена, уточнилась длительность).
  final bookChanged = ValueNotifier<int>(0);

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

  /// id книги, которая сейчас загружена в плеер.
  int? get currentBookId => _bookId;
  Book? get currentBook => _book;
  List<BookChapter> get bookChapters => _chapters;
  BookTimeline get bookTimeline => _timeline;

  /// Место от начала книги.
  Duration get bookPosition => Duration(milliseconds: _timeline.globalOf(_track, _player.position.inMilliseconds));

  Stream<Duration> get bookPositionStream =>
      _player.positionStream.map((p) => Duration(milliseconds: _timeline.globalOf(_track, p.inMilliseconds)));

  /// Точное место в книге для закладок и синхронизации.
  AudioLocator get bookLocator => AudioLocator(_track, _player.position.inMilliseconds);

  int get currentChapter => _timeline.chapterAt(bookPosition.inMilliseconds);

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
    _leaveBook();
    final previous = _episodeId;
    // Прерванный эпизод — в очередь, только если его действительно слушали
    // и переключение сделал человек (а не восстановление при запуске).
    if (autoplay && _activated && previous != null && previous != episodeId) await _requeue(previous);
    final podcast = await _db.podcastById(episode.podcastId);

    final token = ++_startToken;
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

    if (autoplay) {
      // Кнопка сразу показывает «играет»; звук начнётся, когда узнаем,
      // где остановились на другом устройстве, и загрузим эпизод.
      _starting = true;
      if (_player.playing) await _player.pause();
      _broadcastState();
      if (at == null) await _pullProgress(episodeId);
    }
    if (token != _startToken) return; // успели запустить другой эпизод
    final state = await _db.episodeState(episodeId);
    final speed = await _db.podcastSpeed(episode.podcastId) ??
        double.tryParse(await _db.setting(PlayerSettings.speed) ?? '') ??
        1.0;

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
      _stopStarting(token);
      _errors.add('Не удалось загрузить аудио: ${e.message ?? 'ошибка ${e.code}'}');
      return;
    } catch (e) {
      _stopStarting(token);
      _errors.add('Не удалось загрузить аудио: $e');
      return;
    }

    await _player.setSpeed(speed);
    if (autoplay) {
      // Пока загружали, нажали паузу или запустили другой эпизод.
      if (token != _startToken || !_starting) return;
      _starting = false;
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
    final last = await _db.setting(PlayerSettings.last) ?? '';
    if (last.startsWith('book:')) {
      final bookId = int.tryParse(last.substring(5));
      if (bookId == null || bookId == _bookId) return;
      final book = await _db.bookById(bookId);
      if (book == null || book.missing || book.kind != BookKind.audio) return;
      if (_player.playing) return;
      await playBook(bookId, autoplay: false);
      return;
    }
    final id = int.tryParse(last);
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

  /// Когда поставили на паузу (для отмотки назад после паузы в книге).
  DateTime? _pausedAt;

  /// Отмотка назад после паузы в книге: чем дольше пауза, тем больше —
  /// чтобы вспомнить, на чём остановились.
  static Duration smartRewind(Duration pause) {
    if (pause < const Duration(seconds: 10)) return Duration.zero;
    if (pause < const Duration(minutes: 5)) return const Duration(seconds: 3);
    if (pause < const Duration(hours: 1)) return const Duration(seconds: 10);
    return const Duration(seconds: 20);
  }

  @override
  Future<void> play() async {
    final episodeId = _episodeId;
    if (_starting) return; // уже запускаемся
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (_bookId != null && pausedAt != null && !_player.playing && _player.processingState == ProcessingState.ready) {
      final back = smartRewind(DateTime.now().difference(pausedAt));
      if (back > Duration.zero && await _db.setting(BookSettings.smartResume) != 'false') {
        await seekBook(bookPosition - back);
      }
    }
    if (episodeId != null && !_player.playing && _player.processingState == ProcessingState.ready) {
      final token = ++_startToken;
      // Кнопка сразу показывает «играет», а пока проверяем прогресс:
      // здесь стояла пауза, эпизод могли слушать на другом устройстве.
      _starting = true;
      _broadcastState();
      await _pullProgress(episodeId);
      if (token != _startToken || !_starting) return; // нажали паузу
      _starting = false;
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
  Future<void> pause() async {
    if (_starting) {
      _starting = false;
      _startToken++;
      _broadcastState();
    }
    await _player.pause();
  }

  /// Нажали play, но звук ещё не пошёл (проверка прогресса, загрузка).
  bool _starting = false;
  int _startToken = 0;

  void _stopStarting(int token) {
    if (token != _startToken || !_starting) return;
    _starting = false;
    _broadcastState();
  }

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
    final bookId = _bookId;
    if (bookId != null) {
      _activated = true;
      try {
        await _db.setSetting(PlayerSettings.last, 'book:$bookId');
        await _db.setSetting(PlayerSettings.lastAt, DateTime.now().toUtc().toIso8601String());
        await _db.markBookOpened(bookId);
      } catch (e) {
        debugPrint('Не удалось отметить запуск книги: $e');
      }
      return;
    }
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
  Future<void> rewind() => _bookId != null
      ? seekBook(bookPosition - Duration(seconds: skipSteps.value.$1))
      : seek(seekRelative(_player.position, Duration(seconds: -skipSteps.value.$1), _player.duration));

  @override
  Future<void> fastForward() => _bookId != null
      ? seekBook(bookPosition + Duration(seconds: skipSteps.value.$2))
      : seek(seekRelative(_player.position, Duration(seconds: skipSteps.value.$2), _player.duration));

  // Кнопки «следующий/предыдущий» на клавиатуре и наушниках перематывают:
  // в подкастах перемотка нужнее, чем переход по очереди.
  @override
  Future<void> skipToNext() => fastForward();

  @override
  Future<void> skipToPrevious() => rewind();

  @override
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    final bookId = _bookId;
    if (bookId != null) {
      await _db.setBookSpeed(bookId, speed);
      return;
    }
    final podcastId = _podcastId;
    if (podcastId != null) await _db.setPodcastSpeed(podcastId, speed);
  }

  @override
  Future<void> stop() async {
    _starting = false;
    _startToken++;
    await _savePosition();
    unawaited(_remoteState?.cancel());
    _remoteState = null;
    _episodeId = null;
    _podcastId = null;
    _leaveBook();
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
    sleepAtChapterEnd.value = false;
    _sleepChapter = null;
  }

  Future<void> _onCompleted() async {
    if (_bookId != null) return _onTrackCompleted();
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
    if (_bookId != null) return _saveBookPosition();
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


  // -------------------------------------------------------------------------
  // Аудиокниги
  // -------------------------------------------------------------------------

  /// Запустить книгу с места [at] или с сохранённого. Место на сервере
  /// интерфейс сверяет заранее (с вопросом человеку), здесь — не сверяем.
  Future<void> playBook(int bookId, {AudioLocator? at, bool autoplay = true}) async {
    if (_bookId == bookId && _player.processingState != ProcessingState.idle && at == null) {
      if (autoplay) await play();
      return;
    }
    final book = await _db.bookById(bookId);
    if (book == null) return;
    final tracks = await _db.tracksOfBook(bookId);
    if (tracks.isEmpty) {
      _errors.add('В книге нет файлов');
      return;
    }

    await _savePosition();
    // Прерванный эпизод — в очередь, как при переключении на другой эпизод.
    final previousEpisode = _episodeId;
    if (autoplay && _activated && previousEpisode != null) await _requeue(previousEpisode);
    unawaited(_remoteState?.cancel());
    _remoteState = null;
    _episodeId = null;
    _podcastId = null;

    final token = ++_startToken;
    _bookId = bookId;
    _book = book;
    _tracks = tracks;
    _chapters = await _db.bookChaptersOf(bookId);
    _rebuildTimeline();
    _activated = false;
    _touched = false;
    _seeked = at != null;
    _cancelSleepTimer();

    final progress = await _db.bookProgress(bookId);
    var target = at ?? AudioLocator.parse(progress?.locator);
    if (target == null && progress != null && progress.positionMs > 0) {
      final l = _timeline.locate(progress.positionMs);
      target = AudioLocator(l.track, l.ms);
    }
    // Книга дослушана — сначала.
    if (target != null && progress != null && progress.percent >= 0.999 && at == null) target = null;
    target ??= const AudioLocator(0, 0);
    if (target.track >= tracks.length) target = AudioLocator(tracks.length - 1, 0);
    _track = target.track;
    _start = Duration(milliseconds: target.ms);
    _publishBookItem();

    if (autoplay) {
      _starting = true;
      if (_player.playing) await _player.pause();
      _broadcastState();
    }
    final ok = await _loadTrack(_track, Duration(milliseconds: target.ms), token);
    if (!ok) {
      _stopStarting(token);
      return;
    }
    await _player.setSpeed(book.speed ?? double.tryParse(await _db.setting(PlayerSettings.speed) ?? '') ?? 1.0);
    if (autoplay) {
      if (token != _startToken || !_starting) return;
      _starting = false;
      _touched = true;
      await _activate();
      unawaited(_player.play());
    }
  }

  void _leaveBook() {
    if (_bookId == null) return;
    _bookId = null;
    _book = null;
    _tracks = const [];
    _chapters = const [];
    _timeline = BookTimeline(const [], const []);
    _track = 0;
    sleepAtChapterEnd.value = false;
    _sleepChapter = null;
    bookChanged.value++;
  }

  void _rebuildTimeline() {
    _timeline = BookTimeline(
      [for (final t in _tracks) t.durationMs],
      [for (final c in _chapters) (trackIdx: c.trackIdx, startMs: c.startMs)],
    );
    bookChanged.value++;
  }

  Future<bool> _loadTrack(int idx, Duration at, int token) async {
    final track = _tracks[idx];
    try {
      final duration = await _player.setFilePath(track.path, initialPosition: at);
      if (token != _startToken && _bookId == null) return false;
      // Длительность из плеера точнее тегов (а у ogg и flac теги её не дают).
      if (duration != null && (duration.inMilliseconds - track.durationMs).abs() > 1000 && _bookId != null) {
        final updated = track.copyWith(durationMs: duration.inMilliseconds);
        _tracks = [..._tracks]..[idx] = updated;
        unawaited(_db.update(_db.bookTracks).replace(updated));
        _rebuildTimeline();
        final total = _timeline.totalMs;
        final book = _book;
        if (book != null && total != book.durationMs) {
          unawaited((_db.update(_db.books)..where((b) => b.id.equals(book.id)))
              .write(BooksCompanion(durationMs: Value(total))));
        }
      }
      _publishBookItem();
      return true;
    } on PlayerInterruptedException {
      return false;
    } on PlayerException catch (e) {
      _errors.add('Не удалось открыть файл книги: ${e.message ?? 'ошибка ${e.code}'}');
      return false;
    } catch (e) {
      _errors.add('Не удалось открыть файл книги: $e');
      return false;
    }
  }

  void _publishBookItem() {
    final book = _book;
    if (book == null) return;
    final chapter = _chapters.isEmpty ? null : _chapters[_timeline.chapterAt(bookPosition.inMilliseconds)];
    final duration = _tracks.isEmpty ? null : Duration(milliseconds: _tracks[_track].durationMs);
    final item = MediaItem(
      id: 'book:${book.id}:$_track',
      title: chapter?.title ?? book.title,
      album: book.title,
      artist: book.author ?? book.title,
      artUri: book.coverPath == null ? null : Uri.file(book.coverPath!),
      duration: duration == null || duration == Duration.zero ? null : duration,
      extras: {'bookId': book.id},
    );
    final current = mediaItem.value;
    if (current == null || current.id != item.id || current.title != item.title || current.duration != item.duration) {
      mediaItem.add(item);
    }
  }

  /// Перейти к месту [position] от начала книги.
  Future<void> seekBook(Duration position) async {
    if (_bookId == null) return;
    var g = position.inMilliseconds;
    if (g < 0) g = 0;
    if (_timeline.totalMs > 0 && g > _timeline.totalMs - 500) g = _timeline.totalMs - 500;
    final l = _timeline.locate(g);
    if (l.track != _track) {
      final wasPlaying = _player.playing;
      _track = l.track;
      final ok = await _loadTrack(l.track, Duration(milliseconds: l.ms), _startToken);
      if (!ok) return;
      _touched = true;
      _seeked = true;
      await _savePosition();
      if (wasPlaying) unawaited(_player.play());
    } else {
      await seek(Duration(milliseconds: l.ms));
    }
    _publishBookItem();
  }

  Future<void> seekToChapter(int idx) async {
    if (_chapters.isEmpty) return;
    await seekBook(Duration(milliseconds: _timeline.chapterStart(idx.clamp(0, _chapters.length - 1))));
  }

  Future<void> nextChapter() async {
    final c = currentChapter;
    if (c + 1 < _timeline.chapterCount) await seekToChapter(c + 1);
  }

  /// В начало главы; если от её начала прошло меньше 3 секунд — к предыдущей.
  Future<void> previousChapter() async {
    final c = currentChapter;
    final into = bookPosition.inMilliseconds - _timeline.chapterStart(c);
    await seekToChapter(into < 3000 && c > 0 ? c - 1 : c);
  }

  /// Таймер сна до конца текущей главы.
  void setSleepAtChapterEnd(bool on) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepTimer.value = null;
    sleepAtChapterEnd.value = on && _bookId != null;
    _sleepChapter = sleepAtChapterEnd.value ? currentChapter : null;
  }

  void _checkChapterEnd(Duration _) {
    if (_bookId == null) return;
    // Название главы в уведомлении — следим за переходом.
    _publishBookItem();
    final sleepChapter = _sleepChapter;
    if (sleepChapter == null || !_player.playing) return;
    final end = _timeline.chapterEnd(sleepChapter);
    if (bookPosition.inMilliseconds >= end - 250 || currentChapter > sleepChapter) {
      _sleepChapter = null;
      sleepAtChapterEnd.value = false;
      unawaited(pause());
    }
  }

  Future<void> _onTrackCompleted() async {
    final bookId = _bookId;
    if (bookId == null) return;
    if (_track + 1 < _tracks.length) {
      _track++;
      _touched = true;
      final ok = await _loadTrack(_track, Duration.zero, _startToken);
      if (ok && _bookId == bookId) {
        await _saveBookPosition();
        unawaited(_player.play());
      }
      return;
    }
    // Книга дослушана.
    try {
      final last = _tracks.length - 1;
      await _db.saveBookProgress(
        bookId,
        locator: AudioLocator(last, _tracks[last].durationMs).encode(),
        positionMs: _timeline.totalMs,
        percent: 1,
      );
      await _db.setBookShelf(bookId, BookShelf.done);
      await _db.setSetting(PlayerSettings.last, '');
      onBookProgress?.call(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('Не удалось отметить книгу прослушанной: $e');
    }
    _leaveBook(); // stop() не должен записать место
    await stop();
  }

  Future<void> _saveBookPosition() async {
    final bookId = _bookId;
    if (bookId == null || !_touched) return;
    final state = _player.processingState;
    if (state == ProcessingState.idle || state == ProcessingState.loading) return;
    final position = _player.position;
    if (!_seeked && _start > const Duration(seconds: 10) && position < const Duration(seconds: 3)) return;
    final global = _timeline.globalOf(_track, position.inMilliseconds);
    try {
      await _db.saveBookProgress(
        bookId,
        locator: AudioLocator(_track, position.inMilliseconds).encode(),
        positionMs: global,
        percent: _timeline.totalMs > 0 ? global / _timeline.totalMs : 0,
      );
      onBookProgress?.call(const Duration(seconds: 60));
    } catch (e) {
      debugPrint('Не удалось сохранить место в книге: $e');
    }
  }

  void _broadcastState() {
    final playing = _player.playing || _starting;
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
      processingState: _starting ? AudioProcessingState.buffering : switch (_player.processingState) {
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
