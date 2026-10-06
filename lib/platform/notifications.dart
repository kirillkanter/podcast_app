/// Разрешение на уведомления на Android (канал в MainActivity.kt).
/// На других платформах уведомления считаются разрешёнными.
library;

import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('podcast_app/notifications');

/// Разрешены ли уведомления приложению. `null` — узнать не удалось.
Future<bool?> notificationsEnabled() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _channel.invokeMethod<bool>('enabled');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Показывает системный запрос разрешения (Android 13+), если он ещё
/// возможен. Возвращает итоговое состояние.
Future<bool?> requestNotifications() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _channel.invokeMethod<bool>('request');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Открывает настройки уведомлений приложения.
Future<void> openNotificationSettings() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod<void>('openSettings');
  } on PlatformException {
    // Нечего показать пользователю — настройки откроет вручную.
  } on MissingPluginException {
    // То же.
  }
}
