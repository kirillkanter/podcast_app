/// Вкладка «Каталог» в книгах: поиск, фильтры, жанры и подборки.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../catalog/books/book_catalog.dart';
import '../../app_scope.dart';
import '../../icons.dart';
import '../../menu.dart';
import '../../scrolling.dart';
import '../../theme.dart';
import 'catalog_item.dart';
import 'catalog_list.dart';
import 'catalog_widgets.dart';

/// Подборки каталога. [header] — заголовок экрана с переключателем.
class CatalogView extends StatefulWidget {
  const CatalogView({super.key, required this.config, required this.header});

  final CatalogConfig config;
  final Widget header;

  @override
  State<CatalogView> createState() => _CatalogViewState();
}

class _CatalogViewState extends State<CatalogView> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  var _language = CatalogLanguage.all;
  var _kind = CatalogKind.all;
  bool _languageLoaded = false;

  CatalogFilter get _filter => CatalogFilter(language: _language, kind: _kind);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_languageLoaded) {
      _languageLoaded = true;
      AppScope.of(context).bookCatalog?.language().then((l) {
        if (mounted && l != _language) setState(() => _language = l);
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _query = q.trim());
    });
  }

  void _setLanguage(CatalogLanguage l) {
    setState(() => _language = l);
    unawaited(AppScope.of(context).bookCatalog?.setLanguage(l));
  }

  void _openGenre(BookGenre genre) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BookCatalogListScreen(title: genre.name, genre: genre, filter: _filter),
      ));

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final catalog = AppScope.of(context).bookCatalog!;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final side = wide ? 32.0 : 20.0;
    final filter = _filter;
    final config = widget.config;

    Widget chip(String label, bool on, VoidCallback onTap) => ChoiceChip(
          label: Text(label, maxLines: 1),
          selected: on,
          labelStyle: TextStyle(fontWeight: on ? FontWeight.w600 : FontWeight.w500, color: on ? c.onFill : c.text),
          side: on ? BorderSide.none : BorderSide(color: c.line),
          onSelected: (_) => onTap(),
        );

    final searchField = TextField(
      controller: _search,
      onChanged: _onQuery,
      onSubmitted: (q) {
        _debounce?.cancel();
        setState(() => _query = q.trim());
      },
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: config.librivox && config.opds.isEmpty ? 'Название или автор (на языке книги)' : 'Название или автор',
        prefixIcon: Padding(padding: const EdgeInsets.all(12), child: BcIcon(BcIcons.search, size: 20, color: c.muted)),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Очистить',
                icon: BcIcon(BcIcons.close, size: 18, color: c.muted),
                onPressed: () {
                  _search.clear();
                  setState(() => _query = '');
                },
              ),
        filled: true,
        fillColor: c.raised,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
      ),
    );

    final language = BcMenu<CatalogLanguage>(
      tooltip: 'Язык книг',
      borderRadius: BorderRadius.circular(20),
      onSelected: _setLanguage,
      selected: _language,
      options: [for (final l in CatalogLanguage.values) MenuOption(l, l.label)],
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(border: Border.all(color: c.line), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          BcIcon(BcIcons.globe, size: 16, color: c.text),
          const SizedBox(width: 6),
          Text(_language.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(width: 2),
          BcIcon(BcIcons.chevronDown, size: 16, color: c.muted),
        ]),
      ),
    );

    final filters = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: side),
      child: Row(children: [
        language,
        const SizedBox(width: 10),
        for (final k in CatalogKind.values) ...[
          chip(k.label, _kind == k, () => setState(() => _kind = k)),
          const SizedBox(width: 8),
        ],
      ]),
    );

    final genres = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: side),
      child: Row(children: [
        for (final g in bookGenres) ...[
          ActionChip(
            label: Text(g.name),
            side: BorderSide(color: c.line),
            backgroundColor: c.raised,
            labelStyle: TextStyle(fontWeight: FontWeight.w500, color: c.text),
            onPressed: () => _openGenre(g),
          ),
          const SizedBox(width: 8),
        ],
      ]),
    );

    final cardWidth = wide ? 132.0 : 112.0;
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(child: widget.header),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, 4, side, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: searchField),
          ),
        ),
      ),
      SliverToBoxAdapter(child: filters),
      if (_query.isNotEmpty)
        CatalogResults(
          key: ValueKey('search/$_query/${filter.key}'),
          load: () => catalog.searchPage(_query, filter),
          side: side,
          empty: 'Ничего не найдено',
        )
      else ...[
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(top: 12, bottom: 18), child: genres)),
        if (config.librivox && filter.audio)
          SliverToBoxAdapter(
            child: _Shelf(
              key: ValueKey('lv/${filter.key}'),
              title: 'Популярное на LibriVox',
              audio: true,
              load: () => catalog.popularLibriVox(filter),
              cardWidth: cardWidth,
              side: side,
              wide: wide,
              onAll: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => BookCatalogListScreen(title: 'Популярное на LibriVox', popularLibriVox: true, filter: filter),
              )),
            ),
          ),
        if (filter.text)
          for (final o in config.opds)
            SliverToBoxAdapter(
              child: _Shelf(
                key: ValueKey('opds/${o.id}/${filter.key}'),
                title: o.name,
                load: () => catalog.popularOpds(o.id, filter),
                cardWidth: cardWidth,
                side: side,
                wide: wide,
                alwaysAll: true,
                emptyText: 'Подборки нет — откройте «Все», там разделы каталога',
                onAll: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => BookCatalogListScreen(title: o.name, opdsCatalogId: o.id, filter: filter, browse: true),
                )),
              ),
            ),
        for (final g in bookGenres)
          SliverToBoxAdapter(
            child: _Shelf(
              key: ValueKey('${g.id}/${filter.key}/${config.encode().hashCode}'),
              title: g.name,
              audio: filter.kind == CatalogKind.audio || (filter.kind == CatalogKind.all && config.opds.isEmpty),
              load: () => catalog.genre(g, filter),
              cardWidth: cardWidth,
              side: side,
              wide: wide,
              hideEmpty: true,
              onAll: () => _openGenre(g),
            ),
          ),
      ],
      SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 24)),
    ]);
  }
}

/// Ряд обложек с заголовком и «Все ›». Пустой или с ошибкой жанр
/// не показывается вовсе.
class _Shelf extends StatefulWidget {
  const _Shelf({
    super.key,
    required this.title,
    required this.load,
    required this.cardWidth,
    required this.side,
    required this.wide,
    required this.onAll,
    this.hideEmpty = false,
    this.audio = false,
    this.alwaysAll = false,
    this.emptyText = 'Здесь пока пусто',
  });

  /// «Все ›» и при пустом ряде (каталог OPDS: там его разделы).
  final bool alwaysAll;
  final String emptyText;

  /// В ряду только аудиокниги (пока не загрузился — для заглушек).
  final bool audio;

  final String title;
  final Future<List<CatalogBook>> Function() load;
  final double cardWidth;
  final double side;
  final bool wide;
  final VoidCallback onAll;
  final bool hideEmpty;

  @override
  State<_Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<_Shelf> {
  late Future<List<CatalogBook>> _future = widget.load();
  final _scroll = ScrollController(keepScrollOffset: false);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final w = widget.cardWidth;
    return FutureBuilder<List<CatalogBook>>(
      future: _future,
      builder: (context, s) {
        final items = s.data;
        // Только аудиокниги — место под квадратные обложки, без пустоты сверху.
        final audioOnly = items == null || items.isEmpty ? widget.audio : items.every((b) => b.audio);
        final coverHeight = audioOnly ? w : w * 1.5;
        // Название в две строки, автор, источник — с учётом размера шрифта.
        final textHeight = MediaQuery.textScalerOf(context).scale(84);
        if (widget.hideEmpty && (s.hasError || (items != null && items.isEmpty))) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.fromLTRB(widget.side, 0, widget.side - 8, 8),
              child: Row(children: [
                Flexible(child: Text(widget.title, style: sectionTitleStyle(context))),
                if (items != null && (items.isNotEmpty || widget.alwaysAll)) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: c.ink,
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: widget.onAll,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Все'),
                      BcIcon(BcIcons.chevronRight, size: 16, color: c.ink),
                    ]),
                  ),
                ],
              ]),
            ),
            SizedBox(
              height: items != null && items.isEmpty ? 40 : coverHeight + textHeight,
              child: s.hasError
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: widget.side - 24),
                        child: CatalogMessage(catalogError(s.error),
                            onRetry: () => setState(() => _future = widget.load())),
                      ),
                    )
                  : items != null && items.isEmpty
                      ? Padding(
                          padding: EdgeInsets.symmetric(horizontal: widget.side),
                          child: Text(widget.emptyText, style: TextStyle(color: c.muted)),
                        )
                      : ScrollArrows(
                          controller: _scroll,
                          enabled: widget.wide,
                          top: coverHeight / 2 - 20,
                          child: ListView.separated(
                            controller: _scroll,
                            scrollDirection: Axis.horizontal,
                            padding: EdgeInsets.symmetric(horizontal: widget.side),
                            itemCount: items == null ? 6 : items.length.clamp(0, 20),
                            separatorBuilder: (_, _) => const SizedBox(width: 14),
                            itemBuilder: (context, i) => items == null
                                ? Align(
                                    alignment: Alignment.topCenter,
                                    child: Container(
                                      width: w,
                                      height: coverHeight,
                                      decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(10)),
                                    ),
                                  )
                                : CatalogCard(
                                    book: items[i],
                                    width: w,
                                    coverHeight: coverHeight,
                                    onTap: () => openCatalogBook(context, items[i]),
                                  ),
                          ),
                        ),
            ),
          ]),
        );
      },
    );
  }
}
