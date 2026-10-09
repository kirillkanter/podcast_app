/// Общие части каталога книг: обложка, пометка типа, карточка и строка.
library;

import 'package:flutter/material.dart';

import '../../../catalog/books/book_catalog.dart';
import '../../cover_image.dart';
import '../../icons.dart';
import '../../nav_ink.dart';
import '../../podcast_cover.dart';
import '../../theme.dart';

/// Обложка книги из каталога: аудиокнига — квадрат, книга — 2:3.
class CatalogCover extends StatelessWidget {
  const CatalogCover({super.key, required this.book, required this.width, this.large = false});

  final CatalogBook book;
  final double width;

  /// Крупная (страница книги) — берём полную картинку, а не миниатюру.
  final bool large;

  static const _colors = [
    Color(0xFF5B2A3A), Color(0xFF3E5A3A), Color(0xFF26385A), Color(0xFF2E5A6B),
    Color(0xFF6B4A2E), Color(0xFF4B3B6B), Color(0xFF2F5D50), Color(0xFF7A3B5C),
  ];

  double get height => book.audio ? width : width * 1.5;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(width > 120 ? 12 : 8);
    final placeholder = Container(
      width: width,
      height: height,
      color: _colors[book.id.hashCode.abs() % _colors.length],
      padding: EdgeInsets.all(width * 0.1),
      alignment: Alignment.bottomLeft,
      child: width < 40
          ? const SizedBox.shrink()
          : Text(
              book.title,
              maxLines: book.audio ? 3 : 5,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: displayFont,
                fontWeight: FontWeight.w600,
                fontSize: (width * 0.11).clamp(7.0, 20.0),
                height: 1.1,
                color: Colors.white,
              ),
            ),
    );
    final url = large ? (book.cover ?? book.thumbnail) : book.smallCover;
    return ClipRRect(
      borderRadius: radius,
      child: url == null
          ? placeholder
          : Image(
              image: ResizeImage.resizeIfNeeded(
                decodeWidth(width * MediaQuery.devicePixelRatioOf(context)),
                null,
                CachedCoverImage(url),
              ),
              width: width,
              height: height,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => placeholder,
              frameBuilder: (_, child, frame, sync) => sync || frame != null ? child : placeholder,
            ),
    );
  }
}

/// Значок типа (наушники или книга) и подпись: источник, длительность.
class KindMark extends StatelessWidget {
  const KindMark({super.key, required this.audio, required this.text, this.size = 12});

  final bool audio;
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Tooltip(
        message: audio ? 'Аудиокнига' : 'Книга',
        child: BcIcon(audio ? BcIcons.headphones : BcIcons.book, size: size + 1, color: c.ink),
      ),
      const SizedBox(width: 5),
      Flexible(
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: size, color: c.muted)),
      ),
    ]);
  }
}

/// Карточка в подборке: обложка, название, автор, тип и источник.
class CatalogCard extends StatelessWidget {
  const CatalogCard({super.key, required this.book, required this.width, required this.onTap, this.selected = false});

  final CatalogBook book;
  final double width;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    // Обложки в ряду — одной высоты: квадрат аудиокниги стоит внизу
    // места под обложку книги.
    return SizedBox(
      width: width,
      child: NavInkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: width * 1.5,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(width > 120 ? 12 : 8),
                  border: selected ? Border.all(color: c.ink, width: 2) : null,
                ),
                child: CatalogCover(book: book, width: width),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, height: 1.25)),
          if (book.author != null)
            Text(book.author!,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
          const SizedBox(height: 3),
          KindMark(audio: book.audio, text: book.sourceName, size: 11),
        ]),
      ),
    );
  }
}

/// Строка списка: обложка слева, текст справа.
class BookCatalogRow extends StatelessWidget {
  const BookCatalogRow({super.key, required this.book, required this.onTap, this.side = 20, this.selected = false});

  final CatalogBook book;
  final VoidCallback onTap;
  final double side;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return NavInkWell(
      onTap: onTap,
      child: Container(
        color: selected ? c.raised : null,
        padding: EdgeInsets.fromLTRB(side, 8, side, 8),
        child: Row(children: [
          SizedBox(
            width: 56,
            height: 84,
            child: Align(alignment: Alignment.center, child: CatalogCover(book: book, width: 56)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.25)),
              if (book.author != null) ...[
                const SizedBox(height: 2),
                Text(book.author!,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.muted)),
              ],
              const SizedBox(height: 5),
              KindMark(audio: book.audio, text: book.sourceName),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Сообщение вместо списка (пусто, ошибка).
class CatalogMessage extends StatelessWidget {
  const CatalogMessage(this.text, {super.key, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(children: [
        Text(text, textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
        if (onRetry != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.ink),
            onPressed: onRetry,
            child: const Text('Повторить'),
          ),
      ]),
    );
  }
}

String catalogError(Object? e) => e is BookCatalogException ? e.message : 'Не удалось загрузить';

String formatSize(int bytes) {
  final mb = bytes / 1024 / 1024;
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1).replaceAll('.', ',')} ГБ';
  if (mb >= 10) return '${mb.round()} МБ';
  if (mb >= 0.1) return '${mb.toStringAsFixed(1).replaceAll('.', ',')} МБ';
  return '${(bytes / 1024).ceil()} КБ';
}

String chaptersWord(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return '$n глава';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return '$n главы';
  return '$n глав';
}
