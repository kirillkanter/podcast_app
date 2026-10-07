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
import android.os.IBinder

/**
 * Сервис «на переднем плане», пока качаются эпизоды: уведомление
 * с прогрессом, и Android не останавливает загрузки, даже если приложение
 * закрыли из списка недавних. Сами загрузки идут в Dart (движок Flutter
 * переживает закрытие окна, его держит audio_service).
 *
 * Файл копируется tool/patch_platforms.dart рядом с MainActivity.
 */
class DownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = build(
            this,
            intent?.getStringExtra(EXTRA_TITLE) ?: "Загрузка эпизодов",
            intent?.getStringExtra(EXTRA_TEXT) ?: "",
            intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1,
        )
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    /** Android 15+: лимит времени для dataSync исчерпан — уходим тихо. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    fun update(title: String, text: String, progress: Int) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, build(this, title, text, progress))
    }

    companion object {
        private const val CHANNEL_ID = "ru.bcaster.app.downloads"
        private const val NOTIFICATION_ID = 2101
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_PROGRESS = "progress"

        @Volatile
        var instance: DownloadService? = null

        /** Показать или обновить уведомление. `false` — Android не дал запустить сервис. */
        fun show(context: Context, title: String, text: String, progress: Int): Boolean {
            val running = instance
            if (running != null) {
                running.update(title, text, progress)
                return true
            }
            return try {
                val intent = Intent(context, DownloadService::class.java)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_TEXT, text)
                    .putExtra(EXTRA_PROGRESS, progress)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
                true
            } catch (e: Exception) {
                false
            }
        }

        fun hide(context: Context) {
            context.stopService(Intent(context, DownloadService::class.java))
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
                    PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
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
