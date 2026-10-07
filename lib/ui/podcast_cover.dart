import 'package:flutter/material.dart';

import 'cover_image.dart';

/// Ширина декодирования: вдвое больше пикселей на экране, округлённая
/// до 256/512/1024 — одна картинка в кэше на несколько размеров.
int decodeWidth(double pixels) {
  final want = pixels * 2;
  for (final w in const [256, 512, 1024]) {
    if (want <= w) return w;
  }
  return 1600;
}

/// Обложка подкаста или эпизода с заглушкой, если картинки нет
/// или она не загрузилась.
class PodcastCover extends StatelessWidget {
  const PodcastCover({super.key, required this.url, this.size = 56});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.podcasts, size: size * 0.5, color: scheme.onSurfaceVariant),
    );

    final imageUrl = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size > 80 ? 12 : 8),
      child: imageUrl == null
          ? placeholder
          : Image(
              image: ResizeImage.resizeIfNeeded(
                // Декодируем не в исходном 3000×3000, но с запасом: уменьшение
                // ровно до размера на экране делает декодер грубо, края идут
                // лесенкой. Запас вдвое дальше сглаживает видеокарта.
                decodeWidth(size * MediaQuery.devicePixelRatioOf(context)),
                null,
                CachedCoverImage(imageUrl),
              ),
              width: size,
              height: size,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => placeholder,
              // Пока картинка читается с диска или качается — заглушка.
              frameBuilder: (_, child, frame, sync) => sync || frame != null ? child : placeholder,
            ),
    );
  }
}
