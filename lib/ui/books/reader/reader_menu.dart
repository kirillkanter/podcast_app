/// Меню книги, как в Kindle: страница уменьшается, соседние видны по бокам,
/// их можно листать; ушли со своей страницы — кнопка «Вернуться на стр. N».
/// Внизу — мини-плеер (если что-то играет), ползунок по книге и кнопки.
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

/// Книга глазами меню: сколько глав и страниц, как нарисовать страницу.
abstract class MenuBook {
  int get chapterCount;

  /// Листов в главе (в развороте лист — две страницы).
  int pageCount(int chapter);

  /// Страниц в главе.
  int pagesInChapter(int chapter);

  /// Номера страниц листа: «31» или «31–32».
  String pageNumbers(int chapter, int sheet);
  String chapterTitle(int chapter);
  Widget page(int chapter, int page);
  double percentAt(int chapter, int page);
  ({int chapter, int page}) locate(double percent);
  bool bookmarked(int chapter, int page);
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
    required this.pageSize,
    required this.onOpenPage,
    required this.onExit,
    required this.onToggleBookmark,
    required this.onContents,
    required this.onBookmarks,
    required this.onStyle,
    required this.onSearch,
  });

  final String bookTitle;
  final String? author;
  final MenuBook book;

  /// Где читаем.
  final int chapter;
  final int page;
  final Paper paper;
  final Size pageSize;
  final void Function(int chapter, int page) onOpenPage;
  final VoidCallback onExit;

  /// Поставить или убрать закладку на странице, которая сейчас в центре ленты.
  final void Function(int chapter, int page) onToggleBookmark;
  final VoidCallback onContents;
  final VoidCallback onBookmarks;
  final VoidCallback onStyle;
  final VoidCallback onSearch;

  @override
  State<ReaderMenu> createState() => _ReaderMenuState();
}


class _ReaderMenuState extends State<ReaderMenu> {
  /// Глава, страницы которой сейчас в ленте. По краям ленты — по странице
  /// соседних глав: долистали до неё — лента переходит на ту главу.
  late int _ch = widget.chapter;

  /// Доля ширины ленты под один лист: столько, чтобы между листами были
  /// небольшие зазоры (в альбомной ориентации листы шире).
  double _fraction = 0.62;
  bool _sized = false;
  late PageController _pages = PageController(initialPage: _pre + widget.page, viewportFraction: _fraction);
  late int _index = _pre + widget.page;
  double? _drag;

  int get _pre => _ch > 0 ? 1 : 0;
  int get _count => widget.book.pageCount(_ch);
  int get _post => _ch < widget.book.chapterCount - 1 ? 1 : 0;

  /// Глава и страница элемента ленты [i].
  ({int chapter, int page}) _at(int i) {
    if (_pre == 1 && i == 0) return (chapter: _ch - 1, page: widget.book.pageCount(_ch - 1) - 1);
    final p = i - _pre;
    if (p >= _count) return (chapter: _ch + 1, page: 0);
    return (chapter: _ch, page: p);
  }

  ({int chapter, int page}) get _shown => _at(_index);

  bool get _away => _shown.chapter != widget.chapter || _shown.page != widget.page;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Показать страницу [page] главы [chapter]: та же глава — листаем,
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
      // Остановились на странице соседней главы — переходим на неё.
      if (at.chapter != _ch) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _show(at.chapter, at.page);
        });
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shade = dark ? const Color(0xFF0E0E0E) : const Color(0xFFE6E6E0);
    final shown = _shown;
    final percent = _drag ?? widget.book.percentAt(shown.chapter, shown.page);
    return Material(
      color: shade,
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
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
                  if (widget.author != null)
                    Text(widget.author!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
                ]),
              ),
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
          ),
          Padding(
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
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              // Уменьшенная страница: целиком по высоте, с полями вокруг.
              final h = box.maxHeight - 24;
              final byHeight = h / widget.pageSize.height;
              final wanted = ((widget.pageSize.width * byHeight + 20 + 28) / box.maxWidth).clamp(0.3, 0.86);
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
              final scale = math.min(byHeight, w / widget.pageSize.width).clamp(0.05, 1.0);
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
                        onTap: () => widget.onOpenPage(at.chapter, at.page),
                        child: AnimatedScale(
                          duration: const Duration(milliseconds: 200),
                          scale: i == _index ? 1 : 0.9,
                          child: Container(
                            width: widget.pageSize.width * scale + 20,
                            height: widget.pageSize.height * scale + 28,
                            decoration: BoxDecoration(
                              color: widget.paper.bg,
                              borderRadius: BorderRadius.circular(10),
                              border: current ? Border.all(color: c.bar, width: 2) : null,
                              boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8))],
                            ),
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 18),
                            child: FittedBox(
                              fit: BoxFit.contain,
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                width: widget.pageSize.width,
                                height: widget.pageSize.height,
                                child: IgnorePointer(child: widget.book.page(at.chapter, at.page)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            }),
          ),
          SizedBox(
            height: 48,
            child: Center(
              child: AnimatedSwitcher(
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
              ),
            ),
          ),
          const _MiniPlayer(),
          Container(
            decoration: BoxDecoration(color: c.card, border: Border(top: BorderSide(color: c.divider))),
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: Slider(
                    value: percent.clamp(0.0, 1.0),
                    // Ползунок листает ленту на ходу; книга не открывается —
                    // открыть страницу можно тапом по ней.
                    onChanged: (v) {
                      final at = widget.book.locate(v);
                      setState(() => _drag = v);
                      if (at.chapter != _shown.chapter || at.page != _shown.page) _show(at.chapter, at.page);
                    },
                    onChangeEnd: (_) => setState(() => _drag = null),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${(percent * 100).floor()} %',
                      textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: c.muted)),
                ),
              ]),
              Row(children: [
                Expanded(child: _Action(icon: const BcIcon(BcIcons.chapters, size: 22), label: 'Оглавление', onTap: widget.onContents)),
                Expanded(child: _Action(icon: const BcIcon(BcIcons.bookmark, size: 22), label: 'Закладки', onTap: widget.onBookmarks)),
                Expanded(
                  child: _Action(
                    icon: const Text('Аа', style: TextStyle(fontFamily: 'PTSerif', fontSize: 19, fontWeight: FontWeight.w700)),
                    label: 'Текст',
                    onTap: widget.onStyle,
                  ),
                ),
              ]),
            ]),
          ),
        ]),
      ),
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
  const _Action({required this.icon, required this.label, required this.onTap});

  final Widget icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
  const _MiniPlayer();

  @override
  Widget build(BuildContext context) {
    return NowPlayingBuilder(builder: (context, now, audio) {
      final item = now.item;
      if (audio == null || item == null || !now.active) return const SizedBox.shrink();
      final c = BcColors.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Glass(
          child: SizedBox(
            height: 56,
            child: Stack(children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  PodcastCover(url: item.artUri?.toString(), size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      if (item.album != null)
                        Text(item.album!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
                    ]),
                  ),
                  RoundIconButton(
                    icon: now.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    tooltip: now.playing ? 'Пауза' : 'Продолжить',
                    style: RoundStyle.accent,
                    size: 40,
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
