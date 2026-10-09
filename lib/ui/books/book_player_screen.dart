/// Плеер аудиокниги: всё вокруг главы — название, место в главе, переход
/// по главам, таймер «до конца главы», закладки, скорость этой книги.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../../books/locator.dart';
import '../../data/db/books_dao.dart';
import '../../data/db/database.dart';
import '../../player/playback_logic.dart';
import '../../player/podcast_audio_handler.dart';
import '../app_scope.dart';
import '../format.dart';
import '../icons.dart';
import '../marquee.dart';
import '../menu.dart';
import '../now_playing.dart';
import '../theme.dart';
import 'book_start.dart';
import 'book_widgets.dart';

class BookPlayerScreen extends StatefulWidget {
  const BookPlayerScreen({super.key});

  static Route<void> route() => PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 340),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => const BookPlayerScreen(),
        transitionsBuilder: (_, animation, _, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic),
          ),
          child: child,
        ),
      );

  @override
  State<BookPlayerScreen> createState() => _BookPlayerScreenState();
}

class _BookPlayerScreenState extends State<BookPlayerScreen> with SingleTickerProviderStateMixin {
  /// Сдвиг вниз, пока плеер тянут пальцем.
  double _drag = 0;
  double _dragFrom = 0;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
    ..addListener(() => setState(() => _drag = _dragFrom * (1 - Curves.easeOut.transform(_back.value))));

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _pull(double dy) => setState(() => _drag = math.max(0, _drag + dy));

  /// Отпустили: далеко или быстро — свернуть, иначе вернуть на место.
  void _release(double velocity) {
    if (_drag <= 0) return;
    final height = MediaQuery.sizeOf(context).height;
    if (_drag > height * 0.18 || velocity > 700) {
      Navigator.of(context).pop();
    } else {
      _dragFrom = _drag;
      _back.forward(from: 0);
    }
  }

  /// Список прокручен до верха и его тянут дальше вниз — тянем весь плеер.
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification && n.overscroll < 0 && n.dragDetails != null) {
      _pull(-n.overscroll);
    } else if (n is ScrollUpdateNotification && _drag > 0 && (n.scrollDelta ?? 0) > 0 && n.dragDetails != null) {
      _pull(-(n.scrollDelta ?? 0));
    } else if (n is ScrollEndNotification && _drag > 0) {
      _release(n.dragDetails?.primaryVelocity ?? 0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Transform.translate(
        offset: Offset(0, _drag),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragUpdate: (d) => _pull(d.delta.dy),
          onVerticalDragEnd: (d) => _release(d.primaryVelocity ?? 0),
          child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: _content(context)),
        ),
      );

  Widget _content(BuildContext context) {
    final c = BcColors.of(context);
    return NowPlayingBuilder(builder: (context, now, audio) {
      final book = audio?.currentBook;
      if (audio == null || book == null || !now.active) {
        // Книга закончилась или плеер закрыли — экран не закрывается сам,
        // чтобы не исчезать от случайного пустого состояния.
        return Scaffold(
          backgroundColor: c.bg,
          appBar: AppBar(),
          body: Center(child: Text('Сейчас книга не играет', style: TextStyle(color: c.muted))),
        );
      }
      final wide = MediaQuery.sizeOf(context).width >= 900;
      return Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: ValueListenableBuilder<int>(
            valueListenable: audio.bookChanged,
            builder: (context, _, _) => wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: _PlayerColumn(audio: audio, now: now, book: book, showNext: false),
                        ),
                      ),
                    ),
                    VerticalDivider(width: 1, color: c.divider),
                    SizedBox(width: 420, child: _ChaptersPanel(audio: audio, book: book)),
                  ])
                : _PlayerColumn(audio: audio, now: now, book: book, showNext: true),
          ),
        ),
      );
    });
  }
}

class _PlayerColumn extends StatelessWidget {
  const _PlayerColumn({required this.audio, required this.now, required this.book, required this.showNext});

  final PodcastAudioHandler audio;
  final NowPlaying now;
  final Book book;
  final bool showNext;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return StreamBuilder<Duration>(
      stream: audio.bookPositionStream,
      builder: (context, snap) {
        final position = snap.data ?? audio.bookPosition;
        final t = audio.bookTimeline;
        final chapters = audio.bookChapters;
        final idx = t.chapterAt(position.inMilliseconds);
        final chapterStart = t.chapterStart(idx);
        final chapterEnd = t.chapterEnd(idx);
        final chapterTitle = chapters.isEmpty ? book.title : chapters[idx].title;
        final inChapter = position.inMilliseconds - chapterStart;
        final chapterLen = chapterEnd - chapterStart;
        final percent = t.totalMs > 0 ? position.inMilliseconds / t.totalMs : 0.0;
        final left = t.totalMs - position.inMilliseconds;

        return Column(children: [
          Row(children: [
            IconButton(
              tooltip: 'Свернуть',
              icon: BcIcon(BcIcons.chevronDown, size: 26, color: c.text),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Expanded(child: Text('Аудиокнига', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.muted))),
            IconButton(
              tooltip: 'Закрыть плеер',
              icon: BcIcon(BcIcons.close, size: 22, color: c.text),
              onPressed: () async {
                // Навигатор — заранее: после остановки этот экран перестраивается.
                final nav = Navigator.of(context);
                nav.pop();
                await audio.close();
              },
            ),
          ]),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(28, 4, 28, 12), children: [
              Center(child: BookCover(book: book, size: MediaQuery.sizeOf(context).height < 700 ? 170 : 220)),
              const SizedBox(height: 20),
              Text(
                chapters.isEmpty ? ' ' : 'Глава ${idx + 1} из ${chapters.length}',
                style: TextStyle(fontSize: 13, color: c.muted),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 28,
                child: Marquee(
                  text: chapterTitle,
                  running: now.playing,
                  style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 20, color: c.text),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                [book.title, ?book.author].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.ink),
              ),
              const SizedBox(height: 14),
              _ChapterSlider(
                audio: audio,
                start: chapterStart,
                length: chapterLen,
                position: inChapter,
              ),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: ThinProgress(value: percent, height: 2)),
                const SizedBox(width: 10),
                Text(
                  'книга ${(percent * 100).floor()} % · осталось ${formatDuration(left) == '' ? '0 мин' : formatDuration(left)}',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ]),
              const SizedBox(height: 14),
              _Controls(audio: audio, now: now),
              if (showNext && chapters.length > 1) ...[
                const SizedBox(height: 16),
                _ChaptersCard(audio: audio, current: idx),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(children: [
              Expanded(child: _SpeedAction(audio: audio, book: book)),
              Expanded(child: _SleepAction(audio: audio)),
              Expanded(
                child: _BottomAction(
                  icon: BcIcons.bookmarkAdd,
                  label: 'Закладка',
                  onTap: () => _addBookmark(context, audio, book),
                ),
              ),
              if (showNext)
                Expanded(
                  child: _BottomAction(
                    icon: BcIcons.chapters,
                    label: 'Главы',
                    onTap: () => _showChapters(context, audio, book),
                  ),
                ),
            ]),
          ),
        ]);
      },
    );
  }
}

Future<void> _addBookmark(BuildContext context, PodcastAudioHandler audio, Book book) async {
  final db = AppScope.of(context).db;
  final bookSync = AppScope.of(context).bookSync;
  final chapters = audio.bookChapters;
  final g = audio.bookPosition.inMilliseconds;
  final idx = audio.bookTimeline.chapterAt(g);
  final into = Duration(milliseconds: g - audio.bookTimeline.chapterStart(idx));
  final label = chapters.isEmpty ? formatClock(Duration(milliseconds: g)) : '${chapters[idx].title}, ${formatClock(into)}';
  await db.addBookmark(book.id, locator: audio.bookLocator.encode(), positionMs: g, label: label);
  bookSync?.highlightsChanged();
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Закладка: $label')));
  }
}

void _showChapters(BuildContext context, PodcastAudioHandler audio, Book book) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => _ChaptersPanel(audio: audio, book: book, controller: controller, closeOnTap: true),
    ),
  );
}

class _ChapterSlider extends StatefulWidget {
  const _ChapterSlider({required this.audio, required this.start, required this.length, required this.position});

  final PodcastAudioHandler audio;
  final int start;
  final int length;
  final int position;

  @override
  State<_ChapterSlider> createState() => _ChapterSliderState();
}

class _ChapterSliderState extends State<_ChapterSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final max = widget.length <= 0 ? 1.0 : widget.length.toDouble();
    final value = (_drag ?? widget.position.toDouble()).clamp(0.0, max);
    final small = TextStyle(fontSize: 12, color: c.muted, fontFeatures: const [FontFeature.tabularFigures()]);
    return Column(children: [
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 4,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
        ),
        child: Slider(
          value: value,
          max: max,
          onChanged: (v) => setState(() => _drag = v),
          onChangeEnd: (v) {
            setState(() => _drag = null);
            widget.audio.seekBook(Duration(milliseconds: widget.start + v.round()));
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(formatClock(Duration(milliseconds: value.round())), style: small),
          Text('−${formatClock(Duration(milliseconds: (max - value).round()))}', style: small),
        ]),
      ),
    ]);
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.audio, required this.now});

  final PodcastAudioHandler audio;
  final NowPlaying now;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      RoundIconButton(icon: Icons.skip_previous_rounded, iconSize: 30, size: 48, tooltip: 'Предыдущая глава', onPressed: audio.previousChapter),
      const SizedBox(width: 6),
      RoundIconButton(
        icon: SkipStepIcon(audio: audio, forward: false, size: 34),
        size: 56,
        tooltip: 'Назад',
        onPressed: audio.rewind,
      ),
      const SizedBox(width: 10),
      if (now.loading)
        SizedBox.square(
          dimension: 80,
          child: Padding(padding: const EdgeInsets.all(24), child: CircularProgressIndicator(strokeWidth: 2.5, color: c.bar)),
        )
      else
        RoundIconButton(
          icon: now.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: now.playing ? 'Пауза' : 'Слушать',
          style: RoundStyle.accent,
          size: 80,
          iconSize: 40,
          onPressed: now.playing ? audio.pause : () => resumeAudioBook(context),
        ),
      const SizedBox(width: 10),
      RoundIconButton(
        icon: SkipStepIcon(audio: audio, forward: true, size: 34),
        size: 56,
        tooltip: 'Вперёд',
        onPressed: audio.fastForward,
      ),
      const SizedBox(width: 6),
      RoundIconButton(icon: Icons.skip_next_rounded, iconSize: 30, size: 48, tooltip: 'Следующая глава', onPressed: audio.nextChapter),
    ]);
  }
}

/// Главы прямо в плеере: текущая и несколько следующих, по нажатию
/// раскрывается весь список (как главы эпизода в плеере подкастов).
class _ChaptersCard extends StatefulWidget {
  const _ChaptersCard({required this.audio, required this.current});

  final PodcastAudioHandler audio;
  final int current;

  @override
  State<_ChaptersCard> createState() => _ChaptersCardState();
}

class _ChaptersCardState extends State<_ChaptersCard> {
  var _all = false;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final chapters = widget.audio.bookChapters;
    final t = widget.audio.bookTimeline;
    final cur = widget.current;
    // Свёрнуто: всегда семь строк (предыдущая, текущая и следующие; у конца
    // книги — последние семь), чтобы высота не менялась и плеер не прыгал.
    const window = 7;
    final int from = _all ? 0 : (cur - 1).clamp(0, math.max<int>(0, chapters.length - window));
    final int to = _all ? chapters.length : math.min<int>(chapters.length, from + window);
    final tabular = const [FontFeature.tabularFigures()];
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
          child: Text('Главы · ${chapters.length}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
        ),
        for (var i = from; i < to; i++)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => widget.audio.seekToChapter(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: i == cur ? c.raised : null,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                SizedBox(
                  width: 30,
                  child: i == cur
                      ? Icon(Icons.graphic_eq_rounded, size: 18, color: c.ink)
                      : Text('${i + 1}', style: TextStyle(fontSize: 13, color: c.muted, fontFeatures: tabular)),
                ),
                Expanded(
                  child: Text(
                    chapters[i].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: i == cur ? FontWeight.w600 : FontWeight.w400,
                      color: i < cur ? c.muted : c.text,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(chapterLength(t.chapterEnd(i) - t.chapterStart(i)),
                    style: TextStyle(fontSize: 13, color: c.muted, fontFeatures: tabular)),
              ]),
            ),
          ),
        if (chapters.length > to - from || _all)
          TextButton(
            onPressed: () => setState(() => _all = !_all),
            child: Text(_all ? 'Свернуть' : 'Все главы'),
          ),
      ]),
    );
  }
}

/// Главы и закладки (боковая панель на компьютере, лист на телефоне).
class _ChaptersPanel extends StatefulWidget {
  const _ChaptersPanel({required this.audio, required this.book, this.controller, this.closeOnTap = false});

  final PodcastAudioHandler audio;
  final Book book;
  final ScrollController? controller;
  final bool closeOnTap;

  @override
  State<_ChaptersPanel> createState() => _ChaptersPanelState();
}

class _ChaptersPanelState extends State<_ChaptersPanel> {
  var _bookmarks = false;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final audio = widget.audio;
    final db = AppScope.of(context).db;
    void done() {
      if (widget.closeOnTap) Navigator.of(context).maybePop();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        child: Row(children: [
          _Tab(label: 'Главы', selected: !_bookmarks, onTap: () => setState(() => _bookmarks = false)),
          const SizedBox(width: 22),
          _Tab(label: 'Закладки', selected: _bookmarks, onTap: () => setState(() => _bookmarks = true)),
        ]),
      ),
      Divider(height: 1, color: c.divider),
      Expanded(
        child: _bookmarks
            ? SingleChildScrollView(
                controller: widget.controller,
                child: BookmarksList(
                  db: db,
                  bookId: widget.book.id,
                  onOpen: (b) {
                    final l = AudioLocator.parse(b.locator);
                    if (l != null) audio.seekBook(Duration(milliseconds: audio.bookTimeline.globalOf(l.track, l.ms)));
                    done();
                  },
                ),
              )
            : StreamBuilder<Duration>(
                stream: audio.bookPositionStream,
                builder: (context, snap) {
                  final g = (snap.data ?? audio.bookPosition).inMilliseconds;
                  final t = audio.bookTimeline;
                  final current = t.chapterAt(g);
                  final chapters = audio.bookChapters;
                  return ListView.builder(
                    controller: widget.controller,
                    itemCount: chapters.length,
                    itemBuilder: (context, i) {
                      final len = t.chapterEnd(i) - t.chapterStart(i);
                      return ChapterTile(
                        number: i + 1,
                        title: chapters[i].title,
                        trailing: chapterLength(len),
                        current: i == current,
                        done: i < current,
                        progress: len > 0 ? (g - t.chapterStart(i)) / len : null,
                        onTap: () {
                          audio.seekToChapter(i);
                          done();
                        },
                      );
                    },
                  );
                },
              ),
      ),
    ]);
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: selected ? c.bar : Colors.transparent, width: 2))),
        child: Text(label,
            style: TextStyle(fontSize: 15, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: selected ? c.text : c.muted)),
      ),
    );
  }
}

class _BottomAction extends StatelessWidget {
  const _BottomAction({required this.icon, required this.label, required this.onTap, this.value});

  final BcIcons icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        height: 58,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (value != null)
            SizedBox(
              height: 22,
              child: Center(
                child: Text(value!,
                    maxLines: 1,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.ink)),
              ),
            )
          else
            BcIcon(icon, size: 22, color: c.text),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.text)),
        ]),
      ),
    );
  }
}

class _SpeedAction extends StatelessWidget {
  const _SpeedAction({required this.audio, required this.book});

  final PodcastAudioHandler audio;
  final Book book;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return StreamBuilder<PlaybackState>(
      stream: audio.playbackState,
      builder: (context, _) => BcMenu<double>(
        tooltip: 'Скорость этой книги',
        borderRadius: BorderRadius.circular(12),
        selected: audio.speed,
        onSelected: audio.setSpeed,
        options: [for (final s in playbackSpeeds) MenuOption(s, formatSpeed(s))],
        child: SizedBox(
          height: 58,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(formatSpeed(audio.speed),
                style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 16, color: c.ink)),
            const SizedBox(height: 4),
            Text('Скорость', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.text)),
          ]),
        ),
      ),
    );
  }
}

class _SleepAction extends StatefulWidget {
  const _SleepAction({required this.audio});

  final PodcastAudioHandler audio;

  @override
  State<_SleepAction> createState() => _SleepActionState();
}

class _SleepActionState extends State<_SleepAction> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final audio = widget.audio;
    return ValueListenableBuilder<bool>(
      valueListenable: audio.sleepAtChapterEnd,
      builder: (context, chapterEnd, _) => ValueListenableBuilder<SleepTimer?>(
        valueListenable: audio.sleepTimer,
        builder: (context, timer, _) {
          final value = chapterEnd
              ? 'до конца главы'
              : timer == null
                  ? null
                  : '${(timer.remaining(DateTime.now()).inSeconds / 60).ceil()} мин';
          return BcMenu<int>(
            tooltip: 'Таймер сна',
            borderRadius: BorderRadius.circular(12),
            selected: chapterEnd ? -1 : (timer == null ? 0 : null),
            onSelected: (v) {
              if (v == -1) {
                audio.setSleepAtChapterEnd(true);
              } else {
                audio.setSleepTimer(v == 0 ? null : Duration(minutes: v));
              }
            },
            options: const [
              MenuOption(0, 'Выключен'),
              MenuOption(-1, 'До конца главы'),
              MenuOption(15, '15 минут'),
              MenuOption(30, '30 минут'),
              MenuOption(45, '45 минут'),
              MenuOption(60, '1 час'),
            ],
            child: IgnorePointer(child: _BottomAction(icon: BcIcons.timer, label: 'Таймер', value: value, onTap: () {})),
          );
        },
      ),
    );
  }
}
