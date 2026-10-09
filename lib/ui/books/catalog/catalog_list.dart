/// Список книг каталога: жанр, подборка, раздел каталога OPDS или поиск.
/// Догружается страницами по мере прокрутки. На компьютере — сетка
/// обложек и книга в панели справа.
library;

import 'package:flutter/material.dart';

import '../../../catalog/books/book_catalog.dart';
import '../../app_scope.dart';
import '../../icons.dart';
import '../../nav_ink.dart';
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
    this.onFirst,
    this.onSection,
  });

  final Future<CatalogPage> Function() load;
  final double side;
  final String empty;

  /// Выбор книги вместо перехода на её страницу (панель справа).
  final ValueChanged<CatalogBook>? onSelect;
  final String? selectedId;

  /// Первая книга загрузилась (чтобы сразу показать её в панели).
  final ValueChanged<CatalogBook>? onFirst;

  /// Открыть подраздел каталога OPDS.
  final ValueChanged<OpdsNav>? onSection;

  @override
  State<CatalogResults> createState() => _CatalogResultsState();
}

class _CatalogResultsState extends State<CatalogResults> {
  final _books = <CatalogBook>[];
  final _sections = <OpdsNav>[];
  Future<CatalogPage> Function()? _more;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load(widget.load);
  }

  Future<void> _load(Future<CatalogPage> Function() load) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await load();
      if (!mounted) return;
      final wasEmpty = _books.isEmpty;
      setState(() {
        _books.addAll(page.books);
        _sections.addAll(page.sections);
        _more = page.more;
        _loading = false;
      });
      if (wasEmpty && _books.isNotEmpty) widget.onFirst?.call(_books.first);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  /// Дошли до конца списка — следующая страница.
  void _maybeMore(int index) {
    if (index < _books.length - 6 || _loading || _error != null || _more == null) return;
    final more = _more!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_loading && _more == more) _load(more);
    });
  }

  void _open(CatalogBook b) => widget.onSelect != null ? widget.onSelect!(b) : openCatalogBook(context, b);

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final side = widget.side;

    final footer = _error != null
        ? CatalogMessage(catalogError(_error), onRetry: () => _load(_more ?? widget.load))
        : _loading
            ? const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
            : _more != null
                ? Center(
                    child: TextButton(
                      style: TextButton.styleFrom(foregroundColor: c.ink),
                      onPressed: () => _load(_more!),
                      child: const Text('Показать ещё'),
                    ),
                  )
                : _books.isEmpty && _sections.isEmpty
                    ? CatalogMessage(widget.empty)
                    : const SizedBox.shrink();

    final sections = SliverList.builder(
      itemCount: _sections.length,
      itemBuilder: (context, i) {
        final s = _sections[i];
        return NavInkWell(
          onTap: widget.onSection == null ? null : () => widget.onSection!(s),
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 12, side - 4, 12),
            child: Row(children: [
              BcIcon(BcIcons.folder, size: 22, color: c.ink),
              const SizedBox(width: 14),
              Expanded(child: Text(s.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
              BcIcon(BcIcons.chevronRight, size: 18, color: c.muted),
            ]),
          ),
        );
      },
    );

    final Widget books;
    if (wide) {
      books = SliverPadding(
        padding: EdgeInsets.fromLTRB(side, 12, side, 8),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 160,
            mainAxisSpacing: 20,
            crossAxisSpacing: 18,
            childAspectRatio: 0.46,
          ),
          itemCount: _books.length,
          itemBuilder: (context, i) {
            _maybeMore(i);
            return LayoutBuilder(
              builder: (context, box) => Align(
                alignment: Alignment.topLeft,
                child: CatalogCard(
                  book: _books[i],
                  width: box.maxWidth,
                  selected: _books[i].id == widget.selectedId,
                  onTap: () => _open(_books[i]),
                ),
              ),
            );
          },
        ),
      );
    } else {
      books = SliverPadding(
        padding: const EdgeInsets.only(top: 6),
        sliver: SliverList.builder(
          itemCount: _books.length,
          itemBuilder: (context, i) {
            _maybeMore(i);
            return BookCatalogRow(book: _books[i], side: side, onTap: () => _open(_books[i]));
          },
        ),
      );
    }

    return SliverMainAxisGroup(slivers: [
      if (_sections.isNotEmpty) sections,
      books,
      SliverToBoxAdapter(child: footer),
    ]);
  }
}

/// Страница жанра, подборки или раздела каталога OPDS.
class BookCatalogListScreen extends StatefulWidget {
  const BookCatalogListScreen({
    super.key,
    required this.title,
    required this.filter,
    this.genre,
    this.popularLibriVox = false,
    this.opdsCatalogId,
    this.opdsUrl,
    this.browse = false,
  });

  final String title;
  final CatalogFilter filter;
  final BookGenre? genre;
  final bool popularLibriVox;
  final String? opdsCatalogId;

  /// Раздел каталога OPDS; null — корень.
  final String? opdsUrl;

  /// Показать каталог OPDS как есть: разделы и книги без фильтров.
  final bool browse;

  @override
  State<BookCatalogListScreen> createState() => _BookCatalogListScreenState();
}

class _BookCatalogListScreenState extends State<BookCatalogListScreen> {
  late var _kind = widget.filter.kind;
  CatalogBook? _selected;

  Future<CatalogPage> _load(BookCatalog catalog, CatalogFilter f) {
    if (widget.genre != null) return catalog.genrePage(widget.genre!, f);
    if (widget.popularLibriVox) return catalog.popularLibriVoxPage(f);
    if (widget.opdsCatalogId != null) {
      if (widget.browse) return catalog.browseOpds(widget.opdsCatalogId!, url: widget.opdsUrl);
      return catalog.popularOpdsPage(widget.opdsCatalogId!, f);
    }
    return Future.value(const CatalogPage([]));
  }

  void _openSection(OpdsNav s) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BookCatalogListScreen(
          title: s.title,
          filter: widget.filter,
          opdsCatalogId: widget.opdsCatalogId,
          opdsUrl: s.url,
          browse: true,
        ),
      ));

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
                  labelStyle: TextStyle(
                      fontWeight: _kind == k ? FontWeight.w600 : FontWeight.w500, color: _kind == k ? c.onFill : c.text),
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
        load: () => _load(catalog, filter),
        side: side,
        empty: widget.genre != null
            ? 'В этом жанре пока ничего не нашлось'
            : widget.browse
                ? 'В этом разделе пусто'
                : 'Список пуст',
        onSelect: wide ? (b) => setState(() => _selected = b) : null,
        onFirst: wide ? (b) => setState(() => _selected ??= b) : null,
        onSection: _openSection,
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
