import 'package:flutter/material.dart';

import '../data/db/database.dart';
import 'add_feed_dialog.dart';
import 'app_scope.dart';
import 'diagnostics_dialog.dart';
import 'format.dart';
import 'mini_player.dart';
import 'podcast_cover.dart';
import 'podcast_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.refreshOnStart = true});

  /// Обновить подписки при запуске. В тестах выключено.
  final bool refreshOnStart;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Stream<List<Podcast>>? _podcasts;
  bool _refreshing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_podcasts == null) {
      _podcasts = AppScope.of(context).db.watchSubscribedPodcasts();
      if (widget.refreshOnStart) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAll(silent: true));
      }
    }
  }

  Future<void> _refreshAll({bool silent = false}) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final repository = AppScope.of(context).repository;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final summary = await repository.refreshAll();
      if (!mounted) return;
      final parts = <String>[
        if (summary.newEpisodes > 0)
          '${summary.newEpisodes} ${plural(summary.newEpisodes, 'новый эпизод', 'новых эпизода', 'новых эпизодов')}',
        if (summary.failed.isNotEmpty)
          'не удалось обновить: ${summary.failed.length}',
      ];
      if (parts.isNotEmpty || !silent) {
        messenger.showSnackBar(SnackBar(
          content: Text(parts.isEmpty ? 'Новых эпизодов нет' : _capitalize(parts.join(', '))),
        ));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Future<void> _add() async {
    final id = await showAddFeedDialog(context);
    if (id == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PodcastScreen(podcastId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: const MiniPlayer(),
      appBar: AppBar(
        title: const Text('Подкасты'),
        actions: [
          IconButton(
            tooltip: 'Обновить все',
            onPressed: _refreshing ? null : _refreshAll,
            icon: _refreshing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          PopupMenuButton<void>(
            tooltip: 'Ещё',
            itemBuilder: (_) => [
              PopupMenuItem<void>(
                onTap: () => showDiagnosticsDialog(context),
                child: const Text('Диагностика'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Добавить'),
      ),
      body: StreamBuilder<List<Podcast>>(
        stream: _podcasts,
        builder: (context, snapshot) {
          final podcasts = snapshot.data;
          if (podcasts == null) return const Center(child: CircularProgressIndicator());
          return RefreshIndicator(
            onRefresh: _refreshAll,
            child: podcasts.isEmpty ? const _EmptyState() : _PodcastList(podcasts: podcasts),
          );
        },
      ),
    );
  }
}

class _PodcastList extends StatelessWidget {
  const _PodcastList({required this.podcasts});

  final List<Podcast> podcasts;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: podcasts.length,
      itemBuilder: (context, i) {
        final p = podcasts[i];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: PodcastCover(url: p.imageUrl),
          title: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: p.lastError != null
              ? Text(
                  'Ошибка обновления',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              : (p.author == null ? null : Text(p.author!, maxLines: 1, overflow: TextOverflow.ellipsis)),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => PodcastScreen(podcastId: p.id)),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // ListView, чтобы работал жест «потянуть для обновления».
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.podcasts, size: 64, color: theme.colorScheme.outline),
        const SizedBox(height: 16),
        Text('Подписок пока нет', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'Нажмите «Добавить» и вставьте ссылку на RSS-фид подкаста '
          'или на его страницу в Apple Podcasts.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
