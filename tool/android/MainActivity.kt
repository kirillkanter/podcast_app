package com.example.podcast_app

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Activity приложения.
 *
 * Наследуется от AudioServiceActivity: этого требует audio_service, чтобы
 * фоновый сервис и интерфейс работали с одним движком Flutter.
 *
 * Канал podcast_app/notifications: проверка и запрос разрешения на уведомления
 * и переход в их настройки — без сторонних плагинов.
 *
 * Файл копируется поверх сгенерированного tool/patch_platforms.dart.
 */
class MainActivity : AudioServiceActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enabled" -> result.success(notificationsEnabled())
                    "request" -> requestPermission(result)
                    "diagnostics" -> result.success(diagnostics())
                    "openSettings" -> {
                        openNotificationSettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("bad_args", "url is required", null)
                        } else {
                            try {
                                startActivity(
                                    Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    "batteryUnrestricted" -> result.success(batteryUnrestricted())
                    "requestBatteryUnrestricted" -> {
                        requestBatteryUnrestricted()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Снято ли с приложения ограничение батареи (фоновая работа без помех). */
    private fun batteryUnrestricted(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    /** Системный запрос «разрешить работу в фоне»; если его нет — настройки приложения. */
    private fun requestBatteryUnrestricted() {
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(android.net.Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (e: Exception) {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(android.net.Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    private fun notificationsEnabled(): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return manager.areNotificationsEnabled()
    }

    /** Что Android знает об уведомлениях приложения — для экрана «Диагностика». */
    private fun diagnostics(): String {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val lines = mutableListOf<String>()
        lines.add("Android API: ${Build.VERSION.SDK_INT}, ${Build.MANUFACTURER} ${Build.MODEL}")
        if (Build.VERSION.SDK_INT >= 26) {
            val active = manager.activeNotifications
            lines.add("Активных уведомлений приложения: ${active.size}")
            for (n in active) {
                lines.add("  id=${n.id}, канал=${n.notification.channelId}, ongoing=${n.isOngoing}")
            }
            val channels = manager.notificationChannels
            if (channels.isEmpty()) lines.add("Каналов уведомлений нет")
            for (c in channels) {
                lines.add("Канал «${c.name}» (${c.id}): важность ${c.importance}")
            }
        }
        return lines.joinToString("\n")
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(notificationsEnabled())
            return
        }
        pendingPermissionResult?.success(notificationsEnabled())
        pendingPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE) {
            pendingPermissionResult?.success(notificationsEnabled())
            pendingPermissionResult = null
        }
    }

    private fun openNotificationSettings() {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    companion object {
        private const val CHANNEL = "podcast_app/notifications"
        private const val SYSTEM_CHANNEL = "basic_caster/system"
        private const val REQUEST_CODE = 4101
    }
}
