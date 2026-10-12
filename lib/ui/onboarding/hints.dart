/// Подсказки при первом использовании: каждая показывается один раз
/// и только когда человек дошёл до нужного места. «Понятно» убирает её
/// навсегда.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/db/database.dart';
import '../theme.dart';

abstract final class HintKeys {
  /// Пройден экран приветствия (или он не нужен: библиотека не пустая).
  static const onboarded = 'onb.done';
  static const search = 'hint.search';
  static const booksAdd = 'hint.booksAdd';
  static const shelves = 'hint.shelves';
  static const reader = 'hint.reader';
}

/// Элементы, на которые указывают подсказки.
abstract final class HintTargets {
  static final searchTab = GlobalKey(debugLabel: 'hint-search-tab');
  static final booksAdd = GlobalKey(debugLabel: 'hint-books-add');
}

bool _showing = false;

/// Показать подсказку [key] один раз. Возвращает, когда её закрыли
/// (или сразу, если её уже видели).
Future<void> showHintOnce(
  BuildContext context,
  AppDatabase db,
  String key, {
  GlobalKey? target,
  required String title,
  required String text,
}) async {
  if (_showing || await db.setting(key) == 'true') return;
  if (!context.mounted) return;
  _showing = true;
  try {
    await db.setSetting(key, 'true');
    if (!context.mounted) return;
    await showCoachMark(context, target: target, title: title, text: text);
  } finally {
    _showing = false;
  }
}

/// Подсказка поверх экрана. С [target] — затемнение с вырезом вокруг
/// элемента и пузырь со стрелкой к нему; без — карточка внизу экрана,
/// экран не затемняется.
Future<void> showCoachMark(BuildContext context, {GlobalKey? target, required String title, required String text}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final done = Completer<void>();
  late OverlayEntry entry;
  void close() {
    if (done.isCompleted) return;
    entry.remove();
    done.complete();
  }

  entry = OverlayEntry(builder: (context) => _CoachMark(target: target, title: title, text: text, onClose: close));
  overlay.insert(entry);
  return done.future;
}

class _CoachMark extends StatelessWidget {
  const _CoachMark({required this.target, required this.title, required this.text, required this.onClose});

  final GlobalKey? target;
  final String title;
  final String text;
  final VoidCallback onClose;

  Rect? _rect(BuildContext overlayContext) {
    final box = target?.currentContext?.findRenderObject();
    final overlayBox = overlayContext.findRenderObject();
    if (box is! RenderBox || !box.attached || overlayBox is! RenderBox) return null;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    return topLeft & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final rect = _rect(context);
    final bubble = _Bubble(title: title, text: text, onClose: onClose);
    if (rect == null) {
      // Без цели — карточка внизу, экран остаётся доступным.
      return Positioned(
        left: 12,
        right: 12,
        bottom: padding.bottom + 12,
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: bubble)),
      );
    }
    final hole = rect.inflate(6);
    final below = hole.center.dy < size.height / 2;
    const width = 300.0;
    final left = (hole.center.dx - width / 2).clamp(12.0, size.width - width - 12);
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onClose,
          child: CustomPaint(painter: _ScrimPainter(hole: hole, color: const Color(0x99000000))),
        ),
      ),
      Positioned(
        left: left,
        width: width,
        top: below ? hole.bottom + 14 : null,
        bottom: below ? null : size.height - hole.top + 14,
        child: Material(
          type: MaterialType.transparency,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (below) _Arrow(up: true, color: c.card, dx: hole.center.dx - left),
            bubble,
            if (!below) _Arrow(up: false, color: c.card, dx: hole.center.dx - left),
          ]),
        ),
      ),
    ]);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.title, required this.text, required this.onClose});

  final String title;
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Material(
      color: c.card,
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text)),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(text, style: TextStyle(fontSize: 14, height: 1.4, color: c.body)),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              style: TextButton.styleFrom(foregroundColor: c.ink),
              onPressed: onClose,
              child: const Text('Понятно', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.up, required this.color, required this.dx});

  final bool up;
  final Color color;
  final double dx;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 10,
        width: double.infinity,
        child: CustomPaint(painter: _ArrowPainter(up: up, color: color, dx: dx)),
      );
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter({required this.up, required this.color, required this.dx});

  final bool up;
  final Color color;
  final double dx;

  @override
  void paint(Canvas canvas, Size size) {
    final x = dx.clamp(20.0, size.width - 20);
    final path = up
        ? (Path()
          ..moveTo(x - 10, size.height)
          ..lineTo(x, 0)
          ..lineTo(x + 10, size.height))
        : (Path()
          ..moveTo(x - 10, 0)
          ..lineTo(x, size.height)
          ..lineTo(x + 10, 0));
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.dx != dx || old.up != up || old.color != color;
}

class _ScrimPainter extends CustomPainter {
  _ScrimPainter({required this.hole, required this.color});

  final Rect hole;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    final inner = Path()..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(16)));
    canvas.drawPath(Path.combine(PathOperation.difference, outer, inner), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => old.hole != hole || old.color != color;
}
