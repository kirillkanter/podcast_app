import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'icons.dart';

/// Цвета Basic Caster. Тёмная тема — основная: салатовый акцент из логотипа.
/// В светлой салатовый плохо читается на белом, поэтому заливки и ссылки
/// там травяные (#557F00 — светлейший оттенок, на котором белый текст ещё
/// проходит по контрасту 4,5:1).
@immutable
class BcColors extends ThemeExtension<BcColors> {
  const BcColors({
    required this.bg,
    required this.text,
    required this.muted,
    required this.raised,
    required this.card,
    required this.line,
    required this.divider,
    required this.body,
    required this.ink,
    required this.fill,
    required this.onFill,
    required this.bar,
    required this.glass,
    required this.glassBorder,
    required this.track,
  });

  /// Фон экрана.
  final Color bg;
  final Color text;

  /// Второстепенный текст и значки.
  final Color muted;

  /// Кнопки-плашки, поле поиска, выбранный пункт меню.
  final Color raised;

  /// Карточки (очередь, настройки).
  final Color card;

  /// Обводки кнопок, дорожки прогресса.
  final Color line;
  final Color divider;

  /// Текст описаний.
  final Color body;

  /// Акцентный текст: ссылки, активная вкладка.
  final Color ink;

  /// Заливка главной кнопки и текст/значок на ней.
  final Color fill;
  final Color onFill;

  /// Полосы прогресса.
  final Color bar;

  /// Матовое стекло мини-плеера.
  final Color glass;
  final Color glassBorder;

  /// Дорожка ползунка на стекле.
  final Color track;

  static const dark = BcColors(
    bg: Color(0xFF161616),
    text: Color(0xFFF5F5F2),
    muted: Color(0xFFA3A3A0),
    raised: Color(0xFF262626),
    card: Color(0xFF1F1F1F),
    line: Color(0xFF3A3A3A),
    divider: Color(0xFF2A2A2A),
    body: Color(0xFFDCDCD8),
    ink: Color(0xFFC5F52E),
    fill: Color(0xFFC5F52E),
    onFill: Color(0xFF161616),
    bar: Color(0xFFC5F52E),
    glass: Color(0x8C303030),
    glassBorder: Color(0x14FFFFFF),
    track: Color(0x2EFFFFFF),
  );

  static const light = BcColors(
    bg: Color(0xFFF6F6F2),
    text: Color(0xFF161616),
    muted: Color(0xFF66665F),
    raised: Color(0xFFE9E9E3),
    card: Color(0xFFEEEEE8),
    line: Color(0xFFD3D3CC),
    divider: Color(0xFFE4E4DE),
    body: Color(0xFF3A3A36),
    ink: Color(0xFF4A7300),
    fill: Color(0xFF557F00),
    onFill: Color(0xFFFFFFFF),
    bar: Color(0xFF557F00),
    glass: Color(0x9EFFFFFF),
    glassBorder: Color(0x0F000000),
    track: Color(0x1F000000),
  );

  static BcColors of(BuildContext context) =>
      Theme.of(context).extension<BcColors>() ?? (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  BcColors copyWith() => this;

  @override
  BcColors lerp(BcColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return BcColors(
      bg: l(bg, other.bg),
      text: l(text, other.text),
      muted: l(muted, other.muted),
      raised: l(raised, other.raised),
      card: l(card, other.card),
      line: l(line, other.line),
      divider: l(divider, other.divider),
      body: l(body, other.body),
      ink: l(ink, other.ink),
      fill: l(fill, other.fill),
      onFill: l(onFill, other.onFill),
      bar: l(bar, other.bar),
      glass: l(glass, other.glass),
      glassBorder: l(glassBorder, other.glassBorder),
      track: l(track, other.track),
    );
  }
}

/// Шрифт заголовков (Unbounded) и основной шрифт (Golos Text).
const displayFont = 'Unbounded';
const bodyFont = 'GolosText';

/// Крупный заголовок экрана: «Библиотека», «Поиск».
TextStyle screenTitleStyle(BuildContext context) => TextStyle(
      fontFamily: displayFont,
      fontWeight: FontWeight.w600,
      fontSize: 26,
      letterSpacing: -0.5,
      height: 1.2,
      color: BcColors.of(context).text,
    );

/// Заголовок раздела: «Подписки», «Новые эпизоды».
TextStyle sectionTitleStyle(BuildContext context) => TextStyle(
      fontFamily: displayFont,
      fontWeight: FontWeight.w500,
      fontSize: 17,
      height: 1.25,
      color: BcColors.of(context).text,
    );

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? BcColors.dark : BcColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.fill,
    onPrimary: c.onFill,
    primaryContainer: c.raised,
    onPrimaryContainer: c.text,
    secondary: c.fill,
    onSecondary: c.onFill,
    secondaryContainer: c.raised,
    onSecondaryContainer: c.text,
    tertiary: c.ink,
    onTertiary: c.onFill,
    error: brightness == Brightness.dark ? const Color(0xFFFF8A7A) : const Color(0xFFB3261E),
    onError: brightness == Brightness.dark ? const Color(0xFF3B0A05) : Colors.white,
    surface: c.bg,
    onSurface: c.text,
    onSurfaceVariant: c.muted,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.card,
    surfaceContainer: c.card,
    surfaceContainerHigh: c.raised,
    surfaceContainerHighest: c.raised,
    outline: c.line,
    outlineVariant: c.divider,
    inverseSurface: c.text,
    onInverseSurface: c.bg,
    inversePrimary: c.ink,
    surfaceTint: Colors.transparent,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: bodyFont);
  TextStyle display(TextStyle? s, FontWeight w) =>
      (s ?? const TextStyle()).copyWith(fontFamily: displayFont, fontWeight: w);
  final text = base.textTheme.copyWith(
    displayLarge: display(base.textTheme.displayLarge, FontWeight.w600),
    displayMedium: display(base.textTheme.displayMedium, FontWeight.w600),
    displaySmall: display(base.textTheme.displaySmall, FontWeight.w600),
    headlineLarge: display(base.textTheme.headlineLarge, FontWeight.w600),
    headlineMedium: display(base.textTheme.headlineMedium, FontWeight.w600),
    headlineSmall: display(base.textTheme.headlineSmall, FontWeight.w600),
    titleLarge: display(base.textTheme.titleLarge, FontWeight.w500).copyWith(fontSize: 19),
  );
  return base.copyWith(
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    textTheme: text.apply(bodyColor: c.text, displayColor: c.text),
    extensions: [c],
    dividerTheme: DividerThemeData(color: c.divider, space: 1, thickness: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 19, color: c.text),
    ),
    iconTheme: IconThemeData(color: c.text),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.ink, textStyle: const TextStyle(fontWeight: FontWeight.w500)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.fill,
        foregroundColor: c.onFill,
        textStyle: const TextStyle(fontFamily: bodyFont, fontWeight: FontWeight.w600, fontSize: 15),
        minimumSize: const Size(0, 44),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: c.line, width: 1.5),
        textStyle: const TextStyle(fontFamily: bodyFont, fontWeight: FontWeight.w600, fontSize: 15),
        minimumSize: const Size(0, 44),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.bar, linearTrackColor: c.line, circularTrackColor: Colors.transparent),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.bar,
      inactiveTrackColor: c.track,
      thumbColor: c.bar,
      overlayColor: c.bar.withValues(alpha: 0.12),
      trackHeight: 4,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onFill : c.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.fill : c.line),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: c.fill,
      labelStyle: TextStyle(fontFamily: bodyFont, fontWeight: FontWeight.w500, fontSize: 14, color: c.text),
      secondaryLabelStyle: TextStyle(fontFamily: bodyFont, fontWeight: FontWeight.w600, fontSize: 14, color: c.onFill),
      side: BorderSide(color: c.line),
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    listTileTheme: ListTileThemeData(iconColor: c.muted, textColor: c.text),
    dialogTheme: DialogThemeData(backgroundColor: c.card, surfaceTintColor: Colors.transparent),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: c.card, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(color: c.raised, surfaceTintColor: Colors.transparent),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.text,
      contentTextStyle: TextStyle(fontFamily: bodyFont, color: c.bg),
      actionTextColor: brightness == Brightness.dark ? const Color(0xFF557F00) : c.fill,
      behavior: SnackBarBehavior.floating,
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: TextStyle(color: c.muted),
    ),
  );
}

/// Матовое стекло: размытое содержимое под панелью и полупрозрачная заливка.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 16, this.blur = 24});

  final Widget child;
  final double radius;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final shape = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.glass,
            borderRadius: shape,
            border: Border.all(color: c.glassBorder),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Круглая кнопка со значком: плашка (`filled`), обводка или прозрачная.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 44,
    this.iconSize = 22,
    this.style = RoundStyle.plain,
    this.color,
  });

  /// `IconData`, [BcIcons] или готовый виджет.
  final Object icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final RoundStyle style;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final (bg, fg, border) = switch (style) {
      RoundStyle.plain => (Colors.transparent, color ?? c.text, null),
      RoundStyle.raised => (c.raised, color ?? c.text, null),
      RoundStyle.outline => (Colors.transparent, color ?? c.text, BorderSide(color: c.line, width: 1.5)),
      RoundStyle.accent => (c.fill, c.onFill, null),
    };
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          color: bg,
          shape: CircleBorder(side: border ?? BorderSide.none),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Center(child: anyIcon(icon, size: iconSize, color: fg)),
          ),
        ),
      ),
    );
  }
}

enum RoundStyle { plain, raised, outline, accent }

/// Тонкая полоса прогресса: [value] от 0 до 1.
class ThinProgress extends StatelessWidget {
  const ThinProgress({super.key, required this.value, this.width, this.height = 3});

  final double value;
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: Stack(children: [
          Positioned.fill(child: ColoredBox(color: c.line)),
          FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            heightFactor: 1,
            child: ColoredBox(color: c.bar),
          ),
        ]),
      ),
    );
  }
}

/// Ключ настройки темы: `system`, `light` или `dark`.
const themeSettingKey = 'ui.theme';

ThemeMode themeModeFrom(String? value) => switch (value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
