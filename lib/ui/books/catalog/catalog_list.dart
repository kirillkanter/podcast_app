/// Список книг каталога: жанр, подборка или результаты поиска.
/// На компьютере — сетка обложек и книга в панели справа.
library;

import 'package:flutter/material.dart';

import '../../../catalog/books/book_catalog.dart';
import '../../app_scope.dart';
import '../../theme.dart';
import 'catalog_item.dart';
import 'catalog_widgets.dart';

/// Книги из [load] в виде слайвера: строки на телефоне, сетка на компьютере.
class CatalogResults extends StatefulWidget {
  const CatalogResults({
    super.key,
    required this.load,
    required this.side,
    required this.empty,
    this.onSelect,
    this.selectedId,
  });

  final Future<List<CatalogBook>> Function() load;
  final double side;
  final String empty;

  /// Выбор книги вместо перехода на её страницу (панель справа).
  final ValueChanged<CatalogBook>? onSelect;
  final String? selectedId;

  @override
  State<CatalogResults> createState() => _CatalogResultsState();
}

class _CatalogResultsState extends State<CatalogResults> {
  late Future<List<CatalogBook>> _future = widget.load();

  void _open(CatalogBook b) => widget.onSelect != null ? widget.onSelect!(b) : openCatalogBook(context, b);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return FutureBuilder<List<CatalogBook>>(
      future: _future,
      builder: (context, s) {
        if (s.hasError) {
          return SliverToBoxAdapter(
            child: CatalogMessage(catalogError(s.error), onRetry: () => setState(() => _future = widget.load())),
          );
        }
        if (!s.hasData) {
          return const SliverToBoxAdapter(
            child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          );
        }
        final items = s.data!;
        if (items.isEmpty) return SliverToBoxAdapter(child: CatalogMessage(widget.empty));
        if (wide) {
          return SliverPadding(
            padding: EdgeInsets.fromLTRB(widget.side, 12, widget.side, 24),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                mainAxisSpacing: 20,
                crossAxisSpacing: 18,
                childAspectRatio: 0.48,
              ),
              itemCount: items.length,
              itemBuilder: (context, i) => LayoutBuilder(
                builder: (context, box) => Align(
                  alignment: Alignment.topLeft,
                  child: CatalogCard(
                    book: items[i],
                    width: box.maxWidth,
                    selected: items[i].id == widget.selectedId,
                    onTap: () => _open(items[i]),
                  ),
                ),
              ),
            ),
          );
        }
        return SliverPadding(
          padding: const EdgeInsets.only(top: 6),
          sliver: SliverList.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => BookCatalogRow(book: items[i], side: widget.side, onTap: () => _open(items[i])),
          ),
        );
      },
    );
  }
}

/// Страница жанра или подборки.
class BookCatalogListScreen extends StatefulWidget {
  const BookCatalogListScreen({
    super.key,
    required this.title,
    required this.filter,
    this.genre,
    this.popularLibriVox = false,
    this.opdsCatalogId,
  });

  final String title;
  final CatalogFilter filter;
  final BookGenre? genre;
  final bool popularLibriVox;
  final String? opdsCatalogId;

  @override
  State<BookCatalogListScreen> createState() => _BookCatalogListScreenState();
}

class _BookCatalogListScreenState extends State<BookCatalogListScreen> {
  late var _kind = widget.filter.kind;
  CatalogBook? _selected;

  Future<List<CatalogBook>> _load(BookCatalog catalog, CatalogFilter f) {
    if (widget.genre != null) return catalog.genre(widget.genre!, f);
    if (widget.popularLibriVox) return catalog.popularLibriVox(f);
    if (widget.opdsCatalogId != null) return catalog.popularOpds(widget.opdsCatalogId!, f);
    return Future.value(const []);
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final catalog = AppScope.of(context).bookCatalog!;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final side = wide ? 32.0 : 20.0;
    final filter = CatalogFilter(language: widget.filter.language, kind: _kind);
    // Тип выбирают только в жанрах: подборка одного источника — одного типа.
    final kinds = widget.genre != null;

    final list = CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 12),
          child: Text(widget.title, style: screenTitleStyle(context)),
        ),
      ),
      if (kinds)
        SliverToBoxAdapter(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: side),
            child: Row(children: [
              for (final k in CatalogKind.values) ...[
                ChoiceChip(
                  label: Text(k.label),
                  selected: _kind == k,
                  labelStyle: TextStyle(fontWeight: _kind == k ? FontWeight.w600 : FontWeight.w500, color: _kind == k ? c.onFill : c.text),
                  side: _kind == k ? BorderSide.none : BorderSide(color: c.line),
                  onSelected: (_) => setState(() => _kind = k),
                ),
                const SizedBox(width: 8),
              ],
            ]),
          ),
        ),
      CatalogResults(
        key: ValueKey(filter.key),
        load: () => _load(catalog, filter).then((items) {
          if (wide && _selected == null && items.isNotEmpty && mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _selected == null) setState(() => _selected = items.first);
            });
          }
          return items;
        }),
        side: side,
        empty: widget.genre != null ? 'В этом жанре пока ничего не нашлось' : 'Список пуст',
        onSelect: wide ? (b) => setState(() => _selected = b) : null,
        selectedId: _selected?.id,
      ),
      SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16)),
    ]);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(),
      body: !wide
          ? list
          : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: list),
              Container(width: 1, color: c.divider),
              SizedBox(
                width: 400,
                child: _selected == null
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                        child: CatalogItemDetails(key: ValueKey(_selected!.id), book: _selected!, panel: true),
                      ),
              ),
            ]),
    );
  }
}
