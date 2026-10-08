/// Добавление книг: файлы (текстовые и аудио) и папки с аудиокнигами.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../books/book_scanner.dart';
import '../../books/text/text_parser.dart';
import '../../platform/books_platform.dart';
import '../app_scope.dart';
import '../format.dart';

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

/// Выбрать файлы книг. Текстовые — каждая отдельной книгой;
/// аудиофайлы, выбранные вместе, — одна книга.
Future<void> pickBookFiles(BuildContext context) async {
  final library = AppScope.of(context).books;
  if (library == null) return;
  final List<String> paths;
  try {
    paths = await pickFilesForBooks();
  } catch (e) {
    if (context.mounted) _snack(context, 'Не удалось открыть выбор файлов: $e');
    return;
  }
  if (paths.isEmpty) return;
  final texts = paths.where((x) => textFormatOf(x) != null).toList();
  final audio = paths.where(isAudioFile).toList();
  final other = paths.length - texts.length - audio.length;

  var added = 0;
  final errors = <String>[];
  for (final path in texts) {
    try {
      await library.importTextFile(path);
      added++;
    } on FormatException catch (e) {
      errors.add('${p.basename(path)}: ${e.message}');
    } catch (e) {
      errors.add('${p.basename(path)}: $e');
    }
  }
  if (audio.isNotEmpty) {
    try {
      final id = await library.addAudioFiles(audio);
      if (id != null) added++;
    } catch (e) {
      errors.add('Аудиофайлы: $e');
    }
  }
  if (!context.mounted) return;
  final parts = [
    if (added > 0) 'Добавлено: $added ${plural(added, 'книга', 'книги', 'книг')}',
    if (other > 0) 'пропущено файлов другого формата: $other (нужны EPUB, FB2, TXT или аудио)',
    ...errors,
  ];
  if (parts.isNotEmpty) _snack(context, parts.join('. '));
}

/// Добавить папку с аудиокнигами: каждая подпапка — отдельная книга.
Future<void> pickBookFolder(BuildContext context) async {
  final library = AppScope.of(context).books;
  if (library == null) return;
  if (!await requestMediaPermission()) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: const Text('Без доступа к аудиофайлам приложение не увидит книги в папке.'),
        action: SnackBarAction(label: 'Настройки', onPressed: openAppSettings),
      ));
    }
    return;
  }
  String? path;
  try {
    path = await pickFolderForBooks();
  } catch (e) {
    if (context.mounted) _snack(context, 'Не удалось открыть выбор папки: $e');
    return;
  }
  if (path == null) return;
  if (!await Directory(path).exists()) {
    if (context.mounted) _snack(context, 'Папка недоступна: $path');
    return;
  }
  final found = await library.addSource(path);
  if (!context.mounted) return;
  _snack(
    context,
    found == 0
        ? 'В папке не нашлось аудиокниг. Каждая книга — отдельная подпапка с аудиофайлами.'
        : 'Найдено: $found ${plural(found, 'книга', 'книги', 'книг')}',
  );
}

/// Перед проверкой папок на Android — убедиться, что разрешение ещё есть.
Future<void> rescanBookSources(BuildContext context) async {
  final scope = AppScope.of(context);
  final library = scope.books;
  if (library == null) return;
  final sources = await scope.db.select(scope.db.bookSources).get();
  if (sources.isNotEmpty && !await mediaPermissionGranted()) return;
  await library.rescanAll();
}
