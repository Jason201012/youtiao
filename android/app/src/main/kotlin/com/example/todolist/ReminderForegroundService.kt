package com.example.todolist

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 前台守护服务：
 * 在 App 被用户划掉最近任务后，仍保持进程常驻，使 setAlarmClock 定时闹钟与
 * 进程内兜底延迟都能准时触发。ColorOS / Realme 等国产 ROM 会把被划掉的第三方
 * App 速冻、取消后台闹钟，前台服务是唯一可靠的保活手段。
 */
class ReminderForegroundService : Service() {

    companion object {
        const val SERVICE_ID = 1001
        const val CHANNEL_ID = "reminder_guard_channel"
        const val CHANNEL_NAME = "提醒守护"
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY：被系统低内存回收后，系统会在资源充裕时自动重启本服务
        startForeground(SERVICE_ID, buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_MIN, // 安静：不发声、不亮屏、不弹窗
                ).apply {
                    description = "保持提醒在后台准时送达"
                    setShowBadge(false)
                }
                mgr.createNotificationChannel(channel)
            }
        }
    }

    private fun buildNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setContentTitle("有条")
        .setContentText("提醒守护中，后台闹钟保持运行")
        .setSmallIcon(R.mipmap.ic_launcher)
        .setOngoing(true) // 不可滑动清除
        .setCategory(NotificationCompat.CATEGORY_SERVICE)
        .setPriority(NotificationCompat.PRIORITY_MIN)
        .setContentIntent(openAppPendingIntent())
        .build()

    private fun openAppPendingIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
