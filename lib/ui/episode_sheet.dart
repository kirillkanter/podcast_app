import 'package:flutter/material.dart';

import '../data/db/database.dart';
import '../download/download_manager.dart';
import '../player/playback_logic.dart';
import 'app_scope.dart';
import 'download_button.dart';
import 'format.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';

/// Карточка эпизода: название, дата, длительность, кнопки, описание.
Future<void> showEpisodeSheet(BuildContext context, EpisodeWithState item) {
  return showModalBottomSheet<void>(
    context: context,
    // Поверх вкладок и мини-плеера, а не внутри раздела.
    useRootNavigator: true,
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
    final downloads = AppScope.of(context).downloads;

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
              onPressed: () async {
                Navigator.of(context).pop();
                await db.setPlayed(e.id, !played);
                if (!played) await downloads?.onPlayed(e.id);
              },
            ),
            if (downloads != null) _downloadAction(context, downloads),
          ],
        ),
        if (item.download?.status == DownloadStatus.failed && item.download?.error != null) ...[
          const SizedBox(height: 8),
          Text(item.download!.error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        ],
        if (text.isNotEmpty) ...[
          const SizedBox(height: 20),
          // SelectionArea, а не SelectableText: у SelectableText внутри своя
          // прокручиваемая область, она перехватывала жест и описание
          // не прокручивалось вверх.
          SelectionArea(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ],
    );
  }


  Widget _downloadAction(BuildContext context, DownloadManager downloads) {
    final id = item.episode.id;
    final d = item.download;
    void close() => Navigator.of(context).pop();
    return switch (d?.status) {
      null || DownloadStatus.removed => OutlinedButton.icon(
          icon: const Icon(Icons.download_outlined),
          label: const Text('Скачать'),
          onPressed: () {
            downloads.enqueue(id);
            close();
          },
        ),
      DownloadStatus.queued || DownloadStatus.running => OutlinedButton.icon(
          icon: const Icon(Icons.close),
          label: Text(downloadLabel(d) == null ? 'Отменить загрузку' : 'Отменить (${downloadLabel(d)})'),
          onPressed: () {
            downloads.remove(id);
            close();
          },
        ),
      DownloadStatus.completed => OutlinedButton.icon(
          icon: const Icon(Icons.delete_outline),
          label: Text(d!.totalBytes == null ? 'Удалить загрузку' : 'Удалить загрузку (${formatBytes(d.totalBytes!)})'),
          onPressed: () {
            downloads.remove(id);
            close();
          },
        ),
      DownloadStatus.failed => OutlinedButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Повторить загрузку'),
          onPressed: () {
            downloads.retry(id);
            close();
          },
        ),
    };
  }
}
