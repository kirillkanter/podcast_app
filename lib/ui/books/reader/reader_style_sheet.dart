/// Настройки текста читалки: размер, шрифт, фон, интервал, две колонки.
library;

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'reader_style.dart';

class ReaderStyleSheet extends StatelessWidget {
  const ReaderStyleSheet({super.key, required this.style, required this.onChanged});

  final ReaderStyle style;
  final ValueChanged<ReaderStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final brightness = Theme.of(context).brightness;
    final paper = style.paperFor(brightness);
    Widget label(String t) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(t, style: TextStyle(fontSize: 13, color: c.muted)),
        );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            _StyleButton(
              width: 56,
              selected: false,
              onTap: style.size > 0 ? () => onChanged(style.copyWith(size: style.size - 1)) : null,
              child: const Text('A', style: TextStyle(fontFamily: 'PTSerif', fontSize: 15)),
            ),
            Expanded(
              child: Center(
                child: Text('${style.fontSize.round()}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text)),
              ),
            ),
            _StyleButton(
              width: 56,
              selected: false,
              onTap: style.size < readerSizes.length - 1 ? () => onChanged(style.copyWith(size: style.size + 1)) : null,
              child: const Text('A', style: TextStyle(fontFamily: 'PTSerif', fontSize: 23)),
            ),
          ]),
          const SizedBox(height: 16),
          label('Шрифт'),
          Row(children: [
            for (final f in ReaderFont.values) ...[
              Expanded(
                child: _StyleButton(
                  selected: style.font == f,
                  onTap: () => onChanged(style.copyWith(font: f)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(f.label, style: TextStyle(fontFamily: f.family, fontSize: 15, color: c.text)),
                        Text(f.hint, style: TextStyle(fontSize: 11, color: c.muted)),
                      ]),
                    ),
                  ),
                ),
              ),
              if (f != ReaderFont.values.last) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 16),
          label('Фон'),
          Row(children: [
            for (final p in Paper.values) ...[
              Expanded(
                child: _StyleButton(
                  selected: paper == p,
                  background: p.bg,
                  onTap: () => onChanged(style.copyWith(paper: p)),
                  child: Text(p.label, style: TextStyle(fontSize: 14, color: p.ink)),
                ),
              ),
              if (p != Paper.values.last) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 16),
          label('Межстрочный интервал'),
          Row(children: [
            for (var i = 0; i < readerSpacings.length; i++) ...[
              Expanded(
                child: _StyleButton(
                  selected: style.spacing == i,
                  onTap: () => onChanged(style.copyWith(spacing: i)),
                  child: Text(const ['Плотно', 'Обычно', 'Свободно'][i], style: TextStyle(fontSize: 14, color: c.text)),
                ),
              ),
              if (i != readerSpacings.length - 1) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 16),
          label('Поля'),
          Row(children: [
            for (var i = 0; i < readerMargins.length; i++) ...[
              Expanded(
                child: _StyleButton(
                  selected: style.margin == i,
                  onTap: () => onChanged(style.copyWith(margin: i)),
                  child: _MarginIcon(factor: readerMargins[i], color: c.text),
                ),
              ),
              if (i != readerMargins.length - 1) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 16),
          label('Выравнивание'),
          Row(children: [
            for (final j in [true, false]) ...[
              Expanded(
                child: _StyleButton(
                  selected: style.justify == j,
                  onTap: () => onChanged(style.copyWith(justify: j)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(j ? Icons.format_align_justify : Icons.format_align_left, size: 20, color: c.text),
                    const SizedBox(width: 8),
                    Text(j ? 'По ширине' : 'По левому краю', style: TextStyle(fontSize: 14, color: c.text)),
                  ]),
                ),
              ),
              if (j) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 16),
          label('Перелистывание'),
          Row(children: [
            for (final t in PageTurn.values) ...[
              Expanded(
                child: _StyleButton(
                  selected: style.pageTurn == t,
                  onTap: () => onChanged(style.copyWith(pageTurn: t)),
                  child: Text(t.label, style: TextStyle(fontSize: 14, color: c.text)),
                ),
              ),
              if (t != PageTurn.values.last) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: style.landscapeSpread,
            onChanged: (v) => onChanged(style.copyWith(landscapeSpread: v)),
            title: Text('Две колонки в альбомной ориентации', style: TextStyle(fontSize: 15, color: c.text)),
            subtitle: Text('Когда телефон повёрнут набок — разворот, как у бумажной книги',
                style: TextStyle(fontSize: 12, color: c.muted)),
          ),
        ]),
      ),
    );
  }
}

class _StyleButton extends StatelessWidget {
  const _StyleButton({required this.child, required this.selected, required this.onTap, this.width, this.background});

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final double? width;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Material(
      color: background ?? c.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? c.bar : Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(width: width, height: 52, child: Center(child: Opacity(opacity: onTap == null ? 0.4 : 1, child: child))),
      ),
    );
  }
}

/// Схема страницы с полями: строки текста между полями.
class _MarginIcon extends StatelessWidget {
  const _MarginIcon({required this.factor, required this.color});

  final double factor;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pad = 3 + 5 * factor;
    return Container(
      width: 34,
      height: 30,
      padding: EdgeInsets.symmetric(horizontal: pad, vertical: 5),
      decoration: BoxDecoration(border: Border.all(color: color.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(4)),
      child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        for (var i = 0; i < 4; i++) Container(height: 2, color: color.withValues(alpha: 0.8)),
      ]),
    );
  }
}
