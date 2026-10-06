import 'package:flutter/material.dart';

import '../data/db/database.dart';
import 'format.dart';
import 'podcast_cover.dart';

/// Карточка эпизода: название, дата, длительность, описание.
Future<void> showEpisodeSheet(BuildContext context, Episode episode) {
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
      builder: (context, controller) => _EpisodeDetails(episode: episode, controller: controller),
    ),
  );
}

class _EpisodeDetails extends StatelessWidget {
  const _EpisodeDetails({required this.episode, required this.controller});

  final Episode episode;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = episode;
    final text = htmlToText(e.description ?? e.summary);
    final meta = [
      formatEpisodeDate(e.pubDate),
      formatDuration(e.durationMs),
      if (e.season != null) 'сезон ${e.season}',
      if (e.episodeNumber != null) 'эпизод ${e.episodeNumber}',
    ].where((s) => s.isNotEmpty).join(' · ');

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
        Text(
          'Воспроизведение появится в следующей версии.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        ),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 16),
          SelectableText(text, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }
}
