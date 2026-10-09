/// Книга из каталога: обложка, сведения, главы и скачивание в библиотеку.
library;

import 'package:flutter/material.dart';

import '../../../catalog/books/book_catalog.dart';
import '../../../data/db/books_dao.dart';
import '../../../platform/open_url.dart';
import '../../app_scope.dart';
import '../../format.dart';
import '../../icons.dart';
import '../../theme.dart';
import '../book_screen.dart';
import 'catalog_widgets.dart';

/// Отдельная страница книги (телефон).
class CatalogItemScreen extends StatelessWidget {
  const CatalogItemScreen({super.key, required this.book});

  final CatalogBook book;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.paddingOf(context).bottom + 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: CatalogItemDetails(book: book),
          ),
        ),
      ),
    );
  }
}

void openCatalogBook(BuildContext context, CatalogBook book) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => CatalogItemScreen(book: book)));

/// Содержимое страницы книги; на компьютере — в панели справа.
class CatalogItemDetails extends StatefulWidget {
  const CatalogItemDetails({super.key, required this.book, this.panel = false});

  final CatalogBook book;

  /// В боковой панели: обложка меньше.
  final bool panel;

  @override
  State<CatalogItemDetails> createState() => _CatalogItemDetailsState();
}

class _CatalogItemDetailsState extends State<CatalogItemDetails> {
  Future<CatalogDetails>? _details;
  Stream<Map<String, int>>? _downloaded;
  bool _allChapters = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final catalog = AppScope.of(context).bookCatalog;
    _details ??= catalog?.details(widget.book);
    _downloaded ??= catalog?.watchDownloaded();
  }

  @override
  void didUpdateWidget(CatalogItemDetails old) {
    super.didUpdateWidget(old);
    if (old.book.id != widget.book.id) {
      _details = AppScope.of(context).bookCatalog?.details(widget.book);
      _allChapters = false;
    }
  }

  Future<void> _download(BookCatalog catalog, CatalogDetails d) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final id = await catalog.download(d);
      if (id != null) {
        messenger.showSnackBar(SnackBar(content: Text('«${d.book.title}» — в библиотеке')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e is BookCatalogException ? e.message : 'Не удалось скачать: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final catalog = AppScope.of(context).bookCatalog;
    return FutureBuilder<CatalogDetails>(
      future: _details,
      builder: (context, snap) {
        final d = snap.data;
        final book = d?.book ?? widget.book;
        final coverWidth = widget.panel ? (book.audio ? 200.0 : 160.0) : (book.audio ? 220.0 : 170.0);
        final duration = d?.duration;
        final summary = [
          if (book.audio && d != null && d.files.isNotEmpty) chaptersWord(d.files.length),
          if (duration != null) formatDuration(duration.inMilliseconds),
          if (!book.audio && d?.best != null) d!.best!.format.toUpperCase(),
        ].join(' · ');
        final facts = <(String, String)>[
          if (d?.size != null) ('Размер', formatSize(d!.size!)),
          if (!book.audio && d?.best != null) ('Формат', _formatName(d!.best!.format)),
          if (book.language != null) ('Язык', _languageName(book.language!)),
          ('Источник', book.sourceName),
        ];
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 8),
          Center(child: CatalogCover(book: book, width: coverWidth, large: true)),
          const SizedBox(height: 20),
          Text(book.title,
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: widget.panel ? 18 : 21, height: 1.25)),
          if (book.author != null) ...[
            const SizedBox(height: 6),
            Text(book.author!, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: c.body)),
          ],
          if (book.source == CatalogSource.librivox) ...[
            const SizedBox(height: 4),
            Text('Читают: волонтёры LibriVox', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.muted)),
          ],
          const SizedBox(height: 10),
          Center(child: KindMark(audio: book.audio, text: summary.isEmpty ? (book.audio ? 'Аудиокнига' : 'Книга') : summary, size: 13)),
          const SizedBox(height: 20),
          if (catalog != null)
            _Button(
              catalog: catalog,
              book: book,
              details: d,
              loading: snap.connectionState != ConnectionState.done,
              error: snap.hasError ? catalogError(snap.error) : null,
              downloaded: _downloaded,
              onDownload: d == null ? null : () => _download(catalog, d),
              onRetry: () => setState(() => _details = catalog.details(widget.book)),
            ),
          if (book.webUrl != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 46),
                shape: const StadiumBorder(),
                foregroundColor: c.text,
                side: BorderSide(color: c.line),
              ),
              onPressed: () => openUrl(book.webUrl!),
              icon: BcIcon(BcIcons.external, size: 18, color: c.text),
              label: const Text('Открыть на сайте'),
            ),
          ],
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(14)),
            child: Column(children: [
              for (var i = 0; i < facts.length; i++) ...[
                if (i > 0) Divider(height: 1, color: c.divider),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(children: [
                    Text(facts[i].$1, style: TextStyle(fontSize: 14, color: c.muted)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(facts[i].$2,
                          textAlign: TextAlign.right, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                    ),
                  ]),
                ),
              ],
            ]),
          ),
          if ((book.description ?? '').isNotEmpty) ...[
            const SizedBox(height: 22),
            Text('О книге', style: sectionTitleStyle(context)),
            const SizedBox(height: 8),
            Text(book.description!, style: TextStyle(fontSize: 14, height: 1.5, color: c.body)),
          ],
          if (book.audio && d != null && d.files.length > 1) ...[
            const SizedBox(height: 22),
            Text('Главы', style: sectionTitleStyle(context)),
            const SizedBox(height: 6),
            for (final (i, f) in d.files.take(_allChapters ? d.files.length : 5).indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  SizedBox(
                    width: 32,
                    child: Text('${i + 1}', style: TextStyle(fontSize: 13, color: c.muted)),
                  ),
                  Expanded(
                    child: Text(f.title ?? 'Глава ${i + 1}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                  ),
                  if (f.duration != null)
                    Text(_clock(f.duration!), style: TextStyle(fontSize: 13, color: c.muted)),
                ]),
              ),
            if (!_allChapters && d.files.length > 5)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(foregroundColor: c.ink, padding: EdgeInsets.zero),
                  onPressed: () => setState(() => _allChapters = true),
                  child: Text('Все ${chaptersWord(d.files.length)}'),
                ),
              ),
          ],
        ]);
      },
    );
  }

  static String _clock(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  static String _formatName(String f) => switch (f) {
        'fbz' => 'FB2 (zip)',
        _ => f.toUpperCase(),
      };

  static String _languageName(String code) => switch (code) {
        'ru' => 'Русский',
        'en' => 'Английский',
        'de' => 'Немецкий',
        'fr' => 'Французский',
        'es' => 'Испанский',
        'it' => 'Итальянский',
        _ => code,
      };
}

/// Главная кнопка: скачать / идёт загрузка / в библиотеке.
class _Button extends StatelessWidget {
  const _Button({
    required this.catalog,
    required this.book,
    required this.details,
    required this.loading,
    required this.error,
    required this.downloaded,
    required this.onDownload,
    required this.onRetry,
  });

  final BookCatalog catalog;
  final CatalogBook book;
  final CatalogDetails? details;
  final bool loading;
  final String? error;
  final Stream<Map<String, int>>? downloaded;
  final VoidCallback? onDownload;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final style = FilledButton.styleFrom(minimumSize: const Size(0, 50), shape: const StadiumBorder());
    return StreamBuilder<Map<String, int>>(
      stream: downloaded,
      builder: (context, got) => ValueListenableBuilder<Map<String, CatalogDownload>>(
        valueListenable: catalog.downloads,
        builder: (context, running, _) {
          final progress = running[book.id];
          if (progress != null) {
            final f = progress.fraction;
            return Container(
              height: 50,
              padding: const EdgeInsets.only(left: 20, right: 4),
              decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(25)),
              child: Row(children: [
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(f == null ? 'Загрузка' : 'Загрузка · ${(f * 100).round()} %',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                      const Spacer(),
                      if (progress.total != null)
                        Text('${formatSize(progress.received)} из ${formatSize(progress.total!)}',
                            style: TextStyle(fontSize: 12, color: c.muted)),
                    ]),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(value: f, minHeight: 4, backgroundColor: c.track, color: c.ink),
                    ),
                  ]),
                ),
                IconButton(
                  tooltip: 'Отменить загрузку',
                  onPressed: () => catalog.cancel(book.id),
                  icon: BcIcon(BcIcons.close, size: 20, color: c.text),
                ),
              ]),
            );
          }
          final bookId = got.data?[book.id];
          if (bookId != null) {
            return FutureBuilder(
              future: AppScope.of(context).db.bookById(bookId),
              builder: (context, b) {
                if (b.connectionState == ConnectionState.done && b.data == null) {
                  // Книгу удалили из библиотеки — можно скачать снова.
                  return _downloadButton(context, style);
                }
                return FilledButton.icon(
                  style: style.copyWith(
                    backgroundColor: WidgetStatePropertyAll(c.raised),
                    foregroundColor: WidgetStatePropertyAll(c.text),
                  ),
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => BookScreen(bookId: bookId))),
                  icon: BcIcon(BcIcons.downloaded, size: 20, color: c.ink),
                  label: const Text('В библиотеке'),
                );
              },
            );
          }
          return _downloadButton(context, style);
        },
      ),
    );
  }

  Widget _downloadButton(BuildContext context, ButtonStyle style) {
    final c = BcColors.of(context);
    if (error != null) {
      return Column(children: [
        Text(error!, textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
        TextButton(style: TextButton.styleFrom(foregroundColor: c.ink), onPressed: onRetry, child: const Text('Повторить')),
      ]);
    }
    final d = details;
    final noFiles = d != null && d.files.isEmpty;
    final size = d?.size;
    return FilledButton.icon(
      style: style,
      onPressed: loading || noFiles ? null : onDownload,
      icon: loading
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const BcIcon(BcIcons.download, size: 20),
      label: Text(noFiles
          ? 'Файлов для скачивания нет'
          : size == null
              ? 'Скачать в библиотеку'
              : 'Скачать в библиотеку · ${formatSize(size)}'),
    );
  }
}
