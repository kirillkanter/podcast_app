/// Раздел «Книги»: аудиокниги и текстовые книги, отдельно от подкастов.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../catalog/books/book_catalog.dart';
import '../../data/db/books_dao.dart';
import '../../data/db/database.dart';
import '../app_scope.dart';
import '../icons.dart';
import '../menu.dart';
import '../now_playing.dart';
import '../nav_ink.dart';
import '../theme.dart';
import 'book_import.dart';
import 'book_screen.dart';
import 'book_start.dart';
import 'book_widgets.dart';
import 'catalog/add_opds.dart';
import 'catalog/catalog_view.dart';
import 'reader/reading_stats.dart';

enum _Filter {
  reading('В процессе'),
  later('Отложено'),
  done('Готово'),
  all('Все');

  const _Filter(this.label);
  final String label;

  bool matches(Book b) => switch (this) {
        _Filter.reading => b.shelf == BookShelf.reading,
        _Filter.later => b.shelf == BookShelf.later,
        _Filter.done => b.shelf == BookShelf.done,
        _Filter.all => true,
      };
}

class BooksScreen extends StatefulWidget {
  const BooksScreen({super.key});

  @override
  State<BooksScreen> createState() => _BooksScreenState();
}

class _BooksScreenState extends State<BooksScreen> with WidgetsBindingObserver {
  var _filter = _Filter.reading;
  Stream<List<BookItem>>? _books;
  bool _scanned = false;
  bool _refreshing = false;

  /// Открыта вкладка «Каталог».
  bool _catalogTab = false;
  Stream<CatalogConfig>? _catalogConfig;

  static bool get _desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _books ??= AppScope.of(context).db.watchBooks();
    _catalogConfig ??= AppScope.of(context).bookCatalog?.watchConfig();
    if (!_scanned) {
      _scanned = true;
      // Новые книги в папках-источниках появятся без нажатий.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(rescanBookSources(context));
        // На компьютере ещё и следим за папками.
        if (_desktop) unawaited(AppScope.of(context).books?.watchSources());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    // Вернулись в приложение (например, после копирования книг в папку) —
    // проверяем папки, но не чаще раза в минуту.
    final last = AppScope.of(context).books?.lastScan;
    if (last == null || DateTime.now().difference(last) > const Duration(minutes: 1)) {
      unawaited(rescanBookSources(context));
    }
  }

  Future<void> _refresh() async {
    final scope = AppScope.of(context);
    setState(() => _refreshing = true);
    try {
      await rescanBookSources(context);
      try {
        await scope.sync?.syncNow();
      } catch (_) {
        // Ошибка видна в настройках синхронизации.
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _openBook(Book book) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BookScreen(bookId: book.id)));

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final library = AppScope.of(context).books;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<CatalogConfig>(
          stream: _catalogConfig,
          builder: (context, cfg) {
            final config = cfg.data;
            final catalogOn = config != null && config.enabled;
            final header = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: EdgeInsets.fromLTRB(wide ? 32 : 20, 20, wide ? 24 : 12, catalogOn ? 4 : 8),
                child: SizedBox(
                  // Высота одна на обеих вкладках: кнопки справа разного размера.
                  height: 48,
                  child: Row(children: [
                  Expanded(child: Text('Книги', style: screenTitleStyle(context).copyWith(fontSize: wide ? 30 : 26))),
                  if (!(catalogOn && _catalogTab)) ...[
                    IconButton(
                      tooltip: 'Статистика чтения',
                      onPressed: () => showReadingStats(context),
                      icon: Icon(Icons.insights_rounded, color: c.text),
                    ),
                    IconButton(
                      tooltip: 'Обновить: проверить папки с книгами и синхронизировать',
                      onPressed: _refreshing ? null : _refresh,
                      icon: _refreshing
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.refresh_rounded, color: c.text),
                    ),
                  ],
                  const SizedBox(width: 4),
                  _AddButton(config: config, onCatalogAdded: () => setState(() => _catalogTab = true)),
                ]),
                ),
              ),
              if (catalogOn)
                Padding(
                  padding: EdgeInsets.fromLTRB(wide ? 32 : 20, 4, 20, 12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: _Tabs(catalog: _catalogTab, onChanged: (v) => setState(() => _catalogTab = v)),
                  ),
                ),
            ]);
            if (catalogOn && _catalogTab) return CatalogView(config: config!, header: header);
            return StreamBuilder<List<BookItem>>(
          stream: _books,
          builder: (context, snap) {
            final all = snap.data ?? const <BookItem>[];
            final items = all.where((i) => _filter.matches(i.book)).toList();
            final current = all
                .where((i) => i.book.shelf == BookShelf.reading && (i.progress?.percent ?? 0) > 0 && (i.progress?.percent ?? 0) < 0.995)
                .firstOrNull;
            return RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
                SliverToBoxAdapter(child: header),
                if (library != null)
                  SliverToBoxAdapter(
                    child: ValueListenableBuilder<String?>(
                      valueListenable: library.status,
                      builder: (context, status, _) => status == null
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                              child: Row(children: [
                                const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                const SizedBox(width: 10),
                                Expanded(child: Text(status, style: TextStyle(fontSize: 13, color: c.muted))),
                              ]),
                            ),
                    ),
                  ),
                if (snap.hasData && all.isEmpty)
                  const SliverFillRemaining(hasScrollBody: false, child: _Empty())
                else ...[
                  if (current != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(wide ? 32 : 16, 4, wide ? 32 : 16, 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 640),
                            child: _CurrentCard(item: current, onOpen: () => _openBook(current.book)),
                          ),
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.fromLTRB(wide ? 32 : 20, 0, 20, 10),
                      child: Row(children: [
                        for (final f in _Filter.values) ...[
                          ChoiceChip(
                            label: Text('${f.label} · ${all.where((i) => f.matches(i.book)).length}'),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ]),
                    ),
                  ),
                  if (items.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          switch (_filter) {
                            _Filter.reading => 'Сейчас ничего не читается и не слушается.',
                            _Filter.later => 'Отложенных книг нет.',
                            _Filter.done => 'Законченных книг пока нет.',
                            _Filter.all => 'Книг нет.',
                          },
                          style: TextStyle(color: c.muted),
                        ),
                      ),
                    )
                  else if (wide)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(32, 6, 32, 24),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 190,
                          mainAxisSpacing: 22,
                          crossAxisSpacing: 18,
                          childAspectRatio: 0.66,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, i) => _GridTile(item: items[i], onOpen: () => _openBook(items[i].book)),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) => _BookRow(item: items[i], onOpen: () => _openBook(items[i].book)),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ]),
            );
          },
        );
          },
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.config, required this.onCatalogAdded});

  /// Настройки каталога; null — каталога в приложении нет (тесты).
  final CatalogConfig? config;

  /// Каталог включили или добавили — показать вкладку «Каталог».
  final VoidCallback onCatalogAdded;

  Future<void> _select(BuildContext context, int v) async {
    switch (v) {
      case 0:
        await pickBookFiles(context);
      case 1:
        await pickBookFolder(context);
      case 2:
        await showAddOpdsCatalog(context);
        if (!context.mounted) return;
        final catalog = AppScope.of(context).bookCatalog;
        if (catalog != null && (await catalog.config()).opds.isNotEmpty) onCatalogAdded();
      case 3:
        await AppScope.of(context).bookCatalog?.setLibriVox(true);
        onCatalogAdded();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final catalog = AppScope.of(context).bookCatalog;
    return BcMenu<int>(
      tooltip: 'Добавить книгу или каталог',
      borderRadius: BorderRadius.circular(22),
      onSelected: (v) => _select(context, v),
      options: [
        const MenuOption(0, 'Файлы книги (EPUB, FB2, TXT, MP3, M4B)'),
        const MenuOption(1, 'Папка с аудиокнигами'),
        if (catalog != null) const MenuOption(2, 'Каталог OPDS'),
        if (catalog != null && config != null && !config!.librivox) const MenuOption(3, 'Каталог LibriVox'),
      ],
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: c.raised, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: BcIcon(BcIcons.plus, size: 22, color: c.text),
      ),
    );
  }
}

/// Переключатель «Мои | Каталог», как в макете: две половины на подложке.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.catalog, required this.onChanged});

  final bool catalog;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    Widget tab(String label, bool value) {
      final on = catalog == value;
      return Expanded(
        child: Semantics(
          selected: on,
          button: true,
          child: Material(
            color: on ? c.bg : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: on ? null : () => onChanged(value),
              child: SizedBox(
                height: 36,
                child: Center(
                  child: Text(
                    label,
                    textHeightBehavior: const TextHeightBehavior(
                      applyHeightToFirstAscent: false,
                      applyHeightToLastDescent: false,
                    ),
                    style: TextStyle(
                      fontSize: 14,
                      height: 1,
                      // Одинаковая толщина: иначе подписи «прыгают» по высоте.
                      fontWeight: FontWeight.w600,
                      color: on ? c.text : c.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [tab('Мои', false), tab('Каталог', true)]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        BcIcon(BcIcons.book, size: 48, color: c.muted),
        const SizedBox(height: 16),
        Text('Здесь будут ваши книги', style: sectionTitleStyle(context), textAlign: TextAlign.center),
        const SizedBox(height: 10),
        Text(
          'Аудиокниги — папкой: каждая подпапка с файлами MP3 или M4B становится книгой. '
          'Электронные книги — файлами EPUB, FB2 и TXT; они синхронизируются между устройствами.',
          textAlign: TextAlign.center,
          style: TextStyle(color: c.muted, height: 1.45),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => pickBookFolder(context),
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('Папка с аудиокнигами'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => pickBookFiles(context),
          icon: const Icon(Icons.upload_file_outlined),
          label: const Text('Файлы книг'),
        ),
      ]),
    );
  }
}

/// Кнопка на строке книги: слушать/пауза или читать.
class BookActionButton extends StatelessWidget {
  const BookActionButton({super.key, required this.book, this.size = 44, this.accent = false});

  final Book book;
  final double size;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    if (book.kind == BookKind.text) {
      return RoundIconButton(
        icon: BcIcons.book,
        tooltip: 'Читать',
        size: size,
        style: accent ? RoundStyle.accent : RoundStyle.outline,
        onPressed: () => openTextBook(context, book),
      );
    }
    return NowPlayingBuilder(builder: (context, now, audio) {
      final playing = audio?.currentBookId == book.id && now.playing;
      return RoundIconButton(
        icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        iconSize: size * 0.5,
        tooltip: playing ? 'Пауза' : 'Слушать',
        size: size,
        style: accent ? RoundStyle.accent : RoundStyle.outline,
        onPressed: playing ? audio!.pause : () => startAudioBook(context, book),
      );
    });
  }
}

class _CurrentCard extends StatelessWidget {
  const _CurrentCard({required this.item, required this.onOpen});

  final BookItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final b = item.book;
    final p = item.progress;
    return Material(
      color: c.card,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: NavInkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              BookCover(book: b, size: 104),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.kind == BookKind.audio ? 'Сейчас слушаю' : 'Сейчас читаю',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.ink)),
                  const SizedBox(height: 4),
                  Text(b.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 16, height: 1.25, color: c.text)),
                  if (b.author != null) ...[
                    const SizedBox(height: 4),
                    Text(b.author!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.muted)),
                  ],
                  if (b.narrator != null)
                    Text('Читает ${b.narrator}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.muted)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ThinProgress(value: p?.percent ?? 0, height: 4),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text('${((p?.percent ?? 0) * 100).floor()} %', style: TextStyle(fontSize: 12, color: c.muted)),
                    const Spacer(),
                    Text(bookProgressText(b, p), style: TextStyle(fontSize: 12, color: c.muted)),
                  ]),
                ]),
              ),
              const SizedBox(width: 14),
              BookActionButton(book: b, size: 52, accent: true),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _BookRow extends StatelessWidget {
  const _BookRow({required this.item, required this.onOpen});

  final BookItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final b = item.book;
    return NavInkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(children: [
          Opacity(opacity: b.missing ? 0.5 : 1, child: BookCover(book: b, size: 56)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              if (b.author != null)
                Text(b.author!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
              const SizedBox(height: 4),
              Row(children: [
                BookKindIcon(kind: b.kind),
                const SizedBox(width: 8),
                if ((item.progress?.percent ?? 0) > 0) ...[
                  ThinProgress(value: item.progress!.percent, width: 40),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    b.missing ? 'файлы не найдены' : bookProgressText(b, item.progress),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.muted),
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          if (!b.missing && !(b.kind == BookKind.text && b.path == null)) BookActionButton(book: b),
        ]),
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile({required this.item, required this.onOpen});

  final BookItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final b = item.book;
    return NavInkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onOpen,
      child: LayoutBuilder(builder: (context, box) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Opacity(opacity: b.missing ? 0.5 : 1, child: BookCover(book: b, size: box.maxWidth)),
          const SizedBox(height: 8),
          ThinProgress(value: item.progress?.percent ?? 0),
          const SizedBox(height: 6),
          Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.25)),
          const SizedBox(height: 2),
          Row(children: [
            BookKindIcon(kind: b.kind, size: 13),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                [?b.author, b.missing ? 'файлы не найдены' : bookProgressText(b, item.progress)].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
            ),
          ]),
        ]);
      }),
    );
  }
}
