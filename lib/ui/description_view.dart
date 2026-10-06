import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../platform/open_url.dart';
import '../player/playback_logic.dart';
import 'app_scope.dart';
import 'description.dart';
import 'now_playing.dart';
import 'theme.dart';

/// Описание эпизода с нажимаемыми ссылками и таймкодами: таймкод запускает
/// эпизод [episodeId] с этого места (или перематывает, если он уже играет).
class DescriptionText extends StatefulWidget {
  const DescriptionText({super.key, required this.episodeId, required this.parts, this.style, this.maxLines});

  final int episodeId;
  final List<DescPart> parts;
  final TextStyle? style;
  final int? maxLines;

  @override
  State<DescriptionText> createState() => _DescriptionTextState();
}

class _DescriptionTextState extends State<DescriptionText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(r);
    return r;
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final c = BcColors.of(context);
    final audio = AppScope.of(context).audio;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final active = TextStyle(color: c.ink, fontWeight: FontWeight.w500);
    return Text.rich(
      TextSpan(children: [
        for (final p in widget.parts)
          switch (p) {
            DescText() => TextSpan(text: p.text),
            DescLink(:final url) => TextSpan(
                text: p.text,
                style: active,
                recognizer: _tap(() async {
                  if (!await openUrl(url)) {
                    messenger?.showSnackBar(const SnackBar(content: Text('Не удалось открыть ссылку')));
                  }
                }),
              ),
            DescTime(:final at) => TextSpan(
                text: p.text,
                style: audio == null ? null : active,
                semanticsLabel: 'Перейти к ${formatClock(at)}',
                recognizer: audio == null ? null : _tap(() => audio.playEpisode(widget.episodeId, at: at)),
              ),
          },
      ]),
      style: widget.style ?? TextStyle(fontSize: 14, height: 1.55, color: c.body),
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.fade,
    );
  }
}

/// Список глав; текущая выделена, нажатие — переход к главе.
class ChaptersList extends StatelessWidget {
  const ChaptersList({super.key, required this.episodeId, required this.chapters, this.dividers = false});

  final int episodeId;
  final List<Chapter> chapters;
  final bool dividers;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return NowPlayingBuilder(builder: (context, now, audio) {
      final current = now.isEpisode(episodeId);
      Widget list(Duration? position) {
        final index = position == null ? -1 : currentChapter(chapters, position);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < chapters.length; i++)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: audio == null ? null : () => audio.playEpisode(episodeId, at: chapters[i].start),
              child: Container(
                constraints: const BoxConstraints(minHeight: 40),
                decoration: dividers && i > 0
                    ? BoxDecoration(border: Border(top: BorderSide(color: c.divider)))
                    : null,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 64,
                    child: Text(formatClock(chapters[i].start),
                        style: TextStyle(
                          fontSize: 14,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: i == index || dividers ? c.ink : c.muted,
                        )),
                  ),
                  Expanded(
                    child: Text(chapters[i].title,
                        style: TextStyle(fontSize: 14, fontWeight: i == index ? FontWeight.w600 : FontWeight.w400)),
                  ),
                ]),
              ),
            ),
        ]);
      }

      if (!current || audio == null) return list(null);
      return StreamBuilder<Duration>(
        stream: audio.positionStream,
        builder: (context, pos) => list(pos.data ?? audio.position),
      );
    });
  }
}
