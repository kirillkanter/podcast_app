/// Меню книги, как в Kindle: открытая страница уменьшается (весь экран
/// целиком, с полями), соседние видны по бокам, их можно листать; ушли со
/// своей страницы — кнопка «Вернуться на стр. N». Внизу — мини-плеер (если
/// что-то играет), ползунок по книге и кнопки. Открытие и закрытие — та же
/// страница плавно меняет размер.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../icons.dart';
import '../../now_playing.dart';
import '../../podcast_cover.dart';
import '../../theme.dart';
import '../book_start.dart';
import 'reader_style.dart';

/// Книга глазами меню: сколько глав и листов, как нарисовать экран.
abstract class MenuBook {
  int get chapterCount;

  /// Листов в главе (в развороте лист — две страницы).
  int pageCount(int chapter);

  /// Страниц в главе.
  int pagesInChapter(int chapter);

  /// Номера страниц листа: «31» или «31–32».
  String pageNumbers(int chapter, int sheet);
  String chapterTitle(int chapter);

  /// Экран читалки с этим листом — во весь размер экрана, с полями и
  /// строками над и под текстом (меню его уменьшает).
  Widget screen(int chapter, int sheet);
  double percentAt(int chapter, int sheet);
  ({int chapter, int page}) locate(double percent);
  bool bookmarked(int chapter, int sheet);
}

class ReaderMenu extends StatefulWidget {
  const ReaderMenu({
    super.key,
    required this.bookTitle,
    required this.author,
    required this.book,
    required this.chapter,
    required this.page,
    required this.paper,
    required this.screenSize,
    required this.onOpenPage,
    required this.onExit,
    required this.onToggleBookmark,
    required this.onContents,
    required this.onBookmarks,
    required this.onStyle,
    required this.onSearch,
    required this.onStats,
  });

  final String bookTitle;
  final String? author;
  final MenuBook book;

  /// Где читаем (лист).
  final int chapter;
  final int page;
  final Paper paper;

  /// Размер экрана читалки (меню показывает его уменьшенным).
  final Size screenSize;

  /// Меню закрылось на листе [sheet] главы [chapter] (анимация уже прошла).
  final void Function(int chapter, int sheet) onOpenPage;
  final VoidCallback onExit;

  /// Поставить или убрать закладку на листе, который сейчас в центре ленты.
  final void Function(int chapter, int sheet) onToggleBookmark;
  final VoidCallback onContents;
  final VoidCallback onBookmarks;
  final VoidCallback onStyle;
  final VoidCallback onSearch;
  final VoidCallback onStats;

  @override
  State<ReaderMenu> createState() => ReaderMenuState();
}

class ReaderMenuState extends State<ReaderMenu> with SingleTickerProviderStateMixin {
  /// Глава, листы которой сейчас в ленте. По краям ленты — по листу
  /// соседних глав: долистали до него — лента переходит на ту главу.
  late int _ch = widget.chapter;

  /// Доля ширины ленты под один лист: столько, чтобы между листами были
  /// небольшие зазоры.
  double _fraction = 0.62;
  bool _sized = false;
  late PageController _pages = PageController(initialPage: _pre + widget.page, viewportFraction: _fraction);
  late int _index = _pre + widget.page;
  double? _drag;

  /// 0 — экран во весь размер (читалка), 1 — меню.
  late final AnimationController _zoom = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));

  /// Лист, который сейчас увеличивается или уменьшается; `null` — анимации нет.
  ({int chapter, int page})? _flying = (chapter: -1, page: -1);
  bool _closing = false;

  final _rootKey = GlobalKey();
  final _areaKey = GlobalKey();

  /// Размер уменьшенного экрана в ленте.
  Size _mini = Size.zero;

  int get _pre => _ch > 0 ? 1 : 0;
  int get _count => widget.book.pageCount(_ch);
  int get _post => _ch < widget.book.chapterCount - 1 ? 1 : 0;

  @override
  void initState() {
    super.initState();
    _flying = (chapter: widget.chapter, page: widget.page);
    _zoom.addListener(() => setState(() {}));
    // Первый кадр — экран во весь размер; дальше он уменьшается до места в ленте.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _zoom.animateTo(1, curve: Curves.easeOutCubic);
      if (mounted && !_closing) setState(() => _flying = null);
    });
  }

  @override
  void dispose() {
    _zoom.dispose();
    _pages.dispose();
    super.dispose();
  }

  /// Глава и лист элемента ленты [i].
  ({int chapter, int page}) _at(int i) {
    if (_pre == 1 && i == 0) return (chapter: _ch - 1, page: widget.book.pageCount(_ch - 1) - 1);
    final p = i - _pre;
    if (p >= _count) return (chapter: _ch + 1, page: 0);
    return (chapter: _ch, page: p);
  }

  ({int chapter, int page}) get _shown => _at(_index);

  bool get _away => _shown.chapter != widget.chapter || _shown.page != widget.page;

  /// Закрыть меню: лист в центре увеличивается во весь экран. [toReading] —
  /// вернуться на лист, с которого открыли меню.
  Future<void> close({bool toReading = false}) async {
    if (_closing) return;
    var at = _shown;
    if (toReading && _away) {
      _show(widget.chapter, widget.page);
      at = (chapter: widget.chapter, page: widget.page);
    }
    await _closeOn(at);
  }

  Future<void> _closeOn(({int chapter, int page}) at) async {
    _closing = true;
    setState(() => _flying = at);
    await _zoom.animateBack(0, curve: Curves.easeInCubic);
    if (mounted) widget.onOpenPage(at.chapter, at.page);
  }

  Future<void> _tapItem(int i) async {
    if (_closing || _flying != null) return;
    if (i != _index && _pages.hasClients) {
      // Сначала лист — в центр, потом увеличивается.
      await _pages.animateToPage(i, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      if (!mounted) return;
      _index = i;
    }
    await _closeOn(_at(i));
  }

  /// Показать лист [page] главы [chapter]: та же глава — листаем,
  /// другая — перестраиваем ленту.
  void _show(int chapter, int page, {bool animate = false}) {
    if (chapter == _ch && _pages.hasClients) {
      final i = _pre + page;
      if (animate) {
        unawaited(_pages.animateToPage(i, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic));
      } else {
        _pages.jumpToPage(i);
      }
      setState(() => _index = i);
      return;
    }
    final old = _pages;
    setState(() {
      _ch = chapter;
      _index = _pre + page;
      _pages = PageController(initialPage: _index, viewportFraction: _fraction);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _setFraction(double f) {
    final old = _pages;
    setState(() {
      _fraction = f;
      _pages = PageController(initialPage: _index, viewportFraction: f);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  bool _onScrollEnd(ScrollNotification n) {
    if (n is ScrollEndNotification && n.depth == 0) {
      final at = _shown;
      // Остановились на листе соседней главы — переходим на неё.
      if (at.chapter != _ch) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _show(at.chapter, at.page);
        });
      }
    }
    return false;
  }

  /// Где в меню лежит лист из центра ленты.
  Rect? _targetRect() {
    final root = _rootKey.currentContext?.findRenderObject() as RenderBox?;
    final area = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (root == null || area == null || !area.hasSize || _mini == Size.zero) return null;
    final center = root.globalToLocal(area.localToGlobal(area.size.center(Offset.zero)));
    return Rect.fromCenter(center: center, width: _mini.width, height: _mini.height);
  }

  Widget _miniScreen(int chapter, int sheet) => FittedBox(
        fit: BoxFit.fill,
        child: SizedBox.fromSize(size: widget.screenSize, child: widget.book.screen(chapter, sheet)),
      );

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shade = dark ? const Color(0xFF0E0E0E) : const Color(0xFFE6E6E0);
    final shown = _shown;
    final percent = _drag ?? widget.book.percentAt(shown.chapter, shown.page);
    // Телефон набок: места по высоте мало — всё в одну строку.
    final compact = widget.screenSize.height < 520;
    final t = _zoom.value;
    final chrome = Curves.easeOut.transform(t);

    Widget fade(Widget child) => Opacity(opacity: chrome, child: child);

    final header = Padding(
      padding: EdgeInsets.fromLTRB(4, compact ? 0 : 4, 4, 0),
      child: Row(children: [
        IconButton(
          tooltip: 'Закрыть книгу',
          icon: BcIcon(BcIcons.chevronLeft, color: c.text),
          onPressed: widget.onExit,
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(widget.bookTitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(
              compact
                  ? '${widget.book.chapterTitle(shown.chapter)} · стр. ${widget.book.pageNumbers(shown.chapter, shown.page)} из ${widget.book.pagesInChapter(shown.chapter)}'
                  : (widget.author ?? ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.muted),
            ),
          ]),
        ),
        IconButton(tooltip: 'Статистика чтения', icon: Icon(Icons.insights_rounded, color: c.text), onPressed: widget.onStats),
        IconButton(tooltip: 'Поиск по книге', icon: BcIcon(BcIcons.search, color: c.text), onPressed: widget.onSearch),
        Builder(builder: (context) {
          final marked = widget.book.bookmarked(shown.chapter, shown.page);
          return IconButton(
            tooltip: marked ? 'Убрать закладку' : 'Закладка на этой странице',
            icon: Icon(marked ? Icons.bookmark : Icons.bookmark_outline, color: marked ? c.ink : c.text),
            onPressed: () => widget.onToggleBookmark(shown.chapter, shown.page),
          );
        }),
      ]),
    );

    final chapterLine = Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Row(children: [
        Expanded(
          child: Text(widget.book.chapterTitle(shown.chapter),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Text(
            'стр. ${widget.book.pageNumbers(shown.chapter, shown.page)} из ${widget.book.pagesInChapter(shown.chapter)} · ${(percent * 100).floor()} %',
            style: TextStyle(fontSize: 12, color: c.muted, fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );

    final back = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: !_away
          ? const SizedBox.shrink()
          : FilledButton.icon(
              key: const ValueKey('back'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 36), shape: const StadiumBorder()),
              onPressed: () => _show(widget.chapter, widget.page, animate: true),
              icon: const Icon(Icons.undo_rounded, size: 18),
              label: Text('Вернуться на стр. ${widget.book.pageNumbers(widget.chapter, widget.page)}'),
            ),
    );

    final strip = LayoutBuilder(builder: (context, box) {
      final screen = widget.screenSize;
      final h = box.maxHeight - (compact ? 12 : 24);
      final byHeight = h / screen.height;
      final wanted = ((screen.width * byHeight + 28) / box.maxWidth).clamp(0.3, 0.86);
      if (!_sized) {
        // Первый показ: сразу нужная ширина, без перескока.
        _sized = true;
        if ((wanted - _fraction).abs() > 0.02) {
          _pages.dispose();
          _fraction = wanted;
          _pages = PageController(initialPage: _index, viewportFraction: wanted);
        }
      } else if ((wanted - _fraction).abs() > 0.02) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _setFraction(wanted);
        });
      }
      final w = box.maxWidth * _fraction - 28;
      final scale = math.min(byHeight, w / screen.width).clamp(0.05, 1.0);
      _mini = Size(screen.width * scale, screen.height * scale);
      return NotificationListener<ScrollNotification>(
        onNotification: _onScrollEnd,
        child: PageView.builder(
          key: ValueKey('$_ch/$_fraction'),
          controller: _pages,
          pageSnapping: false,
          physics: _FlingPagePhysics(fraction: _fraction),
          itemCount: _pre + _count + _post,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (context, i) {
            final at = _at(i);
            final current = at.chapter == widget.chapter && at.page == widget.page;
            return Center(
              child: GestureDetector(
                onTap: () => _tapItem(i),
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 200),
                  scale: i == _index ? 1 : 0.92,
                  child: Container(
                    width: _mini.width,
                    height: _mini.height,
                    foregroundDecoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: current ? Border.all(color: c.bar, width: 2) : null,
                    ),
                    decoration: BoxDecoration(
                      color: widget.paper.bg,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8))],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: IgnorePointer(child: _miniScreen(at.chapter, at.page)),
                  ),
                ),
              ),
            );
          },
        ),
      );
    });

    final slider = Slider(
      value: percent.clamp(0.0, 1.0),
      // Ползунок листает ленту на ходу; книга не открывается — открыть лист
      // можно нажатием на него.
      onChanged: (v) {
        final at = widget.book.locate(v);
        setState(() => _drag = v);
        if (at.chapter != _shown.chapter || at.page != _shown.page) _show(at.chapter, at.page);
      },
      onChangeEnd: (_) => setState(() => _drag = null),
    );
    final percentText = SizedBox(
      width: 44,
      child: Text('${(percent * 100).floor()} %', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: c.muted)),
    );
    final actions = [
      _Action(icon: const BcIcon(BcIcons.chapters, size: 22), label: 'Оглавление', onTap: widget.onContents, compact: compact),
      _Action(icon: const BcIcon(BcIcons.bookmark, size: 22), label: 'Закладки', onTap: widget.onBookmarks, compact: compact),
      _Action(
        icon: const Text('Аа', style: TextStyle(fontFamily: 'PTSerif', fontSize: 19, fontWeight: FontWeight.w700)),
        label: 'Текст',
        onTap: widget.onStyle,
        compact: compact,
      ),
    ];
    final bottom = Container(
      decoration: BoxDecoration(color: c.card, border: Border(top: BorderSide(color: c.divider))),
      padding: EdgeInsets.fromLTRB(16, compact ? 2 : 6, 16, compact ? 2 : 8),
      child: compact
          ? Row(children: [...actions, Expanded(child: slider), percentText])
          : Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [Expanded(child: slider), percentText]),
              Row(children: [for (final a in actions) Expanded(child: a)]),
            ]),
    );

    final flying = _flying;
    final target = flying == null ? null : _targetRect();
    final full = Offset.zero & widget.screenSize;

    return Material(
      key: _rootKey,
      color: shade,
      child: Stack(children: [
        SafeArea(
          child: IgnorePointer(
            ignoring: flying != null,
            child: Column(children: [
              fade(header),
              if (!compact) fade(chapterLine),
              Expanded(
                child: Stack(key: _areaKey, children: [
                  Positioned.fill(child: Opacity(opacity: flying == null ? 1 : 0, child: strip)),
                  if (compact) Positioned(left: 0, right: 0, bottom: 4, child: Center(child: fade(back))),
                ]),
              ),
              if (!compact) fade(SizedBox(height: 48, child: Center(child: back))),
              fade(_MiniPlayer(compact: compact)),
              fade(bottom),
            ]),
          ),
        ),
        if (flying != null)
          Positioned.fromRect(
            rect: Rect.lerp(full, target ?? full, target == null ? 0 : t)!,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8 * t),
              child: ColoredBox(color: widget.paper.bg, child: _miniScreen(flying.chapter, flying.page)),
            ),
          ),
      ]),
    );
  }
}

/// Лента страниц с инерцией: быстрый свайп пролистывает несколько страниц,
/// остановка — ровно на странице.
class _FlingPagePhysics extends ScrollPhysics {
  const _FlingPagePhysics({required this.fraction, super.parent});

  final double fraction;

  @override
  _FlingPagePhysics applyTo(ScrollPhysics? ancestor) => _FlingPagePhysics(fraction: fraction, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final extent = position.viewportDimension * fraction;
    if (extent <= 0) return super.createBallisticSimulation(position, velocity);
    final tol = toleranceFor(position);
    final current = position.pixels / extent;
    double page;
    if (velocity.abs() < tol.velocity) {
      page = current.roundToDouble();
    } else {
      // Куда докатилась бы лента сама, с трением.
      final end = FrictionSimulation(0.12, position.pixels, velocity).finalX / extent;
      page = end.roundToDouble();
      // Короткий быстрый свайп — хотя бы на страницу.
      if (velocity > 0 && page <= current) page = current.floorToDouble() + 1;
      if (velocity < 0 && page >= current) page = current.ceilToDouble() - 1;
    }
    final target = (page * extent).clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < tol.distance) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity, tolerance: tol);
  }

  @override
  bool get allowImplicitScrolling => false;
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.compact = false});

  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return IconButton(tooltip: label, onPressed: onTap, icon: SizedBox(height: 24, child: Center(child: icon)));
    }
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
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

/// Маленький плеер: что играет и пауза — не выходя из книги.
class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return NowPlayingBuilder(builder: (context, now, audio) {
      final item = now.item;
      if (audio == null || item == null || !now.active) return const SizedBox.shrink();
      final c = BcColors.of(context);
      return Padding(
        padding: EdgeInsets.fromLTRB(10, 0, 10, compact ? 4 : 10),
        child: Glass(
          child: SizedBox(
            height: compact ? 44 : 56,
            child: Stack(children: [
              Padding(
                padding: EdgeInsets.all(compact ? 4 : 8),
                child: Row(children: [
                  PodcastCover(url: item.artUri?.toString(), size: compact ? 36 : 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      if (item.album != null && !compact)
                        Text(item.album!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
                    ]),
                  ),
                  RoundIconButton(
                    icon: now.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    tooltip: now.playing ? 'Пауза' : 'Продолжить',
                    style: RoundStyle.accent,
                    size: compact ? 36 : 40,
                    iconSize: 22,
                    onPressed: now.playing ? audio.pause : (now.bookId != null ? () => resumeAudioBook(context) : audio.play),
                  ),
                ]),
              ),
              Positioned(left: 0, right: 0, bottom: 0, child: _Progress(item: item, stream: audio.positionStream, color: c.bar)),
            ]),
          ),
        ),
      );
    });
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.item, required this.stream, required this.color});

  final MediaItem item;
  final Stream<Duration> stream;
  final Color color;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
        stream: stream,
        builder: (context, snap) {
          final d = item.duration?.inMilliseconds ?? 0;
          final v = d <= 0 ? 0.0 : ((snap.data?.inMilliseconds ?? 0) / d).clamp(0.0, 1.0);
          return Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(widthFactor: v, child: SizedBox(height: 3, child: ColoredBox(color: color))),
          );
        },
      );
}
