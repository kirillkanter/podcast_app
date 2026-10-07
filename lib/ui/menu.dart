import 'package:flutter/material.dart';

import 'icons.dart';
import 'theme.dart';

/// Пункт выпадающего меню.
class MenuOption<T> {
  const MenuOption(this.value, this.label);

  final T value;
  final String label;
}

/// Выпадающее меню в стиле приложения: скруглённая карточка, открывается
/// прямо под кнопкой (над ней — если кнопка внизу экрана), выровнена по
/// её краю; выбранный пункт отмечен галочкой.
///
/// [alignEnd] — нажимается целая строка, а значение справа (как
/// в настройках): меню выравнивается по правому краю строки.
class BcMenu<T> extends StatelessWidget {
  const BcMenu({
    super.key,
    required this.options,
    required this.onSelected,
    required this.child,
    this.selected,
    this.tooltip,
    this.alignEnd = false,
    this.borderRadius,
  });

  final List<MenuOption<T>> options;
  final ValueChanged<T> onSelected;
  final Widget child;
  final T? selected;
  final String? tooltip;
  final bool alignEnd;
  final BorderRadius? borderRadius;

  Future<void> _open(BuildContext context) async {
    final value = await showBcMenu<T>(
      context: context,
      options: options,
      selected: selected,
      alignEnd: alignEnd,
    );
    if (value != null) onSelected(value);
  }

  @override
  Widget build(BuildContext context) {
    final button = InkWell(
      borderRadius: borderRadius,
      onTap: () => _open(context),
      child: child,
    );
    return Semantics(
      button: true,
      label: tooltip,
      child: tooltip == null || alignEnd ? button : Tooltip(message: tooltip, child: button),
    );
  }
}

/// Показать меню у виджета [context].
Future<T?> showBcMenu<T>({
  required BuildContext context,
  required List<MenuOption<T>> options,
  T? selected,
  bool alignEnd = false,
}) {
  final c = BcColors.of(context);
  final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final box = context.findRenderObject()! as RenderBox;
  var rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  if (alignEnd) rect = Rect.fromLTRB(rect.right - 160, rect.top, rect.right - 12, rect.bottom);
  const gap = 6.0;
  const itemHeight = 44.0;
  final menuHeight = options.length * itemHeight + 12;
  final below = rect.bottom + gap + menuHeight <= overlay.size.height - 16 ||
      rect.center.dy < overlay.size.height / 2;
  final top = below ? rect.bottom + gap : rect.top - gap - menuHeight;
  // Меню выравнивается по ближнему к краю экрана краю кнопки.
  final position = RelativeRect.fromLTRB(
    rect.left,
    top.clamp(8.0, overlay.size.height),
    overlay.size.width - rect.right,
    0,
  );
  return showMenu<T>(
    context: context,
    position: position,
    color: c.card,
    surfaceTintColor: Colors.transparent,
    elevation: 10,
    shadowColor: Colors.black.withValues(alpha: 0.35),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: c.line.withValues(alpha: 0.6)),
    ),
    menuPadding: const EdgeInsets.symmetric(vertical: 6),
    constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
    popUpAnimationStyle: const AnimationStyle(duration: Duration(milliseconds: 160)),
    items: [
      for (final o in options)
        PopupMenuItem<T>(
          value: o.value,
          height: itemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: Text(
                o.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: o.value == selected ? FontWeight.w600 : FontWeight.w400,
                  color: c.text,
                ),
              ),
            ),
            if (o.value == selected) ...[
              const SizedBox(width: 12),
              BcIcon(BcIcons.check, size: 18, color: c.ink),
            ],
          ]),
        ),
    ],
  );
}
