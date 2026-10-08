/// Выделения цветом и заметки: окно заметки и список «Заметки».
library;

import 'package:flutter/material.dart';

import '../../books/locator.dart';
import '../../data/db/books_dao.dart';
import '../../data/db/database.dart';
import '../app_scope.dart';
import '../format.dart';
import '../theme.dart';
import 'reader/reader_style.dart';

/// Заметка к выделению. `null` — отменили; пустая строка — заметку убрали.
Future<String?> showHighlightNoteDialog(BuildContext context, {required String quote, required String note}) {
  final controller = TextEditingController(text: note);
  return showDialog<String>(
    context: context,
    builder: (context) {
      final c = BcColors.of(context);
      return AlertDialog(
        title: const Text('Заметка'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: c.bar, width: 3))),
              child: Text(quote,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'PTSerif', fontSize: 14, height: 1.4, color: c.muted)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Ваша мысль об этом месте',
                filled: true,
                fillColor: c.raised,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Сохранить')),
        ],
      );
    },
  );
}

/// Список выделений книги: цвет, цитата, заметка, где и когда.
class HighlightsList extends StatelessWidget {
  const HighlightsList({super.key, required this.db, required this.bookKey, required this.onOpen, this.place});

  final AppDatabase db;
  final String bookKey;
  final ValueChanged<BookHighlight> onOpen;

  /// Где в книге («Глава 3 · стр. 12»); `null` — не показывать.
  final String? Function(BookHighlight h)? place;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return StreamBuilder<List<BookHighlight>>(
      stream: db.watchHighlights(bookKey),
      builder: (context, snap) {
        final list = [...?snap.data]..sort((a, b) {
            final x = TextLocator.parse(a.startAt);
            final y = TextLocator.parse(b.startAt);
            if (x == null || y == null) return 0;
            return x.compareTo(y);
          });
        if (list.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Выделений пока нет. Выделите текст долгим нажатием и выберите цвет; '
              'к выделению можно добавить заметку.',
              style: TextStyle(color: c.muted, height: 1.4),
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: list.length,
          separatorBuilder: (_, _) => Divider(height: 1, indent: 20, endIndent: 20, color: c.divider),
          itemBuilder: (context, i) {
            final h = list[i];
            final where = place?.call(h);
            return InkWell(
              onTap: () => onOpen(h),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 4,
                    height: 44,
                    margin: const EdgeInsets.only(top: 2, right: 12),
                    decoration: BoxDecoration(
                      color: highlightColors[h.color.clamp(0, highlightColors.length - 1)],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(h.quote,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: 'PTSerif', fontSize: 15, height: 1.4, color: c.text)),
                      if (h.note.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Icon(Icons.sticky_note_2_outlined, size: 16, color: c.ink),
                          const SizedBox(width: 6),
                          Expanded(child: Text(h.note, style: TextStyle(fontSize: 14, height: 1.4, color: c.body))),
                        ]),
                      ],
                      const SizedBox(height: 6),
                      Text([?where, formatAgo(h.createdAt)].join(' · '), style: TextStyle(fontSize: 12, color: c.muted)),
                    ]),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Ещё',
                    icon: Icon(Icons.more_vert, size: 20, color: c.muted),
                    onSelected: (v) async {
                      final sync = AppScope.of(context).bookSync;
                      if (v == 'note') {
                        final note = await showHighlightNoteDialog(context, quote: h.quote, note: h.note);
                        if (note == null) return;
                        await db.updateHighlight(h.id, note: note);
                      } else if (v == 'delete') {
                        await db.deleteHighlight(h.id);
                      }
                      sync?.highlightsChanged();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'note', child: Text(h.note.isEmpty ? 'Добавить заметку' : 'Изменить заметку')),
                      const PopupMenuItem(value: 'delete', child: Text('Удалить выделение')),
                    ],
                  ),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}
