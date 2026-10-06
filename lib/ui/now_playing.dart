import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../player/podcast_audio_handler.dart';
import 'app_scope.dart';

/// Что сейчас играет.
class NowPlaying {
  const NowPlaying(this.item, this.state);

  static const none = NowPlaying(null, null);

  final MediaItem? item;
  final PlaybackState? state;

  int? get episodeId => item?.extras?['episodeId'] as int?;

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
    return StreamBuilder<MediaItem?>(
      stream: audio.mediaItem,
      builder: (context, item) => StreamBuilder<PlaybackState>(
        stream: audio.playbackState,
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
