import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../player/playback_logic.dart';
import '../player/podcast_audio_handler.dart';
import 'now_playing.dart';
import 'player_screen.dart';
import 'podcast_cover.dart';
import 'shell.dart';
import 'theme.dart';

void _openPlayer(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(PlayerScreen.route());

/// Мини-плеер телефона на матовом стекле поверх списка. Нажатие открывает плеер.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  static const height = 62.0;

  @override
  Widget build(BuildContext context) {
    return NowPlayingBuilder(builder: (context, now, audio) {
      final item = now.item;
      if (audio == null || item == null || !now.active) return const SizedBox.shrink();
      final c = BcColors.of(context);
      return Glass(
        child: SizedBox(
          height: height,
          child: Stack(children: [
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => _openPlayer(context),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(children: [
                    PodcastCover(url: item.artUri?.toString(), size: 44),
                    const SizedBox(width: 12),
                    Expanded(child: _Titles(item: item)),
                    RoundIconButton(
                      icon: Icons.replay_10_rounded,
                      tooltip: 'Назад на 10 секунд',
                      onPressed: audio.rewind,
                    ),
                    _PlayPause(now: now, audio: audio, size: 44),
                  ]),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _Progress(audio: audio, item: item, color: c.bar),
            ),
          ]),
        ),
      );
    });
  }
}

/// Нижняя панель плеера на компьютере.
class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar({super.key});

  static const height = 78.0;

  @override
  Widget build(BuildContext context) {
    return NowPlayingBuilder(builder: (context, now, audio) {
      final item = now.item;
      if (audio == null || item == null || !now.active) return const SizedBox.shrink();
      final c = BcColors.of(context);
      return Glass(
        radius: 20,
        blur: 28,
        child: SizedBox(
          height: height,
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(children: [
                Expanded(
                  flex: 3,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _openPlayer(context),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(children: [
                        PodcastCover(url: item.artUri?.toString(), size: 52),
                        const SizedBox(width: 12),
                        Expanded(child: _Titles(item: item)),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 5,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      RoundIconButton(
                          icon: Icons.replay_10_rounded, tooltip: 'Назад на 10 секунд', size: 38, onPressed: audio.rewind),
                      const SizedBox(width: 10),
                      _PlayPause(now: now, audio: audio, size: 40),
                      const SizedBox(width: 10),
                      RoundIconButton(
                          icon: Icons.forward_30_rounded,
                          tooltip: 'Вперёд на 30 секунд',
                          size: 38,
                          onPressed: audio.fastForward),
                    ]),
                    _SeekRow(audio: audio, item: item),
                  ]),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 3,
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    _SpeedButton(audio: audio, color: c.ink),
                    const SizedBox(width: 4),
                    RoundIconButton(
                      icon: Icons.playlist_play_rounded,
                      tooltip: 'Очередь воспроизведения',
                      size: 40,
                      onPressed: () => AppShell.openQueue(context),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

class _Titles extends StatelessWidget {
  const _Titles({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.text)),
        if (item.album != null)
          Text(item.album!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
      ],
    );
  }
}

class _PlayPause extends StatelessWidget {
  const _PlayPause({required this.now, required this.audio, required this.size});

  final NowPlaying now;
  final PodcastAudioHandler audio;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    if (now.loading) {
      return SizedBox.square(
        dimension: size,
        child: Padding(
          padding: EdgeInsets.all(size * 0.28),
          child: CircularProgressIndicator(strokeWidth: 2, color: c.bar),
        ),
      );
    }
    return RoundIconButton(
      icon: now.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      tooltip: now.playing ? 'Пауза' : 'Продолжить',
      style: RoundStyle.accent,
      size: size,
      iconSize: size * 0.55,
      onPressed: now.playing ? audio.pause : audio.play,
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.audio, required this.item, required this.color});

  final PodcastAudioHandler audio;
  final MediaItem item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final duration = item.duration;
    return StreamBuilder<Duration>(
      stream: audio.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final value = duration == null || duration.inMilliseconds == 0
            ? 0.0
            : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        return Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value,
            child: SizedBox(height: 3, child: ColoredBox(color: color)),
          ),
        );
      },
    );
  }
}

class _SeekRow extends StatelessWidget {
  const _SeekRow({required this.audio, required this.item});

  final PodcastAudioHandler audio;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final duration = item.duration ?? Duration.zero;
    final small = TextStyle(fontSize: 12, color: c.muted, fontFeatures: const [FontFeature.tabularFigures()]);
    return StreamBuilder<Duration>(
      stream: audio.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final max = duration.inMilliseconds.toDouble();
        return SizedBox(
          height: 24,
          child: Row(children: [
            Text(formatClock(position), style: small),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: max <= 0 ? 0 : position.inMilliseconds.clamp(0, max).toDouble(),
                  max: max <= 0 ? 1 : max,
                  onChanged: max <= 0 ? null : (v) => audio.seek(Duration(milliseconds: v.round())),
                ),
              ),
            ),
            Text(max <= 0 ? '' : '−${formatClock(duration - position)}', style: small),
          ]),
        );
      },
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.audio, required this.color});

  final PodcastAudioHandler audio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: audio.playbackState,
      builder: (context, _) => PopupMenuButton<double>(
        tooltip: 'Скорость',
        initialValue: audio.speed,
        onSelected: audio.setSpeed,
        itemBuilder: (_) => [
          for (final s in playbackSpeeds) PopupMenuItem(value: s, child: Text(formatSpeed(s))),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(formatSpeed(audio.speed),
              style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 14, color: color)),
        ),
      ),
    );
  }
}
