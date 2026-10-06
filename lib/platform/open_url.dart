/// Открыть ссылку в браузере системы без сторонних плагинов:
/// на Android — через MainActivity, на Windows — через оболочку.
library;

import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('basic_caster/system');

/// `false`, если открыть не удалось.
Future<bool> openUrl(String url) async {
  try {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    }
    if (Platform.isWindows) {
      final result = await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      return result.exitCode == 0;
    }
    if (Platform.isMacOS) return (await Process.run('open', [url])).exitCode == 0;
    if (Platform.isLinux) return (await Process.run('xdg-open', [url])).exitCode == 0;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  } on ProcessException {
    return false;
  }
  return false;
}
