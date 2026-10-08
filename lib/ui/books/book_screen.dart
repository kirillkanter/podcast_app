/// Страница книги: обложка, место в книге, «Слушать» или «Читать»,
/// главы, закладки, описание, полка и удаление.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../books/book_timeline.dart';
import '../../books/locator.dart';
import '../../books/text/text_book.dart';
import '../../data/db/books_dao.dart';
import '../../data/db/database.dart';
import '../../player/playback_logic.dart';
import '../app_scope.dart';
import '../format.dart';
import '../icons.dart';
import '../menu.dart';
import '../now_playing.dart';
import '../theme.dart';
import 'book_start.dart';
import 'book_widgets.dart';
import 'cover_picker.dart';

class BookScreen extends StatefulWidget {
  const BookScreen({super.key, required this.bookId});

  final int bookId;

  @override
  State<BookScreen> createState() => _BookScreenState();
}

enum _Action { later, reading, done, restart, cover, delete }

class _BookScreenState extends State<BookScreen> {
  Stream<BookItem?>? _stream;
  var _tab = 0;
  Future<({List<BookChapter> chapters, BookTimeline timeline})>? _audioChapters;
  Future<TextBookContent>? _text;
  int? _loadedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _stream ??= AppScope.of(context).db.watchBook(widget.bookId);
  }

  void _load(Book book) {
    if (_loadedFor == book.id && (book.kind == BookKind.audio || book.path != null)) return;
    _loadedFor = book.id;
    final scope = AppScope.of(context);
    if (book.kind == BookKind.audio) {
      _audioChapters = () async {
        final tracks = await scope.db.tracksOfBook(book.id);
        final chapters = await scope.db.bookChaptersOf(book.id);
        return (
          chapters: chapters,
          timeline: BookTimeline(
            [for (final t in tracks) t.durationMs],
            [for (final c in chapters) (trackIdx: c.trackIdx, startMs: c.startMs)],
          ),
        );
      }();
    } else if (book.path != null && scope.books != null) {
      _text = scope.books!.openText(book);
    }
  }

  Future<void> _act(Book book, _Action action) async {
    final db = AppScope.of(context).db;
    switch (action) {
      case _Action.later:
        await db.setBookShelf(book.id, BookShelf.later);
      case _Action.reading:
        await db.setBookShelf(book.id, BookShelf.reading);
      case _Action.done:
        await db.setBookShelf(book.id, BookShelf.done);
      case _Action.restart:
        await db.saveBookProgress(
          book.id,
          locator: book.kind == BookKind.audio ? const AudioLocator(0, 0).encode() : TextLocator.start.encode(),
          percent: 0,
        );
        await db.setBookShelf(book.id, BookShelf.reading);
      case _Action.cover:
        final library = AppScope.of(context).books;
        if (library != null) await showCoverPicker(context, library: library, book: book);
      case _Action.delete:
        await _delete(book);
    }
  }

  Future<void> _delete(Book book) async {
    final scope = AppScope.of(context);
    final syncOn = await scope.sync?.isConfigured ?? false;
    if (!mounted) return;
    final text = book.kind == BookKind.text
        ? (syncOn
            ? 'Книга «${book.title}» удалится на всех устройствах, где включена синхронизация, и с сервера. '
                'Место в книге и закладки тоже удалятся.'
            : 'Книга «${book.title}» удалится с этого устройства вместе с местом в книге и закладками.')
        : 'Книга «${book.title}» уйдёт из библиотеки на этом устройстве. '
            '${book.sourceRoot != null ? 'Файлы в папке останутся, и книга больше не появится при проверке папки.' : 'Копия файлов в папке приложения удалится.'}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(book.kind == BookKind.text && syncOn ? 'Удалить книгу везде?' : 'Удалить книгу?'),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Theme.of(context).colorScheme.onError),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final audio = scope.audio;
    if (audio?.currentBookId == book.id) await audio!.close();
    final confirmed = await scope.books?.delete(book) ?? false;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).maybePop();
    if (!confirmed) {
      messenger?.showSnackBar(const SnackBar(
        content: Text('Книга удалена здесь. На других устройствах — при следующей синхронизации (сейчас нет связи с сервером).'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return StreamBuilder<BookItem?>(
      stream: _stream,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) {
          return Scaffold(appBar: AppBar(), body: snap.hasData ? const Center(child: Text('Книга удалена')) : null);
        }
        final book = item.book;
        final p = item.progress;
        _load(book);
        final audio = book.kind == BookKind.audio;
        return Scaffold(
          backgroundColor: c.bg,
          appBar: AppBar(
            actions: [
              BcMenu<_Action>(
                tooltip: 'Ещё',
                borderRadius: BorderRadius.circular(22),
                onSelected: (a) => _act(book, a),
                options: [
                  if (book.shelf != BookShelf.later) const MenuOption(_Action.later, 'Отложить'),
                  if (book.shelf != BookShelf.reading) const MenuOption(_Action.reading, 'Вернуть в «В процессе»'),
                  if (book.shelf != BookShelf.done) MenuOption(_Action.done, audio ? 'Отметить прослушанной' : 'Отметить прочитанной'),
                  if ((p?.percent ?? 0) > 0) const MenuOption(_Action.restart, 'Начать сначала'),
                  if (AppScope.of(context).books != null) const MenuOption(_Action.cover, 'Сменить обложку'),
                  const MenuOption(_Action.delete, 'Удалить книгу'),
                ],
                child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.more_horiz)),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    BookCover(book: book, size: 128),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SelectableText(book.title,
                            style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 19, height: 1.25, color: c.text)),
                        if (book.author != null) ...[
                          const SizedBox(height: 4),
                          Text(book.author!, style: TextStyle(fontSize: 14, color: c.body)),
                        ],
                        if (book.narrator != null)
                          Text('Читает ${book.narrator}', style: TextStyle(fontSize: 13, color: c.muted)),
                        const SizedBox(height: 4),
                        Text(_meta(book), style: TextStyle(fontSize: 13, color: c.muted)),
                        if (book.missing)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text('Файлы книги не найдены: папка недоступна или книгу переместили.',
                                style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.error)),
                          ),
                      ]),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ThinProgress(value: p?.percent ?? 0, height: 4),
                    const SizedBox(height: 6),
                    Row(children: [
                      Text(
                        (p?.percent ?? 0) > 0 ? '${audio ? 'Прослушано' : 'Прочитано'} ${((p!.percent) * 100).floor()} %' : 'Не начата',
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                      const Spacer(),
                      Text(bookProgressText(book, p), style: TextStyle(fontSize: 12, color: c.muted)),
                    ]),
                    if (p?.device != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('Место пришло с устройства «${p!.device}» ${formatAgo(p.updatedAt)}',
                            style: TextStyle(fontSize: 12, color: c.muted)),
                      ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Row(children: [
                    Expanded(child: _MainButton(book: book, progress: p)),
                  ]),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(children: [
                    for (final (i, label) in [audio ? 'Главы' : 'Оглавление', 'Закладки', 'О книге'].indexed) ...[
                      _TabButton(label: label, selected: _tab == i, onTap: () => setState(() => _tab = i)),
                      const SizedBox(width: 22),
                    ],
                  ]),
                ),
                Divider(height: 1, color: c.divider),
                switch (_tab) {
                  0 => audio ? _audioChaptersView(book, p) : _textChaptersView(book, p),
                  1 => FutureBuilder<TextBookContent>(
                      future: audio ? null : _text,
                      builder: (context, text) => BookmarksList(
                        db: AppScope.of(context).db,
                        bookId: book.id,
                        meta: audio ? null : (b) => _textBookmarkMeta(text.data, b),
                        onOpen: (b) => audio
                            ? startAudioBook(context, book, at: AudioLocator.parse(b.locator), openPlayer: true)
                            : openTextBook(context, book, at: TextLocator.parse(b.locator)),
                      ),
                    ),
                  _ => _about(book),
                },
              ]),
            ),
          ),
        );
      },
    );
  }

  /// «Глава · время» под закладкой текстовой книги.
  String _textBookmarkMeta(TextBookContent? content, BookBookmark b) {
    final l = TextLocator.parse(b.locator);
    final ago = formatAgo(b.createdAt);
    if (content == null || l == null || l.chapter >= content.chapters.length) return ago;
    final percent = (content.charsBefore(l.chapter) * 100 / (content.length == 0 ? 1 : content.length)).round();
    return '${content.chapters[l.chapter].title} · $percent % · $ago';
  }

  String _meta(Book b) {
    final parts = <String>[
      if (b.kind == BookKind.audio && (b.durationMs ?? 0) > 0) formatDuration(b.durationMs),
      b.format.toUpperCase(),
      if (b.sizeBytes > 0) '${(b.sizeBytes / 1024 / 1024).toStringAsFixed(b.sizeBytes > 10 << 20 ? 0 : 1)} МБ',
    ];
    return parts.join(' · ');
  }

  Widget _audioChaptersView(Book book, BookProgress? p) {
    return FutureBuilder(
      future: _audioChapters,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
        final t = data.timeline;
        final g = p?.positionMs ?? 0;
        final current = (p?.percent ?? 0) > 0 ? t.chapterAt(g) : -1;
        return Column(children: [
          for (var i = 0; i < data.chapters.length; i++)
            ChapterTile(
              number: i + 1,
              title: data.chapters[i].title,
              trailing: chapterLength(t.chapterEnd(i) - t.chapterStart(i)),
              current: i == current,
              done: current >= 0 && i < current,
              progress: i == current && t.chapterEnd(i) > t.chapterStart(i)
                  ? (g - t.chapterStart(i)) / (t.chapterEnd(i) - t.chapterStart(i))
                  : null,
              onTap: () => startAudioBook(context, book, chapter: data.chapters[i], openPlayer: true),
            ),
        ]);
      },
    );
  }

  Widget _textChaptersView(Book book, BookProgress? p) {
    final c = BcColors.of(context);
    if (book.path == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Книга скачивается с сервера…', style: TextStyle(color: c.muted)),
      );
    }
    return FutureBuilder<TextBookContent>(
      future: _text,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(padding: const EdgeInsets.all(24), child: Text('Не удалось прочитать книгу: ${snap.error}'));
        }
        final content = snap.data;
        if (content == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
        final current = TextLocator.parse(p?.locator)?.chapter ?? -1;
        return Column(children: [
          for (var i = 0; i < content.chapters.length; i++)
            ChapterTile(
              number: i + 1,
              title: content.chapters[i].title,
              trailing: '${(content.charsBefore(i) * 100 / (content.length == 0 ? 1 : content.length)).round()} %',
              current: i == current,
              done: current >= 0 && i < current,
              onTap: () => openTextBook(context, book, chapter: i),
            ),
        ]);
      },
    );
  }

  Widget _about(Book b) {
    final c = BcColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (b.description != null) ...[
          SelectableText(b.description!, style: TextStyle(fontSize: 15, height: 1.5, color: c.body)),
          const SizedBox(height: 18),
        ],
        _Fact('Формат', b.format.toUpperCase()),
        if (b.language != null) _Fact('Язык', b.language!),
        _Fact('Добавлена', formatEpisodeDate(b.addedAt)),
        if (b.kind == BookKind.text) _Fact('На сервере', b.uploaded ? 'да, доступна на всех устройствах' : 'ещё нет'),
        if (b.sourceRoot != null) _Fact('Папка', b.path ?? b.sourceRoot!),
        if (b.kind == BookKind.audio && (b.durationMs ?? 0) > 0) _Fact('Длительность', formatClock(Duration(milliseconds: b.durationMs!))),
      ]),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Text(label, style: TextStyle(fontSize: 13, color: c.muted))),
        Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 14))),
      ]),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: selected ? c.bar : Colors.transparent, width: 2))),
        child: Text(label,
            style: TextStyle(fontSize: 15, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: selected ? c.text : c.muted)),
      ),
    );
  }
}

class _MainButton extends StatelessWidget {
  const _MainButton({required this.book, required this.progress});

  final Book book;
  final BookProgress? progress;

  @override
  Widget build(BuildContext context) {
    final started = (progress?.percent ?? 0) > 0 && (progress?.percent ?? 0) < 0.995;
    if (book.kind == BookKind.text) {
      final ready = book.path != null;
      return FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
        onPressed: ready ? () => openTextBook(context, book) : null,
        icon: const BcIcon(BcIcons.book, size: 20),
        label: Text(!ready ? 'Скачивается…' : (started ? 'Продолжить чтение' : 'Читать')),
      );
    }
    // Одна кнопка: играет эта книга — «Пауза», иначе — слушать с открытым плеером.
    return NowPlayingBuilder(builder: (context, now, audio) {
      final playing = audio?.currentBookId == book.id && now.playing;
      return FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
        onPressed: book.missing
            ? null
            : playing
                ? audio!.pause
                : () => unawaited(startAudioBook(context, book, openPlayer: true)),
        icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        label: Text(playing ? 'Пауза' : (started ? 'Продолжить' : 'Слушать')),
      );
    });
  }
}
