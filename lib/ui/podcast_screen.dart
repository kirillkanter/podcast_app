import 'package:flutter/material.dart';

import '../data/db/database.dart';
import '../data/podcast_repository.dart';
import '../download/download_manager.dart';
import '../feed/models.dart';
import '../platform/open_url.dart';
import 'app_scope.dart';
import 'chapters.dart';
import 'description.dart';
import 'description_view.dart';
import 'download_button.dart';
import 'episode_actions.dart';
import 'episode_sheet.dart';
import 'format.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';
import 'shell.dart';
import 'icons.dart';
import 'theme.dart';

/// Порядок эпизодов на странице подкаста.
enum EpisodeOrder {
  newest('Сначала новые'),
  oldest('Сначала старые');

  const EpisodeOrder(this.label);
  final String label;
}

String _orderKey(int podcastId) => 'podcast.$podcastId.order';

/// «раз в неделю» по датам последних эпизодов; `null`, если не понять.
String? releaseFrequency(List<DateTime?> dates) {
  final sorted = [for (final d in dates) ?d]..sort((a, b) => b.compareTo(a));
  if (sorted.length < 3) return null;
  final recent = sorted.take(11).toList();
  final gaps = [for (var i = 1; i < recent.length; i++) recent[i - 1].difference(recent[i]).inHours / 24]..sort();
  final median = gaps[gaps.length ~/ 2];
  if (median < 1.5) return 'каждый день';
  if (median < 5) return 'несколько раз в неделю';
  if (median < 10) return 'раз в неделю';
  if (median < 18) return 'раз в две недели';
  if (median < 45) return 'раз в месяц';
  return null;
}

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
  Stream<String?>? _order;
  bool _refreshing = false;
  bool _showArchived = false;

  /// Эпизод, открытый в правой колонке на компьютере.
  int? _selected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_podcast == null) {
      final db = AppScope.of(context).db;
      _podcast = db.watchPodcast(widget.podcastId);
      _subscribed = db.watchIsSubscribed(widget.podcastId);
      _episodes = db.watchEpisodesWithState(widget.podcastId);
      _order = db.watchSetting(_orderKey(widget.podcastId));
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
    final c = BcColors.of(context);
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutWidth;
    final hasDownloads = AppScope.of(context).downloads != null;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        actions: [
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (v) {
              if (v == 'refresh') _refresh();
              if (v == 'auto') _chooseAutoDownload(context);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'refresh', child: Text('Обновить')),
              if (hasDownloads) const PopupMenuItem(value: 'auto', child: Text('Автозагрузка…')),
            ],
          ),
          const SizedBox(width: 4),
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
          return StreamBuilder<List<EpisodeWithState>>(
            stream: _episodes,
            builder: (context, eps) => StreamBuilder<String?>(
              stream: _order,
              builder: (context, order) {
                final all = eps.data;
                final ord = switch (order.data) {
                  'oldest' => EpisodeOrder.oldest,
                  'newest' => EpisodeOrder.newest,
                  _ => podcast.podcastType == PodcastType.serial ? EpisodeOrder.oldest : EpisodeOrder.newest,
                };
                final list = all == null ? null : (ord == EpisodeOrder.oldest ? all.reversed.toList() : all);
                return wide ? _wide(context, podcast, list, ord) : _phone(context, podcast, list, ord);
              },
            ),
          );
        },
      ),
    );
  }

  List<EpisodeWithState> _visible(List<EpisodeWithState> all) =>
      _showArchived ? all : all.where((e) => !e.archived).toList();

  Widget _episodesHeader(List<EpisodeWithState> all, EpisodeOrder order, {required bool wide}) {
    return _EpisodesHeader(
      archived: all.where((e) => e.archived).length,
      showArchived: _showArchived,
      order: order,
      wide: wide,
      onToggle: () => setState(() => _showArchived = !_showArchived),
      onOrder: (o) => AppScope.of(context).db.setSetting(_orderKey(widget.podcastId), o.name),
    );
  }

  Widget _phone(BuildContext context, Podcast podcast, List<EpisodeWithState>? all, EpisodeOrder order) {
    final c = BcColors.of(context);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _Header(podcast: podcast, subscribed: _subscribed!, episodes: all ?? const [], wide: false),
          ),
          if (all == null)
            const SliverToBoxAdapter(child: SizedBox.shrink())
          else if (all.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('В фиде нет эпизодов с аудио', textAlign: TextAlign.center),
              ),
            )
          else ...[
            SliverToBoxAdapter(child: _episodesHeader(all, order, wide: false)),
            if (_visible(all).isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  child: Text('Все эпизоды в архиве.', style: TextStyle(color: c.muted)),
                ),
              )
            else
              SliverList.separated(
                itemCount: _visible(all).length,
                separatorBuilder: (_, _) => Divider(height: 1, color: c.divider),
                itemBuilder: (context, i) => _EpisodeTile(item: _visible(all)[i], showsArchived: _showArchived),
              ),
          ],
          SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 24)),
        ],
      ),
    );
  }

  Widget _wide(BuildContext context, Podcast podcast, List<EpisodeWithState>? all, EpisodeOrder order) {
    final c = BcColors.of(context);
    final visible = all == null ? const <EpisodeWithState>[] : _visible(all);
    final selected = visible.where((e) => e.episode.id == _selected).firstOrNull ?? visible.firstOrNull;
    final bottom = MediaQuery.paddingOf(context).bottom + 24;
    final main = CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: _Header(
          podcast: podcast,
          subscribed: _subscribed!,
          episodes: all ?? const [],
          wide: true,
          onAutoDownload: () => _chooseAutoDownload(context),
        ),
      ),
      if (all != null && all.isNotEmpty) ...[
        SliverToBoxAdapter(child: _episodesHeader(all, order, wide: true)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (context, i) => _WideEpisodeRow(
              showsArchived: _showArchived,
              item: visible[i],
              selected: visible[i].episode.id == selected?.episode.id,
              onTap: () => setState(() => _selected = visible[i].episode.id),
            ),
          ),
        ),
      ],
      SliverToBoxAdapter(child: SizedBox(height: bottom)),
    ]);
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 1000 || selected == null) return main;
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: main),
        Container(
          width: (box.maxWidth * 0.3).clamp(320.0, 420.0),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: c.divider))),
          child: _EpisodeAside(key: ValueKey(selected.episode.id), item: selected, bottom: bottom),
        ),
      ]);
    });
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
            BcIcon(BcIcons.globe, size: 16, color: c.ink),
            const SizedBox(width: 5),
            Flexible(
              child: Text(host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.ink)),
            ),
            const SizedBox(width: 3),
            BcIcon(BcIcons.external, size: 14, color: c.ink),
          ]),
        ),
      ),
    );
  }
}

/// Кнопка-«пилюля»: залитая или в обводке.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap, this.icon, this.filled = false, this.iconColor, this.height = 44});

  final String label;
  final VoidCallback? onTap;
  /// `IconData` или [BcIcons].
  final Object? icon;
  final bool filled;
  final Color? iconColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final fg = filled ? c.onFill : c.text;
    return Material(
      color: filled ? c.fill : Colors.transparent,
      shape: StadiumBorder(side: filled ? BorderSide.none : BorderSide(color: c.line, width: 1.5)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: EdgeInsets.fromLTRB(icon == null ? 16 : 12, 0, 16, 0),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              if (icon != null) ...[
                anyIcon(icon!, size: 18, color: iconColor ?? fg),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: fg)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatefulWidget {
  const _Header({
    required this.podcast,
    required this.subscribed,
    required this.episodes,
    required this.wide,
    this.onAutoDownload,
  });

  final Podcast podcast;
  final Stream<bool> subscribed;
  final List<EpisodeWithState> episodes;
  final bool wide;
  final VoidCallback? onAutoDownload;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  bool _expanded = false;

  /// Самый свежий эпизод не из архива.
  EpisodeWithState? get _latest {
    EpisodeWithState? best;
    for (final e in widget.episodes) {
      if (e.archived) continue;
      if (best == null || (e.episode.pubDate?.isAfter(best.episode.pubDate ?? DateTime(0)) ?? false)) best = e;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final p = widget.podcast;
    final description = htmlToText(p.description);
    final scope = AppScope.of(context);
    final category = p.categories.split('\n').where((s) => s.trim().isNotEmpty).firstOrNull;
    final n = widget.episodes.length;
    final stats = [
      ?category,
      if (n > 0) '$n ${plural(n, 'эпизод', 'эпизода', 'эпизодов')}',
      ?releaseFrequency([for (final e in widget.episodes) e.episode.pubDate]),
    ].join(' · ');
    final wide = widget.wide;
    final latest = _latest;

    final title = Text(p.title,
        style: TextStyle(
          fontFamily: displayFont,
          fontWeight: FontWeight.w600,
          fontSize: wide ? 30 : 20,
          height: 1.2,
          letterSpacing: wide ? -0.5 : 0,
        ));
    final author = p.author == null ? null : Text(p.author!, style: TextStyle(fontSize: wide ? 15 : 14, color: c.muted));
    final site = switch (_siteHost(p.link)) {
      final host? => _SiteLink(url: p.link!, host: host),
      null => null,
    };
    final statsText = stats.isEmpty ? null : Text(stats, style: TextStyle(fontSize: 13, color: c.muted));

    final playLatest = latest == null || scope.audio == null
        ? null
        : _Pill(
            label: 'Последний',
            icon: Icons.play_arrow_rounded,
            filled: true,
            height: wide ? 40 : 44,
            onTap: () => scope.audio!.playEpisode(latest.episode.id),
          );
    final subscribe = StreamBuilder<bool>(
      stream: widget.subscribed,
      builder: (context, snapshot) {
        final subscribed = snapshot.data ?? false;
        return subscribed
            ? _Pill(
                label: 'Вы подписаны',
                icon: BcIcons.check,
                iconColor: c.ink,
                height: wide ? 40 : 44,
                onTap: () => scope.repository.setSubscribed(p.id, false),
              )
            : _Pill(
                label: 'Подписаться',
                icon: BcIcons.plus,
                filled: playLatest == null,
                height: wide ? 40 : 44,
                onTap: () async {
                  await scope.repository.setSubscribed(p.id, true);
                  await scope.downloads?.autoDownload(p.id);
                },
              );
      },
    );

    final desc = description.isEmpty
        ? null
        : AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text.rich(
              TextSpan(text: description),
              maxLines: _expanded ? null : (wide ? 2 : 3),
              overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, height: 1.45, color: c.body),
            ),
          ),
          );
    final more = description.length > (wide ? 160 : 120)
        ? Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: c.ink,
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? 'Свернуть' : 'Ещё'),
            ),
          )
        : null;

    final error = p.lastError == null
        ? null
        : Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Последнее обновление не удалось: ${p.lastError}',
              style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
            ),
          );

    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 28, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Обложка привязана к верху: развёрнутое описание не сдвигает её.
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(borderRadius: BorderRadius.circular(22), child: PodcastCover(url: p.imageUrl, size: 168)),
            const SizedBox(width: 24),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ?statsText,
                const SizedBox(height: 6),
                title,
                const SizedBox(height: 6),
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 16, children: [?author, ?site]),
                if (desc != null) ...[
                  const SizedBox(height: 6),
                  ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: desc),
                  ?more,
                ],
                const SizedBox(height: 10),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  ?playLatest,
                  subscribe,
                  if (widget.onAutoDownload != null && scope.downloads != null)
                    _AutoDownloadChip(podcastId: p.id, onTap: widget.onAutoDownload!),
                ]),
              ]),
            ),
          ]),
          ?error,
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(borderRadius: BorderRadius.circular(18), child: PodcastCover(url: p.imageUrl, size: 120)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              title,
              if (author != null) ...[const SizedBox(height: 4), author],
              ?site,
              if (statsText != null) ...[const SizedBox(height: 2), statsText],
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: subscribe),
          if (playLatest != null) ...[const SizedBox(width: 10), Expanded(child: playLatest)],
        ]),
        ?error,
        if (desc != null) ...[const SizedBox(height: 16), desc, ?more],
      ]),
    );
  }
}

/// «Автозагрузка: 1 эпизод ▾».
class _AutoDownloadChip extends StatelessWidget {
  const _AutoDownloadChip({required this.podcastId, required this.onTap});

  final int podcastId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final db = AppScope.of(context).db;
    return StreamBuilder<int?>(
      stream: db.watchPodcastAutoDownloadCount(podcastId),
      builder: (context, own) => StreamBuilder<String?>(
        stream: db.watchSetting(DownloadSettings.autoCount),
        builder: (context, global) {
          final count = own.data ?? int.tryParse(global.data ?? '') ?? 0;
          final label = count <= 0
              ? 'Автозагрузка выключена'
              : 'Автозагрузка: $count ${plural(count, 'эпизод', 'эпизода', 'эпизодов')}';
          return Material(
            color: Colors.transparent,
            shape: StadiumBorder(side: BorderSide(color: c.line, width: 1.5)),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: SizedBox(
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(width: 4),
                    BcIcon(BcIcons.chevronDown, size: 16, color: c.muted),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// «Эпизоды», кнопка показа архива и порядок.
class _EpisodesHeader extends StatelessWidget {
  const _EpisodesHeader({
    required this.archived,
    required this.showArchived,
    required this.order,
    required this.wide,
    required this.onToggle,
    required this.onOrder,
  });

  final int archived;
  final bool showArchived;
  final EpisodeOrder order;
  final bool wide;
  final VoidCallback onToggle;
  final ValueChanged<EpisodeOrder> onOrder;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Padding(
      padding: wide ? const EdgeInsets.fromLTRB(32, 18, 28, 6) : const EdgeInsets.fromLTRB(20, 20, 16, 6),
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
                        BcIcon(showArchived ? BcIcons.eye : BcIcons.eyeOff,
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
        const SizedBox(width: 8),
        PopupMenuButton<EpisodeOrder>(
          tooltip: 'Порядок эпизодов',
          initialValue: order,
          onSelected: onOrder,
          itemBuilder: (_) => [for (final o in EpisodeOrder.values) PopupMenuItem(value: o, child: Text(o.label))],
          child: Container(
            height: 36,
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
            decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(18)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(wide ? order.label : (order == EpisodeOrder.newest ? 'Новые' : 'Старые'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(width: 4),
              BcIcon(BcIcons.chevronDown, size: 16, color: c.muted),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.item, this.showsArchived = false});

  final EpisodeWithState item;
  final bool showsArchived;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final e = item.episode;
    final played = item.state?.played ?? false;
    final positionMs = item.state?.positionMs ?? 0;
    final inProgress = !played && positionMs > 0;
    final dim = played || item.archived;
    final status = downloadLabel(item.download);
    final top = [
      formatEpisodeDate(e.pubDate),
      if (item.archived) 'в архиве',
      ?status,
    ].where((t) => t.isNotEmpty).join(' · ');

    return SwipeableEpisode(
      episode: item.ref,
      showsArchived: showsArchived,
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

/// Строка эпизода на компьютере: нажатие открывает эпизод в правой колонке.
class _WideEpisodeRow extends StatelessWidget {
  const _WideEpisodeRow({required this.item, required this.selected, required this.onTap, this.showsArchived = false});

  final bool showsArchived;

  final EpisodeWithState item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final e = item.episode;
    final played = item.state?.played ?? false;
    final position = item.state?.positionMs ?? 0;
    final inProgress = !played && position > 0;
    final meta = [
      formatEpisodeDate(e.pubDate),
      if (item.archived) 'в архиве',
      ?downloadLabel(item.download),
    ].where((t) => t.isNotEmpty).join(' · ');
    return SwipeableEpisode(
      episode: item.ref,
      showsArchived: showsArchived,
      child: Material(
        color: selected ? c.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          onDoubleTap: () => AppScope.of(context).audio?.playEpisode(e.id),
          child: Opacity(
            opacity: played || item.archived ? 0.55 : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                _PlayCircle(episodeId: e.id),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 3),
                    Text(meta, style: TextStyle(fontSize: 12, color: c.muted)),
                  ]),
                ),
                SizedBox(
                  width: 130,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(played ? 'Прослушан' : formatLeft(e.durationMs, inProgress ? position : 0),
                        style: TextStyle(fontSize: 13, color: c.muted)),
                    if (inProgress && e.durationMs != null) ...[
                      const SizedBox(height: 5),
                      ThinProgress(width: 72, value: position / e.durationMs!),
                    ],
                  ]),
                ),
                const SizedBox(width: 8),
                DownloadButton(episodeId: e.id, download: item.download),
                QueueArchiveButtons(episode: item.ref),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Правая колонка на компьютере: эпизод целиком.
class _EpisodeAside extends StatelessWidget {
  const _EpisodeAside({super.key, required this.item, required this.bottom});

  final EpisodeWithState item;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final e = item.episode;
    final scope = AppScope.of(context);
    final parts = parseDescription(e.description ?? e.summary);
    final size = item.download?.totalBytes ?? e.enclosureLength;
    final meta = [
      formatEpisodeDate(e.pubDate),
      formatDuration(e.durationMs),
      if (size != null && size > 0) formatBytes(size),
    ].where((t) => t.isNotEmpty).join(' · ');
    final ref = item.ref;
    return ListView(
      padding: EdgeInsets.fromLTRB(24, 8, 24, bottom),
      children: [
        if (meta.isNotEmpty) Text(meta, style: TextStyle(fontSize: 12, color: c.muted)),
        const SizedBox(height: 8),
        Text(e.title, style: sectionTitleStyle(context).copyWith(fontSize: 20, height: 1.25)),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (scope.audio != null)
            NowPlayingBuilder(builder: (context, now, audio) {
              final playing = now.isEpisode(e.id) && now.playing;
              return _Pill(
                label: playing ? 'Пауза' : 'Слушать',
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                filled: true,
                height: 36,
                onTap: () => playing ? audio!.pause() : audio!.playEpisode(e.id),
              );
            }),
          _Pill(
            label: item.queued ? 'Из очереди' : 'В очередь',
            icon: item.queued ? BcIcons.queueRemove : BcIcons.queue,
            height: 36,
            onTap: () => EpisodeActions.toggleQueue(context, ref),
          ),
          _Pill(
            label: item.archived ? 'Из архива' : 'В архив',
            icon: item.archived ? BcIcons.unarchive : BcIcons.archive,
            height: 36,
            onTap: () => EpisodeActions.toggleArchive(context, ref),
          ),
        ]),
        const SizedBox(height: 16),
        if (parts.isEmpty)
          Text('Описания нет.', style: TextStyle(color: c.muted))
        else
          DescriptionText(episodeId: e.id, parts: parts),
        FutureBuilder<List<Chapter>>(
          future: ChaptersLoader.instance.load(e),
          builder: (context, s) {
            final chapters = s.data ?? const <Chapter>[];
            if (chapters.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Главы', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
                const SizedBox(height: 4),
                ChaptersList(episodeId: e.id, chapters: chapters, dividers: true),
              ]),
            );
          },
        ),
      ],
    );
  }
}

/// Круглая кнопка «слушать/пауза» в обводке.
class _PlayCircle extends StatelessWidget {
  const _PlayCircle({required this.episodeId});

  final int episodeId;

  @override
  Widget build(BuildContext context) {
    return NowPlayingBuilder(builder: (context, now, audio) {
      if (audio == null) return const SizedBox(width: 36);
      final playing = now.isEpisode(episodeId) && now.playing;
      return RoundIconButton(
        icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        tooltip: playing ? 'Пауза' : 'Слушать',
        size: 36,
        iconSize: 18,
        style: playing ? RoundStyle.accent : RoundStyle.outline,
        onPressed: () => playing ? audio.pause() : audio.playEpisode(episodeId),
      );
    });
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
