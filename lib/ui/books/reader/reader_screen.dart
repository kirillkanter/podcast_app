/// Читалка: книга постранично, настройки текста, оглавление, закладки,
/// перевод выделенного. Пока открыта — экран не гаснет. Место в книге
/// сохраняется при каждом перелистывании и уходит на сервер.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../books/locator.dart';
import '../../../books/text/text_book.dart';
import '../../../books/translator.dart';
import '../../../data/db/books_dao.dart';
import '../../../data/db/database.dart';
import '../../../platform/books_platform.dart';
import '../../../sync/book_sync.dart';
import '../../app_scope.dart';
import '../../icons.dart';
import '../../theme.dart';
import '../book_widgets.dart';
import 'paginator.dart';
import 'reader_style.dart';
import 'translate_sheet.dart';

/// Ключ скорости чтения (символов в минуту) — для «осталось до конца главы».
const _speedKey = 'reader.charsPerMinute';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.book, required this.content, this.at});

  final Book book;
  final TextBookContent content;

  /// Открыть на этом месте (глава из оглавления, закладка); иначе — где остановились.
  final TextLocator? at;

  static Route<void> route({required Book book, required TextBookContent content, TextLocator? at}) =>
      MaterialPageRoute<void>(builder: (_) => ReaderScreen(book: book, content: content, at: at));

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  ReaderStyle _style = const ReaderStyle();
  bool _ready = false;

  int _chapter = 0;
  int _page = 0;

  /// Где читаем: сохраняется при смене страницы, по нему же встаём на место
  /// после смены размера шрифта или окна.
  TextLocator _anchor = TextLocator.start;
  String? _layoutKey;
  final _cache = <String, List<ReaderPage>>{};

  bool _panels = false;
  String? _selected;
  final _focus = FocusNode();
  Timer? _saveTimer;
  double _charsPerMinute = 1100;
  DateTime _pageShownAt = DateTime.now();
  DateTime _lastWheel = DateTime(0);

  // Касание: начало жеста.
  Offset? _downAt;
  DateTime? _downTime;
  PointerDeviceKind? _downKind;

  TextBookContent get _content => widget.content;
  String get _language => widget.content.language != null && widget.content.language!.isNotEmpty
      ? baseLanguage(widget.content.language)
      : guessLanguage(widget.content.chapters.first.blocks.take(20).map((b) => b.text).join(' '));

  late AppDatabase _db;
  BookSync? _bookSync;
  bool _started = false;
  double? _dragPercent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(keepScreenOn(true));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _db = scope.db;
    _bookSync = scope.bookSync;
    if (!_started) {
      _started = true;
      unawaited(_init());
    }
  }

  Future<void> _init() async {
    final db = _db;
    final style = await ReaderStyle.load(db);
    final speed = double.tryParse(await db.setting(_speedKey) ?? '');
    var at = widget.at;
    if (at == null) {
      final p = await db.bookProgress(widget.book.id);
      at = TextLocator.parse(p?.locator);
    }
    if (!mounted) return;
    setState(() {
      _style = style;
      if (speed != null && speed > 100) _charsPerMinute = speed;
      final a = at ?? TextLocator.start;
      _anchor = a.chapter < _content.chapters.length ? a : TextLocator.start;
      _chapter = _anchor.chapter;
      _layoutKey = null; // страница найдётся по _anchor при первой разбивке
      _ready = true;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) _saveNow(push: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(keepScreenOn(false));
    _saveTimer?.cancel();
    _saveNow(push: true);
    _focus.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Место в книге
  // -------------------------------------------------------------------------

  int _charsBefore(TextLocator l) {
    var n = _content.charsBefore(l.chapter);
    final blocks = _content.chapters[l.chapter].blocks;
    for (var i = 0; i < l.block && i < blocks.length; i++) {
      n += blocks[i].length;
    }
    return n + l.offset;
  }

  double get _percent {
    if (_content.length == 0) return 0;
    final pages = _cache[_cacheKey(_chapter)];
    final lastChapter = _chapter == _content.chapters.length - 1;
    if (lastChapter && pages != null && _page >= pages.length - _step) return 1;
    return (_charsBefore(_anchor) / _content.length).clamp(0.0, 1.0);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () => _saveNow());
  }

  void _saveNow({bool push = false}) {
    _saveTimer?.cancel();
    if (!_ready) return;
    final db = _db;
    final sync = _bookSync;
    final percent = _percent;
    final locator = _anchor.encode();
    final speed = _charsPerMinute.round().toString();
    unawaited(() async {
      try {
        await db.saveBookProgress(widget.book.id, locator: locator, percent: percent);
        if (percent >= 0.999) await db.setBookShelf(widget.book.id, BookShelf.done);
        await db.setSetting(_speedKey, speed);
        sync?.pushSoon(push ? const Duration(seconds: 1) : const Duration(seconds: 20));
      } catch (_) {}
    }());
  }

  // -------------------------------------------------------------------------
  // Страницы
  // -------------------------------------------------------------------------

  double _pageWidth = 0;
  double _pageHeight = 0;
  TextScaler _scaler = TextScaler.noScaling;
  bool _spread = false;

  int get _step => _spread ? 2 : 1;

  String _cacheKey(int chapter) =>
      '$chapter|${_style.layoutKey}|${_pageWidth.round()}|${_pageHeight.round()}|${_scaler.scale(10)}';

  TextStyle get _baseStyle => TextStyle(
        fontFamily: _style.font.family,
        fontSize: _style.fontSize,
        height: _style.lineHeight,
        color: _paper.ink,
        letterSpacing: 0,
      );

  Paper get _paper => _style.paperFor(Theme.of(context).brightness);

  List<ReaderPage> _pagesOf(int chapter) => _cache.putIfAbsent(
        _cacheKey(chapter),
        () => paginateChapter(
          _content.chapters[chapter],
          width: _pageWidth,
          height: _pageHeight,
          base: _baseStyle,
          scaler: _scaler,
        ),
      );

  void _showPage(int chapter, int page) {
    final pages = _pagesOf(chapter);
    final p = _spread ? (page.clamp(0, pages.length - 1) ~/ 2) * 2 : page.clamp(0, pages.length - 1);
    setState(() {
      _chapter = chapter;
      _page = p;
      _anchor = pages[p].locator(chapter);
    });
    _scheduleSave();
  }

  void _next() {
    // Скорость чтения — по времени на странице (если читали, а не листали).
    final seconds = DateTime.now().difference(_pageShownAt).inSeconds;
    final chars = _visibleChars();
    if (seconds >= 5 && seconds <= 300 && chars > 200) {
      final measured = chars / (seconds / 60);
      _charsPerMinute = (_charsPerMinute * 0.8 + measured * 0.2).clamp(300, 4000).toDouble();
    }
    _pageShownAt = DateTime.now();
    final pages = _pagesOf(_chapter);
    if (_page + _step < pages.length) {
      _showPage(_chapter, _page + _step);
    } else if (_chapter + 1 < _content.chapters.length) {
      _showPage(_chapter + 1, 0);
    } else {
      _saveNow(push: true);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Конец книги')));
    }
  }

  void _prev() {
    _pageShownAt = DateTime.now();
    if (_page > 0) {
      _showPage(_chapter, _page - _step);
    } else if (_chapter > 0) {
      final pages = _pagesOf(_chapter - 1);
      _showPage(_chapter - 1, pages.length - 1);
    }
  }

  int _visibleChars() {
    final pages = _pagesOf(_chapter);
    var n = 0;
    for (var i = _page; i < _page + _step && i < pages.length; i++) {
      for (final f in pages[i].fragments) {
        n += f.end - f.start;
      }
    }
    return n;
  }

  void _goTo(TextLocator l) {
    if (l.chapter >= _content.chapters.length) return;
    final pages = _pagesOf(l.chapter);
    _showPage(l.chapter, pageOf(pages, l.block, l.offset));
  }

  // -------------------------------------------------------------------------
  // Жесты
  // -------------------------------------------------------------------------

  bool get _hasSelection => (_selected ?? '').trim().isNotEmpty;

  void _onPointerDown(PointerDownEvent e) {
    _downAt = e.localPosition;
    _downTime = DateTime.now();
    _downKind = e.kind;
  }

  void _onPointerUp(PointerUpEvent e, double width) {
    final start = _downAt;
    final time = _downTime;
    _downAt = null;
    if (start == null || time == null) return;
    final d = e.localPosition - start;
    final ms = DateTime.now().difference(time).inMilliseconds;
    // Свайп пальцем — листание (мышью тянут, чтобы выделить текст).
    if (_downKind == PointerDeviceKind.touch && d.dx.abs() > 60 && d.dx.abs() > d.dy.abs() * 1.5 && ms < 700) {
      if (_hasSelection) return;
      d.dx < 0 ? _next() : _prev();
      return;
    }
    if (d.distance > 12 || ms > 450) return;
    if (_hasSelection) return; // нажатие снимает выделение
    final x = e.localPosition.dx / width;
    if (x < 0.3) {
      _prev();
    } else if (x > 0.7) {
      _next();
    } else {
      setState(() => _panels = !_panels);
    }
  }

  void _onWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final now = DateTime.now();
    if (now.difference(_lastWheel) < const Duration(milliseconds: 250)) return;
    _lastWheel = now;
    e.scrollDelta.dy > 0 ? _next() : _prev();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.space) {
      _next();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.pageUp) {
      _prev();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_panels) {
        setState(() => _panels = false);
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -------------------------------------------------------------------------
  // Отрисовка
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final paper = _paper;
    return Scaffold(
      backgroundColor: paper.bg,
      body: !_ready
          ? const SizedBox.shrink()
          : SafeArea(
              child: Focus(
                focusNode: _focus,
                autofocus: true,
                onKeyEvent: _onKey,
                child: LayoutBuilder(builder: (context, box) => _layout(context, box, paper)),
              ),
            ),
    );
  }

  Widget _layout(BuildContext context, BoxConstraints box, Paper paper) {
    final wide = box.maxWidth >= 1000;
    final hPad = wide ? 56.0 : (box.maxWidth > 600 ? 40.0 : 22.0);
    const statusH = 30.0;
    const gutter = 64.0;
    _spread = wide;
    _scaler = MediaQuery.textScalerOf(context);
    final contentW = math.min(box.maxWidth - hPad * 2, wide ? 1200.0 : 720.0);
    _pageWidth = _spread ? (contentW - gutter) / 2 : contentW;
    _pageHeight = box.maxHeight - statusH * 2 - 12;

    // Сменились размеры или шрифт — встаём на то же место.
    final key = _cacheKey(_chapter);
    if (key != _layoutKey) {
      _layoutKey = key;
      final pages = _pagesOf(_chapter);
      var p = pageOf(pages, _anchor.block, _anchor.offset);
      if (_spread) p = (p ~/ 2) * 2;
      _page = p;
      if (_cache.length > 12) _cache.removeWhere((k, _) => !k.endsWith(key.substring(key.indexOf('|'))));
    }
    final pages = _pagesOf(_chapter);
    _page = _page.clamp(0, pages.length - 1);

    final faint = TextStyle(fontSize: 12, color: paper.faint, fontFamily: bodyFont);
    final chapterTitle = _content.chapters[_chapter].title;
    final pageLabel = _spread && _page + 1 < pages.length
        ? 'стр. ${_page + 1}–${_page + 2} из ${pages.length}'
        : 'стр. ${_page + 1} из ${pages.length}';
    final left = _charsLeftInChapter(pages);
    final minutes = (left / _charsPerMinute).ceil();

    final pageWidgets = [
      for (var i = _page; i < _page + _step; i++)
        SizedBox(
          width: _pageWidth,
          height: _pageHeight,
          child: i < pages.length ? _PageView(chapter: _content.chapters[_chapter], page: pages[i], base: _baseStyle, scaler: _scaler) : null,
        ),
    ];

    final body = Column(children: [
      SizedBox(
        height: statusH,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: Row(children: [
            Expanded(child: Text(widget.book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: faint)),
            const SizedBox(width: 16),
            Flexible(child: Text(chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: faint)),
          ]),
        ),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerUp: (e) => _onPointerUp(e, box.maxWidth),
          onPointerSignal: _onWheel,
          behavior: HitTestBehavior.opaque,
          child: SelectionArea(
            onSelectionChanged: (c) => _selected = c?.plainText,
            contextMenuBuilder: (context, state) => AdaptiveTextSelectionToolbar.buttonItems(
              anchors: state.contextMenuAnchors,
              buttonItems: [
                ContextMenuButtonItem(
                  label: 'Перевести',
                  onPressed: () {
                    final text = _selected;
                    state.hideToolbar();
                    if (text != null && text.trim().isNotEmpty) {
                      showTranslateSheet(context, text: text.trim(), sourceLanguage: _language);
                    }
                  },
                ),
                ContextMenuButtonItem(
                  label: 'Словарь',
                  onPressed: () {
                    final text = _selected;
                    state.hideToolbar();
                    if (text != null && text.trim().isNotEmpty) {
                      showTranslateSheet(context, text: text.trim(), sourceLanguage: _language, dictionaryFirst: true);
                    }
                  },
                ),
                ...state.contextMenuButtonItems,
              ],
            ),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: Row(
                  key: ValueKey('$_chapter:$_page:${_layoutKey ?? ''}'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    pageWidgets.first,
                    if (_spread) ...[const SizedBox(width: gutter), pageWidgets.last],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 6),
      SizedBox(
        height: statusH,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: Row(children: [
            Text(pageLabel, style: faint.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            const Spacer(),
            Text(minutes <= 1 ? 'меньше минуты до конца главы' : '$minutes мин до конца главы', style: faint),
          ]),
        ),
      ),
    ]);

    return Stack(children: [
      Positioned.fill(child: body),
      if (_panels) ..._panelsOverlay(context, paper),
    ]);
  }

  int _charsLeftInChapter(List<ReaderPage> pages) {
    final chapter = _content.chapters[_chapter];
    final at = _anchor.chapter == _chapter ? _anchor : pages[_page].locator(_chapter);
    var before = at.offset;
    for (var i = 0; i < at.block && i < chapter.blocks.length; i++) {
      before += chapter.blocks[i].length;
    }
    return math.max(0, chapter.length - before);
  }

  List<Widget> _panelsOverlay(BuildContext context, Paper paper) {
    final c = BcColors.of(context);
    final percent = _percent;
    return [
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Glass(
          radius: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Row(children: [
              IconButton(
                tooltip: 'Назад',
                icon: BcIcon(BcIcons.chevronLeft, color: c.text),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  Text(
                    [?widget.book.author, _content.chapters[_chapter].title].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.muted),
                  ),
                ]),
              ),
              IconButton(
                tooltip: 'Добавить закладку',
                icon: BcIcon(BcIcons.bookmarkAdd, color: c.text),
                onPressed: _addBookmark,
              ),
            ]),
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Glass(
          radius: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: Slider(
                    value: _dragPercent ?? percent,
                    onChanged: (v) => setState(() => _dragPercent = v),
                    onChangeEnd: (v) {
                      setState(() => _dragPercent = null);
                      _jumpToPercent(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text('${((_dragPercent ?? percent) * 100).floor()} %',
                      textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: c.muted)),
                ),
              ]),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _PanelButton(icon: const BcIcon(BcIcons.chapters, size: 22), label: 'Оглавление', onTap: _showContents),
                _PanelButton(icon: const BcIcon(BcIcons.bookmark, size: 22), label: 'Закладки', onTap: _showBookmarks),
                _PanelButton(
                  icon: const Text('Аа', style: TextStyle(fontFamily: 'PTSerif', fontSize: 19, fontWeight: FontWeight.w700)),
                  label: 'Текст',
                  onTap: _showStyle,
                ),
              ]),
            ]),
          ),
        ),
      ),
    ];
  }

  void _jumpToPercent(double v) {
    final target = (v * _content.length).round();
    var acc = 0;
    for (var ch = 0; ch < _content.chapters.length; ch++) {
      final chapter = _content.chapters[ch];
      if (acc + chapter.length >= target || ch == _content.chapters.length - 1) {
        var inside = target - acc;
        for (var b = 0; b < chapter.blocks.length; b++) {
          if (inside <= chapter.blocks[b].length) {
            _goTo(TextLocator(ch, b, math.max(0, inside)));
            return;
          }
          inside -= chapter.blocks[b].length;
        }
        _goTo(TextLocator(ch, 0, 0));
        return;
      }
      acc += chapter.length;
    }
  }

  Future<void> _addBookmark() async {
    final db = _db;
    final pages = _pagesOf(_chapter);
    final first = pages[_page].fragments.where((f) => f.end > f.start).firstOrNull;
    var snippet = '';
    if (first != null) {
      snippet = _content.chapters[_chapter].blocks[first.block].text.substring(first.start, first.end);
      if (snippet.length > 80) snippet = '${snippet.substring(0, 80).trimRight()}…';
    }
    final label = '${_content.chapters[_chapter].title} — $snippet';
    await db.addBookmark(widget.book.id, locator: _anchor.encode(), label: label);
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Закладка добавлена')));
  }

  void _showContents() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, controller) => ListView.builder(
          controller: controller,
          itemCount: _content.chapters.length,
          itemBuilder: (context, i) => ChapterTile(
            number: i + 1,
            title: _content.chapters[i].title,
            trailing: '${(_content.charsBefore(i) * 100 / math.max(1, _content.length)).round()} %',
            current: i == _chapter,
            done: i < _chapter,
            onTap: () {
              Navigator.pop(context);
              _goTo(TextLocator(i, 0, 0));
            },
          ),
        ),
      ),
    );
  }

  void _showBookmarks() {
    final db = _db;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, controller) => SingleChildScrollView(
          controller: controller,
          child: BookmarksList(
            db: db,
            bookId: widget.book.id,
            onOpen: (b) {
              Navigator.pop(context);
              final l = TextLocator.parse(b.locator);
              if (l != null) _goTo(l);
            },
          ),
        ),
      ),
    );
  }

  void _showStyle() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setSheet) {
        void apply(ReaderStyle s) {
          setSheet(() {});
          setState(() => _style = s);
          unawaited(s.save(_db));
        }

        return _StyleSheet(style: _style, onChanged: apply);
      }),
    );
  }
}

/// Страница: куски абзацев тем же оформлением, что и при разбивке.
class _PageView extends StatelessWidget {
  const _PageView({required this.chapter, required this.page, required this.base, required this.scaler});

  final TextChapter chapter;
  final ReaderPage page;
  final TextStyle base;
  final TextScaler scaler;

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    final selection = BcColors.of(context).bar.withValues(alpha: 0.35);
    final fs = base.fontSize ?? 18;
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        maxHeight: double.infinity,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          for (final (i, f) in page.fragments.indexed)
            if (chapter.blocks[f.block].kind == TextBlockKind.empty)
              SizedBox(height: fs * (base.height ?? 1.5) * 0.6)
            else
              Builder(builder: (context) {
                final block = chapter.blocks[f.block];
                final look = blockLook(block.kind, base);
                return Padding(
                  padding: EdgeInsets.only(left: look.inset, top: i == 0 ? 0 : look.before, bottom: look.after),
                  child: RichText(
                    text: fragmentSpan(block, f.start, f.end, look, indent: f.indent),
                    textAlign: look.align,
                    textScaler: scaler,
                    selectionRegistrar: registrar,
                    selectionColor: selection,
                  ),
                );
              }),
        ]),
      ),
    );
  }
}

class _PanelButton extends StatelessWidget {
  const _PanelButton({required this.icon, required this.label, required this.onTap});

  final Widget icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 96,
        height: 54,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(height: 24, child: Center(child: icon)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

class _StyleSheet extends StatelessWidget {
  const _StyleSheet({required this.style, required this.onChanged});

  final ReaderStyle style;
  final ValueChanged<ReaderStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final brightness = Theme.of(context).brightness;
    final paper = style.paperFor(brightness);
    Widget label(String t) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(t, style: TextStyle(fontSize: 13, color: c.muted)),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            _StyleButton(
              width: 56,
              selected: false,
              onTap: style.size > 0 ? () => onChanged(style.copyWith(size: style.size - 1)) : null,
              child: const Text('A', style: TextStyle(fontFamily: 'PTSerif', fontSize: 15)),
            ),
            Expanded(
              child: Center(
                child: Text('${style.fontSize.round()}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text)),
              ),
            ),
            _StyleButton(
              width: 56,
              selected: false,
              onTap: style.size < readerSizes.length - 1 ? () => onChanged(style.copyWith(size: style.size + 1)) : null,
              child: const Text('A', style: TextStyle(fontFamily: 'PTSerif', fontSize: 23)),
            ),
          ]),
          const SizedBox(height: 16),
          label('Шрифт'),
          Row(children: [
            for (final f in ReaderFont.values) ...[
              Expanded(
                child: _StyleButton(
                  selected: style.font == f,
                  onTap: () => onChanged(style.copyWith(font: f)),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(f.label, style: TextStyle(fontFamily: f.family, fontSize: 16, color: c.text)),
                    Text(f.hint, style: TextStyle(fontSize: 11, color: c.muted)),
                  ]),
                ),
              ),
              if (f != ReaderFont.values.last) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 16),
          label('Фон'),
          Row(children: [
            for (final p in Paper.values) ...[
              Expanded(
                child: _StyleButton(
                  selected: paper == p,
                  background: p.bg,
                  onTap: () => onChanged(ReaderStyle(size: style.size, font: style.font, paper: p, spacing: style.spacing)),
                  child: Text(p.label, style: TextStyle(fontSize: 14, color: p.ink)),
                ),
              ),
              if (p != Paper.values.last) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 16),
          label('Межстрочный интервал'),
          Row(children: [
            for (var i = 0; i < readerSpacings.length; i++) ...[
              Expanded(
                child: _StyleButton(
                  selected: style.spacing == i,
                  onTap: () => onChanged(style.copyWith(spacing: i)),
                  child: Text(const ['Плотно', 'Обычно', 'Свободно'][i], style: TextStyle(fontSize: 14, color: c.text)),
                ),
              ),
              if (i != readerSpacings.length - 1) const SizedBox(width: 8),
            ],
          ]),
        ]),
      ),
    );
  }
}

class _StyleButton extends StatelessWidget {
  const _StyleButton({required this.child, required this.selected, required this.onTap, this.width, this.background});

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final double? width;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Material(
      color: background ?? c.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? c.bar : Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(width: width, height: 52, child: Center(child: Opacity(opacity: onTap == null ? 0.4 : 1, child: child))),
      ),
    );
  }
}
