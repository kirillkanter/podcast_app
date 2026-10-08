/// Запуск книги со сверкой места на других устройствах.
///
/// Перед тем как включить аудиокнигу или открыть текстовую, приложение
/// спрашивает у сервера, где в этой книге остановились в последний раз.
/// Если на другом устройстве место новее и отличается — человек выбирает,
/// откуда продолжить. Если сервер не ответил — об этом говорится прямо,
/// с выбором «повторить» или «продолжить здесь».
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../books/book_timeline.dart';
import '../../books/locator.dart';
import '../../books/text/text_book.dart';
import '../../data/db/books_dao.dart';
import '../../data/db/database.dart';
import '../../player/playback_logic.dart';
import '../../sync/book_sync.dart';
import '../app_scope.dart';
import '../format.dart';
import '../theme.dart';
import 'book_player_screen.dart';
import 'reader/reader_screen.dart';

/// Когда последний раз сверяли книгу (чтобы не спрашивать после короткой паузы).
final _checkedAt = <int, DateTime>{};

/// Включить аудиокнигу. [chapter] — с начала этой главы.
Future<void> startAudioBook(
  BuildContext context,
  Book book, {
  BookChapter? chapter,
  AudioLocator? at,
  bool openPlayer = false,
}) async {
  final scope = AppScope.of(context);
  final audio = scope.audio;
  if (audio == null) return;
  if (book.missing) {
    _snack(context, 'Файлы книги не найдены. Проверьте, что папка с книгой доступна.');
    return;
  }
  final target = at ?? (chapter == null ? null : AudioLocator(chapter.trackIdx, chapter.startMs));
  if (audio.currentBookId == book.id && audio.playbackState.value.playing && target == null) {
    if (openPlayer) unawaited(Navigator.of(context, rootNavigator: true).push(BookPlayerScreen.route()));
    return;
  }
  if (target == null) {
    final ok = await _reconcile(context, book, describe: (locator, percent) => _describeAudio(scope.db, book, locator));
    if (!ok || !context.mounted) return;
  }
  // Место могли сменить в диалоге — плеер перечитает его из базы.
  if (audio.currentBookId == book.id && target == null) {
    await audio.playBook(book.id, at: AudioLocator.parse((await scope.db.bookProgress(book.id))?.locator));
  } else {
    await audio.playBook(book.id, at: target);
  }
  if (openPlayer && context.mounted) {
    unawaited(Navigator.of(context, rootNavigator: true).push(BookPlayerScreen.route()));
  }
}

/// Продолжить книгу после паузы (мини-плеер, плеер книги): если пауза
/// была дольше пары минут — сначала сверить место.
Future<void> resumeAudioBook(BuildContext context) async {
  final scope = AppScope.of(context);
  final audio = scope.audio;
  final bookId = audio?.currentBookId;
  if (audio == null || bookId == null) return;
  final last = _checkedAt[bookId];
  if (last != null && DateTime.now().difference(last) < const Duration(minutes: 2)) {
    await audio.play();
    return;
  }
  final book = await scope.db.bookById(bookId);
  if (book == null || !context.mounted) return;
  final before = (await scope.db.bookProgress(bookId))?.locator;
  final ok = await _reconcile(context, book, describe: (l, _) => _describeAudio(scope.db, book, l));
  if (!ok || !context.mounted) return;
  final after = (await scope.db.bookProgress(bookId))?.locator;
  if (after != null && after != before) {
    await audio.playBook(bookId, at: AudioLocator.parse(after));
  } else {
    await audio.play();
  }
}

/// Открыть текстовую книгу в читалке.
Future<void> openTextBook(BuildContext context, Book book, {int? chapter, TextLocator? at}) async {
  final scope = AppScope.of(context);
  final library = scope.books;
  if (library == null) return;
  if (book.path == null) {
    _snack(context, 'Книга ещё скачивается с сервера. Попробуйте через минуту.');
    scope.sync?.schedule(const Duration(seconds: 1));
    return;
  }
  TextBookContent content;
  try {
    content = await _withProgress(context, 'Открываю книгу…', library.openText(book));
  } catch (e) {
    if (context.mounted) _snack(context, 'Не удалось открыть книгу: $e');
    return;
  }
  if (!context.mounted) return;
  if (chapter == null && at == null) {
    final ok = await _reconcile(context, book, describe: (locator, percent) async => _describeText(content, locator, percent));
    if (!ok || !context.mounted) return;
  }
  await scope.db.markBookOpened(book.id);
  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true)
      .push(ReaderScreen.route(book: book, content: content, at: at ?? (chapter == null ? null : TextLocator(chapter, 0, 0))));
}

/// Сверить место с сервером. `false` — человек передумал (закрыл диалог).
Future<bool> _reconcile(
  BuildContext context,
  Book book, {
  required FutureOr<String> Function(String locator, double percent) describe,
}) async {
  final scope = AppScope.of(context);
  final sync = scope.bookSync;
  if (sync == null || !await sync.isConfigured) return true;
  final db = scope.db;
  while (true) {
    RemoteBookProgress? remote;
    String? error;
    try {
      if (!context.mounted) return false;
      remote = await _withProgress(context, 'Проверяю, где вы остановились…', sync.fetchRemote(book.key));
    } on BookSyncException catch (e) {
      error = e.message;
    } catch (e) {
      error = '$e';
    }
    if (!context.mounted) return false;
    if (error != null) {
      final retry = await _ask(
        context,
        title: 'Не удалось сверить место',
        text: 'Не получилось узнать, где вы остановились в этой книге на других устройствах.\n\n$error',
        cancel: 'Продолжить здесь',
        confirm: 'Повторить',
      );
      if (retry == null) return false;
      if (retry) continue;
      return true;
    }
    _checkedAt[book.id] = DateTime.now();
    if (remote == null) return true;
    final own = await sync.deviceId();
    final local = await db.bookProgress(book.id);
    if (remote.deviceId == own) return true;
    if (local != null && !local.updatedAt.isBefore(remote.changed)) return true;
    if (local != null && local.locator == remote.locator) return true;
    if (local == null && remote.percent <= 0) return true;
    if (!context.mounted) return false;

    final there = await describe(remote.locator, remote.percent);
    final here = local == null ? 'книга ещё не начата' : await describe(local.locator, local.percent);
    if (!context.mounted) return false;
    final device = remote.deviceName == null || remote.deviceName!.isEmpty ? 'другом устройстве' : '«${remote.deviceName}»';
    final go = await _ask(
      context,
      title: 'Продолжить с другого устройства?',
      text: 'На $device вы остановились ${formatAgo(remote.changed)}:\n$there\n\nНа этом устройстве:\n$here',
      cancel: 'Остаться здесь',
      confirm: 'Продолжить оттуда',
    );
    if (go == null) return false;
    if (go) {
      await db.applyRemoteBookProgress(
        book.id,
        locator: remote.locator,
        positionMs: remote.positionMs,
        percent: remote.percent,
        changed: remote.changed,
        device: remote.deviceName,
        force: true,
      );
    } else if (local != null) {
      // Остаёмся здесь: это место становится новее, другие устройства
      // предложат продолжить с него.
      await db.saveBookProgress(book.id, locator: local.locator, positionMs: local.positionMs, percent: local.percent);
      sync.pushSoon(const Duration(seconds: 1));
    }
    return true;
  }
}

Future<String> _describeAudio(AppDatabase db, Book book, String locatorText) async {
  final locator = AudioLocator.parse(locatorText);
  if (locator == null) return 'начало книги';
  final tracks = await db.bookTracks(book.id);
  final chapters = await db.bookChaptersOf(book.id);
  final t = BookTimeline(
    [for (final x in tracks) x.durationMs],
    [for (final c in chapters) (trackIdx: c.trackIdx, startMs: c.startMs)],
  );
  final g = t.globalOf(locator.track, locator.ms);
  if (chapters.isEmpty) return formatClock(Duration(milliseconds: g));
  final idx = t.chapterAt(g);
  final into = Duration(milliseconds: g - t.chapterStart(idx));
  return '${chapters[idx].title}, ${formatClock(into)}';
}

String _describeText(TextBookContent content, String locatorText, double percent) {
  final l = TextLocator.parse(locatorText);
  final p = '${(percent * 100).round()} %';
  if (l == null || l.chapter >= content.chapters.length) return p;
  return '${content.chapters[l.chapter].title}, $p книги';
}

Future<T> _withProgress<T>(BuildContext context, String text, Future<T> future) async {
  var shown = false;
  final timer = Timer(const Duration(milliseconds: 300), () {
    if (!context.mounted) return;
    shown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 18),
            Expanded(child: Text(text)),
          ]),
        ),
      ),
    );
  });
  try {
    return await future;
  } finally {
    timer.cancel();
    if (shown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// Диалог с двумя кнопками: `true` — [confirm], `false` — [cancel],
/// `null` — закрыли.
Future<bool?> _ask(
  BuildContext context, {
  required String title,
  required String text,
  required String cancel,
  required String confirm,
}) {
  return showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      final c = BcColors.of(context);
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text, style: TextStyle(fontSize: 15, height: 1.45, color: c.body))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(confirm)),
        ],
      );
    },
  );
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
