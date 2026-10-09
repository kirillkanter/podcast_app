/// Нажимаемая плитка, которая открывает другой экран.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Как [InkWell], но без «застывшей» подсветки после возврата.
///
/// Пока открыт другой экран, анимации на закрытом стоят. Обычный InkWell
/// замирал с серой подсветкой нажатия и доигрывал её, когда пользователь
/// возвращался: серая рамка вспыхивала и резко пропадала. Здесь подсветка
/// сбрасывается, как только экран скрылся под другим, — при возврате плитка
/// уже чистая. Содержимое плитки при этом не пересоздаётся.
class NavInkWell extends StatefulWidget {
  const NavInkWell({super.key, required this.child, this.onTap, this.borderRadius});

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;

  @override
  State<NavInkWell> createState() => _NavInkWellState();
}

class _NavInkWellState extends State<NavInkWell> {
  final _content = GlobalKey();
  int _generation = 0;
  ValueListenable<bool>? _visible;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = TickerMode.getNotifier(context);
    if (next != _visible) {
      _visible?.removeListener(_changed);
      _visible = next..addListener(_changed);
    }
  }

  /// Анимации выключились — экран закрыт другим: убираем следы нажатия.
  void _changed() {
    if (mounted && _visible?.value == false) setState(() => _generation++);
  }

  @override
  void dispose() {
    _visible?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => InkWell(
        key: ValueKey(_generation),
        borderRadius: widget.borderRadius,
        onTap: widget.onTap,
        child: KeyedSubtree(key: _content, child: widget.child),
      );
}
