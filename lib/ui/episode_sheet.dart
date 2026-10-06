import 'package:flutter/material.dart';

import '../data/db/database.dart';
import '../player/playback_logic.dart';
import 'app_scope.dart';
import 'format.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';

/// Карточка эпизода: название, дата, длительность, кнопки, описание.
Future<void> showEpisodeSheet(BuildContext context, EpisodeWithState item) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => _EpisodeDetails(item: item, controller: controller),
    ),
  );
}

class _EpisodeDetails extends StatelessWidget {
  const _EpisodeDetails({required this.item, required this.controller});

  final EpisodeWithState item;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = item.episode;
    final played = item.state?.played ?? false;
    final positionMs = item.state?.positionMs ?? 0;
    final text = htmlToText(e.description ?? e.summary);
    final meta = [
      formatEpisodeDate(e.pubDate),
      formatDuration(e.durationMs),
      if (e.season != null) 'сезон ${e.season}',
      if (e.episodeNumber != null) 'эпизод ${e.episodeNumber}',
    ].where((s) => s.isNotEmpty).join(' · ');
    final db = AppScope.of(context).db;

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (e.imageUrl != null) ...[
              PodcastCover(url: e.imageUrl, size: 64),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title, style: theme.textTheme.titleMedium),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(meta, style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            NowPlayingBuilder(builder: (context, now, audio) {
              if (audio == null) return const SizedBox.shrink();
              final playing = now.isEpisode(e.id) && now.playing;
              final label = playing
                  ? 'Пауза'
                  : (!played && positionMs > 0 ? 'Продолжить с ${formatClock(Duration(milliseconds: positionMs))}' : 'Слушать');
              return FilledButton.icon(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                label: Text(label),
                onPressed: () {
                  if (playing) {
                    audio.pause();
                  } else {
                    audio.playEpisode(e.id);
                    Navigator.of(context).pop();
                  }
                },
              );
            }),
            OutlinedButton.icon(
              icon: Icon(played ? Icons.remove_done : Icons.done),
              label: Text(played ? 'Снять отметку' : 'Отметить прослушанным'),
              onPressed: () {
                db.setPlayed(e.id, !played);
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 20),
          SelectableText(text, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }

}
