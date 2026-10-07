import 'dart:async';

import 'package:flutter/material.dart';

import '../catalog/podcast_catalog.dart';
import '../data/db/database.dart';
import '../data/podcast_repository.dart';
import '../feed/feed_url.dart';
import 'app_scope.dart';
import 'icons.dart';
import 'podcast_cover.dart';
import 'podcast_screen.dart';
import 'scrolling.dart';
import 'shell.dart';
import 'theme.dart';

/// Подкасты каталога, которые сейчас загружаются (подписка или открытие).
final _busy = ValueNotifier<Set<String>>(const {});

void _setBusy(String id, bool busy) =>
    _busy.value = busy ? {..._busy.value, id} : ({..._busy.value}..remove(id));

/// Адрес фида подкаста каталога; в подборках его нет — дозапрашиваем.
Future<String?> _feedOf(PodcastCatalog? catalog, CatalogPodcast p) async {
  if (p.feedUrl != null) return p.feedUrl;
  if (catalog == null) return null;
  return (await catalog.withFeeds([p])).first.feedUrl;
}

const _onlyApple = 'Этот подкаст есть только в Apple Podcasts: открытого RSS-фида у него нет.';

/// Открыть подкаст из каталога, не подписываясь.
Future<void> openCatalogPodcast(BuildContext context, CatalogPodcast p) async {
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  if (_busy.value.contains(p.id)) return;
  _setBusy(p.id, true);
  try {
    final url = await _feedOf(scope.catalog, p);
    if (url == null) {
      messenger.showSnackBar(const SnackBar(content: Text(_onlyApple)));
      return;
    }
    final id = await scope.repository.add(url, subscribe: false);
    _setBusy(p.id, false);
    await navigator.push(MaterialPageRoute<void>(builder: (_) => PodcastScreen(podcastId: id)));
  } on PodcastException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } on CatalogException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } finally {
    _setBusy(p.id, false);
  }
}

/// Подписаться прямо из списка.
Future<void> subscribeCatalogPodcast(BuildContext context, CatalogPodcast p) async {
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  if (_busy.value.contains(p.id)) return;
  _setBusy(p.id, true);
  try {
    final url = await _feedOf(scope.catalog, p);
    if (url == null) {
      messenger.showSnackBar(const SnackBar(content: Text(_onlyApple)));
      return;
    }
    final id = await scope.repository.add(url, subscribe: true);
    unawaited(scope.downloads?.autoDownload(id));
    messenger.showSnackBar(SnackBar(content: Text('Вы подписались на «${p.title}»')));
  } on PodcastException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } on CatalogException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } finally {
    _setBusy(p.id, false);
  }
}

/// Похоже на ссылку на фид: «https://…» или «site.ru/rss» без пробелов.
bool looksLikeUrl(String text) {
  final t = text.trim();
  if (t.contains(' ') || !t.contains('.')) return false;
  return t.startsWith('http://') ||
      t.startsWith('https://') ||
      RegExp(r'^[\w-]+(\.[\w-]+)+(/\S*)?$').hasMatch(t);
}

/// Поиск: строка поиска, рубрики и подборки популярного.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _pages = PageController();
  final _chips = ScrollController(keepScrollOffset: false);
  final _chipKeys = [for (final _ in catalogGenres) GlobalKey()];
  Timer? _debounce;
  String _query = '';
  Future<List<CatalogPodcast>>? _results;
  Future<List<CatalogPodcast>>? _top;
  final _genreLists = <int, Future<List<CatalogPodcast>>>{};

  /// Открытая страница: 0 — «Все» (подборки), 1… — рубрика catalogGenres[page - 1].
  int _page = 0;

  @override
  void initState() {
    super.initState();
    // «Назад» из рубрики — сначала к «Все», потом уже выход.
    AppShell.setBackHandler(ShellTab.search, () {
      if (_query.isNotEmpty) {
        _clear();
        return true;
      }
      if (_page != 0) {
        _goTo(0);
        return true;
      }
      return false;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _top ??= AppScope.of(context).catalog?.top();
  }

  @override
  void dispose() {
    AppShell.setBackHandler(ShellTab.search, null);
    _debounce?.cancel();
    _controller.dispose();
    _pages.dispose();
    _chips.dispose();
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
    // Страницы рубрик заново строятся после поиска: вернуть на нужную.
    if (query.isEmpty && _page != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pages.hasClients) _pages.jumpToPage(_page);
        _scrollChips(_page);
      });
    }
  }

  void _clear() {
    _controller.clear();
    _debounce?.cancel();
    _search('');
  }

  Future<List<CatalogPodcast>> _genreList(CatalogGenre g) {
    final catalog = AppScope.of(context).catalog!;
    return _genreLists.putIfAbsent(g.id, () => catalog.chart(genreId: g.id).then(catalog.withFeeds));
  }

  /// Перейти на страницу: соседнюю — плавно, далёкую — сразу.
  void _goTo(int page) {
    if (!_pages.hasClients) return;
    if ((page - _page).abs() <= 1) {
      _pages.animateToPage(page, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    } else {
      _pages.jumpToPage(page);
    }
  }

  void _onPage(int page) {
    setState(() => _page = page);
    _scrollChips(page);
  }

  /// Пилюля открытой рубрики — сразу после закреплённой «Все».
  void _scrollChips(int page) {
    if (!_chips.hasClients) return;
    if (page == 0) {
      _chips.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
      return;
    }
    final chip = _chipKeys[page - 1].currentContext;
    if (chip != null) {
      Scrollable.ensureVisible(chip, alignment: 0, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
    } else {
      // Пилюля ещё не построена (далеко за краем): прокрутка по примерной ширине.
      _chips.jumpTo((_chips.position.maxScrollExtent * (page - 1) / catalogGenres.length)
          .clamp(0.0, _chips.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollChips(page));
    }
  }

  Future<void> _openUrl(String url) async {
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final id = await scope.repository.add(url.trim(), subscribe: false);
      await navigator.push(MaterialPageRoute<void>(builder: (_) => PodcastScreen(podcastId: id)));
    } on PodcastException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final catalog = AppScope.of(context).catalog;
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutWidth;
    final side = wide ? 32.0 : 20.0;
    final bottom = SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16));
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(side, wide ? 24 : 16, side, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Поиск', style: screenTitleStyle(context)),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.only(left: 16, right: 4),
                  decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(24)),
                  child: Row(children: [
                    BcIcon(BcIcons.search, size: 20, color: c.muted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        key: const Key('searchField'),
                        controller: _controller,
                        textInputAction: TextInputAction.search,
                        onChanged: _onChanged,
                        onSubmitted: (text) {
                          _debounce?.cancel();
                          _search(text);
                        },
                        style: const TextStyle(fontSize: 15),
                        decoration: InputDecoration(
                          hintText: 'Подкаст, автор или ссылка на RSS',
                          hintStyle: TextStyle(color: c.muted),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          isDense: true,
                        ),
                      ),
                    ),
                    if (_controller.text.isNotEmpty)
                      RoundIconButton(
                        icon: BcIcons.close,
                        tooltip: 'Очистить',
                        size: 40,
                        iconSize: 18,
                        color: c.muted,
                        onPressed: _clear,
                      ),
                  ]),
                ),
              ),
            ]),
          ),
          if (catalog == null)
            const _Message('Каталог недоступен')
          else if (_query.isNotEmpty)
            Expanded(child: CustomScrollView(slivers: [..._searchResults(context, side), bottom]))
          else ...[
            _genres(context, side, wide),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                onPageChanged: _onPage,
                itemCount: catalogGenres.length + 1,
                itemBuilder: (context, page) {
                  if (page == 0) {
                    return CustomScrollView(
                      key: const PageStorageKey('search-all'),
                      slivers: [..._collections(context, catalog, wide, side), bottom],
                    );
                  }
                  final g = catalogGenres[page - 1];
                  return CustomScrollView(
                    key: PageStorageKey('search-${g.id}'),
                    slivers: [
                      _CatalogFuture(
                        future: _genreList(g),
                        ranked: true,
                        empty: 'В этой рубрике пока ничего нет',
                        horizontalPadding: side,
                      ),
                      bottom,
                    ],
                  );
                },
              ),
            ),
          ],
        ]),
      ),
    );
  }

  /// Пилюли рубрик: «Все» закреплена слева, остальные уезжают под неё.
  Widget _genres(BuildContext context, double side, bool wide) {
    final c = BcColors.of(context);
    Widget chip(String label, bool on, VoidCallback onTap, {Key? key}) => ChoiceChip(
          key: key,
          label: Text(label, maxLines: 1),
          selected: on,
          labelStyle: TextStyle(fontWeight: on ? FontWeight.w600 : FontWeight.w500, color: on ? c.onFill : c.text),
          side: on ? BorderSide.none : BorderSide(color: c.line),
          onSelected: (_) => onTap(),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      // По нижнему краю: на компьютере над пилюлями стоят стрелки.
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Padding(
          padding: EdgeInsets.only(left: side, right: 8),
          child: chip('Все', _page == 0, () => _goTo(0)),
        ),
        Expanded(
          child: ScrollArrows(
            controller: _chips,
            enabled: wide,
            above: true,
            size: 28,
            child: ShaderMask(
            // Пилюли растворяются у «Все», а не обрезаются ножом.
            shaderCallback: (rect) => LinearGradient(
              colors: const [Colors.transparent, Colors.black],
              stops: [0, (12 / rect.width).clamp(0.0, 1.0)],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: SingleChildScrollView(
              controller: _chips,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(right: side),
              child: Row(children: [
                for (var i = 0; i < catalogGenres.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: chip(catalogGenres[i].name, _page == i + 1, () => _goTo(i + 1), key: _chipKeys[i]),
                  ),
              ]),
            ),
          ),
          ),
        ),
      ]),
    );
  }

  List<Widget> _searchResults(BuildContext context, double side) {
    final c = BcColors.of(context);
    return [
      if (looksLikeUrl(_query))
        SliverToBoxAdapter(
          child: InkWell(
            onTap: () => _openUrl(_query),
            child: Padding(
              padding: EdgeInsets.fromLTRB(side, 8, side, 8),
              child: Row(children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(10)),
                  child: Center(child: BcIcon(BcIcons.globe, size: 24, color: c.ink)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Открыть фид по ссылке', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 3),
                    Text(_query,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, 8, side, 4),
          child: Text('Результаты поиска', style: sectionTitleStyle(context)),
        ),
      ),
      _CatalogFuture(
        key: ValueKey(_query),
        future: _results!,
        ranked: false,
        empty: 'Ничего не найдено',
        horizontalPadding: side,
      ),
    ];
  }

  List<Widget> _collections(BuildContext context, PodcastCatalog catalog, bool wide, double side) {
    return [
      SliverToBoxAdapter(
        child: _Shelf(
          key: const ValueKey('top'),
          title: 'Популярное',
          future: _top!,
          big: true,
          wide: wide,
          side: side,
          onAll: (items) => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => CatalogListScreen(title: 'Популярное', future: Future.value(items)),
          )),
        ),
      ),
      for (var i = 0; i < catalogGenres.length; i++)
        SliverToBoxAdapter(
          child: _Shelf(
            key: ValueKey(catalogGenres[i].id),
            title: catalogGenres[i].name,
            future: catalog.chart(genreId: catalogGenres[i].id),
            big: false,
            wide: wide,
            side: side,
            onAll: (_) => _goTo(i + 1),
          ),
        ),
    ];
  }
}

/// Подборка: заголовок, «Все» и ряд обложек, который листается вбок.
class _Shelf extends StatefulWidget {
  const _Shelf({
    super.key,
    required this.title,
    required this.future,
    required this.big,
    required this.wide,
    required this.side,
    required this.onAll,
  });

  final String title;
  final Future<List<CatalogPodcast>> future;

  /// Крупные карточки с местом в чарте («Популярное»).
  final bool big;
  final bool wide;
  final double side;
  final ValueChanged<List<CatalogPodcast>> onAll;

  @override
  State<_Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<_Shelf> {
  late final Future<List<CatalogPodcast>> _future = widget.future;
  // Без сохранения позиции: иначе ряд брал чужую сохранённую прокрутку
  // (общий ключ страницы) и открывался сдвинутым вбок.
  final _scroll = ScrollController(keepScrollOffset: false);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final card = widget.big ? (widget.wide ? 180.0 : 150.0) : (widget.wide ? 132.0 : 104.0);
    return FutureBuilder<List<CatalogPodcast>>(
      future: _future,
      builder: (context, s) {
        final items = s.data;
        // Рубрика не загрузилась или пустая — не показываем её вовсе.
        if (!widget.big && (s.hasError || (items != null && items.isEmpty))) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.fromLTRB(widget.side, 0, widget.side - 8, 8),
              // «Все» сразу за названием: на широком экране справа его не видно.
              child: Row(children: [
                Flexible(child: Text(widget.title, style: sectionTitleStyle(context))),
                if (items != null && items.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: c.ink,
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => widget.onAll(items),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Все'),
                      BcIcon(BcIcons.chevronRight, size: 16, color: c.ink),
                    ]),
                  ),
                ],
              ]),
            ),
            SizedBox(
              height: card + (widget.big ? 58 : 44),
              child: s.hasError
                  ? Padding(
                      padding: EdgeInsets.symmetric(horizontal: widget.side),
                      child: Text(
                        s.error is CatalogException ? (s.error! as CatalogException).message : 'Не удалось загрузить',
                        style: TextStyle(color: c.muted),
                      ),
                    )
                  : ScrollArrows(
                      controller: _scroll,
                      enabled: widget.wide,
                      top: card / 2 - 20,
                      child: ListView.separated(
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.symmetric(horizontal: widget.side),
                      itemCount: items == null ? 6 : items.length.clamp(0, widget.big ? 10 : 15),
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, i) => items == null
                          ? Align(
                              alignment: Alignment.topCenter,
                              child: Container(
                                width: card,
                                height: card,
                                decoration: BoxDecoration(
                                  color: c.raised,
                                  borderRadius: BorderRadius.circular(widget.big ? 16 : 12),
                                ),
                              ),
                            )
                          : _Card(podcast: items[i], size: card, rank: widget.big ? i + 1 : null),
                    ),
                    ),
            ),
          ]),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.podcast, required this.size, this.rank});

  final CatalogPodcast podcast;
  final double size;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final p = podcast;
    final radius = BorderRadius.circular(rank != null ? 16 : 12);
    return SizedBox(
      width: size,
      child: InkWell(
        borderRadius: radius,
        onTap: () => openCatalogPodcast(context, p),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            ClipRRect(borderRadius: radius, child: PodcastCover(url: p.artworkUrl, size: size)),
            if (rank != null)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: c.bg, shape: BoxShape.circle),
                  child: Text('$rank',
                      style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 14, color: c.ink)),
                ),
              ),
            Positioned.fill(
              child: ValueListenableBuilder<Set<String>>(
                valueListenable: _busy,
                builder: (context, busy, _) => busy.contains(p.id)
                    ? DecoratedBox(
                        decoration: BoxDecoration(color: const Color(0x66000000), borderRadius: radius),
                        child: const Center(
                          child: SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text(p.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: rank != null ? 14 : 13,
                fontWeight: rank != null ? FontWeight.w500 : FontWeight.w400,
                height: 1.25,
              )),
          if (rank != null && p.genre != null)
            Text(p.genre!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
        ]),
      ),
    );
  }
}

/// Список подкастов каталога из [future]: строки с подпиской.
class _CatalogFuture extends StatelessWidget {
  const _CatalogFuture({
    super.key,
    required this.future,
    required this.ranked,
    required this.empty,
    required this.horizontalPadding,
  });

  final Future<List<CatalogPodcast>> future;
  final bool ranked;
  final String empty;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final db = AppScope.of(context).db;
    return StreamBuilder<List<Podcast>>(
      stream: db.watchSubscribedPodcasts(),
      builder: (context, subs) {
        final subscribed = {for (final p in subs.data ?? const <Podcast>[]) feedKey(p.feedUrl)};
        return FutureBuilder<List<CatalogPodcast>>(
          future: future,
          builder: (context, result) {
            if (result.connectionState != ConnectionState.done) {
              return const SliverToBoxAdapter(
                child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
              );
            }
            if (result.hasError) {
              final error = result.error;
              return SliverToBoxAdapter(
                child: _Message(error is CatalogException ? error.message : 'Ошибка: $error'),
              );
            }
            final items = result.data ?? const [];
            if (items.isEmpty) return SliverToBoxAdapter(child: _Message(empty));
            return SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, i) {
                final p = items[i];
                return CatalogRow(
                  podcast: p,
                  rank: ranked ? i + 1 : null,
                  subscribed: p.feedUrl != null && subscribed.contains(feedKey(p.feedUrl!)),
                  horizontalPadding: horizontalPadding,
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Полный список подборки: «Популярное — все».
class CatalogListScreen extends StatelessWidget {
  const CatalogListScreen({super.key, required this.title, required this.future});

  final String title;
  final Future<List<CatalogPodcast>> future;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(),
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(title, style: screenTitleStyle(context)),
          ),
        ),
        _CatalogFuture(future: future, ranked: true, empty: 'Список пуст', horizontalPadding: 20),
        SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16)),
      ]),
    );
  }
}

/// Строка подкаста каталога: место, обложка, название, подписка.
class CatalogRow extends StatelessWidget {
  const CatalogRow({
    super.key,
    required this.podcast,
    required this.subscribed,
    this.rank,
    this.horizontalPadding = 20,
  });

  final CatalogPodcast podcast;
  final bool subscribed;
  final int? rank;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final p = podcast;
    final available = p.feedUrl != null;
    final details = [
      ?p.author,
      ?p.genre,
      if (!available) 'только в Apple Podcasts',
    ].join(' · ');
    return Opacity(
      opacity: available ? 1 : 0.5,
      child: InkWell(
        onTap: available ? () => openCatalogPodcast(context, p) : null,
        child: Padding(
          padding: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding - 8, 8),
          child: Row(children: [
            if (rank != null)
              SizedBox(
                width: 34,
                child: Text('$rank',
                    style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 15, color: c.ink)),
              ),
            ClipRRect(borderRadius: BorderRadius.circular(10), child: PodcastCover(url: p.artworkUrl, size: 56)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.25)),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(details,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<Set<String>>(
              valueListenable: _busy,
              builder: (context, busy, _) {
                if (busy.contains(p.id)) {
                  return const SizedBox.square(
                    dimension: 44,
                    child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                }
                if (subscribed) {
                  return Tooltip(
                    message: 'Вы подписаны',
                    child: SizedBox.square(
                      dimension: 44,
                      child: Center(child: BcIcon(BcIcons.check, size: 22, color: c.ink)),
                    ),
                  );
                }
                if (!available) return const SizedBox(width: 44);
                return RoundIconButton(
                  icon: BcIcons.plus,
                  tooltip: 'Подписаться',
                  style: RoundStyle.outline,
                  size: 40,
                  iconSize: 20,
                  onPressed: () => subscribeCatalogPodcast(context, p),
                );
              },
            ),
          ]),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: BcColors.of(context).muted)),
      );
}
