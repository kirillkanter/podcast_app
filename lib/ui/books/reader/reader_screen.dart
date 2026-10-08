/// Читалка: книга постранично, выделение долгим нажатием (перевод, словарь,
/// копирование), закладка тапом в правый верхний угол, меню книги по тапу
/// в центр. Пока открыта — экран не гаснет. Место в книге сохраняется при
/// каждом перелистывании и уходит на сервер.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
import '../highlights.dart';
import 'paginator.dart';
import 'reader_menu.dart';
import 'reader_selection.dart';
import 'reader_style.dart';
import 'reader_style_sheet.dart';
import 'reading_stats.dart';
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
  StreamSubscription<List<BookHighlight>>? _highlightsSub;
  List<BookHighlight> _highlights = const [];

  /// Нажали на сохранённое выделение: панель для него (цвет, заметка, удалить).
  BookHighlight? _activeHighlight;

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

  /// Открыт выбор цвета закладки (долгое нажатие на угол).
  bool _ribbonColors = false;
  bool _longFired = false;

  /// Номер перелистывания (ключ анимации) и направление: 1 — вперёд.
  int _turn = 0;
  int _turnDir = 1;
  double _gutter = 40;

  /// Следующая смена страницы — без анимации (вернулись из меню).
  bool _instantTurn = false;

  /// Откуда ушли по оглавлению, поиску, закладке или из меню — для кнопки
  /// «Вернуться на стр. N». Пропадает после нескольких перелистываний.
  TextLocator? _returnTo;
  int _returnTurns = 0;

  late final ReadingStats _stats;

  // Размеры экрана читалки (для уменьшенных страниц в меню).
  double _statusH = 40;
  double _hPad = 22;
  Size _screenSize = Size.zero;
  final _menuKey = GlobalKey<ReaderMenuState>();

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
    _startClock();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _db = scope.db;
    _bookSync = scope.bookSync;
    if (!_started) {
      _started = true;
      _stats = ReadingStats(_db);
      _bookmarksSub = _db.watchBookmarks(widget.book.id).listen((list) {
        if (mounted) setState(() => _bookmarks = list);
      });
      _highlightsSub = _db.watchHighlights(widget.book.key).listen((list) {
        if (!mounted) return;
        setState(() {
          _highlights = list;
          final active = _activeHighlight;
          if (active != null) _activeHighlight = list.where((h) => h.id == active.id).firstOrNull;
        });
      });
      // Выделения с других устройств.
      unawaited(_bookSync?.syncHighlights().catchError((Object _) {}));
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
    _stats.resume();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _saveNow(push: true);
      if (_started) unawaited(_stats.pause(sync: _bookSync));
    } else if (state == AppLifecycleState.resumed && _ready) {
      _stats.resume();
      // После возврата в приложение системные строки могли появиться.
      setState(() => _immersive = null);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(keepScreenOn(false));
    _clockTimer?.cancel();
    _returnTimer?.cancel();
    if (_immersive == true) unawaited(setImmersive(false));
    _saveTimer?.cancel();
    _longPress?.cancel();
    _toastTimer?.cancel();
    unawaited(_bookmarksSub?.cancel());
    unawaited(_highlightsSub?.cancel());
    if (_started) unawaited(_stats.pause(sync: _bookSync));
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
          justify: _style.justify,
          images: _content.images,
        ),
      );

  void _showPage(int chapter, int page) {
    final pages = _pagesOf(chapter);
    final p = _spread ? (page.clamp(0, pages.length - 1) ~/ 2) * 2 : page.clamp(0, pages.length - 1);
    if (chapter == _chapter && p == _page) return;
    setState(() {
      _turnDir = chapter > _chapter || (chapter == _chapter && p > _page) ? 1 : -1;
      _turn++;
      // Новые ключи: уходящая страница ещё видна во время анимации.
      _fragKeys.clear();
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
    _countTurn(forward: true);
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

  /// Перелистывание: статистика и кнопка «Вернуться».
  void _countTurn({required bool forward}) {
    _stats.turn(forward: forward);
    if (_returnTo != null && ++_returnTurns >= 3) _returnTo = null;
  }

  Timer? _returnTimer;

  /// Показать «Вернуться на стр. N» на 4 секунды: дольше она закрывает текст.
  void _offerReturn(TextLocator from) {
    _returnTimer?.cancel();
    setState(() {
      _returnTo = from;
      _returnTurns = 0;
    });
    _returnTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _returnTo = null);
    });
  }

  /// Перейти по оглавлению, поиску, закладке — запомнив, откуда.
  void _jump(TextLocator l) {
    final from = _anchor;
    _goTo(l);
    if (from.compareTo(_anchor) != 0) {
      _offerReturn(from);
    }
  }

  void _prev() {
    _pageShownAt = DateTime.now();
    _countTurn(forward: false);
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
    return _globalPage(l.chapter, pageOf(_pagesOf(l.chapter), l.block, l.offset));
  }

  // -------------------------------------------------------------------------
  // Сквозные номера страниц по всей книге
  // -------------------------------------------------------------------------

  /// Страниц в каждой главе при текущей разбивке. Считается в фоне после
  /// открытия книги и смены шрифта; пока не досчитано — оценка по числу знаков.
  final _counts = <int, int>{};
  String? _countsKey;

  int _countOf(int chapter) {
    final known = _counts[chapter] ?? _cache[_cacheKey(chapter)]?.length;
    if (known != null) return known;
    // Оценка: сколько знаков в среднем на странице в уже посчитанных главах.
    var chars = 0;
    var pages = 0;
    _counts.forEach((ch, n) {
      chars += _content.chapters[ch].length;
      pages += n;
    });
    if (pages == 0) {
      final current = _pagesOf(_chapter).length;
      chars = math.max(1, _chapterText.length);
      pages = current;
    }
    final perPage = math.max(1.0, chars / math.max(1, pages));
    return math.max(1, (_content.chapters[chapter].length / perPage).ceil());
  }

  /// Номер страницы [page] главы [chapter] от начала книги (с единицы).
  int _globalPage(int chapter, int page) {
    var n = 0;
    for (var c = 0; c < chapter; c++) {
      n += _countOf(c);
    }
    return n + page + 1;
  }

  int get _totalPages {
    var n = 0;
    for (var c = 0; c < _content.chapters.length; c++) {
      n += _countOf(c);
    }
    return n;
  }

  /// Посчитать страницы всех глав — по главе за раз, не мешая листать.
  void _countPagesLater(String key) {
    if (_countsKey == key) return;
    _countsKey = key;
    _counts.clear();
    unawaited(() async {
      for (var c = 0; c < _content.chapters.length; c++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (!mounted || _countsKey != key) return;
        final cached = _cache[_cacheKey(c)];
        _counts[c] = cached?.length ??
            paginateChapter(
              _content.chapters[c],
              width: _pageWidth,
              height: _pageHeight,
              base: _baseStyle,
              scaler: _scaler,
              justify: _style.justify,
              images: _content.images,
            ).length;
      }
      if (mounted && _countsKey == key) setState(() {});
    }());
  }

  // -------------------------------------------------------------------------
  // Закладки
  // -------------------------------------------------------------------------

  /// Закладки на странице [page] главы [chapter].
  List<BookBookmark> _bookmarksAt(int chapter, int page) {
    final pages = _pagesOf(chapter);
    if (page < 0 || page >= pages.length) return const [];
    final from = pages[page].locator(chapter);
    final to = page + 1 < pages.length ? pages[page + 1].locator(chapter) : TextLocator(chapter + 1, 0, 0);
    return [
      for (final b in _bookmarks)
        if (TextLocator.parse(b.locator) case final l? when l.compareTo(from) >= 0 && l.compareTo(to) < 0) b,
    ];
  }

  List<BookBookmark> _bookmarksOn(int page) => _bookmarksAt(_chapter, page);

  /// Страница, к которой относится угол с закладкой (правая в развороте).
  int get _cornerPage => math.min(_page + _step - 1, _pagesOf(_chapter).length - 1);

  Future<void> _toggleBookmark() => _toggleBookmarkAt(_chapter, _cornerPage);

  /// Поставить или убрать закладку на странице [page] главы [chapter].
  Future<void> _toggleBookmarkAt(int chapter, int page) async {
    final existing = _bookmarksAt(chapter, page);
    unawaited(HapticFeedback.lightImpact());
    if (existing.isNotEmpty) {
      for (final b in existing) {
        await _db.deleteBookmark(b.id);
      }
      return;
    }
    final pages = _pagesOf(chapter);
    if (page < 0 || page >= pages.length) return;
    final at = pages[page].locator(chapter);
    final first = pages[page].fragments.where((f) => f.end > f.start).firstOrNull;
    var snippet = '';
    if (first != null) {
      snippet = _content.chapters[chapter].blocks[first.block].text.substring(first.start, first.end);
      if (snippet.length > 120) snippet = '${snippet.substring(0, 120).trimRight()}…';
    }
    await _db.addBookmark(widget.book.id, locator: at.encode(), label: snippet);
    if (!mounted) return;
    setState(() => _ribbonDrop++);
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
    _activeHighlight = null;
    _selection = null;
    _selAnchor = null;
    _selecting = false;
    _selBoxes = const [];
    _dragHandle = null;
  }

  String _keyId(int page, int frag) => '$_turn:$_chapter:$page:$frag';

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
    WidgetsBinding.instance.scheduleFrame();
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
  // Выделения цветом и заметки
  // -------------------------------------------------------------------------

  /// Сохранённые выделения в абзаце [block] главы [chapter].
  List<TextMark> _marksOf(int chapter, int block, Paper paper) {
    if (_highlights.isEmpty) return const [];
    final out = <TextMark>[];
    final alpha = paper == Paper.dark ? 0.38 : 0.55;
    for (final h in _highlights) {
      final a = TextLocator.parse(h.startAt);
      final b = TextLocator.parse(h.endAt);
      if (a == null || b == null || a.chapter != chapter || block < a.block || block > b.block) continue;
      final length = _content.chapters[chapter].blocks[block].length;
      final s = block == a.block ? a.offset : 0;
      final e = block == b.block ? b.offset : length;
      if (e <= s) continue;
      out.add((
        start: s,
        end: e,
        color: highlightColors[h.color.clamp(0, highlightColors.length - 1)].withValues(alpha: alpha),
        note: h.note.isNotEmpty,
      ));
    }
    return out;
  }

  /// Место под пальцем, только если палец прямо на тексте.
  ChapterPos? _exactPos(Offset global) {
    for (final v in _visibleParagraphs()) {
      final local = v.p.globalToLocal(global);
      if (!(Offset.zero & v.p.size).contains(local)) continue;
      final pos = v.p.getPositionForOffset(local).offset;
      final f = v.f;
      return ChapterPos(f.block, (f.start + pos - (f.indent ? indentChar.length : 0)).clamp(f.start, f.end));
    }
    return null;
  }

  BookHighlight? _highlightAt(Offset global) {
    if (_highlights.isEmpty) return null;
    final pos = _exactPos(global);
    if (pos == null) return null;
    for (final h in _highlights.reversed) {
      final a = TextLocator.parse(h.startAt);
      final b = TextLocator.parse(h.endAt);
      if (a == null || b == null || a.chapter != _chapter) continue;
      final from = ChapterPos(a.block, a.offset);
      final to = ChapterPos(b.block, b.offset);
      if (!(pos < from) && pos < to) return h;
    }
    return null;
  }

  /// Показать панель для сохранённого выделения.
  void _openHighlight(BookHighlight h) {
    final a = TextLocator.parse(h.startAt)!;
    final b = TextLocator.parse(h.endAt)!;
    setState(() {
      _clearSelection();
      _activeHighlight = h;
      _selAnchor = ChapterPos(a.block, a.offset);
      _selection = TextSelectionRange(ChapterPos(a.block, a.offset), ChapterPos(b.block, b.offset));
    });
    _afterSelectionChange();
  }

  /// Выделить цветом [color] (новое выделение) или сменить цвет.
  Future<BookHighlight?> _applyColor(int color) async {
    final active = _activeHighlight;
    if (active != null) {
      await _db.updateHighlight(active.id, color: color);
      _bookSync?.highlightsChanged();
      if (mounted) setState(_clearSelection);
      return active;
    }
    final sel = _selection;
    if (sel == null || sel.isEmpty) return null;
    // Выделили поверх существующих заметок — объединяем в одну, а не
    // создаём вторую поверх первой.
    var from = sel.start;
    var to = sel.end;
    final overlapping = <BookHighlight>[];
    for (final h in _highlights) {
      final a = TextLocator.parse(h.startAt);
      final b = TextLocator.parse(h.endAt);
      if (a == null || b == null || a.chapter != _chapter) continue;
      final hs = ChapterPos(a.block, a.offset);
      final he = ChapterPos(b.block, b.offset);
      if (he < from || to < hs || he == from || to == hs) continue;
      overlapping.add(h);
      if (hs < from) from = hs;
      if (to < he) to = he;
    }
    if (overlapping.isNotEmpty) {
      final keep = overlapping.first;
      final merged = TextSelectionRange(from, to);
      final quote = selectedText(_chapterText, merged);
      await _db.updateHighlightRange(
        keep.id,
        start: TextLocator(_chapter, from.block, from.offset).encode(),
        end: TextLocator(_chapter, to.block, to.offset).encode(),
        quote: quote.length > 2000 ? '${quote.substring(0, 2000)}…' : quote,
        color: color,
        note: overlapping.map((h) => h.note).where((n) => n.isNotEmpty).join('\n\n'),
      );
      for (final h in overlapping.skip(1)) {
        await _db.deleteHighlight(h.id);
      }
      _bookSync?.highlightsChanged();
      if (mounted) setState(_clearSelection);
      return _db.highlightById(keep.id);
    }
    final quote = _selectedText;
    final id = await _db.addHighlight(
      widget.book.key,
      start: TextLocator(_chapter, sel.start.block, sel.start.offset).encode(),
      end: TextLocator(_chapter, sel.end.block, sel.end.offset).encode(),
      quote: quote.length > 2000 ? '${quote.substring(0, 2000)}…' : quote,
      color: color,
    );
    _bookSync?.highlightsChanged();
    if (mounted) setState(_clearSelection);
    unawaited(HapticFeedback.selectionClick());
    return _db.highlightById(id);
  }

  Future<void> _deleteHighlight() async {
    final active = _activeHighlight;
    if (active == null) return;
    await _db.deleteHighlight(active.id);
    _bookSync?.highlightsChanged();
    if (mounted) setState(_clearSelection);
  }

  /// Заметка к выделению (новое выделение — жёлтым).
  Future<void> _editNote() async {
    final h = _activeHighlight ?? await _applyColor(0);
    if (h == null || !mounted) return;
    setState(_clearSelection);
    final note = await showHighlightNoteDialog(context, quote: h.quote, note: h.note);
    if (note == null) return;
    await _db.updateHighlight(h.id, note: note);
    _bookSync?.highlightsChanged();
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

  bool _inCorner(Offset global) {
    final box = _readerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final local = box.globalToLocal(global);
    return local.dx > box.size.width - _cornerSize.width && local.dy < _cornerSize.height;
  }

  void _onPointerDown(PointerDownEvent e) {
    _longFired = false;
    if (_ribbonColors) {
      // Касание мимо выбора цвета — закрыть его, и больше ничего.
      setState(() => _ribbonColors = false);
      _downAt = null;
      return;
    }
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
    if (_selection == null && _inCorner(e.position)) {
      // Долгое нажатие на угол — цвет закладки, как в Kindle.
      _longPress = Timer(const Duration(milliseconds: 450), () async {
        _longFired = true;
        if (_bookmarksOn(_cornerPage).isEmpty) await _toggleBookmark();
        unawaited(HapticFeedback.selectionClick());
        if (mounted) setState(() => _ribbonColors = true);
      });
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
    if (start == null || time == null || _longFired) return;
    if (_selecting) {
      _selecting = false;
      _dragHandle = null;
      if (_selection?.isEmpty ?? true) {
        setState(_clearSelection);
      } else {
        // Перерисовать: панель с переводом видна, только когда палец отпущен.
        setState(() {});
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
    // Нажали на ссылку на сноску — показать сноску.
    final note = _noteAt(e.position);
    if (note != null) {
      _showNote(note);
      return;
    }
    final highlight = _highlightAt(e.position);
    if (highlight != null) {
      _openHighlight(highlight);
      return;
    }
    final image = _imageAt(e.position);
    if (image != null) {
      unawaited(Navigator.of(context).push(_ImageViewer.route(image)));
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
        _closeMenu();
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

  /// Закрыть меню с анимацией — обратно на страницу, где читали.
  void _closeMenu() {
    final menu = _menuKey.currentState;
    if (menu != null) {
      unawaited(menu.close(toReading: true));
    } else {
      setState(() => _menu = false);
    }
  }

  // -------------------------------------------------------------------------
  // Сноски
  // -------------------------------------------------------------------------

  /// Ссылка на сноску под точкой [global] (с запасом в несколько пикселей).
  String? _noteAt(Offset global) {
    if (_content.notes.isEmpty) return null;
    for (final v in _visibleParagraphs()) {
      final block = _chapterText.blocks[v.f.block];
      if (!block.runs.any((r) => r.note != null)) continue;
      final shift = v.f.indent ? indentChar.length : 0;
      var pos = 0;
      for (final r in block.runs) {
        final rs = pos;
        final re = pos + r.text.length;
        pos = re;
        if (r.note == null || re <= v.f.start || rs >= v.f.end) continue;
        final a = math.max(rs, v.f.start) - v.f.start + shift;
        final b = math.min(re, v.f.end) - v.f.start + shift;
        for (final box in v.p.getBoxesForSelection(TextSelection(baseOffset: a, extentOffset: b))) {
          final rect = Rect.fromLTRB(box.left, box.top, box.right, box.bottom).inflate(12);
          if (rect.contains(v.p.globalToLocal(global))) return r.note;
        }
      }
    }
    return null;
  }

  /// Картинка под точкой [global] — открыть во весь экран.
  BookImage? _imageAt(Offset global) {
    if (_content.images.isEmpty) return null;
    final pages = _pagesOf(_chapter);
    for (var page = _page; page < _page + _step && page < pages.length; page++) {
      final frags = pages[page].fragments;
      for (var i = 0; i < frags.length; i++) {
        final block = _chapterText.blocks[frags[i].block];
        if (block.kind != TextBlockKind.image) continue;
        final box = _fragKeys[_keyId(page, i)]?.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.attached) continue;
        if ((box.localToGlobal(Offset.zero) & box.size).contains(global)) return _content.images[block.image];
      }
    }
    return null;
  }

  void _showNote(String key) {
    final text = _content.notes[key];
    if (text == null) return;
    unawaited(HapticFeedback.selectionClick());
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final c = BcColors.of(context);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(
                child: Container(
                  width: 40,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(3)),
                ),
              ),
              Text('Сноска', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
              const SizedBox(height: 8),
              SelectableText(
                text,
                style: TextStyle(fontFamily: _style.font.family, fontSize: math.min(_style.fontSize, 19), height: 1.5, color: c.text),
              ),
            ]),
          ),
        );
      },
    );
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
        if (_selection != null) {
          setState(_clearSelection);
        } else {
          _closeMenu();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _overlayStyle(paper),
        child: Scaffold(
          backgroundColor: paper.bg,
          // Клавиатура (заметка, поиск) не сжимает страницу: иначе текст
          // перестраивается под ней.
          resizeToAvoidBottomInset: false,
          body: !_ready
              ? const SizedBox.shrink()
              : Focus(
                  focusNode: _focus,
                  autofocus: true,
                  onKeyEvent: _onKey,
                  child: LayoutBuilder(builder: (context, full) {
                    final insets = _stableInsets(context, full.biggest);
                    _screenSize = full.biggest;
                    _syncSystemUi();
                    return Stack(children: [
                      Positioned.fill(
                        child: Padding(
                          padding: insets,
                          child: LayoutBuilder(builder: (context, box) => _layout(context, box, paper)),
                        ),
                      ),
                      // Меню книги: страница уменьшается и становится листом в ленте.
                      if (_menu) Positioned.fill(child: _menuView(paper)),
                    ]);
                  }),
                ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Весь экран
  // -------------------------------------------------------------------------

  EdgeInsets _insets = EdgeInsets.zero;
  bool? _insetsLandscape;
  bool? _immersive;

  /// Отступы от краёв экрана (вырез камеры, системные строки) — только
  /// растут: когда строки прячутся или появляются (меню), текст не
  /// перестраивается. Сбрасываются при повороте.
  EdgeInsets _stableInsets(BuildContext context, Size size) {
    final landscape = size.width > size.height;
    final p = MediaQuery.viewPaddingOf(context);
    if (landscape != _insetsLandscape) {
      _insetsLandscape = landscape;
      _insets = p;
    } else {
      _insets = EdgeInsets.fromLTRB(
        math.max(_insets.left, p.left),
        math.max(_insets.top, p.top),
        math.max(_insets.right, p.right),
        math.max(_insets.bottom, p.bottom),
      );
    }
    return _insets;
  }

  /// Системные строки: спрятаны во время чтения, видны в меню.
  void _syncSystemUi() {
    final want = _style.fullscreen && !_menu;
    if (want == _immersive) return;
    _immersive = want;
    unawaited(setImmersive(want));
  }

  /// Цвет значков в системной строке: под меню и под страницу.
  SystemUiOverlayStyle _overlayStyle(Paper paper) {
    final darkBg = _menu ? Theme.of(context).brightness == Brightness.dark : paper == Paper.dark;
    return (darkBg ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    );
  }

  // Часы и заряд в строке над текстом (системные значки спрятаны).
  String _clock = '';
  int? _battery;
  Timer? _clockTimer;
  int _clockTicks = 0;

  void _startClock() {
    void tick() {
      final now = DateTime.now();
      final t = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      if (t != _clock && mounted) setState(() => _clock = t);
      if (_clockTicks++ % 8 == 0) {
        unawaited(batteryLevel().then((b) {
          if (mounted && b != _battery) setState(() => _battery = b);
        }));
      }
    }

    tick();
    _clockTimer = Timer.periodic(const Duration(seconds: 15), (_) => tick());
  }

  Widget _layout(BuildContext context, BoxConstraints box, Paper paper) {
    final landscape = box.maxWidth > box.maxHeight;
    final wide = box.maxWidth >= 1000;
    _spread = wide || (_style.landscapeSpread && landscape && box.maxWidth >= 560);
    final hPad = (wide ? 56.0 : (box.maxWidth > 600 ? 40.0 : 22.0)) * _style.marginFactor;
    final statusH = landscape && !wide ? 30.0 : 40.0;
    final gutter = wide ? 64.0 : 40.0;
    _scaler = MediaQuery.textScalerOf(context);
    final contentW = math.min(box.maxWidth - hPad * 2, _spread ? 1200.0 : 720.0);
    _pageWidth = _spread ? (contentW - gutter) / 2 : contentW;
    _pageHeight = box.maxHeight - statusH * 2 - 8;
    _gutter = gutter;
    _statusH = statusH;
    _hPad = hPad;

    // Сменились размеры или шрифт — встаём на то же место.
    final key = _cacheKey(_chapter);
    final sizeKey = key.substring(key.indexOf('|'));
    if (sizeKey != _layoutKey) {
      _layoutKey = sizeKey;
      _turn++;
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
    _countPagesLater(sizeKey);

    final cornerMarked = _bookmarksOn(_cornerPage).isNotEmpty;
    final c = BcColors.of(context);
    if (_instantTurn) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _instantTurn = false);
    }

    final reading = Column(children: [
      _statusTop(_chapter, paper),
      Expanded(
        child: ClipRect(
          child: AnimatedSwitcher(
            duration: _instantTurn
                ? Duration.zero
                : switch (_style.pageTurn) {
              PageTurn.none => Duration.zero,
              PageTurn.slide => const Duration(milliseconds: 180),
              PageTurn.fade => const Duration(milliseconds: 220),
            },
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
            transitionBuilder: (child, animation) {
              if (_style.pageTurn == PageTurn.fade) return FadeTransition(opacity: animation, child: child);
              final incoming = child.key == ValueKey(_turn);
              final from = Offset(incoming ? _turnDir.toDouble() : -_turnDir.toDouble(), 0);
              return SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(animation), child: child);
            },
            child: ColoredBox(
              key: ValueKey(_turn),
              color: paper.bg,
              child: SizedBox.expand(
                child: Center(
                  child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ..._pageRow(_chapter, _page, paper: paper, live: true),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
      _statusBottom(_chapter, _page, paper),
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
                ? Transform.translate(offset: Offset(0, -44 * (1 - v)), child: _Ribbon(color: _style.ribbonColor(c.bar)))
                : const SizedBox.shrink(),
          ),
        ),
      ),
      if (_selection != null && !_selecting && _selBoxes.isNotEmpty) ..._selectionOverlay(box.biggest, c),
      if (_selection != null && _selBoxes.isNotEmpty && _activeHighlight == null) ..._handles(c),
      Positioned(
        left: 16,
        right: 16,
        top: 8,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _toast == null
              ? const SizedBox.shrink()
              : _Toast(key: ValueKey(_toast), text: _toast!, onUndo: _toastUndo, ribbon: _style.ribbonColor(c.bar)),
        ),
      ),
      if (_ribbonColors)
        Positioned(
          top: 52,
          right: 8,
          child: _RibbonColors(
            selected: _style.bookmarkColor,
            accent: c.bar,
            onSelect: (i) {
              final s = _style.copyWith(bookmarkColor: i);
              setState(() {
                _style = s;
                _ribbonColors = false;
              });
              unawaited(s.save(_db));
            },
          ),
        ),
      // Вернуться туда, откуда ушли по оглавлению, поиску или закладке.
      if (!_menu)
        Positioned(
          left: 0,
          right: 0,
          bottom: _statusH + 4,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _returnTo == null
                  ? const SizedBox.shrink()
                  : _ReturnPill(key: const ValueKey('return'), label: _returnLabel(_returnTo!), onTap: _goBack),
            ),
          ),
        ),
    ]);
  }

  String _returnLabel(TextLocator l) {
    if (l.chapter >= _content.chapters.length) return 'Вернуться';
    return 'Вернуться на стр. ${_pageNumber(l)}';
  }


  void _goBack() {
    final to = _returnTo;
    if (to == null) return;
    _returnTimer?.cancel();
    setState(() => _returnTo = null);
    _goTo(to);
  }

  /// Строка над страницей: название главы; во весь экран — ещё время
  /// и заряд слева (системные значки спрятаны).
  Widget _statusTop(int chapter, Paper paper) {
    final faint = TextStyle(fontSize: 12, color: paper.faint, fontFamily: bodyFont);
    final showClock = _style.fullscreen && Platform.isAndroid && _clock.isNotEmpty;
    return SizedBox(
      height: _statusH,
      child: Stack(children: [
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: showClock ? 96 : _cornerSize.width),
            child: Text(_content.chapters[chapter].title,
                maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: faint),
          ),
        ),
        if (showClock)
          Positioned(
            left: _hPad,
            top: 0,
            bottom: 0,
            child: Center(
              child: Text(
                [_clock, if (_battery != null) '$_battery %'].join(' · '),
                style: faint.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ),
      ]),
    );
  }

  /// Строка под страницей: номер страницы и сколько читать до конца главы.
  Widget _statusBottom(int chapter, int page, Paper paper) {
    final pages = _pagesOf(chapter);
    final faint = TextStyle(fontSize: 12, color: paper.faint, fontFamily: bodyFont);
    final g = _globalPage(chapter, page);
    final label = _spread && page + 1 < pages.length ? 'стр. $g–${g + 1} из $_totalPages' : 'стр. $g из $_totalPages';
    final minutes = (_charsLeft(chapter, page) / _charsPerMinute).ceil();
    return SizedBox(
      height: _statusH,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _hPad),
        child: Row(children: [
          Text(label, style: faint.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          const Spacer(),
          Flexible(
            child: Text(minutes <= 1 ? 'меньше минуты до конца главы' : '$minutes мин до конца главы',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: faint),
          ),
        ]),
      ),
    );
  }

  /// Страница (или разворот) [page] главы [chapter]. [live] — та, что на
  /// экране: с выделением и ключами для попадания пальцем в текст.
  List<Widget> _pageRow(int chapter, int page, {required Paper paper, required bool live}) {
    final pages = _pagesOf(chapter);
    final c = BcColors.of(context);
    Widget one(int i) => SizedBox(
          width: _pageWidth,
          height: _pageHeight,
          child: i < pages.length
              ? _PageView(
                  chapter: _content.chapters[chapter],
                  page: pages[i],
                  base: _baseStyle,
                  scaler: _scaler,
                  justify: _style.justify,
                  noteColor: c.ink,
                  images: _content.images,
                  pageSize: Size(_pageWidth, _pageHeight),
                  marksOf: (block) => _marksOf(chapter, block, paper),
                  keyFor: live ? (frag) => _fragKey(i, frag) : null,
                  selection: live ? _selection : null,
                  highlight: c.bar.withValues(alpha: 0.32),
                )
              : null,
        );
    return [
      one(page),
      if (_spread) ...[
        SizedBox(
            width: _gutter,
            height: _pageHeight,
            child: Center(child: VerticalDivider(width: 1, color: paper.faint.withValues(alpha: 0.2)))),
        one(page + 1),
      ],
    ];
  }

  /// Экран читалки целиком (для меню): строки сверху и снизу, страница,
  /// ленточка закладки.
  Widget _screenFor(int chapter, int page, Paper paper) {
    final c = BcColors.of(context);
    final last = math.min(page + _step - 1, _pagesOf(chapter).length - 1);
    return ColoredBox(
      color: paper.bg,
      child: Padding(
        padding: _insets,
        child: Stack(children: [
        Column(children: [
          _statusTop(chapter, paper),
          Expanded(
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _pageRow(chapter, page, paper: paper, live: false),
              ),
            ),
          ),
          _statusBottom(chapter, page, paper),
        ]),
        if (_bookmarksAt(chapter, last).isNotEmpty)
          Positioned(top: 0, right: 24, child: _Ribbon(color: _style.ribbonColor(c.bar))),
        ]),
      ),
    );
  }

  /// Символов от начала страницы [page] до конца главы.
  int _charsLeft(int chapter, int page) {
    final text = _content.chapters[chapter];
    final pages = _pagesOf(chapter);
    final at = chapter == _chapter && page == _page ? _anchor : pages[page.clamp(0, pages.length - 1)].locator(chapter);
    var before = at.offset;
    for (var i = 0; i < at.block && i < text.blocks.length; i++) {
      before += text.blocks[i].length;
    }
    return math.max(0, text.length - before);
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
    const toolbarH = 92.0;
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
            activeColor: _activeHighlight?.color,
            hasNote: (_activeHighlight?.note ?? '').isNotEmpty,
            onColor: (i) => unawaited(_applyColor(i)),
            onNote: () => unawaited(_editNote()),
            onDelete: _activeHighlight == null ? null : () => unawaited(_deleteHighlight()),
            onTranslate: () => _translate(),
            onDictionary: () => _translate(dictionary: true),
            onCopy: _copy,
          ),
        ),
      ),
    ];
  }

  Widget _menuView(Paper paper) {
    final book = _MenuBookView(this, paper);
    return ReaderMenu(
      key: _menuKey,
      bookTitle: widget.book.title,
      author: widget.book.author,
      book: book,
      chapter: _chapter,
      page: _page ~/ _step,
      paper: paper,
      screenSize: _screenSize,
      onOpenPage: (chapter, sheet) {
        final from = _anchor;
        _instantTurn = true;
        setState(() => _menu = false);
        _showPage(chapter, sheet * _step);
        if (from.compareTo(_anchor) != 0) {
          _offerReturn(from);
        }
      },
      // Pop, а не maybePop: maybePop перехватывается и только закрывает меню.
      onExit: () => Navigator.of(context).pop(),
      onToggleBookmark: book.toggle,
      onContents: _showContents,
      onBookmarks: _showBookmarks,
      onStyle: _showStyle,
      onSearch: _showSearch,
      onStats: () => showReadingStats(context),
    );
  }



  /// Место в книге на [v] (0..1) её длины.
  TextLocator _locatorAt(double v) {
    final target = (v.clamp(0.0, 1.0) * _content.length).round();
    var acc = 0;
    for (var ch = 0; ch < _content.chapters.length; ch++) {
      final chapter = _content.chapters[ch];
      if (acc + chapter.length >= target || ch == _content.chapters.length - 1) {
        var inside = target - acc;
        for (var b = 0; b < chapter.blocks.length; b++) {
          if (inside <= chapter.blocks[b].length) return TextLocator(ch, b, math.max(0, inside));
          inside -= chapter.blocks[b].length;
        }
        return TextLocator(ch, 0, 0);
      }
      acc += chapter.length;
    }
    return TextLocator.start;
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
              _jump(TextLocator(i, 0, 0));
            },
          ),
        ),
      ),
    );
  }

  /// Закладки и выделения с заметками — две вкладки одного листа.
  void _showBookmarks() {
    final db = _db;
    String place(TextLocator? l, DateTime at) {
      if (l == null || l.chapter >= _content.chapters.length) return formatAgo(at);
      return '${_content.chapters[l.chapter].title} · стр. ${_pageNumber(l)} · ${formatAgo(at)}';
    }

    void open(BuildContext sheet, TextLocator? l) {
      Navigator.pop(sheet);
      setState(() => _menu = false);
      if (l != null) _jump(l);
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DefaultTabController(
        length: 2,
        initialIndex: _bookmarks.isEmpty && _highlights.isNotEmpty ? 1 : 0,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          maxChildSize: 0.95,
          builder: (context, controller) => Column(children: [
            // Числа обновляются сразу, когда что-то удалили.
            TabBar(tabs: [
              StreamBuilder<List<BookBookmark>>(
                stream: db.watchBookmarks(widget.book.id),
                builder: (context, snap) => Tab(text: 'Закладки · ${(snap.data ?? _bookmarks).length}'),
              ),
              StreamBuilder<List<BookHighlight>>(
                stream: db.watchHighlights(widget.book.key),
                builder: (context, snap) => Tab(text: 'Заметки · ${(snap.data ?? _highlights).length}'),
              ),
            ]),
            Expanded(
              child: TabBarView(children: [
                SingleChildScrollView(
                  controller: controller,
                  child: BookmarksList(
                    db: db,
                    bookId: widget.book.id,
                    meta: (b) => place(TextLocator.parse(b.locator), b.createdAt),
                    onOpen: (b) => open(context, TextLocator.parse(b.locator)),
                  ),
                ),
                SingleChildScrollView(
                  child: HighlightsList(
                    db: db,
                    bookKey: widget.book.key,
                    place: (h) {
                      final l = TextLocator.parse(h.startAt);
                      if (l == null || l.chapter >= _content.chapters.length) return null;
                      return '${_content.chapters[l.chapter].title} · стр. ${_pageNumber(l)}';
                    },
                    onOpen: (h) => open(context, TextLocator.parse(h.startAt)),
                  ),
                ),
              ]),
            ),
          ]),
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
          _jump(TextLocator(chapter, block, start));
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
    this.justify = true,
    this.noteColor,
    this.images = const {},
    this.pageSize = Size.zero,
    this.marksOf,
  });

  final List<TextMark> Function(int block)? marksOf;

  final Map<String, BookImage> images;
  final Size pageSize;
  final bool justify;
  final Color? noteColor;
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
            else if (chapter.blocks[f.block].kind == TextBlockKind.image)
              _imageItem(context, chapter.blocks[f.block], first: i == 0, key: keyFor?.call(i))
            else
              Builder(builder: (context) {
                final block = chapter.blocks[f.block];
                final look = blockLook(block.kind, base, justify: justify);
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
                      noteColor: noteColor,
                      marks: marksOf?.call(f.block) ?? const [],
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

/// «Вернуться на стр. N» — после перехода по оглавлению, поиску, закладке.
class _ReturnPill extends StatelessWidget {
  const _ReturnPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Material(
      color: c.raised,
      elevation: 6,
      shadowColor: Colors.black45,
      shape: StadiumBorder(side: BorderSide(color: c.glassBorder)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.undo_rounded, size: 18, color: c.text),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: c.text)),
            ),
          ]),
        ),
      ),
    );
  }
}

extension on _PageView {
  /// Узоры в SVG обычно чёрные: на тёмном фоне красим их цветом текста.
  ColorFilter? _svgTint(BookImage img) {
    final ink = base.color;
    if (ink == null || ink.computeLuminance() < 0.5) return null;
    return ColorFilter.mode(ink, BlendMode.srcIn);
  }

  /// Картинка по центру, с отступами; размер — как при разбивке на страницы.
  Widget _imageItem(BuildContext context, TextBlock block, {required bool first, Key? key}) {
    final img = images[block.image];
    if (img == null) return const SizedBox.shrink();
    final gap = imageGap(base);
    final size = imageBoxSize(img, pageSize.width, pageSize.height - gap);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : gap, bottom: gap),
      child: Center(
        child: SizedBox.fromSize(
          key: key,
          size: size,
          child: img.svg
              ? SvgPicture.memory(img.bytes, fit: BoxFit.contain, colorFilter: _svgTint(img))
              : Image.memory(
                  img.bytes,
                  fit: BoxFit.contain,
                  // Декодируем под размер на экране, а не исходный — меньше памяти.
                  cacheWidth: math.min(img.width, (size.width * dpr).round()),
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
        ),
      ),
    );
  }
}

/// Картинка во весь экран: масштаб пальцами; не увеличена — смахнуть вверх
/// или вниз, чтобы закрыть (картинка тянется за пальцем, фон бледнеет).
class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.image});

  final BookImage image;

  static Route<void> route(BookImage image) => PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => _ImageViewer(image: image),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
      );

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> with SingleTickerProviderStateMixin {
  final _zoom = TransformationController();
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(() => setState(() => _dy = _from * (1 - Curves.easeOutCubic.transform(_back.value))));

  /// Сдвиг картинки пальцем (когда не увеличена).
  double _dy = 0;
  double _from = 0;
  bool _zoomed = false;

  @override
  void dispose() {
    _zoom.dispose();
    _back.dispose();
    super.dispose();
  }

  bool get _scaled => _zoom.value.getMaxScaleOnAxis() > 1.01;

  void _end(ScaleEndDetails d) {
    final zoomed = _scaled;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
    if (zoomed || _dy == 0) return;
    final v = d.velocity.pixelsPerSecond.dy;
    if (_dy.abs() > 120 || (v.abs() > 900 && v.sign == _dy.sign)) {
      Navigator.of(context).pop();
      return;
    }
    _from = _dy;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    final fade = (1 - (_dy.abs() / 420)).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: fade),
      body: Stack(children: [
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(0, _dy),
            child: InteractiveViewer(
              transformationController: _zoom,
              maxScale: 6,
              // Не увеличена — палец тянет всю картинку (закрыть), а не двигает её.
              panEnabled: _zoomed,
              onInteractionStart: (_) => _back.stop(),
              onInteractionUpdate: (d) {
                if (_scaled) {
                  if (!_zoomed) setState(() => _zoomed = true);
                  return;
                }
                if (d.pointerCount == 1) setState(() => _dy += d.focalPointDelta.dy);
              },
              onInteractionEnd: _end,
              child: Center(
                child: image.svg
                    ? ColoredBox(color: Colors.white, child: SvgPicture.memory(image.bytes, fit: BoxFit.contain))
                    : Image.memory(image.bytes, fit: BoxFit.contain, gaplessPlayback: true),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Opacity(
              opacity: fade,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  tooltip: 'Закрыть',
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ),
      ]),
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

/// Панель над выделением: цвета и заметка, перевод, словарь, копирование.
/// Для сохранённого выделения — ещё «удалить», текущий цвет отмечен.
class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.onTranslate,
    required this.onDictionary,
    required this.onCopy,
    required this.onColor,
    required this.onNote,
    this.onDelete,
    this.activeColor,
    this.hasNote = false,
  });

  final VoidCallback onTranslate;
  final VoidCallback onDictionary;
  final VoidCallback onCopy;
  final ValueChanged<int> onColor;
  final VoidCallback onNote;
  final VoidCallback? onDelete;
  final int? activeColor;
  final bool hasNote;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    // Кнопки по 36, вокруг по 4: скругления кнопок и панели концентричны.
    final text = TextButton.styleFrom(
      foregroundColor: c.text,
      minimumSize: const Size(0, 36),
      fixedSize: const Size.fromHeight(36),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: const StadiumBorder(),
    );
    Widget round(Widget child, String tooltip, VoidCallback onTap) => Tooltip(
          message: tooltip,
          child: InkResponse(
            onTap: onTap,
            radius: 20,
            child: SizedBox.square(dimension: 36, child: Center(child: child)),
          ),
        );
    return Material(
      color: c.raised,
      elevation: 10,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: c.glassBorder)),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < highlightColors.length; i++)
              round(
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: highlightColors[i],
                    shape: BoxShape.circle,
                    border: Border.all(color: i == activeColor ? c.text : Colors.transparent, width: 2),
                  ),
                  child: i == activeColor ? const Icon(Icons.check_rounded, size: 16, color: Colors.black87) : null,
                ),
                activeColor == null ? 'Выделить цветом' : 'Сменить цвет',
                () => onColor(i),
              ),
            Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 6), color: c.divider),
            round(Icon(hasNote ? Icons.sticky_note_2 : Icons.sticky_note_2_outlined, size: 21, color: c.text),
                hasNote ? 'Изменить заметку' : 'Заметка', onNote),
            if (onDelete != null) round(Icon(Icons.delete_outline_rounded, size: 21, color: c.text), 'Удалить заметку', onDelete!),
          ]),
          const SizedBox(height: 4),
          Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 36),
                fixedSize: const Size.fromHeight(36),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard,
                shape: const StadiumBorder(),
              ),
              onPressed: onTranslate,
              icon: const BcIcon(BcIcons.translate, size: 16),
              label: const Text('Перевести', style: TextStyle(fontSize: 14)),
            ),
            TextButton(style: text, onPressed: onDictionary, child: const Text('Словарь')),
            TextButton(style: text, onPressed: onCopy, child: const Text('Копировать')),
          ]),
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

/// Книга для меню: страницы любой главы при текущей разбивке.
/// Книга для меню: листы любой главы при текущей разбивке. В развороте
/// лист — две страницы рядом, иначе — одна.
class _MenuBookView implements MenuBook {
  _MenuBookView(this.s, this.paper) : step = s._step;

  final _ReaderScreenState s;
  final Paper paper;
  final int step;

  int _first(int chapter, int sheet) => math.min(sheet * step, s._pagesOf(chapter).length - 1);

  @override
  int get chapterCount => s._content.chapters.length;

  @override
  int pageCount(int chapter) => (s._pagesOf(chapter).length + step - 1) ~/ step;

  @override
  int pagesInChapter(int chapter) => s._pagesOf(chapter).length;

  @override
  int get totalPages => s._totalPages;

  @override
  String pageNumbers(int chapter, int sheet) {
    final first = _first(chapter, sheet);
    final a = s._globalPage(chapter, first);
    return step == 2 && first + 1 < pagesInChapter(chapter) ? '$a–${a + 1}' : '$a';
  }

  @override
  String chapterTitle(int chapter) => s._content.chapters[chapter].title;

  @override
  Widget screen(int chapter, int sheet) => s._screenFor(chapter, _first(chapter, sheet), paper);

  @override
  double percentAt(int chapter, int sheet) {
    if (s._content.length == 0) return 0;
    final pages = s._pagesOf(chapter);
    final page = _first(chapter, sheet);
    if (chapter == chapterCount - 1 && page + step >= pages.length) return 1;
    return (s._charsBefore(pages[page].locator(chapter)) / s._content.length).clamp(0.0, 1.0);
  }

  @override
  ({int chapter, int page}) locate(double percent) {
    final l = s._locatorAt(percent);
    return (chapter: l.chapter, page: pageOf(s._pagesOf(l.chapter), l.block, l.offset) ~/ step);
  }

  @override
  bool bookmarked(int chapter, int sheet) {
    final first = _first(chapter, sheet);
    for (var p = first; p < first + step; p++) {
      if (s._bookmarksAt(chapter, p).isNotEmpty) return true;
    }
    return false;
  }

  /// Закладка листа: есть на какой-то из страниц — снять, нет — поставить
  /// на правую (как угол в книге).
  void toggle(int chapter, int sheet) {
    final first = _first(chapter, sheet);
    final last = math.min(first + step - 1, pagesInChapter(chapter) - 1);
    for (var p = first; p <= last; p++) {
      if (s._bookmarksAt(chapter, p).isNotEmpty) {
        unawaited(s._toggleBookmarkAt(chapter, p));
        return;
      }
    }
    unawaited(s._toggleBookmarkAt(chapter, last));
  }
}

/// Выбор цвета закладки.
class _RibbonColors extends StatelessWidget {
  const _RibbonColors({required this.selected, required this.accent, required this.onSelect});

  final int selected;
  final Color accent;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Material(
      color: c.raised,
      elevation: 10,
      shadowColor: Colors.black54,
      shape: StadiumBorder(side: BorderSide(color: c.glassBorder)),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < bookmarkColors.length; i++)
            Tooltip(
              message: i == 0 ? 'Цвет приложения' : 'Цвет закладки',
              child: InkResponse(
                onTap: () => onSelect(i),
                radius: 22,
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: i == selected ? c.text : Colors.transparent, width: 2),
                  ),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: bookmarkColors[i] ?? accent),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
