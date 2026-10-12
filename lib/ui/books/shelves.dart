/// Свои полки: создать, переименовать, удалить, поставить книгу на полку.
library;

import 'package:flutter/material.dart';

import '../../data/db/database.dart';
import '../../data/db/shelves_dao.dart';
import '../app_scope.dart';
import '../icons.dart';
import '../theme.dart';

void _changed(BuildContext context) => AppScope.of(context).bookSync?.shelvesChanged();

/// Спросить название полки. null — отменили.
Future<String?> askShelfName(BuildContext context, {String initial = '', String title = 'Новая полка'}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      void done() {
        final name = controller.text.trim();
        if (name.isNotEmpty) Navigator.of(context).pop(name);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Например, «Отпуск» или «Перечитать»'),
          onSubmitted: (_) => done(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: done, child: Text(initial.isEmpty ? 'Создать' : 'Сохранить')),
        ],
      );
    },
  );
}

/// Создать полку. Возвращает её uid или null.
Future<String?> createShelf(BuildContext context) async {
  final db = AppScope.of(context).db;
  final name = await askShelfName(context);
  if (name == null || !context.mounted) return null;
  final uid = await db.createShelf(name);
  if (context.mounted) _changed(context);
  return uid;
}

/// Переименовать или удалить полку. true — полку удалили.
Future<bool> editShelf(BuildContext context, UserShelf shelf) async {
  final db = AppScope.of(context).db;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    backgroundColor: BcColors.of(context).card,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(shelf.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: sectionTitleStyle(context)),
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Переименовать'),
          onTap: () => Navigator.of(context).pop('rename'),
        ),
        ListTile(
          leading: BcIcon(BcIcons.trash, size: 22, color: Theme.of(context).colorScheme.error),
          title: Text('Удалить полку', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          subtitle: const Text('Книги останутся в библиотеке'),
          onTap: () => Navigator.of(context).pop('delete'),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (!context.mounted) return false;
  switch (action) {
    case 'rename':
      final name = await askShelfName(context, initial: shelf.name, title: 'Название полки');
      if (name == null || !context.mounted) return false;
      await db.renameShelf(shelf.uid, name);
      if (context.mounted) _changed(context);
      return false;
    case 'delete':
      await db.deleteShelf(shelf.uid);
      if (context.mounted) _changed(context);
      return true;
  }
  return false;
}

/// Выбор полок для книги: отметить галочками, создать новую.
Future<void> showBookShelves(BuildContext context, Book book) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: BcColors.of(context).card,
      builder: (context) => _BookShelvesSheet(book: book),
    );

class _BookShelvesSheet extends StatefulWidget {
  const _BookShelvesSheet({required this.book});

  final Book book;

  @override
  State<_BookShelvesSheet> createState() => _BookShelvesSheetState();
}

class _BookShelvesSheetState extends State<_BookShelvesSheet> {
  Stream<List<UserShelf>>? _shelves;
  Stream<Set<String>>? _on;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final db = AppScope.of(context).db;
    _shelves ??= db.watchShelves();
    _on ??= db.watchShelvesOfBook(widget.book.key);
  }

  Future<void> _toggle(String uid, bool on) async {
    await AppScope.of(context).db.setBookOnShelf(uid, widget.book.key, on);
    if (mounted) _changed(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: StreamBuilder<List<UserShelf>>(
          stream: _shelves,
          builder: (context, shelves) => StreamBuilder<Set<String>>(
            stream: _on,
            builder: (context, on) {
              final list = shelves.data ?? const <UserShelf>[];
              final selected = on.data ?? const <String>{};
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                  child: Text('Полки', style: sectionTitleStyle(context)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(widget.book.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.muted)),
                ),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final s in list)
                      CheckboxListTile(
                        value: selected.contains(s.uid),
                        title: Text(s.name),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (v) => _toggle(s.uid, v ?? false),
                      ),
                    ListTile(
                      leading: BcIcon(BcIcons.plus, size: 22, color: c.ink),
                      title: Text('Новая полка', style: TextStyle(color: c.ink)),
                      onTap: () async {
                        final uid = await createShelf(context);
                        if (uid != null) await _toggle(uid, true);
                      },
                    ),
                  ]),
                ),
                const SizedBox(height: 8),
              ]);
            },
          ),
        ),
      ),
    );
  }
}
