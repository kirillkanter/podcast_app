import 'package:flutter/material.dart';

import '../data/db/database.dart';
import '../data/podcast_repository.dart';
import '../platform/open_url.dart';
import 'app_scope.dart';
import 'download_button.dart';
import 'episode_actions.dart';
import 'episode_sheet.dart';
import 'format.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';
import 'theme.dart';

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
  bool _showArchived = false;

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
    final downloads = AppScope.of(context).downloads;
    try {
      final added = await AppScope.of(context).repository.refresh(widget.podcastId);
      await downloads?.autoDownload(widget.podcastId);
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

  Future<void> _chooseAutoDownload(BuildContext context) async {
    final scope = AppScope.of(context);
    final current = await scope.db.podcastAutoDownloadCount(widget.podcastId);
    if (!context.mounted) return;
    final choice = await showDialog<_AutoChoice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Автозагрузка новых эпизодов'),
        children: [
          for (final option in _AutoChoice.values)
            ListTile(
              leading: Icon(option.count == current ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(option.label),
              onTap: () => Navigator.of(context).pop(option),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await scope.db.setPodcastAutoDownloadCount(widget.podcastId, choice.count);
    await scope.downloads?.autoDownload(widget.podcastId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          if (AppScope.of(context).downloads != null)
            PopupMenuButton<void>(
              tooltip: 'Ещё',
              itemBuilder: (_) => [
                PopupMenuItem<void>(
                  onTap: () => _chooseAutoDownload(context),
                  child: const Text('Автозагрузка…'),
                ),
              ],
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
                    final all = snapshot.data;
                    if (all == null) {
                      return const SliverToBoxAdapter(child: SizedBox.shrink());
                    }
                    if (all.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('В фиде нет эпизодов с аудио', textAlign: TextAlign.center),
                        ),
                      );
                    }
                    final archived = all.where((e) => e.archived).length;
                    final items = _showArchived ? all : all.where((e) => !e.archived).toList();
                    final c = BcColors.of(context);
                    return SliverMainAxisGroup(slivers: [
                      SliverToBoxAdapter(
                        child: _EpisodesHeader(
                          archived: archived,
                          showArchived: _showArchived,
                          onToggle: () => setState(() => _showArchived = !_showArchived),
                        ),
                      ),
                      if (items.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                            child: Text('Все эпизоды в архиве.', style: TextStyle(color: c.muted)),
                          ),
                        )
                      else
                        SliverList.separated(
                          itemCount: items.length,
                          separatorBuilder: (_, _) => Divider(height: 1, color: c.divider),
                          itemBuilder: (context, i) => _EpisodeTile(item: items[i]),
                        ),
                    ]);
                  },
                ),
                SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 24)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Домен сайта подкаста без «www.», если ссылка в RSS похожа на сайт.
String? _siteHost(String? link) {
  final uri = link == null ? null : Uri.tryParse(link);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) return null;
  return uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
}

/// Ссылка на сайт подкаста: откроется в браузере.
class _SiteLink extends StatelessWidget {
  const _SiteLink({required this.url, required this.host});

  final String url;
  final String host;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Tooltip(
      message: 'Открыть сайт подкаста в браузере',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          if (!await openUrl(url)) {
            messenger.showSnackBar(const SnackBar(content: Text('Не удалось открыть ссылку')));
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.public_rounded, size: 16, color: c.ink),
            const SizedBox(width: 5),
            Flexible(
              child: Text(host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.ink)),
            ),
            const SizedBox(width: 3),
            Icon(Icons.north_east_rounded, size: 14, color: c.ink),
          ]),
        ),
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
    final downloads = AppScope.of(context).downloads;

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
                    if (_siteHost(p.link) case final host?) ...[
                      const SizedBox(height: 2),
                      _SiteLink(url: p.link!, host: host),
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
                                onPressed: () async {
                                  await repository.setSubscribed(p.id, true);
                                  await downloads?.autoDownload(p.id);
                                },
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

/// «Эпизоды» и кнопка показа архива.
class _EpisodesHeader extends StatelessWidget {
  const _EpisodesHeader({required this.archived, required this.showArchived, required this.onToggle});

  final int archived;
  final bool showArchived;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 6),
      child: Row(children: [
        Expanded(child: Text('Эпизоды', style: sectionTitleStyle(context))),
        if (archived > 0)
          Semantics(
            toggled: showArchived,
            child: Tooltip(
              message: showArchived ? 'Скрыть эпизоды из архива' : 'Показать эпизоды из архива',
              child: Material(
                color: showArchived ? c.raised : Colors.transparent,
                shape: StadiumBorder(side: BorderSide(color: showArchived ? Colors.transparent : c.line)),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: onToggle,
                  child: SizedBox(
                    height: 36,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(showArchived ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                            size: 16, color: c.text),
                        const SizedBox(width: 6),
                        Text('Архив $archived', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.item});

  final EpisodeWithState item;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final e = item.episode;
    final played = item.state?.played ?? false;
    final positionMs = item.state?.positionMs ?? 0;
    final inProgress = !played && positionMs > 0;
    final dim = played || item.archived;
    final status = downloadLabel(item.download);
    final date = formatEpisodeDate(e.pubDate);
    final top = [
      date,
      if (item.archived) 'в архиве',
      ?status,
    ].where((t) => t.isNotEmpty).join(' · ');

    return SwipeableEpisode(
      episode: item.ref,
      child: InkWell(
        onTap: () => showEpisodeSheet(context, item),
        child: Opacity(
          opacity: dim ? 0.55 : 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (top.isNotEmpty) Text(top, style: TextStyle(fontSize: 12, color: c.muted)),
              const SizedBox(height: 4),
              Text(e.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.3)),
              if (inProgress && e.durationMs != null) ...[
                const SizedBox(height: 8),
                ThinProgress(value: positionMs / e.durationMs!),
              ],
              const SizedBox(height: 6),
              Row(children: [
                _PlayPill(
                  episodeId: e.id,
                  label: played ? 'Прослушан' : formatLeft(e.durationMs, inProgress ? positionMs : 0),
                ),
                const Spacer(),
                DownloadButton(episodeId: e.id, download: item.download),
                QueueArchiveButtons(episode: item.ref, size: 44),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Кнопка «слушать» с оставшимся временем.
class _PlayPill extends StatelessWidget {
  const _PlayPill({required this.episodeId, required this.label});

  final int episodeId;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return NowPlayingBuilder(builder: (context, now, audio) {
      if (audio == null) return const SizedBox(height: 44);
      final current = now.isEpisode(episodeId);
      final playing = current && now.playing;
      final text = playing ? 'Пауза' : (label.isEmpty ? 'Слушать' : label);
      return Tooltip(
        message: playing ? 'Пауза' : 'Слушать',
        child: Material(
          color: playing ? c.fill : Colors.transparent,
          shape: StadiumBorder(side: playing ? BorderSide.none : BorderSide(color: c.line, width: 1.5)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => playing ? audio.pause() : audio.playEpisode(episodeId),
            child: SizedBox(
              height: 36,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (current && now.loading)
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 18, color: playing ? c.onFill : c.text),
                  const SizedBox(width: 6),
                  Text(text,
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500, color: playing ? c.onFill : c.text)),
                ]),
              ),
            ),
          ),
        ),
      );
    });
  }
}

enum _AutoChoice {
  global(null, 'Как в общих настройках'),
  off(0, 'Выключена'),
  one(1, 'Последний эпизод'),
  three(3, '3 последних эпизода'),
  five(5, '5 последних эпизодов');

  const _AutoChoice(this.count, this.label);

  final int? count;
  final String label;
}
