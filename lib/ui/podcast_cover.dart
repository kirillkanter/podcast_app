import 'package:flutter/material.dart';

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
          : Image.network(
              imageUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              // Декодируем картинку в нужном размере, а не в исходном 3000×3000.
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (_, _, _) => placeholder,
              loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
            ),
    );
  }
}
