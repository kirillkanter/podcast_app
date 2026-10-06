import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../player/playback_logic.dart';
import '../player/podcast_audio_handler.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';

/// Полноэкранный плеер.
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const PlayerScreen(),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Свернуть',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: NowPlayingBuilder(builder: (context, now, audio) {
        final item = now.item;
        if (audio == null || item == null || !now.active) {
          return const Center(child: Text('Сейчас ничего не играет'));
        }
        return LayoutBuilder(builder: (context, constraints) {
          final coverSize = math.min(320.0, math.min(constraints.maxWidth - 64, constraints.maxHeight * 0.4));
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [
                  Center(child: PodcastCover(url: item.artUri?.toString(), size: coverSize)),
                  const SizedBox(height: 24),
                  Text(
                    item.title,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (item.album != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      item.album!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _SeekBar(audio: audio, duration: item.duration),
                  const SizedBox(height: 8),
                  _Controls(audio: audio, now: now),
                  const SizedBox(height: 16),
                  _Extras(audio: audio, state: now.state!),
                ],
              ),
            ),
          );
        });
      }),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.audio, required this.duration});

  final PodcastAudioHandler audio;
  final Duration? duration;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// Позиция, пока пользователь тянет ползунок.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = widget.duration;
    final maxMs = (duration?.inMilliseconds ?? 0).toDouble();

    return StreamBuilder<Duration>(
      stream: widget.audio.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? widget.audio.position;
        final shownMs = _dragging ?? position.inMilliseconds.toDouble();
        final shown = Duration(milliseconds: shownMs.round());
        final left = duration == null ? null : duration - shown;

        return Column(
          children: [
            Slider(
              value: maxMs <= 0 ? 0.0 : shownMs.clamp(0.0, maxMs),
              max: maxMs <= 0 ? 1 : maxMs,
              onChanged: maxMs <= 0 ? null : (v) => setState(() => _dragging = v),
              onChangeEnd: maxMs <= 0
                  ? null
                  : (v) {
                      setState(() => _dragging = null);
                      widget.audio.seek(Duration(milliseconds: v.round()));
                    },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatClock(shown), style: theme.textTheme.bodySmall),
                  if (left != null) Text('−${formatClock(left)}', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.audio, required this.now});

  final PodcastAudioHandler audio;
  final NowPlaying now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Назад на 10 секунд',
          iconSize: 40,
          icon: const Icon(Icons.replay_10),
          onPressed: audio.rewind,
        ),
        const SizedBox(width: 24),
        SizedBox.square(
          dimension: 72,
          child: now.loading
              ? const Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(),
                )
              : IconButton.filled(
                  tooltip: now.playing ? 'Пауза' : 'Продолжить',
                  iconSize: 40,
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  ),
                  icon: Icon(now.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: now.playing ? audio.pause : audio.play,
                ),
        ),
        const SizedBox(width: 24),
        IconButton(
          tooltip: 'Вперёд на 30 секунд',
          iconSize: 40,
          icon: const Icon(Icons.forward_30),
          onPressed: audio.fastForward,
        ),
      ],
    );
  }
}

class _Extras extends StatelessWidget {
  const _Extras({required this.audio, required this.state});

  final PodcastAudioHandler audio;
  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        PopupMenuButton<double>(
          tooltip: 'Скорость',
          initialValue: state.speed,
          onSelected: audio.setSpeed,
          itemBuilder: (_) => [
            for (final s in playbackSpeeds)
              PopupMenuItem(value: s, child: Text(formatSpeed(s))),
          ],
          child: _ExtraLabel(icon: Icons.speed, text: formatSpeed(state.speed)),
        ),
        ValueListenableBuilder<SleepTimer?>(
          valueListenable: audio.sleepTimer,
          builder: (context, timer, _) => PopupMenuButton<_SleepChoice>(
            tooltip: 'Таймер сна',
            onSelected: (choice) {
              switch (choice) {
                case _SleepChoice.off:
                  audio.setSleepTimer(null);
                case _SleepChoice.min15:
                  audio.setSleepTimer(const Duration(minutes: 15));
                case _SleepChoice.min30:
                  audio.setSleepTimer(const Duration(minutes: 30));
                case _SleepChoice.min60:
                  audio.setSleepTimer(const Duration(minutes: 60));
              }
            },
            itemBuilder: (_) => [
              if (timer != null) const PopupMenuItem(value: _SleepChoice.off, child: Text('Выключить таймер')),
              const PopupMenuItem(value: _SleepChoice.min15, child: Text('Через 15 минут')),
              const PopupMenuItem(value: _SleepChoice.min30, child: Text('Через 30 минут')),
              const PopupMenuItem(value: _SleepChoice.min60, child: Text('Через час')),
            ],
            child: _ExtraLabel(
              icon: timer == null ? Icons.bedtime_outlined : Icons.bedtime,
              text: _sleepLabel(timer),
            ),
          ),
        ),
      ],
    );
  }

  static String _sleepLabel(SleepTimer? timer) {
    if (timer == null) return 'Таймер сна';
    final left = timer.remaining(DateTime.now());
    final minutes = (left.inSeconds / 60).ceil();
    return 'Ещё $minutes мин';
  }
}

enum _SleepChoice { off, min15, min30, min60 }

class _ExtraLabel extends StatelessWidget {
  const _ExtraLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Text(text),
        ],
      ),
    );
  }
}
