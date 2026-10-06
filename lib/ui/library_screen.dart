import 'dart:async';

import 'package:flutter/material.dart';

import '../data/db/database.dart';
import 'add_feed_dialog.dart';
import 'app_scope.dart';
import 'episode_sheet.dart';
import 'format.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';
import 'podcast_screen.dart';
import 'shell.dart';
import 'theme.dart';

/// Библиотека: лента эпизодов подписок и сетка подписок.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, this.refreshOnStart = true});

  /// Обновить подписки при запуске. В тестах выключено.
  final bool refreshOnStart;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  FeedFilter _filter = FeedFilter.fresh;
  bool _refreshing = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      if (widget.refreshOnStart) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAll(silent: true));
      }
    }
  }

  Future<void> _refreshAll({bool silent = false}) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final summary = await scope.repository.refreshAll();
      await scope.downloads?.autoDownloadAll();
      if (!mounted) return;
      final parts = <String>[
        if (summary.newEpisodes > 0)
          '${summary.newEpisodes} ${plural(summary.newEpisodes, 'новый эпизод', 'новых эпизода', 'новых эпизодов')}',
        if (summary.failed.isNotEmpty) 'не удалось обновить: ${summary.failed.length}',
      ];
      if (parts.isNotEmpty || !silent) {
        final text = parts.isEmpty ? 'Новых эпизодов нет' : parts.join(', ');
        messenger.showSnackBar(SnackBar(content: Text(text[0].toUpperCase() + text.substring(1))));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _add() async {
    final id = await showAddFeedDialog(context);
    if (id == null || !mounted) return;
    unawaited(AppScope.of(context).downloads?.autoDownload(id));
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PodcastScreen(podcastId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final db = AppScope.of(context).db;
    final c = BcColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<List<Podcast>>(
          stream: db.watchSubscribedPodcasts(),
          builder: (context, subs) {
            final podcasts = subs.data;
            return RefreshIndicator(
              onRefresh: _refreshAll,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _header(context)),
                  if (podcasts == null)
                    const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
                  else if (podcasts.isEmpty)
                    const SliverToBoxAdapter(child: _EmptyState())
                  else ...[
                    SliverToBoxAdapter(child: _filters()),
                    _Feed(filter: _filter),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                        child: Text('Подписки', style: sectionTitleStyle(context)),
                      ),
                    ),
                    _SubscriptionGrid(podcasts: podcasts),
                  ],
                  SliverPadding(padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 16)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      child: Row(children: [
        Expanded(child: Text('Библиотека', style: screenTitleStyle(context))),
        _refreshing
            ? const SizedBox.square(
                dimension: 44,
                child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : RoundIconButton(icon: Icons.refresh_rounded, tooltip: 'Обновить все', onPressed: _refreshAll),
        const SizedBox(width: 4),
        RoundIconButton(
          icon: Icons.add_rounded,
          tooltip: 'Добавить по ссылке RSS',
          style: RoundStyle.raised,
          onPressed: _add,
        ),
      ]),
    );
  }

  Widget _filters() {
    final c = BcColors.of(context);
    const labels = {
      FeedFilter.fresh: 'Новые',
      FeedFilter.started: 'Начатые',
      FeedFilter.downloaded: 'Загруженные',
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Row(children: [
        for (final f in FeedFilter.values) ...[
          ChoiceChip(
            label: Text(labels[f]!),
            selected: f == _filter,
            labelStyle: TextStyle(
              fontWeight: f == _filter ? FontWeight.w600 : FontWeight.w500,
              color: f == _filter ? c.onFill : c.text,
            ),
            side: f == _filter ? BorderSide.none : BorderSide(color: c.line),
            onSelected: (_) => setState(() => _filter = f),
          ),
          const SizedBox(width: 8),
        ],
      ]),
    );
  }
}

class _Feed extends StatelessWidget {
  const _Feed({required this.filter});

  final FeedFilter filter;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return StreamBuilder<List<FeedEpisode>>(
      stream: AppScope.of(context).db.watchFeed(filter, limit: 20),
      builder: (context, snapshot) {
        final items = snapshot.data;
        if (items == null) return const SliverToBoxAdapter(child: SizedBox(height: 80));
        if (items.isEmpty) {
          final text = switch (filter) {
            FeedFilter.fresh => 'Всё прослушано. Новые эпизоды появятся здесь.',
            FeedFilter.started => 'Начатых эпизодов нет.',
            FeedFilter.downloaded => 'Загруженных эпизодов нет.',
          };
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(text, style: TextStyle(color: c.muted)),
            ),
          );
        }
        return SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, i) => _FeedRow(item: items[i]),
        );
      },
    );
  }
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.item});

  final FeedEpisode item;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final e = item.episode;
    final position = item.state?.positionMs ?? 0;
    final started = position > 0 && !(item.state?.played ?? false);
    final downloaded = item.download?.status == DownloadStatus.completed;
    final date = formatEpisodeDate(e.pubDate).toLowerCase();
    return InkWell(
      onTap: () => showEpisodeSheet(context, (episode: e, state: item.state, download: item.download)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
        child: Row(children: [
          PodcastCover(url: e.imageUrl ?? item.podcast.imageUrl, size: 56),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                date.isEmpty ? item.podcast.title : '${item.podcast.title} · $date',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
              const SizedBox(height: 3),
              Text(e.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.3)),
              const SizedBox(height: 4),
              Row(children: [
                if (started) ...[
                  ThinProgress(width: 48, value: e.durationMs == null ? 0 : position / e.durationMs!),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(formatLeft(e.durationMs, started ? position : 0),
                      maxLines: 1, style: TextStyle(fontSize: 12, color: c.muted)),
                ),
                if (downloaded) ...[
                  const SizedBox(width: 6),
                  Tooltip(message: 'Загружен', child: Icon(Icons.download_done_rounded, size: 15, color: c.muted)),
                ],
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          _PlayCircle(episodeId: e.id),
        ]),
      ),
    );
  }
}

/// Кнопка «слушать/пауза» в обводке.
class _PlayCircle extends StatelessWidget {
  const _PlayCircle({required this.episodeId});

  final int episodeId;

  @override
  Widget build(BuildContext context) {
    return NowPlayingBuilder(builder: (context, now, audio) {
      if (audio == null) return const SizedBox.shrink();
      final current = now.isEpisode(episodeId);
      if (current && now.loading) {
        return const SizedBox.square(
          dimension: 44,
          child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      final playing = current && now.playing;
      return RoundIconButton(
        icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        tooltip: playing ? 'Пауза' : 'Слушать',
        style: playing ? RoundStyle.accent : RoundStyle.outline,
        onPressed: () => playing ? audio.pause() : audio.playEpisode(episodeId),
      );
    });
  }
}

class _SubscriptionGrid extends StatelessWidget {
  const _SubscriptionGrid({required this.podcasts});

  final List<Podcast> podcasts;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<int, int>>(
      stream: AppScope.of(context).db.watchNewEpisodeCounts(),
      builder: (context, counts) => SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 150,
            mainAxisSpacing: 16,
            crossAxisSpacing: 12,
            childAspectRatio: 0.72,
          ),
          itemCount: podcasts.length,
          itemBuilder: (context, i) {
            final p = podcasts[i];
            final n = counts.data?[p.id] ?? 0;
            return _SubscriptionTile(podcast: p, newCount: n);
          },
        ),
      ),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({required this.podcast, required this.newCount});

  final Podcast podcast;
  final int newCount;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PodcastScreen(podcastId: podcast.id)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(
            builder: (context, box) => Stack(children: [
              PodcastCover(url: podcast.imageUrl, size: box.maxWidth),
              if (newCount > 0) Positioned(top: 6, right: 6, child: CountBadge(count: newCount)),
              if (podcast.lastError != null)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Tooltip(
                    message: 'Ошибка обновления',
                    child: Icon(Icons.error_rounded, size: 20, color: Theme.of(context).colorScheme.error),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        Text(podcast.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 1.25, color: c.text)),
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 72, 32, 32),
      child: Column(children: [
        Icon(Icons.podcasts_rounded, size: 64, color: c.line),
        const SizedBox(height: 16),
        Text('Подписок пока нет', textAlign: TextAlign.center, style: sectionTitleStyle(context)),
        const SizedBox(height: 8),
        Text(
          'Найдите подкаст во вкладке «Поиск» или нажмите «+» вверху и вставьте ссылку на RSS-фид.',
          textAlign: TextAlign.center,
          style: TextStyle(color: c.muted, height: 1.4),
        ),
      ]),
    );
  }
}
