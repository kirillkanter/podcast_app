/// Меню книги, как в Kindle: страница уменьшается, соседние видны по бокам,
/// их можно листать; ушли со своей страницы — кнопка «Вернуться на стр. N».
/// Внизу — мини-плеер (если что-то играет), ползунок по книге и кнопки.
library;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../../icons.dart';
import '../../now_playing.dart';
import '../../podcast_cover.dart';
import '../../theme.dart';
import '../book_start.dart';
import 'reader_style.dart';

class ReaderMenu extends StatefulWidget {
  const ReaderMenu({
    super.key,
    required this.bookTitle,
    required this.author,
    required this.chapterTitle,
    required this.pageCount,
    required this.page,
    required this.percent,
    required this.paper,
    required this.pageSize,
    required this.pageBuilder,
    required this.bookmarked,
    required this.onOpenPage,
    required this.onClose,
    required this.onExit,
    required this.onToggleBookmark,
    required this.onContents,
    required this.onBookmarks,
    required this.onStyle,
    required this.onSearch,
    required this.onSeekPercent,
  });

  final String bookTitle;
  final String? author;
  final String chapterTitle;
  final int pageCount;

  /// Страница, на которой читаем.
  final int page;
  final double percent;
  final Paper paper;
  final Size pageSize;
  final Widget Function(int page) pageBuilder;
  final bool bookmarked;
  final ValueChanged<int> onOpenPage;
  final VoidCallback onClose;
  final VoidCallback onExit;
  final VoidCallback onToggleBookmark;
  final VoidCallback onContents;
  final VoidCallback onBookmarks;
  final VoidCallback onStyle;
  final VoidCallback onSearch;
  final ValueChanged<double> onSeekPercent;

  @override
  State<ReaderMenu> createState() => _ReaderMenuState();
}

class _ReaderMenuState extends State<ReaderMenu> {
  late final PageController _pages = PageController(initialPage: widget.page, viewportFraction: 0.62);
  late int _shown = widget.page;
  double? _drag;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shade = dark ? const Color(0xFF0E0E0E) : const Color(0xFFE6E6E0);
    final percent = _drag ?? widget.percent;
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
              IconButton(
                tooltip: widget.bookmarked ? 'Убрать закладку' : 'Закладка на этой странице',
                icon: Icon(widget.bookmarked ? Icons.bookmark : Icons.bookmark_outline, color: widget.bookmarked ? c.ink : c.text),
                onPressed: widget.onToggleBookmark,
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Row(children: [
              Expanded(
                child: Text(widget.chapterTitle,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              Text('стр. ${_shown + 1} из ${widget.pageCount} · ${(percent * 100).floor()} %',
                  style: TextStyle(fontSize: 12, color: c.muted, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              // Уменьшенная страница: целиком по высоте, с полями вокруг.
              final h = box.maxHeight - 24;
              final scale = (h / widget.pageSize.height).clamp(0.2, 1.0);
              return PageView.builder(
                controller: _pages,
                itemCount: widget.pageCount,
                onPageChanged: (i) => setState(() => _shown = i),
                itemBuilder: (context, i) {
                  final current = i == widget.page;
                  return Center(
                    child: GestureDetector(
                      onTap: () => widget.onOpenPage(i),
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 200),
                        scale: i == _shown ? 1 : 0.9,
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
                              child: IgnorePointer(child: widget.pageBuilder(i)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            }),
          ),
          SizedBox(
            height: 48,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _shown == widget.page
                    ? const SizedBox.shrink()
                    : FilledButton.icon(
                        key: const ValueKey('back'),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 36), shape: const StadiumBorder()),
                        onPressed: () => _pages.animateToPage(widget.page,
                            duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic),
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        label: Text('Вернуться на стр. ${widget.page + 1}'),
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
                    onChanged: (v) => setState(() => _drag = v),
                    onChangeEnd: (v) {
                      setState(() => _drag = null);
                      widget.onSeekPercent(v);
                    },
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
