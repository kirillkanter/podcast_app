/// Полоска рекламы внизу экрана: один баннер Яндекса над нижним меню.
/// Пока объявление не загрузилось — места не занимает.
library;

import 'package:flutter/material.dart';

import '../ads/ads.dart';
import 'theme.dart';

class AdBar extends StatefulWidget {
  const AdBar({super.key});

  @override
  State<AdBar> createState() => _AdBarState();
}

class _AdBarState extends State<AdBar> {
  InlineBanner? _banner;

  @override
  void dispose() {
    _banner?.dispose();
    super.dispose();
  }

  void _create(double width) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Сменили тему — запросить объявление в новом оформлении.
    if (_banner != null && _banner!.dark != dark) {
      // Старый баннер ещё слушают виджеты этого кадра — убрать после него.
      final old = _banner!;
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      _banner = null;
    }
    if (_banner != null || width <= 0) return;
    _banner = InlineBanner(AdPlacement.bar, width: width.floor(), dark: dark)..load();
  }

  @override
  Widget build(BuildContext context) {
    if (!adsSupported) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: adsReady,
      builder: (context, ready, _) {
        if (!ready) return const SizedBox.shrink();
        return LayoutBuilder(builder: (context, box) {
          _create(box.maxWidth);
          final banner = _banner!;
          return ValueListenableBuilder<bool>(
            valueListenable: banner.ready,
            builder: (context, viewReady, _) {
              if (!viewReady) return const SizedBox.shrink();
              // Баннер стоит в дереве всё время (иначе Яндекс не загрузит
              // объявление); пока его нет — почти без высоты.
              return ValueListenableBuilder<bool>(
                valueListenable: banner.loaded,
                builder: (context, loaded, _) {
                  final c = BcColors.of(context);
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.bg,
                      border: loaded ? Border(top: BorderSide(color: c.divider)) : null,
                    ),
                    child: Center(child: banner.widget()),
                  );
                },
              );
            },
          );
        });
      },
    );
  }
}

/// «О рекламе»: зачем реклама, где её нет, персональная реклама.
Future<void> showAboutAds(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      backgroundColor: BcColors.of(context).card,
      builder: (context) {
        final c = BcColors.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('О рекламе', style: sectionTitleStyle(context)),
              const SizedBox(height: 12),
              Text(
                'Реклама помогает приложению оставаться бесплатным. Её показывает Рекламная сеть Яндекса: '
                'одна полоска внизу библиотеки и поиска, без звука и не на весь экран. '
                'В плеере, читалке и на странице книги рекламы нет.',
                style: TextStyle(fontSize: 15, height: 1.45, color: c.body),
              ),
              const SizedBox(height: 10),
              Text(
                'Рекламодатель и маркировка указаны в самом объявлении. '
                'Подбор по интересам можно выключить в настройках: «Персональная реклама».',
                style: TextStyle(fontSize: 13, height: 1.4, color: c.muted),
              ),
            ]),
          ),
        );
      },
    );
