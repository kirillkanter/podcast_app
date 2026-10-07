/// Прокрутка на компьютере: мышью можно тянуть списки, а у рядов, которые
/// листаются вбок, есть стрелки.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'icons.dart';
import 'theme.dart';

/// Списки тянутся мышью и тачпадом так же, как пальцем.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };
}

/// Стрелки «влево/вправо» поверх ряда, который листается вбок.
/// Стрелка видна, только когда в ту сторону есть что листать.
class ScrollArrows extends StatefulWidget {
  const ScrollArrows({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
    this.top,
    this.size = 40,
  });

  final ScrollController controller;
  final Widget child;
  final bool enabled;

  /// Отступ стрелок сверху; `null` — по центру ряда.
  final double? top;
  final double size;

  @override
  State<ScrollArrows> createState() => _ScrollArrowsState();
}

class _ScrollArrowsState extends State<ScrollArrows> {
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(ScrollArrows old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _page(int direction) {
    final c = widget.controller;
    if (!c.hasClients) return;
    final p = c.position;
    final target = (p.pixels + direction * p.viewportDimension * 0.8).clamp(0.0, p.maxScrollExtent);
    c.animateTo(target, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final body = NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
        return false;
      },
      child: widget.child,
    );
    if (!widget.enabled) return body;
    final c = widget.controller;
    final has = c.hasClients && c.position.hasContentDimensions;
    final left = has && c.position.pixels > 1;
    final right = has && c.position.pixels < c.position.maxScrollExtent - 1;
    final colors = BcColors.of(context);
    Widget arrow(bool forward) => Material(
          color: colors.raised,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: Colors.black45,
          child: RoundIconButton(
            icon: forward ? BcIcons.chevronRight : BcIcons.chevronLeft,
            tooltip: forward ? 'Дальше' : 'Назад',
            size: widget.size,
            iconSize: 20,
            onPressed: () => _page(forward ? 1 : -1),
          ),
        );
    return Stack(children: [
      body,
      if (left)
        Positioned(
          left: 8,
          top: widget.top,
          bottom: widget.top == null ? 0 : null,
          child: Center(child: arrow(false)),
        ),
      if (right)
        Positioned(
          right: 8,
          top: widget.top,
          bottom: widget.top == null ? 0 : null,
          child: Center(child: arrow(true)),
        ),
    ]);
  }
}
