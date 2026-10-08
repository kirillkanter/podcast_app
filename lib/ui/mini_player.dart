import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../player/playback_logic.dart';
import '../player/podcast_audio_handler.dart';
import 'books/book_player_screen.dart';
import 'books/book_start.dart';
import 'now_playing.dart';
import 'player_screen.dart';
import 'podcast_cover.dart';
import 'shell.dart';
import 'icons.dart';
import 'theme.dart';
import 'menu.dart';
import 'marquee.dart';

void _openPlayer(BuildContext context, NowPlaying now) => Navigator.of(context, rootNavigator: true)
    .push(now.bookId != null ? BookPlayerScreen.route() : PlayerScreen.route());

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
                onTap: () => _openPlayer(context, now),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(children: [
                    PodcastCover(url: item.artUri?.toString(), size: 44),
                    const SizedBox(width: 12),
                    Expanded(child: _Titles(item: item, running: now.playing)),
                    RoundIconButton(
                      icon: SkipStepIcon(audio: audio, forward: false, size: 26),
                      tooltip: 'Перемотать назад',
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
                    onTap: () => _openPlayer(context, now),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(children: [
                        PodcastCover(url: item.artUri?.toString(), size: 52),
                        const SizedBox(width: 12),
                        Expanded(child: _Titles(item: item, running: now.playing)),
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
                          icon: SkipStepIcon(audio: audio, forward: false, size: 26), tooltip: 'Перемотать назад', size: 38, onPressed: audio.rewind),
                      const SizedBox(width: 10),
                      _PlayPause(now: now, audio: audio, size: 40),
                      const SizedBox(width: 10),
                      RoundIconButton(
                          icon: SkipStepIcon(audio: audio, forward: true, size: 26),
                          tooltip: 'Перемотать вперёд',
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
                    if (now.bookId != null)
                      RoundIconButton(
                        icon: BcIcons.chapters,
                        tooltip: 'Главы и плеер книги',
                        size: 40,
                        onPressed: () => _openPlayer(context, now),
                      )
                    else
                      RoundIconButton(
                        icon: BcIcons.queue,
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
  const _Titles({required this.item, required this.running});

  final MediaItem item;

  /// Играет — длинные названия бегут строкой.
  final bool running;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Marquee(
          text: item.title,
          running: running,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.text),
        ),
        if (item.album != null)
          Marquee(text: item.album!, running: running, style: TextStyle(fontSize: 12, color: c.muted)),
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
      // Книгу после паузы — со сверкой места на других устройствах.
      onPressed: now.playing ? audio.pause : (now.bookId != null ? () => resumeAudioBook(context) : audio.play),
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
      builder: (context, _) => BcMenu<double>(
        tooltip: 'Скорость',
        borderRadius: BorderRadius.circular(18),
        selected: audio.speed,
        onSelected: audio.setSpeed,
        options: [for (final s in playbackSpeeds) MenuOption(s, formatSpeed(s))],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(formatSpeed(audio.speed),
              style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 14, color: color)),
        ),
      ),
    );
  }
}
