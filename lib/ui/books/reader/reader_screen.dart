/// Читалка: книга постранично, выделение долгим нажатием (перевод, словарь,
/// копирование), закладка тапом в правый верхний угол, меню книги по тапу
/// в центр. Пока открыта — экран не гаснет. Место в книге сохраняется при
/// каждом перелистывании и уходит на сервер.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../books/locator.dart';
import '../../../books/text/text_book.dart';
import '../../../books/translator.dart';
import '../../../data/db/books_dao.dart';
import '../../../data/db/database.dart';
import '../../../platform/books_platform.dart';
import '../../../sync/book_sync.dart';
import '../../app_scope.dart';
import '../../format.dart';
import '../../icons.dart';
import '../../theme.dart';
import '../book_widgets.dart';
import 'paginator.dart';
import 'reader_menu.dart';
import 'reader_selection.dart';
import 'reader_style.dart';
import 'reader_style_sheet.dart';
import 'translate_sheet.dart';

/// Ключ скорости чтения (символов в минуту) — для «осталось до конца главы».
const _speedKey = 'reader.charsPerMinute';

/// Зона закладки: правый верхний угол страницы.
const _cornerSize = Size(72, 64);

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

  bool _menu = false;
  final _focus = FocusNode();
  Timer? _saveTimer;
  double _charsPerMinute = 1100;
  DateTime _pageShownAt = DateTime.now();
  DateTime _lastWheel = DateTime(0);

  late AppDatabase _db;
  BookSync? _bookSync;
  bool _started = false;
  StreamSubscription<List<BookBookmark>>? _bookmarksSub;
  List<BookBookmark> _bookmarks = const [];

  // Выделение.
  TextSelectionRange? _selection;
  bool _selecting = false;
  bool _wordMode = true;
  ChapterPos? _selAnchor;
  List<Rect> _selBoxes = const [];

  /// Тянем за край выделения: 0 — начало, 1 — конец.
  int? _dragHandle;

  // Жест: начало касания.
  Offset? _downAt;
  DateTime? _downTime;
  PointerDeviceKind? _downKind;
  Timer? _longPress;
  bool _mouseSelecting = false;

  // Плашка вверху («Закладка на стр. 5 · Отменить»).
  String? _toast;
  VoidCallback? _toastUndo;
  Timer? _toastTimer;

  /// Растёт при каждой новой закладке — ленточка проигрывает появление.
  int _ribbonDrop = 0;

  final _readerKey = GlobalKey();
  final _fragKeys = <String, GlobalKey>{};

  TextBookContent get _content => widget.content;
  TextChapter get _chapterText => _content.chapters[_chapter];

  String get _language => widget.content.language != null && widget.content.language!.isNotEmpty
      ? baseLanguage(widget.content.language)
      : guessLanguage(widget.content.chapters.first.blocks.take(20).map((b) => b.text).join(' '));

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
      _bookmarksSub = _db.watchBookmarks(widget.book.id).listen((list) {
        if (mounted) setState(() => _bookmarks = list);
      });
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
      _layoutKey = null;
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
    _longPress?.cancel();
    _toastTimer?.cancel();
    unawaited(_bookmarksSub?.cancel());
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
      if (chapter != _chapter) _fragKeys.clear();
      _chapter = chapter;
      _page = p;
      _anchor = pages[p].locator(chapter);
      _clearSelection();
    });
    _scheduleSave();
  }

  void _next() {
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
      _showToast('Конец книги');
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

  /// Номер страницы места [l] в главе (с единицы) при текущей разбивке.
  int _pageNumber(TextLocator l) {
    if (l.chapter >= _content.chapters.length) return 1;
    return pageOf(_pagesOf(l.chapter), l.block, l.offset) + 1;
  }

  // -------------------------------------------------------------------------
  // Закладки
  // -------------------------------------------------------------------------

  /// Закладки на странице [page] текущей главы.
  List<BookBookmark> _bookmarksOn(int page) {
    final pages = _pagesOf(_chapter);
    if (page < 0 || page >= pages.length) return const [];
    final from = pages[page].locator(_chapter);
    final to = page + 1 < pages.length ? pages[page + 1].locator(_chapter) : TextLocator(_chapter + 1, 0, 0);
    return [
      for (final b in _bookmarks)
        if (TextLocator.parse(b.locator) case final l? when l.compareTo(from) >= 0 && l.compareTo(to) < 0) b,
    ];
  }

  /// Страница, к которой относится угол с закладкой (правая в развороте).
  int get _cornerPage => math.min(_page + _step - 1, _pagesOf(_chapter).length - 1);

  Future<void> _toggleBookmark() async {
    final page = _cornerPage;
    final existing = _bookmarksOn(page);
    unawaited(HapticFeedback.lightImpact());
    if (existing.isNotEmpty) {
      for (final b in existing) {
        await _db.deleteBookmark(b.id);
      }
      _showToast('Закладка убрана', undo: () async {
        for (final b in existing) {
          await _db.addBookmark(widget.book.id, locator: b.locator, positionMs: b.positionMs, label: b.label);
        }
      });
      return;
    }
    final pages = _pagesOf(_chapter);
    final at = pages[page].locator(_chapter);
    final first = pages[page].fragments.where((f) => f.end > f.start).firstOrNull;
    var snippet = '';
    if (first != null) {
      snippet = _chapterText.blocks[first.block].text.substring(first.start, first.end);
      if (snippet.length > 120) snippet = '${snippet.substring(0, 120).trimRight()}…';
    }
    final id = await _db.addBookmark(widget.book.id, locator: at.encode(), label: snippet);
    if (!mounted) return;
    setState(() => _ribbonDrop++);
    _showToast('Закладка на стр. ${page + 1}', undo: () => _db.deleteBookmark(id));
  }

  void _showToast(String text, {FutureOr<void> Function()? undo}) {
    _toastTimer?.cancel();
    setState(() {
      _toast = text;
      _toastUndo = undo == null
          ? null
          : () {
              unawaited(Future.sync(undo));
              _hideToast();
            };
    });
    _toastTimer = Timer(const Duration(seconds: 3), _hideToast);
  }

  void _hideToast() {
    if (!mounted) return;
    setState(() {
      _toast = null;
      _toastUndo = null;
    });
  }

  // -------------------------------------------------------------------------
  // Выделение
  // -------------------------------------------------------------------------

  void _clearSelection() {
    _selection = null;
    _selAnchor = null;
    _selecting = false;
    _selBoxes = const [];
    _dragHandle = null;
  }

  String _keyId(int page, int frag) => '$_chapter:$page:$frag';

  GlobalKey _fragKey(int page, int frag) => _fragKeys.putIfAbsent(_keyId(page, frag), GlobalKey.new);

  /// Куски абзацев на экране вместе с их отрисовкой.
  Iterable<({PageFragment f, RenderParagraph p})> _visibleParagraphs() sync* {
    final pages = _pagesOf(_chapter);
    for (var page = _page; page < _page + _step && page < pages.length; page++) {
      final frags = pages[page].fragments;
      for (var i = 0; i < frags.length; i++) {
        final ro = _fragKeys[_keyId(page, i)]?.currentContext?.findRenderObject();
        if (ro is RenderParagraph && ro.attached) yield (f: frags[i], p: ro);
      }
    }
  }

  /// Место в главе под точкой [global] (ближайший кусок текста).
  ChapterPos? _hitTest(Offset global) {
    ({PageFragment f, RenderParagraph p})? best;
    var bestDist = double.infinity;
    for (final v in _visibleParagraphs()) {
      final rect = v.p.localToGlobal(Offset.zero) & v.p.size;
      final dx = global.dx < rect.left ? rect.left - global.dx : (global.dx > rect.right ? global.dx - rect.right : 0.0);
      final dy = global.dy < rect.top ? rect.top - global.dy : (global.dy > rect.bottom ? global.dy - rect.bottom : 0.0);
      final d = dx * 4 + dy; // по горизонтали — сильнее: колонки
      if (d < bestDist) {
        bestDist = d;
        best = v;
      }
    }
    if (best == null) return null;
    final local = best.p.globalToLocal(global);
    final clamped = Offset(local.dx.clamp(0.0, best.p.size.width), local.dy.clamp(0.0, math.max(0.0, best.p.size.height - 1)));
    final pos = best.p.getPositionForOffset(clamped).offset;
    final f = best.f;
    final inBlock = (f.start + pos - (f.indent ? indentChar.length : 0)).clamp(f.start, f.end);
    return ChapterPos(f.block, inBlock);
  }

  void _selectWordAt(Offset global) {
    final pos = _hitTest(global);
    if (pos == null) return;
    final text = _chapterText.blocks[pos.block].text;
    final w = wordAt(text, pos.offset);
    setState(() {
      _selAnchor = ChapterPos(pos.block, w.start);
      _selection = TextSelectionRange(ChapterPos(pos.block, w.start), ChapterPos(pos.block, w.end));
      _selecting = true;
      _wordMode = true;
    });
    unawaited(HapticFeedback.selectionClick());
    _afterSelectionChange();
  }

  /// Растянуть выделение до точки [global].
  void _extendTo(Offset global) {
    final pos = _hitTest(global);
    final anchor = _selAnchor;
    if (pos == null || anchor == null) return;
    var focus = pos;
    if (_wordMode) {
      final text = _chapterText.blocks[pos.block].text;
      final w = wordAt(text, pos.offset);
      focus = pos < anchor ? ChapterPos(pos.block, w.start) : ChapterPos(pos.block, w.end);
      // Якорь — слово целиком, в какую бы сторону ни тянули.
      final anchorWord = wordAt(_chapterText.blocks[anchor.block].text, anchor.offset);
      final a = pos < anchor ? ChapterPos(anchor.block, anchorWord.end) : ChapterPos(anchor.block, anchorWord.start);
      setState(() => _selection = TextSelectionRange(a, focus));
    } else {
      setState(() => _selection = TextSelectionRange(anchor, focus));
    }
    _afterSelectionChange();
  }

  /// После перерисовки — где на экране выделение (для панели и ручек).
  void _afterSelectionChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sel = _selection;
      final box = _readerKey.currentContext?.findRenderObject() as RenderBox?;
      if (sel == null || box == null) return;
      final rects = <Rect>[];
      for (final v in _visibleParagraphs()) {
        final r = sel.rangeIn(v.f.block, _chapterText.blocks[v.f.block].length);
        if (r == null) continue;
        final s = math.max(r.start, v.f.start);
        final e = math.min(r.end, v.f.end);
        if (e <= s) continue;
        final shift = v.f.indent ? indentChar.length : 0;
        for (final b in v.p.getBoxesForSelection(
            TextSelection(baseOffset: s - v.f.start + shift, extentOffset: e - v.f.start + shift))) {
          final topLeft = box.globalToLocal(v.p.localToGlobal(Offset(b.left, b.top)));
          rects.add(Rect.fromLTWH(topLeft.dx, topLeft.dy, b.right - b.left, b.bottom - b.top));
        }
      }
      setState(() => _selBoxes = rects);
    });
  }

  String get _selectedText => _selection == null ? '' : selectedText(_chapterText, _selection!);

  void _translate({bool dictionary = false}) {
    final sel = _selection;
    final text = _selectedText;
    if (sel == null || text.isEmpty) return;
    final block = _chapterText.blocks[sel.start.block].text;
    final sentence = sel.start.block == sel.end.block ? sentenceAround(block, sel.start.offset, sel.end.offset) : null;
    unawaited(showTranslateSheet(context,
        text: text, sourceLanguage: _language, sentence: sentence, dictionaryFirst: dictionary));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _selectedText));
    setState(_clearSelection);
    _showToast('Скопировано');
  }

  // -------------------------------------------------------------------------
  // Жесты
  // -------------------------------------------------------------------------

  /// Касание рядом с ручкой выделения: 0 — начало, 1 — конец.
  int? _handleAt(Offset local) {
    if (_selBoxes.isEmpty) return null;
    final first = _selBoxes.first;
    final last = _selBoxes.last;
    if ((local - first.bottomLeft).distance < 28) return 0;
    if ((local - last.bottomRight).distance < 28) return 1;
    return null;
  }

  void _onPointerDown(PointerDownEvent e) {
    _downAt = e.position;
    _downTime = DateTime.now();
    _downKind = e.kind;
    _mouseSelecting = false;
    _longPress?.cancel();
    final local = (_readerKey.currentContext?.findRenderObject() as RenderBox?)?.globalToLocal(e.position);
    final handle = local == null ? null : _handleAt(local);
    if (handle != null && _selection != null) {
      // Тянем за ручку: противоположный край — якорь.
      _dragHandle = handle;
      _selAnchor = handle == 0 ? _selection!.end : _selection!.start;
      _wordMode = true;
      _selecting = true;
      return;
    }
    if (e.kind == PointerDeviceKind.mouse) return;
    // Долгое нажатие — выделить слово; быстрые касания и свайпы его не выделяют.
    _longPress = Timer(const Duration(milliseconds: 450), () => _selectWordAt(e.position));
  }

  void _onPointerMove(PointerMoveEvent e) {
    final start = _downAt;
    if (start == null) return;
    if (_selecting) {
      _extendTo(e.position);
      return;
    }
    if ((e.position - start).distance > 10) _longPress?.cancel();
    // Мышь: тянем — выделяем по буквам, в порядке текста.
    if (_downKind == PointerDeviceKind.mouse && (e.buttons & kPrimaryMouseButton) != 0) {
      if (!_mouseSelecting && (e.position - start).distance > 4) {
        final pos = _hitTest(start);
        if (pos == null) return;
        _mouseSelecting = true;
        _selecting = true;
        _wordMode = false;
        _selAnchor = pos;
        setState(() => _selection = TextSelectionRange(pos, pos));
      }
    }
  }

  void _onPointerUp(PointerUpEvent e, Size area) {
    _longPress?.cancel();
    final start = _downAt;
    final time = _downTime;
    _downAt = null;
    if (start == null || time == null) return;
    if (_selecting) {
      _selecting = false;
      _dragHandle = null;
      if (_selection?.isEmpty ?? true) {
        setState(_clearSelection);
      } else {
        _afterSelectionChange();
      }
      return;
    }
    final d = e.position - start;
    final ms = DateTime.now().difference(time).inMilliseconds;
    if (_downKind == PointerDeviceKind.touch && d.dx.abs() > 50 && d.dx.abs() > d.dy.abs() * 1.4 && ms < 700) {
      d.dx < 0 ? _next() : _prev();
      return;
    }
    if (d.distance > 12 || ms > 600) return;
    // Касание при выделении — только снять выделение.
    if (_selection != null) {
      setState(_clearSelection);
      return;
    }
    final local = (_readerKey.currentContext?.findRenderObject() as RenderBox?)?.globalToLocal(e.position) ?? e.localPosition;
    if (local.dx > area.width - _cornerSize.width && local.dy < _cornerSize.height) {
      unawaited(_toggleBookmark());
      return;
    }
    final x = local.dx / area.width;
    if (x < 0.3) {
      _prev();
    } else if (x > 0.7) {
      _next();
    } else {
      setState(() => _menu = true);
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
    if (_menu) {
      if (k == LogicalKeyboardKey.escape) {
        setState(() => _menu = false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.space) {
      _next();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.pageUp) {
      _prev();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyC && HardwareKeyboard.instance.isControlPressed && _selection != null) {
      unawaited(_copy());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_selection != null) {
        setState(_clearSelection);
      } else {
        setState(() => _menu = true);
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
    return PopScope(
      canPop: !_menu && _selection == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          if (_selection != null) {
            _clearSelection();
          } else {
            _menu = false;
          }
        });
      },
      child: Scaffold(
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
      ),
    );
  }

  Widget _layout(BuildContext context, BoxConstraints box, Paper paper) {
    final landscape = box.maxWidth > box.maxHeight;
    final wide = box.maxWidth >= 1000;
    _spread = wide || (_style.landscapeSpread && landscape && box.maxWidth >= 560);
    final hPad = wide ? 56.0 : (box.maxWidth > 600 ? 40.0 : 22.0);
    final statusH = landscape && !wide ? 30.0 : 40.0;
    final gutter = wide ? 64.0 : 40.0;
    _scaler = MediaQuery.textScalerOf(context);
    final contentW = math.min(box.maxWidth - hPad * 2, _spread ? 1200.0 : 720.0);
    _pageWidth = _spread ? (contentW - gutter) / 2 : contentW;
    _pageHeight = box.maxHeight - statusH * 2 - 8;

    // Сменились размеры или шрифт — встаём на то же место.
    final key = _cacheKey(_chapter);
    final sizeKey = key.substring(key.indexOf('|'));
    if (sizeKey != _layoutKey) {
      _layoutKey = sizeKey;
      _fragKeys.clear();
      _selBoxes = const [];
      _selection = null;
      final pages = _pagesOf(_chapter);
      var p = pageOf(pages, _anchor.block, _anchor.offset);
      if (_spread) p = (p ~/ 2) * 2;
      _page = p;
      if (_cache.length > 12) _cache.removeWhere((k, _) => !k.endsWith(sizeKey));
    }
    final pages = _pagesOf(_chapter);
    _page = _page.clamp(0, pages.length - 1);

    if (_menu) return _menuView(paper, pages);

    final faint = TextStyle(fontSize: 12, color: paper.faint, fontFamily: bodyFont);
    final pageLabel = _spread && _page + 1 < pages.length
        ? 'стр. ${_page + 1}–${_page + 2} из ${pages.length}'
        : 'стр. ${_page + 1} из ${pages.length}';
    final minutes = (_charsLeftInChapter(pages) / _charsPerMinute).ceil();
    final cornerMarked = _bookmarksOn(_cornerPage).isNotEmpty;
    final c = BcColors.of(context);

    Widget pageAt(int i) => SizedBox(
          width: _pageWidth,
          height: _pageHeight,
          child: i < pages.length
              ? _PageView(
                  chapter: _chapterText,
                  page: pages[i],
                  base: _baseStyle,
                  scaler: _scaler,
                  keyFor: (frag) => _fragKey(i, frag),
                  selection: _selection,
                  highlight: c.bar.withValues(alpha: 0.32),
                )
              : null,
        );

    final reading = Column(children: [
      SizedBox(
        height: statusH,
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: _cornerSize.width),
            child: Text(_chapterText.title, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: faint),
          ),
        ),
      ),
      Expanded(
        child: Center(
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            pageAt(_page),
            if (_spread) ...[
              SizedBox(width: gutter, height: _pageHeight, child: Center(child: VerticalDivider(width: 1, color: paper.faint.withValues(alpha: 0.2)))),
              pageAt(_page + 1),
            ],
          ]),
        ),
      ),
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

    return Stack(key: _readerKey, children: [
      Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: (e) => _onPointerUp(e, box.biggest),
          onPointerCancel: (_) => _longPress?.cancel(),
          onPointerSignal: _onWheel,
          child: reading,
        ),
      ),
      // Ленточка закладки в правом верхнем углу.
      Positioned(
        top: 0,
        right: 24,
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            key: ValueKey('ribbon-$_ribbonDrop'),
            tween: Tween<double>(begin: _ribbonDrop > 0 ? 0.0 : 1.0, end: 1.0),
            duration: const Duration(milliseconds: 520),
            curve: Curves.elasticOut,
            builder: (context, v, _) => cornerMarked
                ? Transform.translate(offset: Offset(0, -44 * (1 - v)), child: _Ribbon(color: paper == Paper.sepia ? const Color(0xFF9A4B2E) : c.bar))
                : const SizedBox.shrink(),
          ),
        ),
      ),
      if (_selection != null && !_selecting && _selBoxes.isNotEmpty) ..._selectionOverlay(box.biggest, c),
      if (_selection != null && _selBoxes.isNotEmpty) ..._handles(c),
      Positioned(
        left: 16,
        right: 16,
        top: 8,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _toast == null
              ? const SizedBox.shrink()
              : _Toast(key: ValueKey(_toast), text: _toast!, onUndo: _toastUndo, ribbon: c.bar),
        ),
      ),
    ]);
  }

  List<Widget> _handles(BcColors c) {
    final first = _selBoxes.first;
    final last = _selBoxes.last;
    Widget dot(Offset at, bool left) => Positioned(
          left: at.dx - (left ? 12 : 0),
          top: at.dy,
          child: IgnorePointer(
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: c.bar,
                borderRadius: left
                    ? const BorderRadius.only(topLeft: Radius.circular(6), bottomLeft: Radius.circular(6), bottomRight: Radius.circular(6))
                    : const BorderRadius.only(topRight: Radius.circular(6), bottomLeft: Radius.circular(6), bottomRight: Radius.circular(6)),
              ),
            ),
          ),
        );
    return [dot(first.bottomLeft, true), dot(last.bottomRight, false)];
  }

  List<Widget> _selectionOverlay(Size area, BcColors c) {
    final top = _selBoxes.map((r) => r.top).reduce(math.min);
    final bottom = _selBoxes.map((r) => r.bottom).reduce(math.max);
    final left = _selBoxes.map((r) => r.left).reduce(math.min);
    final right = _selBoxes.map((r) => r.right).reduce(math.max);
    const toolbarH = 44.0;
    final y = top - toolbarH - 14 > 8 ? top - toolbarH - 14 : bottom + 22;
    final ax = (((left + right) / 2) / math.max(1.0, area.width) * 2 - 1).clamp(-1.0, 1.0);
    return [
      Positioned(
        left: 8,
        right: 8,
        top: y,
        child: Align(
          alignment: Alignment(ax, 0),
          child: _SelectionToolbar(
            onTranslate: () => _translate(),
            onDictionary: () => _translate(dictionary: true),
            onCopy: _copy,
          ),
        ),
      ),
    ];
  }

  Widget _menuView(Paper paper, List<ReaderPage> pages) {
    final c = BcColors.of(context);
    return ReaderMenu(
      bookTitle: widget.book.title,
      author: widget.book.author,
      chapterTitle: _chapterText.title,
      pageCount: pages.length,
      page: _page,
      percent: _percent,
      paper: paper,
      pageSize: Size(_pageWidth, _pageHeight),
      bookmarked: _bookmarksOn(_cornerPage).isNotEmpty,
      pageBuilder: (i) => Stack(children: [
        _PageView(chapter: _chapterText, page: pages[i], base: _baseStyle, scaler: _scaler, highlight: Colors.transparent),
        if (_bookmarksOn(i).isNotEmpty) Positioned(top: 0, right: 16, child: _Ribbon(color: c.bar)),
      ]),
      onOpenPage: (i) {
        setState(() => _menu = false);
        _showPage(_chapter, i);
      },
      onClose: () => setState(() => _menu = false),
      onExit: () => Navigator.of(context).maybePop(),
      onToggleBookmark: () => unawaited(_toggleBookmark()),
      onContents: _showContents,
      onBookmarks: _showBookmarks,
      onStyle: _showStyle,
      onSearch: _showSearch,
      onSeekPercent: (v) {
        setState(() => _menu = false);
        _jumpToPercent(v);
      },
    );
  }

  int _charsLeftInChapter(List<ReaderPage> pages) {
    final chapter = _chapterText;
    final at = _anchor.chapter == _chapter ? _anchor : pages[_page].locator(_chapter);
    var before = at.offset;
    for (var i = 0; i < at.block && i < chapter.blocks.length; i++) {
      before += chapter.blocks[i].length;
    }
    return math.max(0, chapter.length - before);
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
              setState(() => _menu = false);
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
            meta: (b) {
              final l = TextLocator.parse(b.locator);
              if (l == null || l.chapter >= _content.chapters.length) return formatAgo(b.createdAt);
              return '${_content.chapters[l.chapter].title} · стр. ${_pageNumber(l)} · ${formatAgo(b.createdAt)}';
            },
            onOpen: (b) {
              Navigator.pop(context);
              final l = TextLocator.parse(b.locator);
              setState(() => _menu = false);
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
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(builder: (context, setSheet) {
        void apply(ReaderStyle s) {
          setSheet(() {});
          setState(() => _style = s);
          unawaited(s.save(_db));
        }

        return ReaderStyleSheet(style: _style, onChanged: apply);
      }),
    );
  }

  void _showSearch() {
    showDialog<void>(
      context: context,
      builder: (context) => _SearchDialog(
        content: _content,
        onOpen: (chapter, block, start, end) {
          Navigator.pop(context);
          setState(() => _menu = false);
          _goTo(TextLocator(chapter, block, start));
          setState(() {
            _selAnchor = ChapterPos(block, start);
            _selection = TextSelectionRange(ChapterPos(block, start), ChapterPos(block, end));
          });
          _afterSelectionChange();
        },
      ),
    );
  }
}

/// Страница: куски абзацев тем же оформлением, что и при разбивке.
class _PageView extends StatelessWidget {
  const _PageView({
    required this.chapter,
    required this.page,
    required this.base,
    required this.scaler,
    required this.highlight,
    this.keyFor,
    this.selection,
  });

  final TextChapter chapter;
  final ReaderPage page;
  final TextStyle base;
  final TextScaler scaler;
  final GlobalKey Function(int frag)? keyFor;
  final TextSelectionRange? selection;
  final Color highlight;

  @override
  Widget build(BuildContext context) {
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
                    key: keyFor?.call(i),
                    text: fragmentSpan(
                      block,
                      f.start,
                      f.end,
                      look,
                      indent: f.indent,
                      highlight: selection?.rangeIn(f.block, block.length),
                      highlightColor: highlight,
                    ),
                    textAlign: look.align,
                    textScaler: scaler,
                  ),
                );
              }),
        ]),
      ),
    );
  }
}

class _Ribbon extends StatelessWidget {
  const _Ribbon({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => ClipPath(
        clipper: _RibbonClipper(),
        child: Container(width: 22, height: 40, color: color),
      );
}

class _RibbonClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size s) => Path()
    ..moveTo(0, 0)
    ..lineTo(s.width, 0)
    ..lineTo(s.width, s.height)
    ..lineTo(s.width / 2, s.height * 0.78)
    ..lineTo(0, s.height)
    ..close();

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _Toast extends StatelessWidget {
  const _Toast({super.key, required this.text, required this.ribbon, this.onUndo});

  final String text;
  final Color ribbon;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: c.text,
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 48,
        child: Row(children: [
          const SizedBox(width: 16),
          if (text.startsWith('Закладка на')) ...[
            SizedBox(width: 12, height: 20, child: ClipPath(clipper: _RibbonClipper(), child: ColoredBox(color: ribbon))),
            const SizedBox(width: 10),
          ],
          Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: c.bg))),
          if (onUndo != null)
            TextButton(
              onPressed: onUndo,
              child: Text('Отменить',
                  style: TextStyle(fontWeight: FontWeight.w600, color: dark ? const Color(0xFF557F00) : const Color(0xFFC5F52E))),
            ),
          const SizedBox(width: 4),
        ]),
      ),
    );
  }
}

class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({required this.onTranslate, required this.onDictionary, required this.onCopy});

  final VoidCallback onTranslate;
  final VoidCallback onDictionary;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Material(
      color: c.raised,
      elevation: 10,
      shadowColor: Colors.black54,
      shape: StadiumBorder(side: BorderSide(color: c.glassBorder)),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 12), shape: const StadiumBorder()),
            onPressed: onTranslate,
            icon: const BcIcon(BcIcons.translate, size: 16),
            label: const Text('Перевести', style: TextStyle(fontSize: 14)),
          ),
          TextButton(onPressed: onDictionary, child: Text('Словарь', style: TextStyle(color: c.text))),
          TextButton(onPressed: onCopy, child: Text('Копировать', style: TextStyle(color: c.text))),
        ]),
      ),
    );
  }
}

/// Поиск по книге: совпадения с кусочком текста вокруг.
class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.content, required this.onOpen});

  final TextBookContent content;
  final void Function(int chapter, int block, int start, int end) onOpen;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  var _query = '';
  Timer? _debounce;
  List<({int chapter, int block, int start, int end, String snippet})> _found = const [];

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      final needle = q.trim().toLowerCase();
      final out = <({int chapter, int block, int start, int end, String snippet})>[];
      if (needle.length >= 2) {
        outer:
        for (var c = 0; c < widget.content.chapters.length; c++) {
          final blocks = widget.content.chapters[c].blocks;
          for (var b = 0; b < blocks.length; b++) {
            final text = blocks[b].text;
            final lower = text.toLowerCase();
            var i = lower.indexOf(needle);
            while (i >= 0) {
              final from = math.max(0, i - 40);
              final to = math.min(text.length, i + needle.length + 60);
              out.add((
                chapter: c,
                block: b,
                start: i,
                end: i + needle.length,
                snippet: '${from > 0 ? '…' : ''}${text.substring(from, to)}${to < text.length ? '…' : ''}',
              ));
              if (out.length >= 200) break outer;
              i = lower.indexOf(needle, i + needle.length);
            }
          }
        }
      }
      if (mounted) setState(() => _found = out);
    });
    setState(() => _query = q);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              autofocus: true,
              onChanged: _search,
              decoration: InputDecoration(
                hintText: 'Найти в книге',
                prefixIcon: Padding(padding: const EdgeInsets.all(12), child: BcIcon(BcIcons.search, size: 20, color: c.muted)),
                filled: true,
                fillColor: c.raised,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
              ),
            ),
          ),
          if (_query.trim().length >= 2)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_found.length >= 200 ? 'Больше 200 совпадений' : 'Совпадений: ${_found.length}',
                    style: TextStyle(fontSize: 12, color: c.muted)),
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _found.length,
              itemBuilder: (context, i) {
                final f = _found[i];
                return ListTile(
                  title: Text(f.snippet, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 1.4)),
                  subtitle: Text(widget.content.chapters[f.chapter].title, style: TextStyle(fontSize: 12, color: c.muted)),
                  onTap: () => widget.onOpen(f.chapter, f.block, f.start, f.end),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
