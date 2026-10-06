import 'package:flutter/material.dart';

import 'now_playing.dart';
import 'player_screen.dart';
import 'podcast_cover.dart';

/// Полоска внизу экрана с текущим эпизодом. Нажатие открывает плеер.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return NowPlayingBuilder(builder: (context, now, audio) {
      final item = now.item;
      if (audio == null || item == null || !now.active) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final duration = item.duration;

      return Material(
        color: theme.colorScheme.surfaceContainerHigh,
        elevation: 3,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StreamBuilder<Duration>(
                stream: audio.positionStream,
                builder: (context, snapshot) {
                  final position = snapshot.data ?? Duration.zero;
                  final value = duration == null || duration.inMilliseconds == 0
                      ? 0.0
                      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
                  return LinearProgressIndicator(value: value, minHeight: 2);
                },
              ),
              InkWell(
                onTap: () => Navigator.of(context).push(PlayerScreen.route()),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  child: Row(
                    children: [
                      PodcastCover(url: item.artUri?.toString(), size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium),
                            if (item.album != null)
                              Text(item.album!, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  )),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Назад на 10 секунд',
                        icon: const Icon(Icons.replay_10),
                        onPressed: audio.rewind,
                      ),
                      if (now.loading)
                        const SizedBox.square(
                          dimension: 48,
                          child: Padding(
                            padding: EdgeInsets.all(14),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        IconButton(
                          tooltip: now.playing ? 'Пауза' : 'Продолжить',
                          icon: Icon(now.playing ? Icons.pause : Icons.play_arrow),
                          onPressed: now.playing ? audio.pause : audio.play,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
