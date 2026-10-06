import 'package:flutter/material.dart';

import '../data/db/database.dart';
import '../download/download_manager.dart';
import 'app_scope.dart';
import 'download_button.dart';
import 'podcast_cover.dart';

/// Загрузки: настройки, занятое место и список загруженных эпизодов.
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Загрузки')),
      body: StreamBuilder<List<DownloadWithEpisode>>(
        stream: _list,
        builder: (context, snapshot) {
          final items = snapshot.data ?? const [];
          final completedBytes = items
              .where((i) => i.download.status == DownloadStatus.completed)
              .fold<int>(0, (sum, i) => sum + (i.download.totalBytes ?? 0));
          return ListView(
            padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 24),
            children: [
              const _Settings(),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Занято: ${formatBytes(completedBytes)}', style: theme.textTheme.titleSmall),
                    ),
                    TextButton.icon(
                      onPressed: _removePlayed,
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('Удалить прослушанные'),
                    ),
                  ],
                ),
              ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Загруженных эпизодов нет. Нажмите значок загрузки у эпизода '
                    'или включите автозагрузку.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final item in items) _DownloadTile(item: item),
            ],
          );
        },
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.item});

  final DownloadWithEpisode item;

  @override
  Widget build(BuildContext context) {
    final d = item.download;
    final status = switch (d.status) {
      DownloadStatus.completed => d.totalBytes == null ? 'Загружено' : 'Загружено · ${formatBytes(d.totalBytes!)}',
      DownloadStatus.failed => d.error ?? 'Ошибка загрузки',
      _ => downloadLabel(d) ?? '',
    };
    return ListTile(
      leading: PodcastCover(url: item.episode.imageUrl ?? item.podcast.imageUrl, size: 44),
      title: Text(item.episode.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${item.podcast.title}\n$status', maxLines: 3, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
      trailing: DownloadButton(episodeId: d.episodeId, download: d),
      onTap: d.status == DownloadStatus.completed
          ? () => AppScope.of(context).audio?.playEpisode(d.episodeId)
          : null,
    );
  }
}

/// Настройки загрузок. Значения хранятся в таблице app_settings.
class _Settings extends StatelessWidget {
  const _Settings();

  @override
  Widget build(BuildContext context) {
    final db = AppScope.of(context).db;
    final manager = AppScope.of(context).downloads!;

    Widget boolSetting(String key, bool fallback, String title, String subtitle) =>
        StreamBuilder<String?>(
          stream: db.watchSetting(key),
          builder: (context, snapshot) {
            final value = snapshot.data == null ? fallback : snapshot.data == 'true';
            return SwitchListTile(
              title: Text(title),
              subtitle: Text(subtitle),
              value: value,
              onChanged: (v) async {
                await db.setSetting(key, '$v');
                manager.resume();
              },
            );
          },
        );

    Widget intSetting(String key, int fallback, String title, Map<int, String> options) =>
        StreamBuilder<String?>(
          stream: db.watchSetting(key),
          builder: (context, snapshot) {
            final value = int.tryParse(snapshot.data ?? '') ?? fallback;
            return ListTile(
              title: Text(title),
              trailing: DropdownButton<int>(
                value: options.containsKey(value) ? value : fallback,
                underline: const SizedBox.shrink(),
                items: [
                  for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await db.setSetting(key, '$v');
                  if (key == DownloadSettings.autoCount) await manager.autoDownloadAll();
                  manager.resume();
                },
              ),
            );
          },
        );

    return Column(
      children: [
        intSetting(DownloadSettings.autoCount, 0, 'Автозагрузка новых эпизодов', const {
          0: 'Выключена',
          1: 'Последний',
          3: '3 последних',
          5: '5 последних',
        }),
        boolSetting(
          DownloadSettings.wifiOnly,
          true,
          'Автозагрузка только по Wi-Fi',
          'Ручная загрузка работает в любой сети',
        ),
        boolSetting(
          DownloadSettings.deletePlayed,
          true,
          'Удалять прослушанные',
          'Файл удаляется, когда эпизод дослушан или отмечен прослушанным',
        ),
        intSetting(DownloadSettings.limitMb, 0, 'Предел места для автозагрузки', const {
          0: 'Без предела',
          1024: '1 ГБ',
          2048: '2 ГБ',
          5120: '5 ГБ',
          10240: '10 ГБ',
        }),
      ],
    );
  }
}
