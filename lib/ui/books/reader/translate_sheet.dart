import 'package:flutter/material.dart';

import '../../../books/translator.dart';
import '../../app_scope.dart';
import '../../icons.dart';
import '../../menu.dart';
import '../../theme.dart';

const _languageNames = {
  'ru': 'русский',
  'en': 'английский',
  'de': 'немецкий',
  'fr': 'французский',
  'es': 'испанский',
  'it': 'итальянский',
  'uk': 'украинский',
};

String languageName(String code) => _languageNames[code] ?? code;

/// Перевод выделенного текста и значение слова из словаря.
/// [sentence] — предложение со словом: переводится тоже, для контекста.
Future<void> showTranslateSheet(
  BuildContext context, {
  required String text,
  required String sourceLanguage,
  String? sentence,
  bool dictionaryFirst = false,
}) {
  final sync = AppScope.of(context).sync;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      maxChildSize: 0.92,
      builder: (context, controller) => _TranslatePanel(
        text: text,
        from: sourceLanguage,
        sentence: sentence,
        controller: controller,
        dictionaryFirst: dictionaryFirst,
        translator: Translator(proxy: sync?.serverAuth),
      ),
    ),
  );
}

class _TranslatePanel extends StatefulWidget {
  const _TranslatePanel({
    required this.text,
    required this.from,
    required this.controller,
    required this.dictionaryFirst,
    required this.translator,
    this.sentence,
  });

  final String text;
  final String from;
  final String? sentence;
  final ScrollController controller;
  final bool dictionaryFirst;
  final Translator translator;

  @override
  State<_TranslatePanel> createState() => _TranslatePanelState();
}

class _TranslatePanelState extends State<_TranslatePanel> {
  late String _to = widget.from == 'ru' ? 'en' : 'ru';
  late Future<String> _translation;
  Future<String>? _context;
  Future<List<WordSense>>? _senses;

  bool get _isWord => !widget.text.trim().contains(RegExp(r'\s')) && widget.text.trim().length <= 40;

  @override
  void initState() {
    super.initState();
    _translate();
    if (_isWord) _senses = widget.translator.define(widget.text, lang: widget.from);
  }

  void _translate() {
    _translation = widget.translator.translate(widget.text, from: widget.from, to: _to);
    final s = widget.sentence;
    _context = _isWord && s != null && s.length > widget.text.length + 3
        ? widget.translator.translate(s, from: widget.from, to: _to)
        : null;
  }

  @override
  void dispose() {
    widget.translator.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final translation = _Card(
      title: 'Перевод',
      child: FutureBuilder<String>(
        future: _translation,
        builder: (context, snap) {
          if (snap.hasError) return _Error('${snap.error}');
          if (!snap.hasData) return const _Skeleton(lines: 1);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(snap.data!, style: TextStyle(fontFamily: 'PTSerif', fontSize: 18, height: 1.4, color: c.text)),
            if (_context != null)
              FutureBuilder<String>(
                future: _context,
                builder: (context, s) => s.hasData
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('Во всей фразе: «${s.data}»', style: TextStyle(fontSize: 13, height: 1.4, color: c.muted)),
                      )
                    : const SizedBox.shrink(),
              ),
          ]);
        },
      ),
    );
    final dictionary = _senses == null
        ? null
        : _Card(
            title: 'Значение · Викисловарь',
            child: FutureBuilder<List<WordSense>>(
              future: _senses,
              builder: (context, snap) {
                if (snap.hasError) return _Error('${snap.error}');
                if (!snap.hasData) return const _Skeleton(lines: 3);
                final list = snap.data!;
                if (list.isEmpty) {
                  return Text('В словаре нет статьи для этого слова. Обычно статьи есть для начальной формы: «дом», а не «дома».',
                      style: TextStyle(color: c.muted, height: 1.4));
                }
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final (i, s) in list.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (s.partOfSpeech != null && (i == 0 || list[i - 1].partOfSpeech != s.partOfSpeech))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(s.partOfSpeech!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.muted)),
                          ),
                        SelectableText('${i + 1}. ${s.definition}', style: TextStyle(fontSize: 15, height: 1.45, color: c.text)),
                        if (s.example != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 18, top: 2),
                            child: Text(s.example!, style: TextStyle(fontSize: 14, fontStyle: FontStyle.italic, color: c.muted)),
                          ),
                      ]),
                    ),
                ]);
              },
            ),
          );

    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 8, 20, 28), children: [
      Center(
        child: Container(
          width: 40,
          height: 5,
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(3)),
        ),
      ),
      Text(
        widget.text,
        maxLines: _isWord ? 1 : 6,
        overflow: TextOverflow.ellipsis,
        style: _isWord
            ? TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 22, height: 1.25, color: c.text)
            : TextStyle(fontFamily: 'PTSerif', fontSize: 16, height: 1.45, color: c.body),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Text(languageName(widget.from), style: TextStyle(fontSize: 13, color: c.muted)),
        const SizedBox(width: 8),
        BcIcon(BcIcons.chevronRight, size: 14, color: c.muted),
        const SizedBox(width: 8),
        BcMenu<String>(
          tooltip: 'Язык перевода',
          borderRadius: BorderRadius.circular(15),
          selected: _to,
          onSelected: (code) => setState(() {
            _to = code;
            _translate();
          }),
          options: [
            for (final code in _languageNames.keys.where((l) => l != widget.from)) MenuOption(code, languageName(code)),
          ],
          child: Container(
            height: 30,
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), border: Border.all(color: c.line)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(languageName(_to), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.text)),
              const SizedBox(width: 4),
              BcIcon(BcIcons.chevronDown, size: 14, color: c.text),
            ]),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      if (widget.dictionaryFirst && dictionary != null) ...[dictionary, translation] else ...[translation, ?dictionary],
      const SizedBox(height: 4),
      Text('Перевод — MyMemory, словарь — Викисловарь. Нужен интернет.', style: TextStyle(fontSize: 11, color: c.muted)),
    ]);
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(color: BcColors.of(context).muted, height: 1.4));
}

/// Заготовка вместо текста, пока он грузится: серые полоски с мерцанием.
class _Skeleton extends StatefulWidget {
  const _Skeleton({required this.lines});

  final int lines;

  @override
  State<_Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<_Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    const widths = [0.92, 0.78, 0.55];
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < widget.lines; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == widget.lines - 1 ? 0 : 9),
            child: FractionallySizedBox(
              widthFactor: widget.lines == 1 ? 0.5 : widths[i % widths.length],
              child: Container(height: 12, decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(6))),
            ),
          ),
      ]),
    );
  }
}
