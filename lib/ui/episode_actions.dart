/// Действия с эпизодом из списков: очередь, архив, «прослушан», загрузка —
/// кнопками и свайпами.
library;

import 'package:flutter/material.dart';

import '../data/db/database.dart';
import 'app_scope.dart';
import 'icons.dart';
import 'theme.dart';

/// Что нужно знать об эпизоде, чтобы показать и выполнить действие.
class EpisodeRef {
  const EpisodeRef({
    required this.id,
    this.queued = false,
    this.archived = false,
    this.played = false,
    this.positionMs = 0,
    this.download,
  });

  final int id;
  final bool queued;
  final bool archived;
  final bool played;

  /// Позиция прослушивания — чтобы «Отменить» вернул её после отметки.
  final int positionMs;
  final Download? download;
}

extension FeedEpisodeRef on FeedEpisode {
  EpisodeRef get ref => EpisodeRef(
        id: episode.id,
        queued: queued,
        archived: archived,
        played: state?.played ?? false,
        positionMs: state?.positionMs ?? 0,
        download: download,
      );

  EpisodeWithState get withState =>
      (episode: episode, state: state, download: download, queued: queued, archived: archived);
}

extension EpisodeWithStateRef on EpisodeWithState {
  EpisodeRef get ref => EpisodeRef(
        id: episode.id,
        queued: queued,
        archived: archived,
        played: state?.played ?? false,
        positionMs: state?.positionMs ?? 0,
        download: download,
      );
}

abstract final class EpisodeActions {
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _say(
    BuildContext context,
    String text, {
    VoidCallback? undo,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    return messenger?.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 3),
      // С кнопкой «Отменить» SnackBar по умолчанию висит, пока его не смахнут.
      persist: false,
      action: undo == null ? null : SnackBarAction(label: 'Отменить', onPressed: undo),
    ));
  }

  static Future<void> toggleQueue(BuildContext context, EpisodeRef e) async {
    final db = AppScope.of(context).db;
    if (e.queued) {
      await db.removeFromQueue(e.id);
      if (context.mounted) _say(context, 'Убрано из очереди', undo: () => db.addToQueue(e.id));
    } else {
      await db.addToQueue(e.id);
      if (context.mounted) _say(context, 'Добавлено в очередь', undo: () => db.removeFromQueue(e.id));
    }
  }

  static Future<void> playNext(BuildContext context, EpisodeRef e) async {
    await AppScope.of(context).db.addToQueue(e.id, next: true);
    if (context.mounted) _say(context, 'Будет следующим в очереди');
  }

  static Future<void> toggleArchive(BuildContext context, EpisodeRef e) async {
    final db = AppScope.of(context).db;
    if (e.archived) {
      await db.setArchived(e.id, false);
      if (context.mounted) _say(context, 'Возвращено из архива');
    } else {
      await db.setArchived(e.id, true);
      if (context.mounted) {
        _say(context, 'Эпизод в архиве', undo: () async {
          await db.setArchived(e.id, false);
          if (e.queued) await db.addToQueue(e.id);
        });
      }
    }
  }

  static Future<void> togglePlayed(BuildContext context, EpisodeRef e) async {
    final scope = AppScope.of(context);
    final db = scope.db;
    if (e.played) {
      await db.setPlayed(e.id, false);
      if (context.mounted) _say(context, 'Отметка снята', undo: () => db.setPlayed(e.id, true));
      return;
    }
    await db.setPlayed(e.id, true);
    if (!context.mounted) return;
    final bar = _say(context, 'Отмечено прослушанным', undo: () async {
      // Как было: позиция, архив, место в очереди.
      await db.setPlayed(e.id, false);
      if (e.positionMs > 0) await db.savePosition(e.id, Duration(milliseconds: e.positionMs));
      if (e.archived) await db.setArchived(e.id, true);
      if (e.queued) await db.addToQueue(e.id);
    });
    // Загрузку прослушанного удаляем, только когда отмена уже невозможна.
    final reason = await bar?.closed;
    if (reason != SnackBarClosedReason.action) await scope.downloads?.onPlayed(e.id);
  }

  static Future<void> download(BuildContext context, EpisodeRef e) async {
    final downloads = AppScope.of(context).downloads;
    if (downloads == null) return;
    switch (e.download?.status) {
      case DownloadStatus.completed:
        _say(context, 'Уже загружен');
      case DownloadStatus.queued || DownloadStatus.running:
        _say(context, 'Уже загружается');
      case DownloadStatus.failed:
        await downloads.retry(e.id);
      case null || DownloadStatus.removed:
        await downloads.enqueue(e.id);
        if (context.mounted) _say(context, 'Загрузка начата');
    }
  }

  static Future<void> run(BuildContext context, SwipeAction action, EpisodeRef e) => switch (action) {
        SwipeAction.archive => toggleArchive(context, e),
        SwipeAction.queue => toggleQueue(context, e),
        SwipeAction.played => togglePlayed(context, e),
        SwipeAction.download => download(context, e),
        SwipeAction.none => Future<void>.value(),
      };

  /// Подпись и значок действия для эпизода в его текущем состоянии.
  static (String, BcIcons) look(SwipeAction action, EpisodeRef e) => switch (action) {
        SwipeAction.archive =>
          e.archived ? ('Из архива', BcIcons.unarchive) : ('В архив', BcIcons.archive),
        SwipeAction.queue =>
          e.queued ? ('Из очереди', BcIcons.queueRemove) : ('В очередь', BcIcons.queue),
        SwipeAction.played =>
          e.played ? ('Не прослушан', BcIcons.uncheck) : ('Прослушан', BcIcons.check),
        SwipeAction.download => ('Скачать', BcIcons.download),
        SwipeAction.none => ('', BcIcons.close),
      };
}

/// Настройки свайпов для всех списков; ставится один раз в каркасе.
class SwipeSettingsScope extends InheritedWidget {
  const SwipeSettingsScope({super.key, required this.left, required this.right, required super.child});

  /// Свайп справа налево.
  final SwipeAction left;

  /// Свайп слева направо.
  final SwipeAction right;

  static const defaultLeft = SwipeAction.archive;
  static const defaultRight = SwipeAction.queue;

  static SwipeSettingsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SwipeSettingsScope>();

  @override
  bool updateShouldNotify(SwipeSettingsScope oldWidget) => left != oldWidget.left || right != oldWidget.right;
}

/// Читает настройки свайпов из базы и передаёт их вниз по дереву.
class SwipeSettingsProvider extends StatelessWidget {
  const SwipeSettingsProvider({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final db = AppScope.of(context).db;
    return StreamBuilder<String?>(
      stream: db.watchSetting(QueueSettings.swipeLeft),
      builder: (context, left) => StreamBuilder<String?>(
        stream: db.watchSetting(QueueSettings.swipeRight),
        builder: (context, right) => SwipeSettingsScope(
          left: SwipeAction.parse(left.data, SwipeSettingsScope.defaultLeft),
          right: SwipeAction.parse(right.data, SwipeSettingsScope.defaultRight),
          child: child,
        ),
      ),
    );
  }
}

/// Строка эпизода со свайпами влево и вправо. Строка возвращается на место,
/// а список обновится сам, если эпизод из него ушёл (архив).
class SwipeableEpisode extends StatefulWidget {
  const SwipeableEpisode({super.key, required this.episode, required this.child, this.left, this.right});

  final EpisodeRef episode;
  final Widget child;

  /// Действия вместо настроек (например, в очереди свайп только убирает).
  final SwipeAction? left;
  final SwipeAction? right;

  @override
  State<SwipeableEpisode> createState() => _SwipeableEpisodeState();
}

class _SwipeableEpisodeState extends State<SwipeableEpisode> {
  /// Насколько далеко дотянули строку (0…1). Действие срабатывает, только
  /// если дотянули до порога: быстрый короткий мах не считается.
  double _progress = 0;

  static const _threshold = 0.45;

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final child = widget.child;
    final scope = SwipeSettingsScope.maybeOf(context);
    final left = widget.left ?? scope?.left ?? SwipeSettingsScope.defaultLeft;
    final right = widget.right ?? scope?.right ?? SwipeSettingsScope.defaultRight;
    final c = BcColors.of(context);
    final row = Material(color: c.bg, child: child);
    if (left == SwipeAction.none && right == SwipeAction.none) return row;
    return Dismissible(
      key: ValueKey('swipe-${episode.id}'),
      direction: left == SwipeAction.none
          ? DismissDirection.startToEnd
          : right == SwipeAction.none
              ? DismissDirection.endToStart
              : DismissDirection.horizontal,
      dismissThresholds: const {
        DismissDirection.startToEnd: _threshold,
        DismissDirection.endToStart: _threshold,
      },
      onUpdate: (d) => _progress = d.progress,
      confirmDismiss: (direction) async {
        final far = _progress >= _threshold;
        _progress = 0;
        if (!far) return false;
        final action = direction == DismissDirection.endToStart ? left : right;
        await EpisodeActions.run(context, action, episode);
        return false;
      },
      background: _SwipeBackground(look: EpisodeActions.look(right, episode), alignEnd: false),
      secondaryBackground: _SwipeBackground(look: EpisodeActions.look(left, episode), alignEnd: true),
      child: row,
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.look, required this.alignEnd});

  final (String, BcIcons) look;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return ColoredBox(
      color: c.fill,
      child: Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: SizedBox(
          width: 112,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BcIcon(look.$2, color: c.onFill, size: 22),
            const SizedBox(height: 6),
            Text(look.$1, style: TextStyle(color: c.onFill, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// Кнопки «в очередь» и «в архив» в строке эпизода (компьютер и страница подкаста).
class QueueArchiveButtons extends StatelessWidget {
  const QueueArchiveButtons({super.key, required this.episode, this.size = 40});

  final EpisodeRef episode;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final (queueLabel, queueIcon) = EpisodeActions.look(SwipeAction.queue, episode);
    final (archiveLabel, archiveIcon) = EpisodeActions.look(SwipeAction.archive, episode);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      RoundIconButton(
        icon: queueIcon,
        tooltip: queueLabel,
        size: size,
        iconSize: 21,
        color: episode.queued ? c.ink : c.muted,
        onPressed: () => EpisodeActions.toggleQueue(context, episode),
      ),
      RoundIconButton(
        icon: archiveIcon,
        tooltip: archiveLabel,
        size: size,
        iconSize: 21,
        color: c.muted,
        onPressed: () => EpisodeActions.toggleArchive(context, episode),
      ),
    ]);
  }
}
