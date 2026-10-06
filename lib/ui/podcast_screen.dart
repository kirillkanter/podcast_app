import 'package:flutter/material.dart';

import '../data/db/database.dart';
import '../data/podcast_repository.dart';
import 'app_scope.dart';
import 'episode_sheet.dart';
import 'format.dart';
import 'mini_player.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';

class PodcastScreen extends StatefulWidget {
  const PodcastScreen({super.key, required this.podcastId});

  final int podcastId;

  @override
  State<PodcastScreen> createState() => _PodcastScreenState();
}

class _PodcastScreenState extends State<PodcastScreen> {
  Stream<Podcast?>? _podcast;
  Stream<bool>? _subscribed;
  Stream<List<EpisodeWithState>>? _episodes;
  bool _refreshing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_podcast == null) {
      final db = AppScope.of(context).db;
      _podcast = db.watchPodcast(widget.podcastId);
      _subscribed = db.watchIsSubscribed(widget.podcastId);
      _episodes = db.watchEpisodesWithState(widget.podcastId);
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final added = await AppScope.of(context).repository.refresh(widget.podcastId);
      messenger.showSnackBar(SnackBar(
        content: Text(added == 0
            ? 'Новых эпизодов нет'
            : '$added ${plural(added, 'новый эпизод', 'новых эпизода', 'новых эпизодов')}'),
      ));
    } on PodcastException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: const MiniPlayer(),
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: StreamBuilder<Podcast?>(
        stream: _podcast,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final podcast = snapshot.data;
          if (podcast == null) return const Center(child: Text('Подкаст не найден'));
          return RefreshIndicator(
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _Header(podcast: podcast, subscribed: _subscribed!),
                ),
                StreamBuilder<List<EpisodeWithState>>(
                  stream: _episodes,
                  builder: (context, snapshot) {
                    final items = snapshot.data;
                    if (items == null) {
                      return const SliverToBoxAdapter(child: SizedBox.shrink());
                    }
                    if (items.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('В фиде нет эпизодов с аудио', textAlign: TextAlign.center),
                        ),
                      );
                    }
                    return SliverList.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                      itemBuilder: (context, i) => _EpisodeTile(item: items[i]),
                    );
                  },
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatefulWidget {
  const _Header({required this.podcast, required this.subscribed});

  final Podcast podcast;
  final Stream<bool> subscribed;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.podcast;
    final description = htmlToText(p.description);
    final repository = AppScope.of(context).repository;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PodcastCover(url: p.imageUrl, size: 112),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.title, style: theme.textTheme.titleLarge),
                    if (p.author != null) ...[
                      const SizedBox(height: 4),
                      Text(p.author!, style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                    ],
                    const SizedBox(height: 12),
                    StreamBuilder<bool>(
                      stream: widget.subscribed,
                      builder: (context, snapshot) {
                        final subscribed = snapshot.data ?? false;
                        return subscribed
                            ? OutlinedButton.icon(
                                onPressed: () => repository.setSubscribed(p.id, false),
                                icon: const Icon(Icons.check),
                                label: const Text('Вы подписаны'),
                              )
                            : FilledButton.icon(
                                onPressed: () => repository.setSubscribed(p.id, true),
                                icon: const Icon(Icons.add),
                                label: const Text('Подписаться'),
                              );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (p.lastError != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Последнее обновление не удалось: ${p.lastError}',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
          if (description.isNotEmpty) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                description,
                maxLines: _expanded ? null : 3,
                overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.item});

  final EpisodeWithState item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = item.episode;
    final played = item.state?.played ?? false;
    final positionMs = item.state?.positionMs ?? 0;
    final inProgress = !played && positionMs > 0;
    final meta = [
      formatEpisodeDate(e.pubDate),
      if (inProgress && e.durationMs != null && e.durationMs! > positionMs)
        'осталось ${formatDuration(e.durationMs! - positionMs)}'
      else
        formatDuration(e.durationMs),
    ].where((s) => s.isNotEmpty).join(' · ');

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 4),
      title: Text(
        e.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: played ? TextStyle(color: theme.colorScheme.onSurfaceVariant) : null,
      ),
      subtitle: meta.isEmpty ? null : Text(meta),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (played)
            Icon(Icons.check, size: 20, color: theme.colorScheme.outline, semanticLabel: 'Прослушан'),
          EpisodePlayButton(episodeId: e.id, size: 32),
        ],
      ),
      onTap: () => showEpisodeSheet(context, item),
    );
  }
}
