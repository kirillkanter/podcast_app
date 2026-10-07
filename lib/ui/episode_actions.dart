/// Действия с эпизодом из списков: очередь, архив, «прослушан», загрузка —
/// кнопками и свайпами.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    // Ждём это в фоне — вызывающий код (свайп) не должен висеть.
    unawaited(bar?.closed.then((reason) async {
      if (reason != SnackBarClosedReason.action) await scope.downloads?.onPlayed(e.id);
    }));
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

/// Строка эпизода со свайпами влево и вправо.
///
/// Строка тянется за пальцем. Пока порог не пройден, подложка серая;
/// как только пройден — она загорается акцентным цветом, значок
/// увеличивается и телефон коротко вибрирует. Действие выполняется,
/// только если отпустить строку за порогом; резкий мах не считается.
/// После этого строка сразу возвращается на место.
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

class _SwipeableEpisodeState extends State<SwipeableEpisode> with SingleTickerProviderStateMixin {
  /// Порог — доля ширины строки.
  static const _threshold = 0.35;

  double _dx = 0;
  double _from = 0;
  bool _armed = false;
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() => setState(() => _dx = _from * (1 - Curves.easeOutCubic.transform(_back.value))));

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  double get _width => context.size?.width ?? 400;

  void _update(DragUpdateDetails d, SwipeAction left, SwipeAction right) {
    _back.stop();
    var dx = _dx + d.delta.dx;
    // В сторону, где действия нет, строка не тянется.
    if (left == SwipeAction.none && dx < 0) dx = 0;
    if (right == SwipeAction.none && dx > 0) dx = 0;
    final armed = dx.abs() >= _width * _threshold;
    if (armed != _armed) HapticFeedback.selectionClick();
    setState(() {
      _dx = dx.clamp(-_width, _width);
      _armed = armed;
    });
  }

  void _end(SwipeAction left, SwipeAction right) {
    if (_armed) {
      final action = _dx < 0 ? left : right;
      // Не ждём: подтверждение и «Отменить» живут сами по себе,
      // а строка сразу возвращается на место.
      unawaited(EpisodeActions.run(context, action, widget.episode));
    }
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final scope = SwipeSettingsScope.maybeOf(context);
    final left = widget.left ?? scope?.left ?? SwipeSettingsScope.defaultLeft;
    final right = widget.right ?? scope?.right ?? SwipeSettingsScope.defaultRight;
    final c = BcColors.of(context);
    final row = Material(color: c.bg, child: widget.child);
    if (left == SwipeAction.none && right == SwipeAction.none) return row;
    final action = _dx < 0 ? left : right;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _back.stop(),
      onHorizontalDragUpdate: (d) => _update(d, left, right),
      onHorizontalDragEnd: (_) => _end(left, right),
      onHorizontalDragCancel: () => _end(SwipeAction.none, SwipeAction.none),
      child: Stack(children: [
        if (_dx != 0)
          Positioned.fill(
            child: _SwipeBackground(
              look: EpisodeActions.look(action, widget.episode),
              alignEnd: _dx < 0,
              armed: _armed,
            ),
          ),
        Transform.translate(offset: Offset(_dx, 0), child: row),
      ]),
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.look, required this.alignEnd, required this.armed});

  final (String, BcIcons) look;
  final bool alignEnd;

  /// Порог пройден: отпустите — и действие выполнится.
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final fg = armed ? c.onFill : c.muted;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      color: armed ? c.fill : c.raised,
      child: Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: SizedBox(
          width: 112,
          child: AnimatedScale(
            scale: armed ? 1.12 : 1,
            duration: const Duration(milliseconds: 150),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              BcIcon(look.$2, color: fg, size: 22),
              const SizedBox(height: 6),
              Text(look.$1, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
          ),
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
