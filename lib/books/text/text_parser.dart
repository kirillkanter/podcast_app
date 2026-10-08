import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'epub_parser.dart';
import 'fb2_parser.dart';
import 'text_book.dart';
import 'txt_parser.dart';

/// Форматы текстовых книг (расширения файлов).
const textBookFormats = {'epub', 'fb2', 'fbz', 'txt'};

/// Формат по имени файла: «книга.fb2.zip» → fbz.
String? textFormatOf(String path) {
  final name = p.basename(path).toLowerCase();
  if (name.endsWith('.fb2.zip')) return 'fbz';
  final ext = p.extension(name).replaceFirst('.', '');
  return textBookFormats.contains(ext) ? ext : null;
}

/// Разобрать книгу. Бросает [FormatException], если файл не читается.
TextBookContent parseTextBook(Uint8List bytes, String format, {required String fallbackTitle}) {
  try {
    return switch (format) {
      'epub' => parseEpub(bytes, fallbackTitle: fallbackTitle),
      'fb2' => parseFb2(bytes, fallbackTitle: fallbackTitle),
      'fbz' => parseFbz(bytes, fallbackTitle: fallbackTitle),
      _ => parseTxt(bytes, fallbackTitle: fallbackTitle),
    };
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('Не удалось прочитать книгу: $e');
  }
}
