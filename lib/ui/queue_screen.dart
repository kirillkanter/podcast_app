import 'package:flutter/material.dart';

import '../data/db/database.dart';
import 'app_scope.dart';
import 'episode_actions.dart';
import 'format.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';
import 'shell.dart';
import 'icons.dart';
import 'theme.dart';

/// Сколько осталось слушать во всей очереди, мс.
int queueLeftMs(List<QueueItem> items) {
  var total = 0;
  for (final q in items) {
    final d = q.episode.durationMs ?? 0;
    final p = (q.state?.played ?? false) ? 0 : (q.state?.positionMs ?? 0);
    total += (d - p).clamp(0, d);
  }
  return total;
}

/// «4 эпизода · 3 ч 41 мин».
String queueSummary(List<QueueItem> items) {
  final n = items.length;
  final left = queueLeftMs(items);
  final count = '$n ${plural(n, 'эпизод', 'эпизода', 'эпизодов')}';
  return left > 0 ? '$count · ${formatDuration(left)}' : count;
}

/// Очередь: что играет сейчас, что дальше, перестановка и удаление.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key, this.showBack = true});

  /// На компьютере очередь — раздел меню, кнопка «назад» не нужна.
  final bool showBack;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  Stream<List<QueueItem>>? _stream;

  /// Порядок после перетаскивания, пока база не прислала новый.
  List<QueueItem>? _optimistic;

  /// Данные из базы, от которых считался [_optimistic].
  List<QueueItem>? _optimisticFrom;
  List<QueueItem>? _latest;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _stream ??= AppScope.of(context).db.watchQueue();
  }

  Future<void> _clear(int count) async {
    final db = AppScope.of(context).db;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить очередь?'),
        content: Text('Из очереди уйдут $count ${plural(count, 'эпизод', 'эпизода', 'эпизодов')}. '
            'Сами эпизоды и их прогресс останутся.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Очистить')),
        ],
      ),
    );
    if (ok == true) await db.clearQueue();
  }

  void _reorder(List<QueueItem> items, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;
    final moved = items[oldIndex];
    setState(() {
      _optimisticFrom = _latest;
      _optimistic = [...items]
        ..removeAt(oldIndex)
        ..insert(newIndex, moved);
    });
    AppScope.of(context).db.moveInQueue(moved.episode.id, newIndex);
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutWidth;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: widget.showBack ? AppBar() : null,
      body: SafeArea(
        top: !widget.showBack,
        bottom: false,
        child: StreamBuilder<List<QueueItem>>(
          stream: _stream,
          builder: (context, snapshot) {
            final fresh = snapshot.data;
            _latest = fresh;
            // Новые данные из базы заменяют временный порядок.
            if (_optimistic != null && !identical(fresh, _optimisticFrom)) _optimistic = null;
            final items = _optimistic ?? fresh;
            return CustomScrollView(slivers: [
              SliverToBoxAdapter(child: _header(context, items, wide)),
              const SliverToBoxAdapter(child: _NowPlayingCard()),
              if (items == null)
                const SliverToBoxAdapter(child: SizedBox(height: 120))
              else if (items.isEmpty)
                SliverToBoxAdapter(child: _empty(c))
              else ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(wide ? 32 : 20, 22, wide ? 32 : 20, 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                      Expanded(child: Text('Далее', style: sectionTitleStyle(context))),
                      Text(queueSummary(items), style: TextStyle(fontSize: 14, color: c.muted)),
                    ]),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: wide ? 22 : 0),
                  sliver: SliverReorderableList(
                    itemCount: items.length,
                    onReorder: (a, b) => _reorder(items, a, b),
                    proxyDecorator: (child, _, _) => Material(
                      color: c.raised,
                      elevation: 6,
                      shadowColor: Colors.black54,
                      borderRadius: BorderRadius.circular(16),
                      child: child,
                    ),
                    itemBuilder: (context, i) => _QueueRow(
                      key: ValueKey(items[i].episode.id),
                      item: items[i],
                      index: i,
                      wide: wide,
                    ),
                  ),
                ),
              ],
              if (!wide) const SliverToBoxAdapter(child: _ContinueToggle(card: true)),
              SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16)),
            ]);
          },
        ),
      ),
    );
  }

  Widget _header(BuildContext context, List<QueueItem>? items, bool wide) {
    final count = items?.length ?? 0;
    final clear = RoundIconButton(
      icon: BcIcons.trash,
      tooltip: 'Очистить очередь',
      style: RoundStyle.raised,
      onPressed: count == 0 ? null : () => _clear(count),
    );
    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
        child: Row(children: [
          Expanded(child: Text('Очередь', style: screenTitleStyle(context))),
          const _ContinueToggle(card: false),
          const SizedBox(width: 12),
          clear,
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 16),
      child: Row(children: [
        Expanded(child: Text('Очередь', style: screenTitleStyle(context))),
        clear,
      ]),
    );
  }

  Widget _empty(BcColors c) => Padding(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
        child: Column(children: [
          BcIcon(BcIcons.queue, size: 56, color: c.line),
          const SizedBox(height: 12),
          Text('Очередь пуста', style: sectionTitleStyle(context)),
          const SizedBox(height: 8),
          Text(
            'Добавляйте эпизоды кнопкой «В очередь» или свайпом вправо по эпизоду в списке.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, height: 1.4),
          ),
        ]),
      );
}

/// «Сейчас играет» над очередью.
class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard();

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutWidth;
    return NowPlayingBuilder(builder: (context, now, audio) {
      final item = now.item;
      if (audio == null || item == null || !now.active) return const SizedBox.shrink();
      final duration = item.duration;
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 10),
        child: Material(
          color: c.card,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              PodcastCover(url: item.artUri?.toString(), size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Сейчас играет', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.ink)),
                  const SizedBox(height: 3),
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 5),
                  StreamBuilder<Duration>(
                    stream: audio.positionStream,
                    builder: (context, pos) {
                      final p = pos.data ?? Duration.zero;
                      final d = duration ?? Duration.zero;
                      return Row(children: [
                        if (d > Duration.zero) ...[
                          ThinProgress(width: 48, value: p.inMilliseconds / d.inMilliseconds),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            [?item.album, if (d > Duration.zero) formatLeft(d.inMilliseconds, p.inMilliseconds)]
                                .where((t) => t.isNotEmpty)
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: c.muted),
                          ),
                        ),
                      ]);
                    },
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              RoundIconButton(
                icon: now.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                tooltip: now.playing ? 'Пауза' : 'Слушать',
                style: RoundStyle.accent,
                onPressed: () => now.playing ? audio.pause() : audio.play(),
              ),
            ]),
          ),
        ),
      );
    });
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({super.key, required this.item, required this.index, required this.wide});

  final QueueItem item;
  final int index;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final e = item.episode;
    final position = (item.state?.played ?? false) ? 0 : (item.state?.positionMs ?? 0);
    final ref = item.ref;
    final handle = ReorderableDragStartListener(
      index: index,
      child: Tooltip(
        message: 'Перетащить, чтобы изменить порядок',
        child: SizedBox.square(
          dimension: 44,
          child: Center(child: BcIcon(BcIcons.drag, size: 20, color: c.muted)),
        ),
      ),
    );
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(item.podcast.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
      const SizedBox(height: 3),
      Text(e.title,
          maxLines: wide ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.3)),
      if (!wide) ...[
        const SizedBox(height: 3),
        Text(formatLeft(e.durationMs, position), style: TextStyle(fontSize: 12, color: c.muted)),
      ],
    ]);

    final Widget row;
    if (wide) {
      row = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(children: [
          handle,
          const SizedBox(width: 6),
          PodcastCover(url: e.imageUrl ?? item.podcast.imageUrl, size: 48),
          const SizedBox(width: 14),
          Expanded(child: text),
          SizedBox(
            width: 110,
            child: Text(formatLeft(e.durationMs, position),
                textAlign: TextAlign.right, style: TextStyle(fontSize: 13, color: c.muted)),
          ),
          const SizedBox(width: 12),
          _PlayButton(episodeId: e.id),
          RoundIconButton(
            icon: BcIcons.close,
            tooltip: 'Убрать из очереди',
            size: 40,
            color: c.muted,
            onPressed: () => EpisodeActions.toggleQueue(context, ref),
          ),
        ]),
      );
    } else {
      row = InkWell(
        onTap: () => AppScope.of(context).audio?.playEpisode(e.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 4, 10),
          child: Row(children: [
            PodcastCover(url: e.imageUrl ?? item.podcast.imageUrl, size: 56),
            const SizedBox(width: 14),
            Expanded(child: text),
            handle,
          ]),
        ),
      );
    }
    // На телефоне строку можно перетащить и долгим нажатием.
    final draggable = wide ? row : ReorderableDelayedDragStartListener(index: index, child: row);
    return SwipeableEpisode(
      episode: ref,
      left: SwipeAction.queue,
      right: SwipeAction.none,
      child: draggable,
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.episodeId});

  final int episodeId;

  @override
  Widget build(BuildContext context) {
    final audio = AppScope.of(context).audio;
    if (audio == null) return const SizedBox.shrink();
    return RoundIconButton(
      icon: Icons.play_arrow_rounded,
      tooltip: 'Слушать сейчас',
      size: 40,
      iconSize: 20,
      style: RoundStyle.outline,
      onPressed: () => audio.playEpisode(episodeId),
    );
  }
}

/// Переключатель «Играть дальше по очереди».
class _ContinueToggle extends StatelessWidget {
  const _ContinueToggle({required this.card});

  /// Отдельной карточкой внизу (телефон) или строкой в заголовке (компьютер).
  final bool card;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final db = AppScope.of(context).db;
    return StreamBuilder<String?>(
      stream: db.watchSetting(QueueSettings.continuePlayback),
      builder: (context, s) {
        final on = s.data != 'false';
        final toggle = Switch(
          value: on,
          onChanged: (v) => db.setSetting(QueueSettings.continuePlayback, '$v'),
        );
        if (!card) {
          return Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Играть дальше по очереди', style: TextStyle(fontSize: 14, color: c.body)),
            const SizedBox(width: 10),
            toggle,
          ]);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 24, 10, 0),
          child: Material(
            color: c.card,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Играть дальше по очереди', style: TextStyle(fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      on ? 'Когда очередь закончится — остановиться' : 'После эпизода — остановиться',
                      style: TextStyle(fontSize: 12, color: c.muted),
                    ),
                  ]),
                ),
                toggle,
              ]),
            ),
          ),
        );
      },
    );
  }
}
