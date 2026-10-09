import 'package:flutter/material.dart';

import '../../data/db/books_dao.dart';
import '../../data/db/database.dart';
import '../../player/playback_logic.dart';
import '../app_scope.dart';
import '../format.dart';
import '../icons.dart';
import '../podcast_cover.dart';
import '../theme.dart';

/// Обложка книги: картинка из файла или цветная плашка с названием.
class BookCover extends StatelessWidget {
  const BookCover({super.key, required this.book, this.size = 56});

  final Book book;
  final double size;

  static const _colors = [
    Color(0xFF5B2A3A), Color(0xFF3E5A3A), Color(0xFF26385A), Color(0xFF2E5A6B),
    Color(0xFF6B4A2E), Color(0xFF4B3B6B), Color(0xFF2F5D50), Color(0xFF7A3B5C),
  ];

  @override
  Widget build(BuildContext context) {
    final path = book.coverPath;
    if (path != null) {
      return PodcastCover(url: Uri.file(path).toString(), size: size, placeholderIcon: Icons.menu_book_outlined);
    }
    final color = _colors[book.key.hashCode.abs() % _colors.length];
    return ClipRRect(
      borderRadius: BorderRadius.circular(size > 80 ? 14 : 9),
      child: Container(
        width: size,
        height: size,
        color: color,
        padding: EdgeInsets.all(size * 0.1),
        alignment: Alignment.bottomLeft,
        child: size < 40
            ? const SizedBox.shrink()
            : Text(
                book.title,
                maxLines: size > 100 ? 5 : 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: displayFont,
                  fontWeight: FontWeight.w600,
                  fontSize: (size * 0.11).clamp(7.0, 20.0),
                  height: 1.1,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }
}

/// Значки формата: наушники — аудио, страница — текст.
class BookKindIcon extends StatelessWidget {
  const BookKindIcon({super.key, required this.kind, this.size = 14, this.color});

  final BookKind kind;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => BcIcon(
        kind == BookKind.audio ? BcIcons.headphones : BcIcons.page,
        size: size,
        color: color ?? BcColors.of(context).muted,
        semanticLabel: kind == BookKind.audio ? 'Аудиокнига' : 'Текстовая книга',
      );
}

/// «осталось 9 ч 48 мин», «41 %», «прочитано», «не начата».
String bookProgressText(Book book, BookProgress? p) {
  if (p == null || p.percent <= 0) {
    if (book.kind == BookKind.audio && (book.durationMs ?? 0) > 0) return formatDuration(book.durationMs);
    return book.path == null && book.kind == BookKind.text ? 'скачивается' : 'не начата';
  }
  if (p.percent >= 0.995) return book.kind == BookKind.audio ? 'прослушана' : 'прочитана';
  if (book.kind == BookKind.audio && (book.durationMs ?? 0) > 0) {
    final left = book.durationMs! - p.positionMs;
    if (left > 0) return 'осталось ${formatDuration(left)}';
  }
  return '${(p.percent * 100).round()} %';
}

/// Строка главы: номер, название, длительность, отметка «прослушана».
class ChapterTile extends StatelessWidget {
  const ChapterTile({
    super.key,
    required this.number,
    required this.title,
    required this.onTap,
    this.trailing,
    this.current = false,
    this.done = false,
    this.progress,
  });

  final int number;
  final String title;
  final String? trailing;
  final bool current;
  final bool done;

  /// Прогресс внутри текущей главы (0..1).
  final double? progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Material(
      color: current ? c.raised.withValues(alpha: 0.6) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(children: [
              SizedBox(
                width: 28,
                child: Text('$number',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 13,
                      color: current ? c.ink : c.muted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    )),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                        color: done && !current ? c.muted : c.text,
                      )),
                  if (current && progress != null) ...[
                    const SizedBox(height: 6),
                    ThinProgress(value: progress!, width: 72),
                  ],
                ]),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                Text(trailing!,
                    style: TextStyle(fontSize: 13, color: c.muted, fontFeatures: const [FontFeature.tabularFigures()])),
              ],
              SizedBox(
                width: 26,
                child: done && !current ? Align(alignment: Alignment.centerRight, child: BcIcon(BcIcons.check, size: 16, color: c.muted)) : null,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Закладки книги: нажатие — перейти, значок — удалить.
class BookmarksList extends StatelessWidget {
  const BookmarksList({super.key, required this.db, required this.bookId, required this.onOpen, this.padding, this.meta});

  final AppDatabase db;
  final int bookId;
  final ValueChanged<BookBookmark> onOpen;
  final EdgeInsets? padding;

  /// Подпись под закладкой («Глава 3 · стр. 12 · вчера»); по умолчанию — время.
  final String Function(BookBookmark bookmark)? meta;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final sync = AppScope.of(context).bookSync;
    return StreamBuilder<List<BookBookmark>>(
      stream: db.watchBookmarks(bookId),
      builder: (context, snap) {
        final list = snap.data ?? const <BookBookmark>[];
        if (list.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Закладок пока нет. Добавить закладку можно кнопкой в плеере или в читалке.',
                style: TextStyle(color: c.muted, height: 1.4)),
          );
        }
        return ListView.builder(
          padding: padding,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final b = list[i];
            return ListTile(
              leading: BcIcon(BcIcons.bookmark, size: 20, color: c.ink),
              title: Text(b.label.isEmpty ? 'Закладка' : b.label, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(meta?.call(b) ?? formatAgo(b.createdAt), style: TextStyle(fontSize: 12, color: c.muted)),
              trailing: IconButton(
                tooltip: 'Удалить закладку',
                icon: BcIcon(BcIcons.close, size: 18, color: c.muted),
                onPressed: () async {
                  await db.deleteBookmark(b.id);
                  sync?.highlightsChanged();
                },
              ),
              onTap: () => onOpen(b),
            );
          },
        );
      },
    );
  }
}

/// Длительность главы: «47:20», «1:12:05».
String chapterLength(int ms) => formatClock(Duration(milliseconds: ms));
