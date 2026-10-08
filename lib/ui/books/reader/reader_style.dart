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
  sans('Golos', 'GolosText', 'без засечек');

  const ReaderFont(this.label, this.family, this.hint);

  final String label;
  final String family;
  final String hint;
}

/// Размеры шрифта (шаги кнопок «A−» и «A+»).
const readerSizes = [14.0, 15.0, 16.0, 17.0, 18.0, 20.0, 22.0, 24.0, 27.0];

/// Межстрочный интервал: плотно, обычно, свободно.
const readerSpacings = [1.35, 1.55, 1.8];

@immutable
class ReaderStyle {
  const ReaderStyle({this.size = 4, this.font = ReaderFont.serif, this.paper, this.spacing = 1});

  /// Индекс в [readerSizes].
  final int size;
  final ReaderFont font;

  /// `null` — по теме приложения.
  final Paper? paper;

  /// Индекс в [readerSpacings].
  final int spacing;

  double get fontSize => readerSizes[size.clamp(0, readerSizes.length - 1)];
  double get lineHeight => readerSpacings[spacing.clamp(0, readerSpacings.length - 1)];

  Paper paperFor(Brightness brightness) => paper ?? (brightness == Brightness.dark ? Paper.dark : Paper.light);

  /// Ключ для кэша разбивки на страницы.
  String get layoutKey => '$size/${font.name}/$spacing';

  ReaderStyle copyWith({int? size, ReaderFont? font, Paper? paper, int? spacing}) => ReaderStyle(
        size: size ?? this.size,
        font: font ?? this.font,
        paper: paper ?? this.paper,
        spacing: spacing ?? this.spacing,
      );

  static Future<ReaderStyle> load(AppDatabase db) async {
    final size = int.tryParse(await db.setting(BookSettings.readerSize) ?? '');
    final font = await db.setting(BookSettings.readerFont);
    final paper = await db.setting(BookSettings.readerPaper);
    final spacing = int.tryParse(await db.setting(BookSettings.readerSpacing) ?? '');
    return ReaderStyle(
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
  }
}
