package com.example.podcast_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Загрузки эпизодов на Android.
 *
 * Сервис «на переднем плане» со своим движком Flutter: в нём работает
 * downloadServiceMain (lib/main.dart), который качает очередь из базы.
 * Движок окна Android выгружает, когда приложение закрывают из списка
 * недавних, а этот сервис продолжает работать, показывая прогресс
 * в уведомлении. Когда очередь пуста, Dart сообщает «done», и сервис
 * останавливается вместе с уведомлением.
 *
 * Файл копируется tool/patch_platforms.dart рядом с MainActivity.
 */
class DownloadService : Service() {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = build(this, "Загрузка эпизодов", "Подготовка…", -1)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (engine == null) {
            startEngine()
        } else {
            // Окно поставило ещё эпизоды в очередь.
            channel?.invokeMethod("poke", null)
        }
        return START_NOT_STICKY
    }

    private fun startEngine() {
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val flutter = FlutterEngine(applicationContext)
        val methods = MethodChannel(flutter.dartExecutor.binaryMessenger, SERVICE_CHANNEL)
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "progress" -> {
                    update(
                        call.argument<String>("title") ?: "Загрузка эпизодов",
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("progress") ?: -1,
                    )
                    result.success(null)
                }
                "done" -> {
                    result.success(null)
                    mainHandler.post { finish() }
                }
                else -> result.notImplemented()
            }
        }
        engine = flutter
        channel = methods
        flutter.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "downloadServiceMain")
        )
    }

    private fun update(title: String, text: String, progress: Int) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, build(this, title, text, progress))
    }

    private fun finish() {
        engine?.destroy()
        engine = null
        channel = null
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        engine?.destroy()
        engine = null
        super.onDestroy()
    }

    /** Android 15+: лимит времени для dataSync исчерпан — остановиться. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        finish()
    }

    companion object {
        private const val CHANNEL_ID = "ru.bcaster.app.downloads"
        private const val NOTIFICATION_ID = 2101
        private const val SERVICE_CHANNEL = "basic_caster/download_service"

        /** Запустить или разбудить сервис. `false` — Android не дал (приложение в фоне). */
        fun start(context: Context): Boolean = try {
            val intent = Intent(context, DownloadService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            true
        } catch (e: Exception) {
            false
        }

        private fun build(context: Context, title: String, text: String, progress: Int): Notification {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Загрузки", NotificationManager.IMPORTANCE_LOW)
                )
            }
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val icon = context.resources.getIdentifier("ic_stat_bcaster", "drawable", context.packageName)
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        context, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    )
                )
            }
            return builder
                .setSmallIcon(if (icon != 0) icon else android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setContentText(text)
                .setProgress(100, progress.coerceIn(0, 100), progress < 0)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .build()
        }
    }
}
