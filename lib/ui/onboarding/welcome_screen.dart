/// Первый запуск: «С чего начнём?» и «Что у вас уже есть?». Оба шага
/// можно пропустить; дальше подсказки появляются по месту.
library;

import 'package:flutter/material.dart';

import '../books/book_import.dart';
import '../icons.dart';
import '../opml_actions.dart';
import '../theme.dart';

/// Что выбрали на первом шаге.
enum WelcomeChoice { podcasts, audiobooks, books }

/// Чем закончилось приветствие.
enum WelcomeResult {
  /// Открыть поиск подкастов.
  search,
  done,
}

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _chosen = <WelcomeChoice>{WelcomeChoice.podcasts};
  int _step = 0;

  void _finish(WelcomeResult r) => Navigator.of(context).pop(r);

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _step = 0);
      },
      child: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _step == 0 ? _first(context) : _second(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _first(BuildContext context) {
    final c = BcColors.of(context);
    return ListView(key: const ValueKey(0), padding: const EdgeInsets.fromLTRB(20, 32, 20, 20), children: [
      const Center(child: AppLogo(size: 72)),
      const SizedBox(height: 18),
      Text('Basic Caster', textAlign: TextAlign.center, style: screenTitleStyle(context)),
      const SizedBox(height: 6),
      Text('Подкасты, аудиокниги и книги в одном приложении',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: c.muted)),
      const SizedBox(height: 32),
      Text('С чего начнём?', style: sectionTitleStyle(context)),
      const SizedBox(height: 12),
      for (final (choice, icon, title, hint) in const [
        (WelcomeChoice.podcasts, BcIcons.library, 'Подкасты', 'Найти в каталоге или перенести подписки из другого приложения'),
        (WelcomeChoice.audiobooks, BcIcons.headphones, 'Аудиокниги', 'Указать папку с MP3 или M4B'),
        (WelcomeChoice.books, BcIcons.book, 'Книги', 'EPUB и FB2, перевод слова по нажатию'),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _ChoiceCard(
            icon: icon,
            title: title,
            hint: hint,
            selected: _chosen.contains(choice),
            onTap: () => setState(() => _chosen.contains(choice) ? _chosen.remove(choice) : _chosen.add(choice)),
          ),
        ),
      const SizedBox(height: 18),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 52), shape: const StadiumBorder()),
        onPressed: _chosen.isEmpty ? null : () => setState(() => _step = 1),
        child: const Text('Дальше'),
      ),
      const SizedBox(height: 6),
      TextButton(
        style: TextButton.styleFrom(foregroundColor: c.muted, minimumSize: const Size(0, 48)),
        onPressed: () => _finish(WelcomeResult.done),
        child: const Text('Пропустить'),
      ),
    ]);
  }

  Widget _second(BuildContext context) {
    final c = BcColors.of(context);
    return ListView(key: const ValueKey(1), padding: const EdgeInsets.fromLTRB(8, 8, 20, 20), children: [
      Row(children: [
        IconButton(
          tooltip: 'Назад',
          onPressed: () => setState(() => _step = 0),
          icon: BcIcon(BcIcons.chevronLeft, size: 24, color: c.text),
        ),
        const Spacer(),
        Text('2 из 2', style: TextStyle(fontSize: 13, color: c.muted)),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 0, 16),
        child: Text('Что у вас уже есть?', style: screenTitleStyle(context).copyWith(fontSize: 24)),
      ),
      if (_chosen.contains(WelcomeChoice.podcasts))
        _SetupCard(
          icon: BcIcons.library,
          title: 'Подкасты',
          hint: 'Найдите подкаст в каталоге или перенесите подписки файлом OPML из другого приложения',
          actions: [
            _SetupAction('Найти подкаст', primary: true, onPressed: () => _finish(WelcomeResult.search)),
            _SetupAction('Перенести из другого приложения', onPressed: () => importOpmlFromFile(context)),
          ],
        ),
      if (_chosen.contains(WelcomeChoice.audiobooks))
        _SetupCard(
          icon: BcIcons.headphones,
          title: 'Аудиокниги',
          hint: 'Каждая подпапка с аудиофайлами станет книгой, новые появятся сами',
          actions: [_SetupAction('Выбрать папку', primary: true, onPressed: () => pickBookFolder(context))],
        ),
      if (_chosen.contains(WelcomeChoice.books))
        _SetupCard(
          icon: BcIcons.book,
          title: 'Книги',
          hint: 'EPUB, FB2 или TXT. Удержите незнакомое слово в книге — появится перевод',
          actions: [_SetupAction('Добавить файлы', primary: true, onPressed: () => pickBookFiles(context))],
        ),
      const SizedBox(height: 18),
      Padding(
        padding: const EdgeInsets.only(left: 12),
        child: FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 52), shape: const StadiumBorder()),
          onPressed: () => _finish(WelcomeResult.done),
          child: const Text('Готово'),
        ),
      ),
    ]);
  }
}

/// Логотип: тёмная «B» на круге цвета акцента.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.fill, shape: BoxShape.circle),
      child: Text('B',
          style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: size * 0.48, height: 1, color: c.onFill)),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.icon, required this.title, required this.hint, required this.selected, required this.onTap});

  final BcIcons icon;
  final String title;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Material(
      color: c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: selected ? c.ink : Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.raised, shape: BoxShape.circle),
              child: BcIcon(icon, size: 22, color: c.text),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(hint, style: TextStyle(fontSize: 13, color: c.muted)),
              ]),
            ),
            const SizedBox(width: 10),
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? c.fill : Colors.transparent,
                shape: BoxShape.circle,
                border: selected ? null : Border.all(color: c.line, width: 2),
              ),
              child: selected ? BcIcon(BcIcons.check, size: 16, color: c.onFill) : null,
            ),
          ]),
        ),
      ),
    );
  }
}

class _SetupAction {
  const _SetupAction(this.label, {required this.onPressed, this.primary = false});

  final String label;
  final VoidCallback onPressed;
  final bool primary;
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.icon, required this.title, required this.hint, required this.actions});

  final BcIcons icon;
  final String title;
  final String hint;
  final List<_SetupAction> actions;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 0, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          BcIcon(icon, size: 22, color: c.ink),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        Text(hint, style: TextStyle(fontSize: 13, height: 1.4, color: c.muted)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final a in actions)
            a.primary
                ? FilledButton(
                    style: FilledButton.styleFrom(shape: const StadiumBorder()),
                    onPressed: a.onPressed,
                    child: Text(a.label),
                  )
                : OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      shape: const StadiumBorder(),
                      foregroundColor: c.text,
                      side: BorderSide(color: c.line),
                    ),
                    onPressed: a.onPressed,
                    child: Text(a.label),
                  ),
        ]),
      ]),
    );
  }
}
