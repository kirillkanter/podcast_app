/// Добавление каталога OPDS: снизу на телефоне, окном по центру на компьютере.
library;

import 'package:flutter/material.dart';

import '../../../catalog/books/book_catalog.dart';
import '../../app_scope.dart';
import '../../icons.dart';
import '../../theme.dart';

Future<void> showAddOpdsCatalog(BuildContext context) {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: BcColors.of(context).card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: const SingleChildScrollView(padding: EdgeInsets.fromLTRB(28, 24, 28, 24), child: AddOpdsForm()),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: BcColors.of(context).card,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.paddingOf(context).bottom + 20),
        child: const AddOpdsForm(),
      ),
    ),
  );
}

class AddOpdsForm extends StatefulWidget {
  const AddOpdsForm({super.key});

  @override
  State<AddOpdsForm> createState() => _AddOpdsFormState();
}

class _AddOpdsFormState extends State<AddOpdsForm> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _login = TextEditingController();
  final _password = TextEditingController();
  bool _private = false;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final catalog = AppScope.of(context).bookCatalog;
    if (catalog == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final added = await catalog.addOpds(
        url: _url.text,
        name: _name.text,
        login: _private ? _login.text : null,
        password: _private ? _password.text : null,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text('Каталог «${added.name}» добавлен. Он появится в книгах, во вкладке «Каталог»')));
    } catch (e) {
      if (mounted) setState(() => _error = e is BookCatalogException ? e.message : 'Не получилось: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    InputDecoration field(String label, {String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          fillColor: c.raised,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Каталог OPDS', style: screenTitleStyle(context).copyWith(fontSize: 20)),
      const SizedBox(height: 6),
      Text('Каталог библиотеки или книжного сайта. Книги из него появятся во вкладке «Каталог».',
          style: TextStyle(fontSize: 13, color: c.muted)),
      const SizedBox(height: 18),
      TextField(
        controller: _url,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enabled: !_busy,
        decoration: field('Адрес каталога', hint: 'https://…/opds'),
        onChanged: (_) => setState(() => _error = null),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _name,
        enabled: !_busy,
        decoration: field('Название (необязательно)'),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final s in opdsSuggestions)
          ActionChip(
            label: Text(s.name),
            side: BorderSide(color: c.line),
            labelStyle: TextStyle(fontWeight: FontWeight.w500, color: c.text),
            onPressed: _busy
                ? null
                : () => setState(() {
                      _url.text = s.url;
                      _name.text = s.name;
                      _error = null;
                    }),
          ),
      ]),
      const SizedBox(height: 6),
      InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _busy ? null : () => setState(() => _private = !_private),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Вход в каталог', style: TextStyle(fontSize: 15)),
                Text('Для закрытых каталогов с логином и паролем', style: TextStyle(fontSize: 12, color: c.muted)),
              ]),
            ),
            AnimatedRotation(
              turns: _private ? 0.5 : 0,
              duration: const Duration(milliseconds: 150),
              child: BcIcon(BcIcons.chevronDown, size: 20, color: c.muted),
            ),
          ]),
        ),
      ),
      if (_private) ...[
        TextField(
          controller: _login,
          enabled: !_busy,
          autocorrect: false,
          autofillHints: const [AutofillHints.username],
          decoration: field('Логин'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: !_showPassword,
          autofillHints: const [AutofillHints.password],
          decoration: field('Пароль').copyWith(
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Скрыть пароль' : 'Показать пароль',
              icon: BcIcon(_showPassword ? BcIcons.eyeOff : BcIcons.eye, size: 20, color: c.muted),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
      const SizedBox(height: 6),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(_error!, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.error)),
        )
      else
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('Проверим адрес и покажем, что в каталоге есть', style: TextStyle(fontSize: 12, color: c.muted)),
        ),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              shape: const StadiumBorder(),
              foregroundColor: c.text,
              side: BorderSide(color: c.line),
            ),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
            onPressed: _busy ? null : _add,
            child: _busy
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Добавить'),
          ),
        ),
      ]),
    ]);
  }
}
