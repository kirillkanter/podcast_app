/// Место под рекламу в списке: карточка с баннером Яндекса и ссылкой
/// «О рекламе». Пока объявление не загрузилось — места не занимает.
library;

import 'package:flutter/material.dart';

import '../ads/ads.dart';
import 'theme.dart';

class AdSlot extends StatefulWidget {
  const AdSlot({super.key, required this.placement, this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 4)});

  final AdPlacement placement;
  final EdgeInsets padding;

  @override
  State<AdSlot> createState() => _AdSlotState();
}

class _AdSlotState extends State<AdSlot> {
  InlineBanner? _banner;

  @override
  void dispose() {
    _banner?.dispose();
    super.dispose();
  }

  void _create(double width) {
    if (_banner != null || width <= 0) return;
    _banner = InlineBanner(widget.placement, width: width.floor());
    _banner!.load();
  }

  @override
  Widget build(BuildContext context) {
    if (!adsSupported) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: adsReady,
      builder: (context, ready, _) {
        if (!ready) return const SizedBox.shrink();
        return LayoutBuilder(builder: (context, box) {
          _create(box.maxWidth - widget.padding.horizontal - 24);
          final banner = _banner!;
          return ValueListenableBuilder<bool>(
            valueListenable: banner.ready,
            builder: (context, viewReady, _) {
              if (!viewReady) return const SizedBox.shrink();
              // Баннер стоит в дереве всё время (иначе Яндекс не загрузит
              // объявление); пока его нет — без карточки и почти без высоты.
              return ValueListenableBuilder<bool>(
                valueListenable: banner.loaded,
                builder: (context, loaded, _) => _AdCard(loaded: loaded, padding: widget.padding, ad: banner.widget()),
              );
            },
          );
        });
      },
    );
  }
}

class _AdCard extends StatelessWidget {
  const _AdCard({required this.loaded, required this.padding, required this.ad});

  final bool loaded;
  final EdgeInsets padding;
  final Widget ad;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Padding(
      padding: loaded ? padding : EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: loaded ? c.card : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: loaded ? const EdgeInsets.fromLTRB(12, 12, 12, 2) : EdgeInsets.zero,
          child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            ClipRect(child: ad),
            if (loaded)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: c.muted,
                    textStyle: const TextStyle(fontSize: 12),
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () => showAboutAds(context),
                  child: const Text('О рекламе'),
                ),
              ),
          ]),
        ),
      ),
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
                'не больше одного объявления на экране, без звука и не на весь экран. '
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
