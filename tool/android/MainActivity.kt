package com.example.podcast_app

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.app.Activity
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import java.io.File
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
    private var pendingMediaResult: MethodChannel.Result? = null
    private var pendingPickResult: MethodChannel.Result? = null

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
                    "downloadsStart" -> result.success(DownloadService.start(applicationContext))
                    "batteryUnrestricted" -> result.success(batteryUnrestricted())
                    "requestBatteryUnrestricted" -> {
                        requestBatteryUnrestricted()
                        result.success(null)
                    }
                    // Читалка: экран не гаснет, пока открыта книга.
                    "keepScreenOn" -> {
                        if (call.argument<Boolean>("on") == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "mediaPermissionGranted" -> result.success(mediaPermissionGranted())
                    "requestMediaPermission" -> requestMediaPermission(result)
                    "openAppSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName"))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }
                    "pickFiles" -> pickFiles(
                        call.argument<String>("mime") ?: "*/*",
                        call.argument<Boolean>("multiple") ?: true,
                        result,
                    )
                    "pickFolder" -> pickFolder(result)
                    else -> result.notImplemented()
                }
            }
    }

    /** Разрешение читать аудиофайлы (папка с аудиокнигами). */
    private fun mediaPermission(): String =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun mediaPermissionGranted(): Boolean =
        checkSelfPermission(mediaPermission()) == PackageManager.PERMISSION_GRANTED

    private fun requestMediaPermission(result: MethodChannel.Result) {
        if (mediaPermissionGranted()) {
            result.success(true)
            return
        }
        pendingMediaResult?.success(false)
        pendingMediaResult = result
        requestPermissions(arrayOf(mediaPermission()), MEDIA_REQUEST_CODE)
    }

    /** Выбор файлов книг: копии во временной папке приложения (пути к ним). */
    private fun pickFiles(mime: String, multiple: Boolean, result: MethodChannel.Result) {
        pendingPickResult?.success(null)
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mime)
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
        try {
            startActivityForResult(intent, PICK_FILES_CODE)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error("no_picker", e.message, null)
        }
    }

    /** Выбор папки: путь в файловой системе (для доступа к аудиофайлам). */
    private fun pickFolder(result: MethodChannel.Result) {
        pendingPickResult?.success(null)
        pendingPickResult = result
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PICK_FOLDER_CODE)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error("no_picker", e.message, null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILES_CODE && requestCode != PICK_FOLDER_CODE) return
        val result = pendingPickResult ?: return
        pendingPickResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(null)
            return
        }
        if (requestCode == PICK_FOLDER_CODE) {
            result.success(data.data?.let { treeToPath(it) })
            return
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        // Копирование может быть долгим (большие аудиофайлы) — не в главном потоке.
        Thread {
            val dir = File(cacheDir, "picked/${System.currentTimeMillis()}")
            dir.mkdirs()
            val paths = mutableListOf<String>()
            for (uri in uris) {
                try {
                    val name = displayName(uri) ?: "file-${paths.size}"
                    val target = File(dir, name.replace('/', '_'))
                    contentResolver.openInputStream(uri)?.use { input ->
                        target.outputStream().use { input.copyTo(it) }
                    }
                    paths.add(target.absolutePath)
                } catch (e: Exception) {
                    // Файл не читается — пропускаем, остальные важнее.
                }
            }
            Handler(Looper.getMainLooper()).post { result.success(paths) }
        }.start()
    }

    private fun displayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) return c.getString(0)
        }
        return uri.lastPathSegment
    }

    /** content://…/tree/primary:Audiobooks → /storage/emulated/0/Audiobooks. */
    private fun treeToPath(uri: Uri): String? {
        val id = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (e: Exception) {
            return null
        }
        val parts = id.split(":", limit = 2)
        val volume = parts[0]
        val rel = if (parts.size > 1) parts[1] else ""
        val base = when {
            volume.equals("primary", ignoreCase = true) -> Environment.getExternalStorageDirectory().absolutePath
            volume.equals("home", ignoreCase = true) -> Environment.getExternalStorageDirectory().absolutePath + "/Documents"
            volume.startsWith("raw") -> return rel
            else -> "/storage/$volume"
        }
        return if (rel.isEmpty()) base else "$base/$rel"
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
        if (requestCode == MEDIA_REQUEST_CODE) {
            pendingMediaResult?.success(mediaPermissionGranted())
            pendingMediaResult = null
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
        private const val MEDIA_REQUEST_CODE = 4102
        private const val PICK_FILES_CODE = 4103
        private const val PICK_FOLDER_CODE = 4104
    }
}
