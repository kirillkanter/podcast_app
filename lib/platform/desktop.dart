// Возможности приложения для Windows: значок в трее, сворачивание
// при закрытии окна, запуск вместе с системой, горячие клавиши.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_taskbar/windows_taskbar.dart' as taskbar;

import '../data/db/database.dart';
import '../player/podcast_audio_handler.dart';

/// Ключи настроек для компьютера.
abstract final class DesktopSettings {
  /// Закрытие окна сворачивает приложение в трей. По умолчанию — да.
  static const tray = 'app.tray';
}

/// Аргумент запуска из автозагрузки: окно сразу уходит в трей.
const trayLaunchArgument = '--tray';

/// Окно и значок в трее на Windows.
class DesktopWindow with WindowListener, TrayListener {
  DesktopWindow(this._db, this._audio);

  final AppDatabase _db;
  final PodcastAudioHandler? _audio;
  bool _trayEnabled = false;
  bool _playing = false;
  StreamSubscription<String?>? _traySetting;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Object?>? _itemSub;

  Future<void> init({bool startHidden = false}) async {
    await windowManager.ensureInitialized();
    // Плагин окна сам обрабатывает WM_GETMINMAXINFO, поэтому предел
    // задаём и здесь (в пикселях интерфейса).
    await windowManager.setMinimumSize(const Size(400, 600));
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);
    _trayEnabled = await _db.setting(DesktopSettings.tray) != 'false';
    if (_trayEnabled) await _showTray();
    _traySetting = _db.watchSetting(DesktopSettings.tray).skip(1).listen((value) async {
      final on = value != 'false';
      if (on == _trayEnabled) return;
      _trayEnabled = on;
      on ? await _showTray() : await trayManager.destroy();
    });
    _playingSub = _audio?.playbackState.map((s) => s.playing).distinct().listen((playing) {
      _playing = playing;
      if (_trayEnabled) unawaited(_updateMenu());
      unawaited(_updateThumbnailButtons());
    });
    _itemSub = _audio?.mediaItem.map((i) => i?.id).distinct().listen((_) {
      unawaited(_updateThumbnailButtons());
    });
    if (startHidden && _trayEnabled) {
      // Окно показывается после первого кадра — прячем его следом.
      WidgetsBinding.instance.addPostFrameCallback((_) => windowManager.hide());
    }
  }

  Future<void> _showTray() async {
    try {
      await trayManager.setIcon('assets/images/tray.ico');
      await trayManager.setToolTip('Basic Caster');
      await _updateMenu();
    } catch (e) {
      debugPrint('Не удалось показать значок в трее: $e');
    }
  }

  Future<void> _updateMenu() => trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Открыть Basic Caster'),
        if (_audio?.currentEpisodeId != null)
          MenuItem(key: 'play', label: _playing ? 'Пауза' : 'Слушать'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Выход'),
      ]));

  Future<void> _show() async {
    await windowManager.show();
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.focus();
    // После того как окно прятали в трей, кнопка в панели задач создаётся
    // заново — вместе с ней пропадают кнопки под миниатюрой.
    unawaited(_updateThumbnailButtons());
  }

  /// Кнопки под миниатюрой окна (наведите курсор на значок в панели
  /// задач): назад, пауза или воспроизведение, вперёд.
  Future<void> _updateThumbnailButtons() async {
    final audio = _audio;
    try {
      if (audio == null || audio.currentEpisodeId == null) {
        await taskbar.WindowsTaskbar.resetThumbnailToolbar();
        return;
      }
      final back = audio.skipSteps.value.$1;
      final forward = audio.skipSteps.value.$2;
      await taskbar.WindowsTaskbar.setThumbnailToolbar([
        taskbar.ThumbnailToolbarButton(
          taskbar.ThumbnailToolbarAssetIcon('assets/taskbar/rewind.ico'),
          'Назад на $back с',
          () => audio.rewind(),
        ),
        _playing
            ? taskbar.ThumbnailToolbarButton(
                taskbar.ThumbnailToolbarAssetIcon('assets/taskbar/pause.ico'),
                'Пауза',
                () => audio.pause(),
              )
            : taskbar.ThumbnailToolbarButton(
                taskbar.ThumbnailToolbarAssetIcon('assets/taskbar/play.ico'),
                'Слушать',
                () => audio.play(),
              ),
        taskbar.ThumbnailToolbarButton(
          taskbar.ThumbnailToolbarAssetIcon('assets/taskbar/forward.ico'),
          'Вперёд на $forward с',
          () => audio.fastForward(),
        ),
      ]);
    } catch (e) {
      debugPrint('Не удалось обновить кнопки в панели задач: $e');
    }
  }

  @override
  void onWindowFocus() => unawaited(_updateThumbnailButtons());

  Future<void> _exit() async {
    try {
      // Пауза сохраняет позицию эпизода.
      await _audio?.pause();
    } catch (_) {}
    await _traySetting?.cancel();
    await _playingSub?.cancel();
    await _itemSub?.cancel();
    if (_trayEnabled) await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    if (_trayEnabled) {
      windowManager.hide();
    } else {
      _exit();
    }
  }

  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() async {
    await _updateMenu();
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _show();
      case 'play':
        final audio = _audio;
        if (audio == null) return;
        audio.playbackState.value.playing ? audio.pause() : audio.play();
      case 'exit':
        _exit();
    }
  }
}

/// Запуск вместе с Windows: запись в реестре текущего пользователя.
abstract final class Autostart {
  static const _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _name = 'BasicCaster';

  static Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run('reg', ['query', _key, '/v', _name]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setEnabled(bool on) async {
    if (!Platform.isWindows) return false;
    try {
      final r = on
          ? await Process.run('reg', [
              'add',
              _key,
              '/v',
              _name,
              '/t',
              'REG_SZ',
              '/d',
              '"${Platform.resolvedExecutable}" $trayLaunchArgument',
              '/f',
            ])
          : await Process.run('reg', ['delete', _key, '/v', _name, '/f']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

/// Горячие клавиши на компьютере: пробел — пауза, стрелки — перемотка.
/// Не мешают полям ввода: там пробел и стрелки работают как обычно.
class PlayerHotkeys extends StatelessWidget {
  const PlayerHotkeys({super.key, required this.audio, required this.child});

  final PodcastAudioHandler? audio;
  final Widget child;

  static bool _editingText() {
    final context = primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final audio = this.audio;
    if (audio == null || audio.currentEpisodeId == null) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed || keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (_editingText()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      audio.playbackState.value.playing ? audio.pause() : audio.play();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      audio.rewind();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      audio.fastForward();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
        debugLabel: 'Горячие клавиши плеера',
        // Фокус по умолчанию — чтобы клавиши работали сразу после запуска.
        autofocus: true,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: child,
      );
}
