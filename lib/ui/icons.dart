/// Значки приложения — тонкие линейные, как в макетах (24×24, линия 2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const _box = '<rect x="3" y="4" width="18" height="5" rx="1"/>'
    '<path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9"/>';

enum BcIcons {
  library('<rect x="4" y="4" width="6" height="16" rx="1.5"/><rect x="14" y="4" width="6" height="16" rx="1.5"/>'),
  search('<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/>'),
  download('<path d="M12 4v11"/><path d="m7 10 5 5 5-5"/><path d="M5 20h14"/>'),
  downloaded('<path d="M5 20h14"/><path d="m7 10.5 3.5 3.5L17 7.5"/>'),
  queue('<path d="M4 6h12M4 12h12M4 18h7M17 15v6M14 18h6"/>'),
  queueRemove('<path d="M4 6h12M4 12h12M4 18h7M14 18h6"/>'),
  queueList('<path d="M4 6h16M4 12h16M4 18h10"/><path d="M17 15.5v5l4-2.5z"/>'),
  playNext('<path d="M4 6h12M4 12h8M4 18h8"/><path d="M15 13.5v7l5.5-3.5z"/>'),
  settings('<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>'),
  archive('$_box<path d="M10 13h4"/>'),
  unarchive('$_box<path d="M12 17.5v-5M9.5 15 12 12.5l2.5 2.5"/>'),
  refresh('<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/>'),
  plus('<path d="M12 5v14M5 12h14"/>'),
  back('<path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 4v5h5"/>'),
  forward('<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/>'),
  timer('<path d="M10 2h4"/><circle cx="12" cy="14" r="8"/><path d="M12 14l3-3"/>'),
  chapters('<path d="M4 6h16M4 12h16M4 18h10"/>'),
  volume('<path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M16.5 8.5a5 5 0 0 1 0 7"/>'),
  volumeOff('<path d="M4 9h4l5-4v14l-5-4H4z"/><path d="m17 9.5 5 5M22 9.5l-5 5"/>'),
  check('<path d="m5 12 5 5 9-10"/>'),
  uncheck('<path d="m5 12 5 5 9-10"/><path d="M4 4l16 16"/>'),
  drag('<path d="M5 9h14M5 15h14"/>'),
  eye('<path d="M2 12c1-2.5 5-7 10-7s9 4.5 10 7c-1 2.5-5 7-10 7S3 14.5 2 12z"/><circle cx="12" cy="12" r="3"/>'),
  eyeOff('<path d="M3 3l18 18"/><path d="M10.6 5.1A10 10 0 0 1 12 5c5 0 9 4.5 10 7a13 13 0 0 1-3 4M6.6 6.6C4.5 8 2.8 10 2 12c1 2.5 5 7 10 7a10 10 0 0 0 4.4-1"/>'),
  chevronDown('<path d="m6 9 6 6 6-6"/>'),
  chevronRight('<path d="m9 6 6 6-6 6"/>'),
  close('<path d="M6 6l12 12M18 6 6 18"/>'),
  trash('<path d="M4 7h16"/><path d="M9 7V4h6v3"/><path d="M6 7l1 13h10l1-13"/>'),
  alert('<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5M12 16.5v.01"/>'),
  clock('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'),
  sync('<path d="M20 11a8 8 0 0 0-14.6-4.5L4 8"/><path d="M4 4v4h4"/><path d="M4 13a8 8 0 0 0 14.6 4.5L20 16"/><path d="M20 20v-4h-4"/>'),
  globe('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z"/>'),
  external('<path d="M7 17 17 7M9 7h8v8"/>');

  const BcIcons(this.body);

  final String body;

  String get svg => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" '
      'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">$body</svg>';
}

/// Значок из [BcIcons]. Цвет и размер — как у обычного `Icon`
/// (по умолчанию из IconTheme).
class BcIcon extends StatelessWidget {
  const BcIcon(this.icon, {super.key, this.size, this.color, this.semanticLabel});

  final BcIcons icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    final c = color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    return SvgPicture.string(
      icon.svg,
      width: s,
      height: s,
      colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
      semanticsLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
    );
  }
}

/// Перемотка назад/вперёд: круговая стрелка с числом секунд внутри.
class SkipIcon extends StatelessWidget {
  const SkipIcon({super.key, required this.forward, required this.seconds, this.size = 34, this.color});

  final bool forward;
  final int seconds;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(
      dimension: size,
      child: Stack(alignment: Alignment.center, children: [
        BcIcon(forward ? BcIcons.forward : BcIcons.back, size: size, color: c),
        Padding(
          padding: EdgeInsets.only(top: size * 0.09),
          child: Text('$seconds',
              style: TextStyle(fontSize: size * 0.29, fontWeight: FontWeight.w600, color: c, height: 1)),
        ),
      ]),
    );
  }
}

/// `IconData` или [BcIcons] → виджет значка.
Widget anyIcon(Object icon, {double? size, Color? color}) => switch (icon) {
      BcIcons() => BcIcon(icon, size: size, color: color),
      IconData() => Icon(icon, size: size, color: color),
      Widget() => icon,
      _ => throw ArgumentError('Неизвестный значок: $icon'),
    };
