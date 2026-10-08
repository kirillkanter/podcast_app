import 'package:flutter/material.dart';

import '../../../books/translator.dart';
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
Future<void> showTranslateSheet(
  BuildContext context, {
  required String text,
  required String sourceLanguage,
  bool dictionaryFirst = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.92,
      builder: (context, controller) => _TranslatePanel(
        text: text,
        from: sourceLanguage,
        controller: controller,
        dictionaryFirst: dictionaryFirst,
      ),
    ),
  );
}

class _TranslatePanel extends StatefulWidget {
  const _TranslatePanel({required this.text, required this.from, required this.controller, required this.dictionaryFirst});

  final String text;
  final String from;
  final ScrollController controller;
  final bool dictionaryFirst;

  @override
  State<_TranslatePanel> createState() => _TranslatePanelState();
}

class _TranslatePanelState extends State<_TranslatePanel> {
  final _translator = Translator();
  late String _to = widget.from == 'ru' ? 'en' : 'ru';
  late Future<String> _translation = _translator.translate(widget.text, from: widget.from, to: _to);
  Future<List<WordSense>>? _senses;

  bool get _isWord => !widget.text.trim().contains(RegExp(r'\s')) && widget.text.trim().length <= 40;

  @override
  void initState() {
    super.initState();
    if (_isWord) _senses = _translator.define(widget.text, lang: widget.from);
  }

  @override
  void dispose() {
    _translator.close();
    super.dispose();
  }

  void _setTarget(String to) => setState(() {
        _to = to;
        _translation = _translator.translate(widget.text, from: widget.from, to: to);
      });

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final translation = _Section(
      title: 'Перевод: ${languageName(widget.from)} → ${languageName(_to)}',
      trailing: PopupMenuButton<String>(
        tooltip: 'Язык перевода',
        onSelected: _setTarget,
        itemBuilder: (_) => [
          for (final code in _languageNames.keys.where((l) => l != widget.from))
            PopupMenuItem(value: code, child: Text(languageName(code))),
        ],
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text('Язык', style: TextStyle(fontSize: 13, color: c.ink)),
        ),
      ),
      child: FutureBuilder<String>(
        future: _translation,
        builder: (context, snap) {
          if (snap.hasError) return Text('${snap.error}', style: TextStyle(color: c.muted));
          if (!snap.hasData) return const _Loading();
          return SelectableText(snap.data!, style: TextStyle(fontSize: 17, height: 1.45, color: c.text));
        },
      ),
    );
    final dictionary = _senses == null
        ? null
        : _Section(
            title: 'Значение (Викисловарь, ${languageName(widget.from)})',
            child: FutureBuilder<List<WordSense>>(
              future: _senses,
              builder: (context, snap) {
                if (snap.hasError) return Text('${snap.error}', style: TextStyle(color: c.muted));
                if (!snap.hasData) return const _Loading();
                final list = snap.data!;
                if (list.isEmpty) {
                  return Text('В словаре нет статьи для этого слова (возможно, нужна начальная форма).',
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
      Text(widget.text, maxLines: 6, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, height: 1.45, color: c.body)),
      const SizedBox(height: 16),
      if (widget.dictionaryFirst && dictionary != null) ...[dictionary, translation] else ...[translation, ?dictionary],
      const SizedBox(height: 8),
      Text('Перевод — MyMemory, словарь — Викисловарь. Нужен интернет.', style: TextStyle(fontSize: 11, color: c.muted)),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 14),
      decoration: BoxDecoration(color: c.raised.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted))),
          ?trailing,
        ]),
        const SizedBox(height: 8),
        Padding(padding: const EdgeInsets.only(right: 6), child: child),
      ]),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
}
