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

  void _onDragEnd(DragEndDetails d) {
    final height = MediaQuery.sizeOf(context).height;
    final velocity = d.primaryVelocity ?? 0;
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
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutWidth;
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
            onVerticalDragUpdate: (d) => setState(() => _drag = math.max(0, _drag + d.delta.dy)),
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
                      ? _WideLayout(frost: f, now: now, audio: audio, item: item, episode: episode, podcast: podcast)
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
            icon: Icons.keyboard_arrow_down_rounded,
            tooltip: 'Свернуть',
            iconSize: 28,
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
            Icon(Icons.chevron_right_rounded, size: size + 3, color: c.ink),
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
  const _Controls({required this.audio, required this.now});

  final PodcastAudioHandler audio;
  final NowPlaying now;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    Widget skip(IconData icon, String tooltip, VoidCallback onPressed) => IconButton(
          tooltip: tooltip,
          iconSize: 36,
          color: c.text,
          constraints: const BoxConstraints.tightFor(width: 56, height: 56),
          icon: Icon(icon),
          onPressed: onPressed,
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      skip(Icons.replay_10_rounded, 'Назад на 10 секунд', audio.rewind),
      const SizedBox(width: 28),
      SizedBox.square(
        dimension: 80,
        child: Material(
          color: c.fill,
          shape: const CircleBorder(),
          child: now.loading
              ? Padding(
                  padding: const EdgeInsets.all(26),
                  child: CircularProgressIndicator(color: c.onFill, strokeWidth: 3),
                )
              : InkWell(
                  customBorder: const CircleBorder(),
                  onTap: now.playing ? audio.pause : audio.play,
                  child: Tooltip(
                    message: now.playing ? 'Пауза' : 'Продолжить',
                    child: Icon(now.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 40, color: c.onFill),
                  ),
                ),
        ),
      ),
      const SizedBox(width: 28),
      skip(Icons.forward_30_rounded, 'Вперёд на 30 секунд', audio.fastForward),
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

/// Описание эпизода на весь экран.
class _DescriptionPage extends StatelessWidget {
  const _DescriptionPage({required this.episode, required this.parts});

  final Episode episode;
  final List<DescPart> parts;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final meta = [formatEpisodeDate(episode.pubDate), formatDuration(episode.durationMs)]
        .where((t) => t.isNotEmpty)
        .join(' · ');
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(title: const Text('Об эпизоде')),
      body: _ChaptersBuilder(
        episode: episode,
        builder: (context, chapters) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            Text(episode.title, style: sectionTitleStyle(context)),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(meta, style: TextStyle(fontSize: 13, color: c.muted)),
            ],
            const SizedBox(height: 16),
            DescriptionText(episodeId: episode.id, parts: parts),
            if (chapters.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Главы', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
              const SizedBox(height: 4),
              ChaptersList(episodeId: episode.id, chapters: chapters, dividers: true),
            ],
          ],
        ),
      ),
    );
  }
}

/// Блок «Об эпизоде»: прокручиваемый текст с таймкодами.
class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.frost, required this.episode});

  final _Frost frost;
  final Episode? episode;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final e = episode;
    final parts = e == null ? const <DescPart>[] : parseDescription(e.description ?? e.summary);
    return Container(
      decoration: BoxDecoration(
        color: frost.tint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: frost.tint),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text('Об эпизоде', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
          ),
          if (e != null && parts.isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: c.ink,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => _DescriptionPage(episode: e, parts: parts),
              )),
              child: const Text('Развернуть'),
            ),
        ]),
        Flexible(
          child: ShaderMask(
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black, Colors.black, Colors.transparent],
              stops: [0, 0.82, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(right: 8, bottom: 24),
              child: parts.isEmpty || e == null
                  ? Text('Описания нет.', style: TextStyle(fontSize: 14, color: c.muted))
                  : DescriptionText(episodeId: e.id, parts: parts),
            ),
          ),
        ),
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

class _PhoneLayout extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final p = podcast;
    final e = episode;
    return LayoutBuilder(builder: (context, box) {
      final cover = math.min(232.0, math.min(box.maxWidth - 64, box.maxHeight * 0.3));
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                audio.stop();
              }
            },
            itemBuilder: (_) => [
              if (p != null) const PopupMenuItem(value: 'podcast', child: Text('Страница подкаста')),
              const PopupMenuItem(value: 'stop', child: Text('Остановить и закрыть плеер')),
            ],
          ),
        ),
        Center(child: _Cover(url: item.artUri?.toString(), size: cover, radius: 22)),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 20, 32, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 20, height: 1.25)),
            const SizedBox(height: 4),
            _PodcastLink(podcast: p, fallback: item.album),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 14, 32, 0),
          child: _SeekBar(audio: audio, duration: item.duration, frost: frost),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Center(child: _Controls(audio: audio, now: now)),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: _AboutCard(frost: frost, episode: e),
          ),
        ),
        _ChaptersBuilder(
          episode: e,
          builder: (context, chapters) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
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
                    top: Icon(timer == null ? Icons.bedtime_outlined : Icons.bedtime_rounded,
                        size: 22, color: timer == null ? c.text : c.ink),
                  ),
                ),
              ),
              Expanded(
                child: _BottomAction(
                  label: 'Главы',
                  dimmed: chapters.isEmpty,
                  top: Icon(Icons.format_list_bulleted_rounded, size: 22, color: chapters.isEmpty ? c.muted : c.text),
                  tooltip: chapters.isEmpty ? 'У эпизода нет глав' : 'Главы эпизода',
                  onTap: chapters.isEmpty || e == null ? null : () => _showChapters(context, e.id, chapters),
                ),
              ),
              Expanded(
                child: _BottomAction(
                  label: 'Очередь',
                  top: Icon(Icons.playlist_play_rounded, size: 24, color: c.text),
                  tooltip: 'Очередь воспроизведения',
                  onTap: () => _openQueue(context),
                ),
              ),
            ]),
          ),
        ),
      ]);
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

class _WideLayout extends StatelessWidget {
  const _WideLayout({
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
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final e = episode;
    final date = formatEpisodeDate(e?.pubDate);
    final pill = BoxDecoration(color: frost.tint, borderRadius: BorderRadius.circular(20));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Header(
        frost: frost,
        title: podcast == null ? 'Сейчас играет' : 'Сейчас играет · ${podcast!.title}',
        wide: true,
        trailing: Material(
          color: frost.tint,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => _openQueue(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.playlist_play_rounded, size: 20, color: c.text),
                const SizedBox(width: 8),
                const Text('Очередь', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        ),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(48, 0, 48, 40),
          child: LayoutBuilder(builder: (context, box) {
            final side = box.maxWidth >= 1000;
            final cover = side ? math.min(380.0, box.maxWidth * 0.32) : math.min(320.0, box.maxWidth);
            final info = ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(item.title,
                    style: const TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 32, height: 1.2)),
                const SizedBox(height: 8),
                _PodcastLink(podcast: podcast, fallback: item.album, suffix: date.isEmpty ? null : date, size: 16),
                const SizedBox(height: 20),
                _SeekBar(audio: audio, duration: item.duration, frost: frost),
                const SizedBox(height: 16),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _Controls(audio: audio, now: now),
                    const SizedBox(width: 12),
                    _SpeedMenu(
                      audio: audio,
                      builder: (speed) => Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.center,
                        decoration: pill,
                        child: Text(speed,
                            style: TextStyle(
                                fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 15, color: c.ink)),
                      ),
                    ),
                    _SleepMenu(
                      audio: audio,
                      builder: (timer, label) => Container(
                        height: 40,
                        padding: EdgeInsets.symmetric(horizontal: timer == null ? 10 : 14),
                        decoration: pill,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(timer == null ? Icons.bedtime_outlined : Icons.bedtime_rounded,
                              size: 20, color: timer == null ? c.text : c.ink),
                          if (timer != null) ...[
                            const SizedBox(width: 6),
                            Text(label, style: const TextStyle(fontSize: 13)),
                          ],
                        ]),
                      ),
                    ),
                    _Volume(audio: audio, frost: frost),
                  ],
                ),
                const SizedBox(height: 24),
                _ChaptersBuilder(
                  episode: e,
                  builder: (context, chapters) {
                    final about = SizedBox(height: 300, child: _AboutCard(frost: frost, episode: e));
                    if (chapters.isEmpty || e == null) return about;
                    final chapterCard = Container(
                      decoration: BoxDecoration(color: frost.tint, borderRadius: BorderRadius.circular(16)),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text('Главы', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
                        const SizedBox(height: 4),
                        ChaptersList(episodeId: e.id, chapters: chapters),
                      ]),
                    );
                    return LayoutBuilder(builder: (context, inner) {
                      if (inner.maxWidth < 600) {
                        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          about,
                          const SizedBox(height: 20),
                          chapterCard,
                        ]);
                      }
                      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: about),
                        const SizedBox(width: 20),
                        Expanded(child: chapterCard),
                      ]);
                    });
                  },
                ),
              ]),
            );
            if (!side) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(child: _Cover(url: item.artUri?.toString(), size: cover, radius: 28)),
                const SizedBox(height: 28),
                info,
              ]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Cover(url: item.artUri?.toString(), size: cover, radius: 28),
                const SizedBox(width: 48),
                Flexible(child: info),
              ],
            );
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
            icon: Icon(v == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 20, color: c.text),
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
