import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../data/db/database.dart';
import '../player/playback_logic.dart';
import '../player/podcast_audio_handler.dart';
import 'app_scope.dart';
import 'chapters.dart';
import 'description.dart';
import 'description_view.dart';
import 'format.dart';
import 'icons.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';
import 'shell.dart';
import 'theme.dart';

/// Цвета стекла большого плеера для светлой и тёмной темы.
class _Frost {
  _Frost(BuildContext context) : dark = Theme.of(context).brightness == Brightness.dark;

  final bool dark;

  Color get frost => dark ? const Color(0x99141414) : const Color(0xA8F6F6F2);
  Color get tint => dark ? const Color(0x0FFFFFFF) : const Color(0x0A000000);
  Color get track => dark ? const Color(0x2EFFFFFF) : const Color(0x1F000000);
  Color get grabber => dark ? const Color(0x4DFFFFFF) : const Color(0x33000000);
}

/// Большой плеер. Выезжает снизу поверх приложения на матовом стекле;
/// на телефоне закрывается смахиванием вниз.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  static Route<void> route() => PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 340),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => const PlayerScreen(),
        transitionsBuilder: (_, animation, _, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic),
          ),
          child: child,
        ),
      );

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with SingleTickerProviderStateMixin {
  /// Сдвиг вниз, пока пользователь тянет плеер.
  double _drag = 0;
  double _dragFrom = 0;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
    ..addListener(() => setState(() => _drag = _dragFrom * (1 - Curves.easeOut.transform(_back.value))));

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _onDragEnd(DragEndDetails d) => _release(d.primaryVelocity ?? 0);

  /// Потянуть плеер вниз на [dy] (из жеста или прокрутки содержимого).
  void _pull(double dy) => setState(() => _drag = math.max(0, _drag + dy));

  /// Отпустили: далеко или быстро — закрыть, иначе вернуть на место.
  void _release(double velocity) {
    final height = MediaQuery.sizeOf(context).height;
    if (_drag > height * 0.18 || velocity > 700) {
      Navigator.of(context).pop();
    } else {
      _dragFrom = _drag;
      _back.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _Frost(context);
    final size = MediaQuery.sizeOf(context);
    // Телефон набок — тоже раскладка в две колонки, только компактная.
    final landscape = size.width > size.height && size.height < 600;
    final wide = size.width >= wideLayoutWidth || landscape;
    final compact = size.height < 560;
    return Material(
      type: MaterialType.transparency,
      child: Transform.translate(
        offset: Offset(0, _drag),
        child: Stack(children: [
          Positioned.fill(
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                child: ColoredBox(color: f.frost),
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragUpdate: (d) => _pull(d.delta.dy),
            onVerticalDragEnd: _onDragEnd,
            child: SafeArea(
              child: NowPlayingBuilder(builder: (context, now, audio) {
                final item = now.item;
                final episodeId = now.episodeId;
                if (audio == null || item == null || episodeId == null || !now.active) {
                  return Column(children: [
                    _Header(frost: f, title: 'Сейчас ничего не играет', wide: wide),
                    const Spacer(),
                  ]);
                }
                return _EpisodeLoader(
                  episodeId: episodeId,
                  builder: (context, episode, podcast) => wide
                      ? _WideLayout(
                          frost: f,
                          now: now,
                          audio: audio,
                          item: item,
                          episode: episode,
                          podcast: podcast,
                          compact: compact,
                        )
                      : _PhoneLayout(frost: f, now: now, audio: audio, item: item, episode: episode, podcast: podcast),
                );
              }),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Эпизод и подкаст из базы для текущего эпизода плеера.
class _EpisodeLoader extends StatefulWidget {
  const _EpisodeLoader({required this.episodeId, required this.builder});

  final int episodeId;
  final Widget Function(BuildContext context, Episode? episode, Podcast? podcast) builder;

  @override
  State<_EpisodeLoader> createState() => _EpisodeLoaderState();
}

class _EpisodeLoaderState extends State<_EpisodeLoader> {
  Future<(Episode?, Podcast?)>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  @override
  void didUpdateWidget(_EpisodeLoader old) {
    super.didUpdateWidget(old);
    if (old.episodeId != widget.episodeId) _future = _load();
  }

  Future<(Episode?, Podcast?)> _load() async {
    final db = AppScope.of(context).db;
    final e = await db.episodeById(widget.episodeId);
    final p = e == null ? null : await db.podcastById(e.podcastId);
    return (e, p);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(Episode?, Podcast?)>(
        future: _future,
        builder: (context, s) => widget.builder(context, s.data?.$1, s.data?.$2),
      );
}

void _openPodcast(BuildContext context, int podcastId) {
  Navigator.of(context).pop();
  AppShell.openPodcast(context, podcastId);
}

void _openQueue(BuildContext context) {
  Navigator.of(context).pop();
  AppShell.openQueue(context);
}

class _Header extends StatelessWidget {
  const _Header({required this.frost, required this.title, required this.wide, this.trailing});

  final _Frost frost;
  final String title;
  final bool wide;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Column(children: [
      Container(
        width: wide ? 48 : 40,
        height: 5,
        margin: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(color: frost.grabber, borderRadius: BorderRadius.circular(3)),
      ),
      Padding(
        padding: wide ? const EdgeInsets.fromLTRB(48, 8, 48, 16) : const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: Row(children: [
          RoundIconButton(
            icon: BcIcons.chevronDown,
            tooltip: 'Свернуть',
            iconSize: 26,
            color: c.text,
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: c.muted)),
          ),
          trailing ?? const SizedBox(width: 44),
        ]),
      ),
    ]);
  }
}

/// Ссылка на страницу подкаста: «Наука вслух ›».
class _PodcastLink extends StatelessWidget {
  const _PodcastLink({required this.podcast, required this.fallback, this.suffix, this.size = 15});

  final Podcast? podcast;
  final String? fallback;
  final String? suffix;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final name = podcast?.title ?? fallback ?? '';
    if (name.isEmpty) return const SizedBox.shrink();
    final p = podcast;
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: p == null ? null : () => _openPodcast(context, p.id),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: size, fontWeight: FontWeight.w500, color: c.ink)),
            ),
            BcIcon(BcIcons.chevronRight, size: size + 2, color: c.ink),
            if (suffix != null) Text(' · $suffix', style: TextStyle(fontSize: size, color: c.muted)),
          ]),
        ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.audio, required this.duration, required this.frost});

  final PodcastAudioHandler audio;
  final Duration? duration;
  final _Frost frost;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final maxMs = (widget.duration?.inMilliseconds ?? 0).toDouble();
    return StreamBuilder<Duration>(
      stream: widget.audio.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? widget.audio.position;
        final shownMs = _dragging ?? position.inMilliseconds.toDouble();
        final shown = Duration(milliseconds: shownMs.round());
        final left = widget.duration == null ? null : widget.duration! - shown;
        final times = TextStyle(fontSize: 12, color: c.muted, fontFeatures: const [FontFeature.tabularFigures()]);
        return Column(children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              inactiveTrackColor: widget.frost.track,
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            ),
            child: SizedBox(
              height: 28,
              child: Slider(
                value: maxMs <= 0 ? 0.0 : shownMs.clamp(0.0, maxMs),
                max: maxMs <= 0 ? 1 : maxMs,
                onChanged: maxMs <= 0 ? null : (v) => setState(() => _dragging = v),
                onChangeEnd: maxMs <= 0
                    ? null
                    : (v) {
                        setState(() => _dragging = null);
                        widget.audio.seek(Duration(milliseconds: v.round()));
                      },
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(formatClock(shown), style: times),
            if (left != null) Text('−${formatClock(left)}', style: times),
          ]),
        ]);
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.audio, required this.now, this.compact = false});

  final PodcastAudioHandler audio;
  final NowPlaying now;

  /// Поменьше — для телефона, повёрнутого набок.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    Widget skip(bool forward, String tooltip, VoidCallback onPressed) => IconButton(
          tooltip: tooltip,
          constraints: BoxConstraints.tightFor(width: compact ? 48 : 56, height: compact ? 48 : 56),
          icon: SkipIcon(forward: forward, seconds: forward ? 30 : 10, color: c.text, size: compact ? 28 : 34),
          onPressed: onPressed,
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      skip(false, 'Назад на 10 секунд', audio.rewind),
      SizedBox(width: compact ? 18 : 28),
      SizedBox.square(
        dimension: compact ? 60 : 80,
        child: Material(
          color: c.fill,
          shape: const CircleBorder(),
          child: now.loading
              ? Padding(
                  padding: EdgeInsets.all(compact ? 18 : 26),
                  child: CircularProgressIndicator(color: c.onFill, strokeWidth: 3),
                )
              : InkWell(
                  customBorder: const CircleBorder(),
                  onTap: now.playing ? audio.pause : audio.play,
                  child: Tooltip(
                    message: now.playing ? 'Пауза' : 'Продолжить',
                    child: Icon(now.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: compact ? 32 : 40, color: c.onFill),
                  ),
                ),
        ),
      ),
      SizedBox(width: compact ? 18 : 28),
      skip(true, 'Вперёд на 30 секунд', audio.fastForward),
    ]);
  }
}

/// Скорость: меню со значениями.
class _SpeedMenu extends StatelessWidget {
  const _SpeedMenu({required this.audio, required this.builder});

  final PodcastAudioHandler audio;
  final Widget Function(String speed) builder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: audio.playbackState,
      builder: (context, _) => PopupMenuButton<double>(
        tooltip: 'Скорость',
        initialValue: audio.speed,
        onSelected: audio.setSpeed,
        itemBuilder: (_) => [for (final s in playbackSpeeds) PopupMenuItem(value: s, child: Text(formatSpeed(s)))],
        child: builder(formatSpeed(audio.speed)),
      ),
    );
  }
}

enum _SleepChoice { off, min15, min30, min60 }

/// Таймер сна: меню.
class _SleepMenu extends StatelessWidget {
  const _SleepMenu({required this.audio, required this.builder});

  final PodcastAudioHandler audio;
  final Widget Function(SleepTimer? timer, String label) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SleepTimer?>(
      valueListenable: audio.sleepTimer,
      builder: (context, timer, _) => PopupMenuButton<_SleepChoice>(
        tooltip: 'Таймер сна',
        onSelected: (choice) => audio.setSleepTimer(switch (choice) {
          _SleepChoice.off => null,
          _SleepChoice.min15 => const Duration(minutes: 15),
          _SleepChoice.min30 => const Duration(minutes: 30),
          _SleepChoice.min60 => const Duration(minutes: 60),
        }),
        itemBuilder: (_) => [
          if (timer != null) const PopupMenuItem(value: _SleepChoice.off, child: Text('Выключить таймер')),
          const PopupMenuItem(value: _SleepChoice.min15, child: Text('Через 15 минут')),
          const PopupMenuItem(value: _SleepChoice.min30, child: Text('Через 30 минут')),
          const PopupMenuItem(value: _SleepChoice.min60, child: Text('Через час')),
        ],
        child: builder(timer, _sleepLabel(timer)),
      ),
    );
  }

  static String _sleepLabel(SleepTimer? timer) {
    if (timer == null) return 'Таймер';
    final minutes = (timer.remaining(DateTime.now()).inSeconds / 60).ceil();
    return 'Ещё $minutes мин';
  }
}

/// Главы эпизода (загружаются один раз).
class _ChaptersBuilder extends StatefulWidget {
  const _ChaptersBuilder({required this.episode, required this.builder});

  final Episode? episode;
  final Widget Function(BuildContext context, List<Chapter> chapters) builder;

  @override
  State<_ChaptersBuilder> createState() => _ChaptersBuilderState();
}

class _ChaptersBuilderState extends State<_ChaptersBuilder> {
  Future<List<Chapter>>? _future;

  void _load() {
    final e = widget.episode;
    _future = e == null ? null : ChaptersLoader.instance.load(e);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ChaptersBuilder old) {
    super.didUpdateWidget(old);
    if (old.episode?.id != widget.episode?.id) _load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Chapter>>(
        future: _future,
        builder: (context, s) => widget.builder(context, s.data ?? const []),
      );
}

void _showChapters(BuildContext context, int episodeId, List<Chapter> chapters) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text('Главы', style: sectionTitleStyle(context)),
          const SizedBox(height: 8),
          ChaptersList(episodeId: episodeId, chapters: chapters, dividers: true),
        ],
      ),
    ),
  );
}

/// Блок «Об эпизоде» целиком: текст с таймкодами и главы.
/// Прокручивается вместе со всем плеером.
class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.frost, required this.episode, this.chapters = const []});

  final _Frost frost;
  final Episode? episode;
  final List<Chapter> chapters;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final e = episode;
    final parts = e == null ? const <DescPart>[] : parseDescription(e.description ?? e.summary);
    final label = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted);
    return Container(
      decoration: BoxDecoration(
        color: frost.tint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: frost.tint),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Об эпизоде', style: label),
        const SizedBox(height: 8),
        if (parts.isEmpty || e == null)
          Text('Описания нет.', style: TextStyle(fontSize: 14, color: c.muted))
        else
          DescriptionText(episodeId: e.id, parts: parts),
        if (chapters.isNotEmpty && e != null) ...[
          const SizedBox(height: 18),
          Text('Главы', style: label),
          const SizedBox(height: 4),
          ChaptersList(episodeId: e.id, chapters: chapters, dividers: true),
        ],
      ]),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url, required this.size, required this.radius});

  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 40, offset: Offset(0, 18))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: PodcastCover(url: url, size: size),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Телефон
// ---------------------------------------------------------------------------

class _PhoneLayout extends StatefulWidget {
  const _PhoneLayout({
    required this.frost,
    required this.now,
    required this.audio,
    required this.item,
    required this.episode,
    required this.podcast,
  });

  final _Frost frost;
  final NowPlaying now;
  final PodcastAudioHandler audio;
  final MediaItem item;
  final Episode? episode;
  final Podcast? podcast;

  @override
  State<_PhoneLayout> createState() => _PhoneLayoutState();
}

class _PhoneLayoutState extends State<_PhoneLayout> {
  final _scroll = ScrollController();
  final _coverKey = GlobalKey();

  /// Высота перемотки и кнопок.
  static const _controlsHeight = 144.0;

  /// Высота обложки с названием — после первой раскладки берётся настоящая.
  double _coverHeight = 330;

  void _measureCover() {
    final h = _coverKey.currentContext?.size?.height;
    if (h != null && (h - _coverHeight).abs() > 0.5 && mounted) setState(() => _coverHeight = h);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Жест вниз в самом верху списка тянет плеер вниз — так он закрывается
  /// смахиванием, хотя всё содержимое прокручивается.
  bool _onScroll(ScrollNotification n) {
    final player = context.findAncestorStateOfType<_PlayerScreenState>();
    if (player == null) return false;
    if (n is OverscrollNotification && n.overscroll < 0 && n.dragDetails != null) {
      player._pull(-n.overscroll);
    } else if (n is ScrollUpdateNotification && player._drag > 0 && (n.scrollDelta ?? 0) > 0) {
      // Потянули обратно вверх: сначала возвращаем плеер, потом листаем.
      player._pull(-(n.scrollDelta ?? 0));
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else if (n is ScrollEndNotification && player._drag > 0) {
      player._release(n.dragDetails?.primaryVelocity ?? 0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureCover());
    final c = BcColors.of(context);
    final frost = widget.frost;
    final now = widget.now;
    final audio = widget.audio;
    final item = widget.item;
    final p = widget.podcast;
    final e = widget.episode;
    return LayoutBuilder(builder: (context, box) {
      final cover = math.min(232.0, math.min(box.maxWidth - 64, box.maxHeight * 0.3));
      return _ChaptersBuilder(
        episode: e,
        builder: (context, chapters) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Header(
            frost: frost,
            title: 'Сейчас играет',
            wide: false,
            trailing: PopupMenuButton<String>(
              tooltip: 'Ещё',
              icon: Icon(Icons.more_horiz_rounded, color: c.text),
              onSelected: (v) {
                if (v == 'podcast' && p != null) _openPodcast(context, p.id);
                if (v == 'stop') {
                  Navigator.of(context).pop();
                  audio.close();
                }
              },
              itemBuilder: (_) => [
                if (p != null) const PopupMenuItem(value: 'podcast', child: Text('Страница подкаста')),
                const PopupMenuItem(value: 'stop', child: Text('Остановить и закрыть плеер')),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: LayoutBuilder(builder: (context, area) {
                // Кнопки лежат поверх списка. Под ними список скрыт маской:
                // описание исчезает у нижнего края кнопок, а не просвечивает
                // сквозь них.
                final list = CustomScrollView(
                  controller: _scroll,
                  physics: const ClampingScrollPhysics(),
                  slivers: [
                    // Обложка и название уезжают вверх при прокрутке.
                    SliverToBoxAdapter(
                      child: KeyedSubtree(
                        key: _coverKey,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Center(child: _Cover(url: item.artUri?.toString(), size: cover, radius: 22)),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(32, 20, 32, 0),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 20, height: 1.25)),
                              const SizedBox(height: 4),
                              _PodcastLink(podcast: p, fallback: item.album),
                            ]),
                          ),
                        ]),
                      ),
                    ),
                    // Место под кнопки: сами кнопки — поверх, см. ниже.
                    const SliverToBoxAdapter(child: SizedBox(height: _controlsHeight)),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      sliver: SliverToBoxAdapter(
                        child: _AboutCard(frost: frost, episode: e, chapters: chapters),
                      ),
                    ),
                  ],
                );
                return AnimatedBuilder(
                  animation: _scroll,
                  child: list,
                  builder: (context, list) {
                    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                    final top = math.max(0.0, _coverHeight - offset);
                    final h = math.max(1.0, area.maxHeight);
                    double at(double y) => (y / h).clamp(0.0, 1.0);
                    return Stack(children: [
                      Positioned.fill(
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (rect) => LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: const [
                              Colors.black,
                              Colors.black,
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black,
                              Colors.black,
                            ],
                            stops: [
                              0,
                              at(top),
                              at(top),
                              at(top + _controlsHeight - 4),
                              at(top + _controlsHeight + 20),
                              1,
                            ],
                          ).createShader(rect),
                          child: list,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: top,
                        height: _controlsHeight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 32),
                              child: _SeekBar(audio: audio, duration: item.duration, frost: frost),
                            ),
                            const SizedBox(height: 4),
                            _Controls(audio: audio, now: now),
                          ]),
                        ),
                      ),
                    ]);
                  },
                );
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(children: [
              Expanded(
                child: _SpeedMenu(
                  audio: audio,
                  builder: (speed) => _BottomAction(
                    label: 'Скорость',
                    top: Text(speed,
                        style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 16, color: c.ink)),
                  ),
                ),
              ),
              Expanded(
                child: _SleepMenu(
                  audio: audio,
                  builder: (timer, label) => _BottomAction(
                    label: label,
                    top: BcIcon(BcIcons.timer, size: 22, color: timer == null ? c.text : c.ink),
                  ),
                ),
              ),
              Expanded(
                child: _BottomAction(
                  label: 'Главы',
                  dimmed: chapters.isEmpty,
                  top: BcIcon(BcIcons.chapters, size: 22, color: chapters.isEmpty ? c.muted : c.text),
                  tooltip: chapters.isEmpty ? 'У эпизода нет глав' : 'Главы эпизода',
                  onTap: chapters.isEmpty || e == null ? null : () => _showChapters(context, e.id, chapters),
                ),
              ),
              Expanded(
                child: _BottomAction(
                  label: 'Очередь',
                  top: BcIcon(BcIcons.queue, size: 22, color: c.text),
                  tooltip: 'Очередь воспроизведения',
                  onTap: () => _openQueue(context),
                ),
              ),
            ]),
          ),
        ]),
      );
    });
  }
}

class _BottomAction extends StatelessWidget {
  const _BottomAction({required this.label, required this.top, this.onTap, this.tooltip, this.dimmed = false});

  final String label;
  final Widget top;
  final VoidCallback? onTap;

  /// Без подсказки кнопка — содержимое меню, нажатие обрабатывает меню.
  final String? tooltip;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final body = SizedBox(
      height: 56,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        top,
        const SizedBox(height: 4),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: dimmed ? c.muted : c.text)),
      ]),
    );
    if (tooltip == null) return body;
    return Tooltip(
      message: tooltip,
      child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap, child: body),
    );
  }
}

// ---------------------------------------------------------------------------
// Компьютер
// ---------------------------------------------------------------------------

class _WideLayout extends StatefulWidget {
  const _WideLayout({
    this.compact = false,
    required this.frost,
    required this.now,
    required this.audio,
    required this.item,
    required this.episode,
    required this.podcast,
  });

  final _Frost frost;
  final NowPlaying now;
  final PodcastAudioHandler audio;
  final MediaItem item;
  final Episode? episode;
  final Podcast? podcast;

  /// Телефон набок: без обложки, всё мельче, главы — под описанием справа.
  final bool compact;

  @override
  State<_WideLayout> createState() => _WideLayoutState();
}

class _WideLayoutState extends State<_WideLayout> with SingleTickerProviderStateMixin {
  bool get compact => widget.compact;

  /// 0 — обложка видна, 1 — главы развёрнуты вместо неё.
  late final AnimationController _chapters = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final Animation<double> _coverShown =
      CurvedAnimation(parent: ReverseAnimation(_chapters), curve: Curves.easeInOutCubic);

  @override
  void dispose() {
    _chapters.dispose();
    super.dispose();
  }

  void _toggleChapters() => _chapters.isForwardOrCompleted ? _chapters.reverse() : _chapters.forward();

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final frost = widget.frost;
    final now = widget.now;
    final audio = widget.audio;
    final item = widget.item;
    final podcast = widget.podcast;
    final e = widget.episode;
    final date = formatEpisodeDate(e?.pubDate);
    final pill = BoxDecoration(color: frost.tint, borderRadius: BorderRadius.circular(20));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Header(
        frost: frost,
        title: podcast == null ? 'Сейчас играет' : 'Сейчас играет · ${podcast!.title}',
        wide: !compact,
        trailing: Material(
          color: frost.tint,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => _openQueue(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                BcIcon(BcIcons.queue, size: 20, color: c.text),
                const SizedBox(width: 8),
                const Text('Очередь', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        ),
      ),
      Expanded(
        child: Padding(
          padding: compact ? const EdgeInsets.fromLTRB(24, 0, 24, 8) : const EdgeInsets.fromLTRB(48, 0, 48, 24),
          child: LayoutBuilder(builder: (context, box) {
            final leftWidth =
                compact ? (box.maxWidth * 0.45).clamp(280.0, 400.0) : (box.maxWidth * 0.36).clamp(340.0, 440.0);
            // Обложка — сколько позволяет высота окна: плеер под ней
            // должен помещаться целиком.
            final cover = math.min(leftWidth, box.maxHeight - 460);
            final speed = _SpeedMenu(
              audio: audio,
              builder: (speed) => Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: pill,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(speed,
                      style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 15, color: c.ink)),
                ]),
              ),
            );
            final timer = _SleepMenu(
              audio: audio,
              builder: (timer, label) => Container(
                height: 40,
                constraints: const BoxConstraints(minWidth: 40),
                padding: EdgeInsets.symmetric(horizontal: timer == null ? 10 : 14),
                decoration: pill,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  BcIcon(BcIcons.timer, size: 20, color: timer == null ? c.text : c.ink),
                  if (timer != null) ...[
                    const SizedBox(width: 6),
                    Text(label, style: const TextStyle(fontSize: 13)),
                  ],
                ]),
              ),
            );

            // Слева — всегда на экране: обложка, название, плеер, главы.
            final left = _ChaptersBuilder(
              episode: e,
              builder: (context, chapters) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (cover >= 120)
                  SizeTransition(
                    sizeFactor: _coverShown,
                    axisAlignment: 1,
                    child: FadeTransition(
                      opacity: _coverShown,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Center(child: _Cover(url: item.artUri?.toString(), size: cover, radius: 28)),
                      ),
                    ),
                  ),
                Text(item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 24, height: 1.2)),
                const SizedBox(height: 6),
                _PodcastLink(podcast: podcast, fallback: item.album, suffix: date.isEmpty ? null : date, size: 15),
                const SizedBox(height: 16),
                _SeekBar(audio: audio, duration: item.duration, frost: frost),
                const SizedBox(height: 10),
                Center(child: _Controls(audio: audio, now: now)),
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  speed,
                  const SizedBox(width: 8),
                  timer,
                  const SizedBox(width: 8),
                  _Volume(audio: audio, frost: frost),
                ]),
                if (chapters.isNotEmpty && e != null) ...[
                  const SizedBox(height: 18),
                  Material(
                    color: frost.tint,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _toggleChapters,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                        child: Row(children: [
                          BcIcon(BcIcons.chapters, size: 20, color: c.text),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text('Главы · ${chapters.length}',
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                          RotationTransition(
                            turns: Tween(begin: 0.0, end: 0.5).animate(_chapters),
                            child: BcIcon(BcIcons.chevronDown, size: 18, color: c.muted),
                          ),
                        ]),
                      ),
                    ),
                  ),
                  // Развёрнутые главы занимают место обложки.
                  Expanded(
                    child: FadeTransition(
                      opacity: _chapters,
                      child: AnimatedBuilder(
                        animation: _chapters,
                        builder: (context, child) =>
                            _chapters.value == 0 ? const SizedBox.shrink() : child!,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                          child: ChaptersList(episodeId: e.id, chapters: chapters, dividers: true),
                        ),
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
              ]),
            );

            if (compact) {
              // Набок: слева плеер (листается, если не влез), справа описание с главами.
              return _ChaptersBuilder(
                episode: e,
                builder: (context, chapters) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(
                    width: leftWidth,
                    child: SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text(item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 18, height: 1.2)),
                        const SizedBox(height: 2),
                        _PodcastLink(podcast: podcast, fallback: item.album, size: 14),
                        const SizedBox(height: 6),
                        _SeekBar(audio: audio, duration: item.duration, frost: frost),
                        const SizedBox(height: 4),
                        Center(child: _Controls(audio: audio, now: now, compact: true)),
                        const SizedBox(height: 8),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          speed,
                          const SizedBox(width: 8),
                          timer,
                        ]),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: SingleChildScrollView(
                      child: _AboutCard(frost: frost, episode: e, chapters: chapters),
                    ),
                  ),
                ]),
              );
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: leftWidth, child: left),
              const SizedBox(width: 48),
              // Справа — только описание, оно листается само по себе.
              Expanded(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: SingleChildScrollView(
                      child: _AboutCard(frost: frost, episode: e),
                    ),
                  ),
                ),
              ),
            ]);
          }),
        ),
      ),
    ]);
  }
}

class _Volume extends StatelessWidget {
  const _Volume({required this.audio, required this.frost});

  final PodcastAudioHandler audio;
  final _Frost frost;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return StreamBuilder<double>(
      stream: audio.volumeStream,
      builder: (context, s) {
        final v = s.data ?? audio.volume;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: v == 0 ? 'Включить звук' : 'Выключить звук',
            icon: BcIcon(v == 0 ? BcIcons.volumeOff : BcIcons.volume, size: 20, color: c.text),
            onPressed: () => audio.setVolume(v == 0 ? 1 : 0),
          ),
          SizedBox(
            width: 110,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: c.text,
                thumbColor: c.text,
                inactiveTrackColor: frost.track,
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: v.clamp(0.0, 1.0),
                onChanged: audio.setVolume,
                semanticFormatterCallback: (x) => 'Громкость ${(x * 100).round()}%',
              ),
            ),
          ),
        ]);
      },
    );
  }
}
