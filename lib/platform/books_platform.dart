/// Системные возможности для книг без сторонних плагинов: выбор файлов
/// и папки, доступ к аудиофайлам (Android), экран без автовыключения.
/// Android — свой канал в MainActivity.kt, Windows — file_selector и WinAPI.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _system = MethodChannel('basic_caster/system');

const bookFileExtensions = ['epub', 'fb2', 'fbz', 'zip', 'txt', 'mp3', 'm4b', 'm4a', 'aac', 'ogg', 'opus', 'flac'];

/// Выбрать файлы книг. Возвращает пути (на Android — копии во временной
/// папке приложения); пусто — ничего не выбрали.
Future<List<String>> pickFilesForBooks() async {
  if (Platform.isAndroid) {
    final list = await _system.invokeListMethod<String>('pickFiles');
    return list ?? const [];
  }
  final files = await openFiles(acceptedTypeGroups: const [
    XTypeGroup(label: 'Книги', extensions: bookFileExtensions),
  ]);
  return [for (final f in files) f.path];
}

/// Выбрать картинку (своя обложка). `null` — не выбрали.
Future<String?> pickImage() async {
  if (Platform.isAndroid) {
    final list = await _system.invokeListMethod<String>('pickFiles', {'mime': 'image/*', 'multiple': false});
    return list == null || list.isEmpty ? null : list.first;
  }
  final f = await openFile(acceptedTypeGroups: const [
    XTypeGroup(label: 'Картинки', extensions: ['jpg', 'jpeg', 'png', 'webp']),
  ]);
  return f?.path;
}

/// Выбрать папку. `null` — не выбрали.
Future<String?> pickFolderForBooks() async {
  if (Platform.isAndroid) return _system.invokeMethod<String>('pickFolder');
  return getDirectoryPath(confirmButtonText: 'Выбрать папку');
}

/// Есть ли доступ к аудиофайлам на телефоне.
Future<bool> mediaPermissionGranted() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _system.invokeMethod<bool>('mediaPermissionGranted') ?? false;
  } catch (_) {
    return false;
  }
}

/// Попросить доступ к аудиофайлам.
Future<bool> requestMediaPermission() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _system.invokeMethod<bool>('requestMediaPermission') ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> openAppSettings() async {
  if (!Platform.isAndroid) return;
  try {
    await _system.invokeMethod<void>('openAppSettings');
  } catch (_) {}
}

/// Не выключать экран (пока открыта читалка).
Future<void> keepScreenOn(bool on) async {
  try {
    if (Platform.isAndroid) {
      await _system.invokeMethod<void>('keepScreenOn', {'on': on});
    } else if (Platform.isWindows) {
      _windowsKeepAwake(on);
    }
  } catch (e) {
    debugPrint('Не удалось ${on ? 'включить' : 'выключить'} постоянный экран: $e');
  }
}

typedef _SetStateNative = Uint32 Function(Uint32 flags);
typedef _SetStateDart = int Function(int flags);

_SetStateDart? _setThreadExecutionState;

void _windowsKeepAwake(bool on) {
  const esContinuous = 0x80000000;
  const esSystemRequired = 0x00000001;
  const esDisplayRequired = 0x00000002;
  _setThreadExecutionState ??= DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_SetStateNative, _SetStateDart>('SetThreadExecutionState');
  _setThreadExecutionState!(on ? esContinuous | esSystemRequired | esDisplayRequired : esContinuous);
}

/// Заряд батареи в процентах (Android); `null` — неизвестно.
Future<int?> batteryLevel() async {
  if (!Platform.isAndroid) return null;
  try {
    return await _system.invokeMethod<int>('batteryLevel');
  } catch (_) {
    return null;
  }
}

/// Полноэкранный режим читалки: системные строки прячутся (Android),
/// смахивание от края показывает их на время.
Future<void> setImmersive(bool on) async {
  if (!Platform.isAndroid) return;
  await SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
}

const _volumeKeys = MethodChannel('basic_caster/volume_keys');

/// Листание кнопками громкости (Android). Пока задан [onKey], кнопки громкости
/// не меняют громкость, а вызывают [onKey]: `true` — «тише» (вперёд),
/// `false` — «громче» (назад). `null` — кнопки снова регулируют громкость.
Future<void> setVolumeKeyPaging(void Function(bool forward)? onKey) async {
  if (!Platform.isAndroid) return;
  _volumeKeys.setMethodCallHandler(onKey == null
      ? null
      : (call) async {
          if (call.method == 'key') onKey(call.arguments == 'next');
        });
  try {
    await _volumeKeys.invokeMethod<void>('enable', {'on': onKey != null});
  } catch (e) {
    debugPrint('Не удалось ${onKey != null ? 'включить' : 'выключить'} листание кнопками громкости: $e');
  }
}
