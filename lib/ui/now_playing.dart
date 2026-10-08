import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../player/podcast_audio_handler.dart';
import 'app_scope.dart';
import 'icons.dart';

/// Что сейчас играет.
class NowPlaying {
  const NowPlaying(this.item, this.state);

  static const none = NowPlaying(null, null);

  final MediaItem? item;
  final PlaybackState? state;

  int? get episodeId => item?.extras?['episodeId'] as int?;

  /// Играет аудиокнига (а не эпизод).
  int? get bookId => item?.extras?['bookId'] as int?;

  bool get active =>
      item != null && state != null && state!.processingState != AudioProcessingState.idle;

  bool get playing => active && state!.playing;

  bool get loading =>
      active &&
      (state!.processingState == AudioProcessingState.loading ||
          state!.processingState == AudioProcessingState.buffering);

  bool isEpisode(int episodeId) => active && this.episodeId == episodeId;
}

/// Перестраивается при смене эпизода и состояния воспроизведения.
class NowPlayingBuilder extends StatelessWidget {
  const NowPlayingBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, NowPlaying now, PodcastAudioHandler? audio) builder;

  @override
  Widget build(BuildContext context) {
    final audio = AppScope.of(context).audio;
    if (audio == null) return builder(context, NowPlaying.none, null);
    // Начальные значения — сразу из плеера: иначе в первом кадре экран
    // считает, что ничего не играет (плеер книги из-за этого закрывался).
    return StreamBuilder<MediaItem?>(
      stream: audio.mediaItem,
      initialData: audio.mediaItem.value,
      builder: (context, item) => StreamBuilder<PlaybackState>(
        stream: audio.playbackState,
        initialData: audio.playbackState.value,
        builder: (context, state) => builder(context, NowPlaying(item.data, state.data), audio),
      ),
    );
  }
}

/// Кнопка «играть/пауза» для эпизода в списке.
class EpisodePlayButton extends StatelessWidget {
  const EpisodePlayButton({super.key, required this.episodeId, this.size = 24});

  final int episodeId;
  final double size;

  @override
  Widget build(BuildContext context) {
    return NowPlayingBuilder(builder: (context, now, audio) {
      if (audio == null) return const SizedBox.shrink();
      final current = now.isEpisode(episodeId);
      if (current && now.loading) {
        return SizedBox.square(
          dimension: 48,
          child: Center(
            child: SizedBox.square(
              dimension: size * 0.9,
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      final playing = current && now.playing;
      return IconButton(
        iconSize: size,
        tooltip: playing ? 'Пауза' : 'Слушать',
        icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_outline),
        onPressed: () => playing ? audio.pause() : audio.playEpisode(episodeId),
      );
    });
  }
}

/// Значок перемотки с числом секунд из настроек.
class SkipStepIcon extends StatelessWidget {
  const SkipStepIcon({super.key, required this.audio, required this.forward, this.size = 34, this.color});

  final PodcastAudioHandler audio;
  final bool forward;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<(int, int)>(
        valueListenable: audio.skipSteps,
        builder: (context, steps, _) =>
            SkipIcon(forward: forward, seconds: forward ? steps.$2 : steps.$1, size: size, color: color),
      );
}
