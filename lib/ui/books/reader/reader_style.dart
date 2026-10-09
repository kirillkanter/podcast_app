import 'package:flutter/material.dart';

import '../../../data/db/books_dao.dart';
import '../../../data/db/database.dart';

/// Фон страницы.
enum Paper {
  dark('Тёмный', Color(0xFF161616), Color(0xFFD6D6D0), Color(0xFF7A7A73)),
  light('Светлый', Color(0xFFF6F6F2), Color(0xFF24241F), Color(0xFF8A8A82)),
  sepia('Сепия', Color(0xFFF1E7D2), Color(0xFF3B2F22), Color(0xFF8C7B63));

  const Paper(this.label, this.bg, this.ink, this.faint);

  final String label;
  final Color bg;
  final Color ink;
  final Color faint;
}

enum ReaderFont {
  serif('PT Serif', 'PTSerif', 'с засечками'),
  sans('Golos', 'GolosText', 'без засечек'),
  dyslexic('OpenDyslexic', 'OpenDyslexic', 'при дислексии');

  const ReaderFont(this.label, this.family, this.hint);

  final String label;
  final String family;
  final String hint;
}

const _spreadKey = 'reader.landscapeSpread';
const _turnKey = 'reader.pageTurn';
const _ribbonKey = 'reader.bookmarkColor';
const _marginKey = 'reader.margin';
const _justifyKey = 'reader.justify';
const _fullKey = 'reader.fullscreen';
const _volumeKey = 'reader.volumeKeys';

/// Цвета выделений текста: жёлтый, зелёный, голубой, розовый.
const highlightColors = [Color(0xFFF5D547), Color(0xFF8FD694), Color(0xFF7FB8F0), Color(0xFFF29BC0)];

/// Поля страницы: узкие, обычные, широкие (множитель к обычным).
const readerMargins = [0.45, 1.0, 1.75];

/// Как листается страница.
enum PageTurn {
  none('Без анимации'),
  slide('Сдвиг'),
  fade('Плавно');

  const PageTurn(this.label);
  final String label;
}

/// Цвета ленточки закладки; `null` — акцентный цвет приложения.
const bookmarkColors = <Color?>[
  null,
  Color(0xFFE0533D),
  Color(0xFFF0A23B),
  Color(0xFF3D7FE0),
  Color(0xFF8E5BD6),
  Color(0xFF2FA36B),
];

/// Размеры шрифта (шаги кнопок «A−» и «A+»).
const readerSizes = [14.0, 15.0, 16.0, 17.0, 18.0, 20.0, 22.0, 24.0, 27.0];

/// Межстрочный интервал: плотно, обычно, свободно.
const readerSpacings = [1.35, 1.55, 1.8];

@immutable
class ReaderStyle {
  const ReaderStyle({
    this.size = 4,
    this.font = ReaderFont.serif,
    this.paper,
    this.spacing = 1,
    this.landscapeSpread = false,
    this.pageTurn = PageTurn.slide,
    this.bookmarkColor = 0,
    this.margin = 1,
    this.justify = true,
    this.fullscreen = true,
    this.volumeKeys = true,
  });

  /// Индекс в [readerSizes].
  final int size;
  final ReaderFont font;

  /// `null` — по теме приложения.
  final Paper? paper;

  /// Индекс в [readerSpacings].
  final int spacing;

  /// Две колонки, когда телефон повёрнут набок.
  final bool landscapeSpread;

  final PageTurn pageTurn;

  /// Индекс в [readerMargins].
  final int margin;

  /// Выравнивание абзацев по ширине (иначе — по левому краю).
  final bool justify;

  /// Прятать системные строки (время, значки) во время чтения.
  final bool fullscreen;

  /// Листать кнопками громкости (Android): «тише» — вперёд, «громче» — назад.
  final bool volumeKeys;

  double get marginFactor => readerMargins[margin.clamp(0, readerMargins.length - 1)];

  /// Индекс в [bookmarkColors].
  final int bookmarkColor;

  /// Цвет ленточки; [accent] — если выбран цвет приложения.
  Color ribbonColor(Color accent) => bookmarkColors[bookmarkColor.clamp(0, bookmarkColors.length - 1)] ?? accent;

  double get fontSize => readerSizes[size.clamp(0, readerSizes.length - 1)];
  double get lineHeight => readerSpacings[spacing.clamp(0, readerSpacings.length - 1)];

  Paper paperFor(Brightness brightness) => paper ?? (brightness == Brightness.dark ? Paper.dark : Paper.light);

  /// Ключ для кэша разбивки на страницы.
  String get layoutKey => '$size/${font.name}/$spacing/$margin/$justify';

  ReaderStyle copyWith({
    int? size,
    ReaderFont? font,
    Paper? paper,
    int? spacing,
    bool? landscapeSpread,
    PageTurn? pageTurn,
    int? bookmarkColor,
    int? margin,
    bool? justify,
    bool? fullscreen,
    bool? volumeKeys,
    bool autoPaper = false,
  }) =>
      ReaderStyle(
        size: size ?? this.size,
        font: font ?? this.font,
        paper: autoPaper ? null : (paper ?? this.paper),
        spacing: spacing ?? this.spacing,
        landscapeSpread: landscapeSpread ?? this.landscapeSpread,
        pageTurn: pageTurn ?? this.pageTurn,
        bookmarkColor: bookmarkColor ?? this.bookmarkColor,
        margin: margin ?? this.margin,
        justify: justify ?? this.justify,
        fullscreen: fullscreen ?? this.fullscreen,
        volumeKeys: volumeKeys ?? this.volumeKeys,
      );

  static Future<ReaderStyle> load(AppDatabase db) async {
    final size = int.tryParse(await db.setting(BookSettings.readerSize) ?? '');
    final font = await db.setting(BookSettings.readerFont);
    final paper = await db.setting(BookSettings.readerPaper);
    final spacing = int.tryParse(await db.setting(BookSettings.readerSpacing) ?? '');
    final spread = await db.setting(_spreadKey);
    final turn = await db.setting(_turnKey);
    final ribbon = int.tryParse(await db.setting(_ribbonKey) ?? '');
    final margin = int.tryParse(await db.setting(_marginKey) ?? '');
    final justify = await db.setting(_justifyKey);
    final full = await db.setting(_fullKey);
    final volume = await db.setting(_volumeKey);
    return ReaderStyle(
      volumeKeys: volume != 'false',
      fullscreen: full != 'false',
      margin: margin ?? 1,
      justify: justify != 'false',
      landscapeSpread: spread == 'true',
      pageTurn: PageTurn.values.where((t) => t.name == turn).firstOrNull ?? PageTurn.slide,
      bookmarkColor: ribbon ?? 0,
      size: size ?? 4,
      font: ReaderFont.values.where((f) => f.name == font).firstOrNull ?? ReaderFont.serif,
      paper: Paper.values.where((p) => p.name == paper).firstOrNull,
      spacing: spacing ?? 1,
    );
  }

  Future<void> save(AppDatabase db) async {
    await db.setSetting(BookSettings.readerSize, '$size');
    await db.setSetting(BookSettings.readerFont, font.name);
    await db.setSetting(BookSettings.readerPaper, paper?.name ?? '');
    await db.setSetting(BookSettings.readerSpacing, '$spacing');
    await db.setSetting(_spreadKey, '$landscapeSpread');
    await db.setSetting(_turnKey, pageTurn.name);
    await db.setSetting(_ribbonKey, '$bookmarkColor');
    await db.setSetting(_marginKey, '$margin');
    await db.setSetting(_justifyKey, '$justify');
    await db.setSetting(_fullKey, '$fullscreen');
    await db.setSetting(_volumeKey, '$volumeKeys');
  }
}
