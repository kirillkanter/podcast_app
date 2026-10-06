import 'dart:async';

import 'package:flutter/material.dart';

import '../catalog/podcast_catalog.dart';
import '../data/db/database.dart';
import '../data/podcast_repository.dart';
import '../feed/feed_url.dart';
import 'app_scope.dart';
import 'podcast_cover.dart';
import 'podcast_screen.dart';

/// Поиск подкастов в каталоге; без запроса показывает популярное.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  Future<List<CatalogPodcast>>? _results;
  Future<List<CatalogPodcast>>? _top;
  Stream<List<Podcast>>? _subscribed;

  /// id подкастов каталога, которые сейчас загружаются.
  final _busy = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _top ??= scope.catalog?.top();
    _subscribed ??= scope.db.watchSubscribedPodcasts();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    setState(() {}); // показать или скрыть кнопку «Очистить»
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(text));
  }

  void _search(String text) {
    final query = text.trim();
    if (query == _query) return;
    setState(() {
      _query = query;
      _results = query.isEmpty ? null : AppScope.of(context).catalog?.search(query);
    });
  }

  /// Подписка прямо из списка.
  Future<void> _subscribe(CatalogPodcast p) async {
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.add(p.id));
    try {
      final id = await scope.repository.add(p.feedUrl!, subscribe: true);
      unawaited(scope.downloads?.autoDownload(id));
      messenger.showSnackBar(SnackBar(content: Text('Вы подписались на «${p.title}»')));
    } on PodcastException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
    }
  }

  /// Открыть подкаст, не подписываясь.
  Future<void> _open(CatalogPodcast p) async {
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy.add(p.id));
    try {
      final id = await scope.repository.add(p.feedUrl!, subscribe: false);
      if (!mounted) return;
      await navigator.push(MaterialPageRoute<void>(builder: (_) => PodcastScreen(podcastId: id)));
    } on PodcastException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context).catalog;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('searchField'),
          controller: _controller,
          autofocus: false,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (text) {
            _debounce?.cancel();
            _search(text);
          },
          decoration: const InputDecoration(
            hintText: 'Название подкаста или автор',
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              tooltip: 'Очистить',
              icon: const Icon(Icons.close),
              onPressed: () {
                _controller.clear();
                _debounce?.cancel();
                _search('');
                setState(() {});
              },
            ),
        ],
      ),
      body: catalog == null
          ? const Center(child: Text('Каталог недоступен'))
          : StreamBuilder<List<Podcast>>(
              stream: _subscribed,
              builder: (context, snapshot) {
                final subscribed = {for (final p in snapshot.data ?? const <Podcast>[]) feedKey(p.feedUrl)};
                final future = _query.isEmpty ? _top : _results;
                return FutureBuilder<List<CatalogPodcast>>(
                  key: ValueKey(_query),
                  future: future,
                  builder: (context, result) {
                    if (result.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (result.hasError) {
                      final error = result.error;
                      return _Message(error is CatalogException ? error.message : 'Ошибка: $error');
                    }
                    final items = result.data ?? const [];
                    if (items.isEmpty) {
                      return _Message(_query.isEmpty ? 'Нет данных о популярных подкастах' : 'Ничего не найдено');
                    }
                    return ListView.builder(
                      itemCount: items.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(
                              _query.isEmpty ? 'Популярное' : 'Результаты поиска',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          );
                        }
                        final p = items[i - 1];
                        return _ResultTile(
                          podcast: p,
                          subscribed: p.feedUrl != null && subscribed.contains(feedKey(p.feedUrl!)),
                          busy: _busy.contains(p.id),
                          onSubscribe: () => _subscribe(p),
                          onOpen: () => _open(p),
                        );
                      },
                    );
                  },
                );
              },
            ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.podcast,
    required this.subscribed,
    required this.busy,
    required this.onSubscribe,
    required this.onOpen,
  });

  final CatalogPodcast podcast;
  final bool subscribed;
  final bool busy;
  final VoidCallback onSubscribe;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = podcast;
    final available = p.feedUrl != null;
    final details = [
      ?p.author,
      ?p.genre,
      if (!available) 'только в Apple Podcasts',
    ].join(' · ');

    final Widget trailing;
    if (busy) {
      trailing = const SizedBox.square(
        dimension: 48,
        child: Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (subscribed) {
      trailing = Icon(Icons.check, color: theme.colorScheme.primary, semanticLabel: 'Вы подписаны');
    } else if (available) {
      trailing = IconButton(tooltip: 'Подписаться', icon: const Icon(Icons.add), onPressed: onSubscribe);
    } else {
      trailing = const SizedBox.shrink();
    }

    return ListTile(
      enabled: available,
      leading: PodcastCover(url: p.artworkUrl, size: 56),
      title: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: details.isEmpty ? null : Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: available && !busy ? onOpen : null,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}
