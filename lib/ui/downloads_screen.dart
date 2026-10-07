import 'package:flutter/material.dart';

import '../data/db/database.dart';
import '../download/download_manager.dart';
import 'app_scope.dart';
import 'download_button.dart';
import 'format.dart';
import 'icons.dart';
import 'podcast_cover.dart';
import 'shell.dart';
import 'theme.dart';

/// Загрузки: занятое место, что качается и что уже на устройстве.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  Stream<List<DownloadWithEpisode>>? _list;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _list ??= AppScope.of(context).db.watchDownloadList();
  }

  Future<void> _removePlayed() async {
    final manager = AppScope.of(context).downloads!;
    final messenger = ScaffoldMessenger.of(context);
    final count = await manager.removePlayed();
    messenger.showSnackBar(SnackBar(
      content: Text(count == 0 ? 'Прослушанных загрузок нет' : 'Удалено файлов: $count'),
    ));
  }

  Future<void> _removeAll(List<DownloadWithEpisode> done) async {
    final manager = AppScope.of(context).downloads!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить все загрузки?'),
        content: Text('С устройства удалятся ${done.length} '
            '${plural(done.length, 'файл', 'файла', 'файлов')}. Эпизоды останутся, их можно слушать по сети.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    for (final d in done) {
      await manager.remove(d.download.episodeId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutWidth;
    final side = wide ? 32.0 : 20.0;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<List<DownloadWithEpisode>>(
          stream: _list,
          builder: (context, snapshot) {
            final items = snapshot.data ?? const [];
            final active = [
              for (final i in items)
                if (i.download.status == DownloadStatus.running ||
                    i.download.status == DownloadStatus.queued ||
                    i.download.status == DownloadStatus.failed)
                  i,
            ];
            final done = [for (final i in items) if (i.download.status == DownloadStatus.completed) i];
            return CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(side, wide ? 24 : 16, side - 8, 12),
                  child: Row(children: [
                    Expanded(child: Text('Загрузки', style: screenTitleStyle(context))),
                    RoundIconButton(
                      icon: BcIcons.settings,
                      tooltip: 'Настройки загрузок',
                      style: RoundStyle.raised,
                      onPressed: () => AppShell.openSettings(context),
                    ),
                  ]),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: wide ? side : 16),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: _SpaceCard(done: done, onClear: done.isEmpty ? null : () => _removeAll(done)),
                    ),
                  ),
                ),
              ),
              if (active.isNotEmpty) ...[
                _Title(side: side, text: 'Загружается'),
                SliverList.list(children: [for (final i in active) _ActiveRow(item: i, side: side)]),
              ],
              _Title(
                side: side,
                text: 'Загружено',
                action: done.isEmpty ? null : ('Удалить прослушанные', _removePlayed),
              ),
              if (done.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(side, 8, side, 16),
                    child: Text(
                      'Загруженных эпизодов нет. Нажмите значок загрузки у эпизода или включите автозагрузку в настройках.',
                      style: TextStyle(color: c.muted, height: 1.4),
                    ),
                  ),
                )
              else
                SliverList.list(children: [for (final i in done) _DoneRow(item: i, side: side)]),
              SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16)),
            ]);
          },
        ),
      ),
    );
  }
}

/// Сколько места занято и правила загрузки.
class _SpaceCard extends StatelessWidget {
  const _SpaceCard({required this.done, required this.onClear});

  final List<DownloadWithEpisode> done;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final db = AppScope.of(context).db;
    final bytes = done.fold<int>(0, (sum, i) => sum + (i.download.totalBytes ?? 0));
    final n = done.length;
    return StreamBuilder<String?>(
      stream: db.watchSetting(DownloadSettings.limitMb),
      builder: (context, limit) => StreamBuilder<String?>(
        stream: db.watchSetting(DownloadSettings.wifiOnly),
        builder: (context, wifi) => StreamBuilder<String?>(
          stream: db.watchSetting(DownloadSettings.deletePlayed),
          builder: (context, delete) {
            final limitMb = int.tryParse(limit.data ?? '') ?? 0;
            final limitBytes = limitMb * 1024 * 1024;
            final rules = [
              if (wifi.data != 'false') 'Автозагрузка только по Wi‑Fi',
              if (delete.data != 'false') 'прослушанные удаляются',
            ].join(' · ');
            return Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
              decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(18)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Text(n == 0 ? '0 МБ' : formatBytes(bytes),
                      style: const TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w500, fontSize: 20)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      [
                        if (limitBytes > 0) 'из лимита ${formatBytes(limitBytes)}',
                        '$n ${plural(n, 'эпизод', 'эпизода', 'эпизодов')}',
                      ].join(' · '),
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 13, color: c.muted),
                    ),
                  ),
                ]),
                if (limitBytes > 0) ...[
                  const SizedBox(height: 10),
                  ThinProgress(value: bytes / limitBytes, height: 6),
                ],
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: Text(rules, style: TextStyle(fontSize: 12, color: c.muted))),
                  if (onClear != null)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      onPressed: onClear,
                      child: const Text('Очистить'),
                    ),
                ]),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.side, required this.text, this.action});

  final double side;
  final String text;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, 22, side - 8, 4),
        child: Row(children: [
          Expanded(child: Text(text, style: sectionTitleStyle(context))),
          if (action != null)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: c.text),
              onPressed: action!.$2,
              child: Text(action!.$1),
            ),
        ]),
      ),
    );
  }
}

/// Загрузка в процессе, в очереди или с ошибкой.
class _ActiveRow extends StatelessWidget {
  const _ActiveRow({required this.item, required this.side});

  final DownloadWithEpisode item;
  final double side;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final d = item.download;
    final manager = AppScope.of(context).downloads!;
    final fraction = downloadFraction(d);
    final String status;
    switch (d.status) {
      case DownloadStatus.running:
        status = d.totalBytes == null
            ? 'Загружается'
            : '${formatBytes(d.receivedBytes)} из ${formatBytes(d.totalBytes!)}';
      case DownloadStatus.failed:
        status = d.error ?? 'Ошибка загрузки';
      default:
        status = d.auto ? 'В очереди · ждёт Wi‑Fi или своей очереди' : 'В очереди';
    }
    final failed = d.status == DownloadStatus.failed;
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 8, side - 10, 8),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: PodcastCover(url: item.episode.imageUrl ?? item.podcast.imageUrl, size: 48),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(item.episode.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            ThinProgress(value: d.status == DownloadStatus.running ? (fraction ?? 0) : 0),
            const SizedBox(height: 5),
            Text(status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: failed ? Theme.of(context).colorScheme.error : c.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        if (failed)
          RoundIconButton(
            icon: BcIcons.refresh,
            tooltip: 'Повторить',
            style: RoundStyle.outline,
            size: 40,
            iconSize: 18,
            onPressed: () => manager.retry(d.episodeId),
          ),
        RoundIconButton(
          icon: BcIcons.close,
          tooltip: 'Отменить загрузку',
          style: RoundStyle.outline,
          size: 40,
          iconSize: 16,
          onPressed: () => manager.remove(d.episodeId),
        ),
      ]),
    );
  }
}

/// Загруженный эпизод: нажатие — слушать, корзина — удалить файл.
class _DoneRow extends StatelessWidget {
  const _DoneRow({required this.item, required this.side});

  final DownloadWithEpisode item;
  final double side;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final d = item.download;
    final e = item.episode;
    final meta = [
      if (d.totalBytes != null) formatBytes(d.totalBytes!),
      formatDuration(e.durationMs),
    ].where((t) => t.isNotEmpty).join(' · ');
    return InkWell(
      onTap: () => AppScope.of(context).audio?.playEpisode(e.id),
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, 8, side - 10, 8),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: PodcastCover(url: e.imageUrl ?? item.podcast.imageUrl, size: 48),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.podcast.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
              const SizedBox(height: 2),
              Text(e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(meta, style: TextStyle(fontSize: 12, color: c.muted)),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          RoundIconButton(
            icon: BcIcons.trash,
            tooltip: 'Удалить загрузку',
            size: 44,
            iconSize: 20,
            color: c.muted,
            onPressed: () => AppScope.of(context).downloads?.remove(d.episodeId),
          ),
        ]),
      ),
    );
  }
}
