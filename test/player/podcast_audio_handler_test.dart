import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/feed/rss_parser.dart';
import 'package:podcast_app/player/podcast_audio_handler.dart';

const _feed = '''
<rss version="2.0"><channel><title>Подкаст</title>
<item><guid>1</guid><title>Эпизод</title>
  <enclosure url="https://cdn.example.com/1.mp3" type="audio/mpeg"/></item>
</channel></rss>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FakeJustAudio platform;
  late PodcastAudioHandler handler;
  late int episodeId;
  late int podcastId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final saved = await db.saveParsedFeed('https://example.com/feed', parseFeed(_feed));
    podcastId = saved.podcastId;
    episodeId = (await db.watchEpisodes(podcastId).first).single.id;
    platform = FakeJustAudio();
    JustAudioPlatform.instance = platform;
    handler = PodcastAudioHandler(db, player: AudioPlayer(handleAudioSessionActivation: false));
  });

  tearDown(() async {
    await handler.stop();
    await db.close();
  });

  Future<PlaybackState> settled() async {
    await pumpEventQueue();
    return handler.playbackState.value;
  }

  test('состояние «играет» доходит до системного плеера после play и pause', () async {
    await handler.playEpisode(episodeId);
    var state = await settled();
    expect(state.playing, isTrue, reason: 'после запуска эпизода');
    expect(state.processingState, AudioProcessingState.ready);
    expect(state.controls.map((c) => c.action), contains(MediaAction.pause));

    await handler.pause();
    state = await settled();
    expect(state.playing, isFalse, reason: 'после паузы');
    expect(state.controls.map((c) => c.action), contains(MediaAction.play));

    // Именно этот переход ломался: play() не порождает playback event,
    // и состояние оставалось «на паузе», хотя звук шёл.
    await handler.play();
    state = await settled();
    expect(state.playing, isTrue, reason: 'после продолжения');
  });

  test('смена паузы со стороны платформы доходит до интерфейса', () async {
    // Так ведут себя нативные плееры (Windows MediaPlayer, ExoPlayer):
    // они сообщают «играет/не играет» отдельным сообщением, без playback event.
    // Раньше обработчик этого не замечал: кнопка в приложении застревала,
    // а Android не показывал уведомление.
    await handler.playEpisode(episodeId);
    expect((await settled()).playing, isTrue);

    platform.player!.reportPlaying(false);
    expect((await settled()).playing, isFalse, reason: 'платформа сообщила о паузе');

    platform.player!.reportPlaying(true);
    expect((await settled()).playing, isTrue, reason: 'платформа сообщила о воспроизведении');
  });

  test('загруженный эпизод играет из файла, дослушанный — сообщает о конце', () async {
    final played = <int>[];
    final local = PodcastAudioHandler(
      db,
      player: AudioPlayer(handleAudioSessionActivation: false),
      localFile: (id) async => id == episodeId ? '/data/episodes/1.mp3' : null,
      onPlayed: (id) async => played.add(id),
    );
    addTearDown(local.stop);

    await local.playEpisode(episodeId);
    await pumpEventQueue();
    final playlist = platform.lastLoad!.audioSourceMessage as ConcatenatingAudioSourceMessage;
    final source = playlist.children.single as UriAudioSourceMessage;
    expect(source.uri, startsWith('file://'));
    expect(source.uri, endsWith('/data/episodes/1.mp3'));

    platform.player!.complete();
    await pumpEventQueue();
    expect(played, [episodeId]);
    expect((await db.episodeState(episodeId))!.played, isTrue);
  });

  test('дослушанный эпизод уходит в архив, дальше играет следующий из очереди', () async {
    final other = await db.saveParsedFeed('https://example.com/other', parseFeed(_feed.replaceAll('1.mp3', '2.mp3')));
    final nextId = (await db.watchEpisodes(other.podcastId).first).single.id;
    await db.addToQueue(episodeId);
    await db.addToQueue(nextId);

    await handler.playEpisode(episodeId);
    await settled();
    expect(await db.queueIds(), [nextId], reason: 'запущенный эпизод уходит из очереди');

    platform.player!.complete();
    await pumpEventQueue();
    await settled();
    expect((await db.episodeState(episodeId))!.played, isTrue);
    expect(await db.isArchived(episodeId), isTrue);
    expect(handler.currentEpisodeId, nextId);
    expect(handler.mediaItem.value?.id, 'https://cdn.example.com/2.mp3');
    expect(handler.playbackState.value.playing, isTrue);
    expect(await db.queueIds(), isEmpty);
  });

  test('«играть дальше по очереди» выключено — после конца эпизода тишина', () async {
    final other = await db.saveParsedFeed('https://example.com/other', parseFeed(_feed.replaceAll('1.mp3', '2.mp3')));
    final nextId = (await db.watchEpisodes(other.podcastId).first).single.id;
    await db.addToQueue(nextId);
    await db.setSetting(QueueSettings.continuePlayback, 'false');

    await handler.playEpisode(episodeId);
    await settled();
    platform.player!.complete();
    await pumpEventQueue();
    await settled();
    expect(handler.currentEpisodeId, isNull);
    expect(await db.queueIds(), [nextId]);
  });

  test('переключились с недослушанного — он первым в очереди; настройка выключает', () async {
    final other = await db.saveParsedFeed('https://example.com/other', parseFeed(_feed.replaceAll('1.mp3', '2.mp3')));
    final secondId = (await db.watchEpisodes(other.podcastId).first).single.id;

    await handler.playEpisode(episodeId);
    await settled();
    await handler.playEpisode(secondId);
    await settled();
    expect(await db.queueIds(), [episodeId]);

    // Обратно: первый уходит из очереди (играет), второй встаёт в неё.
    await handler.playEpisode(episodeId);
    await settled();
    expect(await db.queueIds(), [secondId]);

    await db.clearQueue();
    await db.setSetting(QueueSettings.requeueInterrupted, 'false');
    await handler.playEpisode(secondId);
    await settled();
    expect(await db.queueIds(), isEmpty);
  });

  test('последний эпизод возвращается в плеер на паузе; «закрыть» его забывает', () async {
    await handler.playEpisode(episodeId);
    await settled();
    expect(await db.setting(PlayerSettings.last), '$episodeId');
    await handler.seek(const Duration(minutes: 3));
    await handler.stop();
    await settled();

    // Как после перезапуска: новый обработчик, плеер пуст.
    final again = PodcastAudioHandler(db, player: AudioPlayer(handleAudioSessionActivation: false));
    addTearDown(again.stop);
    platform.lastLoad = null;
    await again.restoreLast();
    await settled();
    expect(again.currentEpisodeId, episodeId);
    expect(again.mediaItem.value?.title, 'Эпизод');
    expect(again.playbackState.value.playing, isFalse, reason: 'на паузе, а не сразу играет');
    expect(platform.lastLoad?.initialPosition?.inMilliseconds, closeTo(180000, 500));

    await again.close();
    expect(await db.setting(PlayerSettings.last), '');
  });

  test('в уведомлении под названием эпизода — название подкаста', () async {
    await handler.playEpisode(episodeId);
    await settled();
    expect(handler.mediaItem.value?.artist, 'Подкаст');
  });

  test('карточка эпизода для системного плеера', () async {
    await handler.playEpisode(episodeId);
    await settled();
    final item = handler.mediaItem.value!;
    expect(item.title, 'Эпизод');
    expect(item.album, 'Подкаст');
    expect(item.extras?['episodeId'], episodeId);
  });

  test('пауза сохраняет позицию, новый запуск продолжает с неё', () async {
    await handler.playEpisode(episodeId);
    await settled();
    await handler.seek(const Duration(minutes: 3));
    await handler.pause();
    await settled();
    // Плеер досчитывает позицию по часам, поэтому допускаем миллисекунды.
    expect((await db.episodeState(episodeId))!.positionMs, closeTo(180000, 500));

    await handler.stop();
    platform.lastLoad = null;
    await handler.playEpisode(episodeId);
    await settled();
    expect(platform.lastLoad?.initialPosition?.inMilliseconds, closeTo(180000, 500));
  });

  test('скорость сохраняется для подкаста и применяется при запуске', () async {
    await handler.playEpisode(episodeId);
    await settled();
    await handler.setSpeed(1.5);
    expect(await db.podcastSpeed(podcastId), 1.5);

    await handler.stop();
    await handler.playEpisode(episodeId);
    await settled();
    expect(platform.player!.speed, 1.5);
  });
}

/// Платформа just_audio без настоящего звука: хранит состояние и шлёт
/// события так же, как реальные реализации (play не шлёт playback event).
class FakeJustAudio extends JustAudioPlatform with MockPlatformInterfaceMixin {
  FakePlayer? player;
  LoadRequest? lastLoad;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      player = FakePlayer(request.id, this);

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    await player?.dispose(DisposeRequest());
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();
}

class FakePlayer extends AudioPlayerPlatform {
  FakePlayer(super.id, this.platform);

  final FakeJustAudio platform;
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final _data = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _state = ProcessingStateMessage.idle;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  double speed = 1.0;
  Completer<void>? _playing$;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  void _emit() {
    if (_events.isClosed) return;
    _events.add(PlaybackEventMessage(
      processingState: _state,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _position,
      duration: _duration,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  /// Эпизод доигран до конца.
  void complete() {
    _position = _duration ?? Duration.zero;
    _state = ProcessingStateMessage.completed;
    _emit();
  }

  /// Нативный плеер сам сменил состояние (буферизация, системная пауза).
  void reportPlaying(bool playing) {
    _playing = playing;
    _data.add(PlayerDataMessage(playing: playing));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    platform.lastLoad = request;
    _state = ProcessingStateMessage.loading;
    _emit();
    _duration = const Duration(hours: 1);
    _position = request.initialPosition ?? Duration.zero;
    _state = ProcessingStateMessage.ready;
    _emit();
    return LoadResponse(duration: _duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (_playing) return PlayResponse();
    _playing = true;
    // Как у реальных плееров: play завершается только при паузе.
    _playing$ = Completer<void>();
    await _playing$!.future;
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (!_playing) return PauseResponse();
    _playing = false;
    _playing$?.complete();
    _emit();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _position = request.position ?? Duration.zero;
    _emit();
    return SeekResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    speed = request.speed;
    return SetSpeedResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    _playing = false;
    if (!(_playing$?.isCompleted ?? true)) _playing$!.complete();
    _state = ProcessingStateMessage.idle;
    _emit();
    return DisposeResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async => SetVolumeResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async => SetPitchResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async => SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse> setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
      SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
          SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(
          SetAllowsExternalPlaybackRequest request) async =>
      SetAllowsExternalPlaybackResponse();

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
          ConcatenatingInsertAllRequest request) async =>
      ConcatenatingInsertAllResponse();

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
          ConcatenatingRemoveRangeRequest request) async =>
      ConcatenatingRemoveRangeResponse();

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(ConcatenatingMoveRequest request) async =>
      ConcatenatingMoveResponse();

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(
          AudioEffectSetEnabledRequest request) async =>
      AudioEffectSetEnabledResponse();
}
