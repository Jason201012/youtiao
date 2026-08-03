package com.example.todolist

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * 每日任务「当天 00:00 自动重置」接收器（运行于 :guard 进程，与 ScheduledNotificationReceiver 一致）。
 *
 * 触发时机：
 *  1) 由 setAlarmClock 在每天 00:00 唤醒（ColorOS 上 setAlarmClock 不被 Doze / 电池优化拦截，
 *     与现有 07:00 每日提醒同机制，无需用户打开 App）；
 *  2) 设备开机（BOOT_COMPLETED）后重新挂上闹钟。
 *
 * 处理逻辑：直接读写 shared_preferences 插件落盘的 `tasks` JSON（文件名 FlutterSharedPreferences），
 * 把「已完成且 completedAt 日期早于今天、且未过截止日」的每日任务重置为未完成，实现「每天循环打卡」。
 * 与 Dart 侧 TaskProvider.load() 的每日重置逻辑保持一致。
 */
class MidnightResetReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_MIDNIGHT = "com.example.todolist.MIDNIGHT_RESET"
        const val PREFS_NAME = "FlutterSharedPreferences"
        const val KEY_TASKS = "tasks"
        const val ALARM_REQUEST = 7723

        /** 安排下一次「当天 00:00」的 setAlarmClock 闹钟（ColorOS 可靠）。幂等：重复调用只会覆盖。 */
        fun schedule(context: Context) {
            try {
                val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val intent = Intent(context, MidnightResetReceiver::class.java).apply {
                    action = ACTION_MIDNIGHT
                }
                val pi = PendingIntent.getBroadcast(
                    context,
                    ALARM_REQUEST,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val now = Calendar.getInstance()
                val midnight = Calendar.getInstance().apply {
                    set(Calendar.HOUR_OF_DAY, 0)
                    set(Calendar.MINUTE, 0)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                    if (timeInMillis <= now.timeInMillis) {
                        add(Calendar.DAY_OF_MONTH, 1)
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    if (am.canScheduleExactAlarms()) {
                        am.setAlarmClock(
                            AlarmManager.AlarmClockInfo(midnight.timeInMillis, pi),
                            pi,
                        )
                    }
                } else {
                    am.setAlarmClock(
                        AlarmManager.AlarmClockInfo(midnight.timeInMillis, pi),
                        pi,
                    )
                }
            } catch (_: Exception) {
                // 安排失败不应导致崩溃
            }
        }

        /** 取消午夜闹钟（关闭每日提醒总开关等场景用）。 */
        fun cancel(context: Context) {
            try {
                val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val intent = Intent(context, MidnightResetReceiver::class.java).apply {
                    action = ACTION_MIDNIGHT
                }
                val pi = PendingIntent.getBroadcast(
                    context,
                    ALARM_REQUEST,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                am.cancel(pi)
            } catch (_: Exception) {
                // 取消失败忽略
            }
        }

        /** 今天的 yyyy-MM-dd（与 ISO 日期串同序比较，无需解析时间/时区）。 */
        private fun todayStr(): String {
            val now = Calendar.getInstance()
            return String.format(
                "%04d-%02d-%02d",
                now.get(Calendar.YEAR),
                now.get(Calendar.MONTH) + 1,
                now.get(Calendar.DAY_OF_MONTH),
            )
        }

        /** 把 ISO 时间戳（yyyy-MM-ddTHH:mm:ss...）截断为前 10 位的日期串，缺失/非法返回 null。 */
        private fun datePart(v: Any?): String? {
            if (v == null || v === JSONObject.NULL) return null
            val s = v.toString()
            if (s.length < 10) return null
            return s.substring(0, 10)
        }
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null) return
        val action = intent?.action
        if (action == Intent.ACTION_BOOT_COMPLETED) {
            // 开机后重新挂上每日 00:00 闹钟
            schedule(context)
            return
        }
        if (action != ACTION_MIDNIGHT) return
        resetDailyTasks(context)
        // 安排下一次，保证每天循环
        schedule(context)
    }

    /** 读取 tasks JSON，重置符合条件的重复任务，写回。 */
    private fun resetDailyTasks(context: Context) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(KEY_TASKS, null) ?: return
            val arr = JSONArray(raw)
            val today = todayStr()
            var changed = false
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                // 解析重复规则（与 Dart Task.repeat 一致）
                val repeat = parseRepeat(obj)
                if (repeat == RepeatMode.NONE) continue
                val status = obj.optString("status", "todo")
                val done = obj.optBoolean("done", false)
                if (status != "done" && !done) continue

                // 截止日期已过的重复任务不再重置（与 load() 的 !_dateHasPassed 一致）
                val dueDate = datePart(obj.opt("dueDate"))
                if (dueDate != null && dueDate < today) continue

                // 仅在「今天是其循环日」才重置（与 Dart Task.repeatsOn 一致）
                if (!isRecurrenceToday(obj, repeat, today)) continue

                // completedAt 日期早于今天才重置（今天刚完成的保持已完成）
                val compDate = datePart(obj.opt("completedAt"))
                val completedBeforeToday = compDate == null || compDate < today
                if (completedBeforeToday) {
                    obj.put("status", "todo")
                    obj.put("done", false)
                    obj.remove("completedAt")
                    changed = true
                }
            }
            if (changed) {
                prefs.edit().putString(KEY_TASKS, arr.toString()).apply()
            }
        } catch (_: Exception) {
            // 解析/写入失败不崩溃
        }
    }

    /** 重复规则枚举，与 Dart RepeatType 对应。 */
    private enum class RepeatMode { NONE, DAILY, WEEKLY, INTERVAL, WEEKDAY }

    /** 从 task JSON 解析重复规则：兼容旧版 dailyReminder 布尔字段。 */
    private fun parseRepeat(obj: JSONObject): RepeatMode {
        val r = obj.optString("repeat", null)
        if (r != null) {
            return when (r) {
                "daily" -> RepeatMode.DAILY
                "weekly" -> RepeatMode.WEEKLY
                "interval" -> RepeatMode.INTERVAL
                "weekday" -> RepeatMode.WEEKDAY
                else -> RepeatMode.NONE
            }
        }
        // 旧数据：dailyReminder=true 视作「每天」
        return if (obj.optBoolean("dailyReminder", false)) RepeatMode.DAILY else RepeatMode.NONE
    }

    /** 判断今天（yyyy-MM-dd）是否为该重复任务的循环日。与 Dart Task.repeatsOn 完全一致。 */
    private fun isRecurrenceToday(obj: JSONObject, repeat: RepeatMode, today: String): Boolean {
        when (repeat) {
            RepeatMode.NONE -> return false
            RepeatMode.DAILY -> return true
            RepeatMode.WEEKDAY -> {
                val wd = weekdayOf(today)
                return wd in 1..5 // 周一至周五
            }
            RepeatMode.WEEKLY -> {
                val wd = weekdayOf(today)
                val days = obj.optJSONArray("repeatWeekdays") ?: return false
                for (j in 0 until days.length()) {
                    if (days.optInt(j, -1) == wd) return true
                }
                return false
            }
            RepeatMode.INTERVAL -> {
                val anchor = datePart(obj.opt("repeatAnchor")) ?: return false
                val diff = dayDiff(anchor, today)
                if (diff < 0) return false
                val n = obj.optInt("repeatInterval", 2).coerceAtLeast(1)
                return diff % n == 0L
            }
        }
    }

    /** 1=周一 … 7=周日（与 Dart DateTime.weekday 一致）。 */
    private fun weekdayOf(dateStr: String): Int {
        // 用 Calendar 解析 yyyy-MM-dd，get(DAY_OF_WEEK)：1=周日…7=周六
        val cal = Calendar.getInstance()
        val parts = dateStr.split("-")
        if (parts.size < 3) return -1
        cal.set(parts[0].toInt(), parts[1].toInt() - 1, parts[2].toInt())
        val dow = cal.get(Calendar.DAY_OF_WEEK) // 1=Sun..7=Sat
        // 转成 1=Mon..7=Sun
        return if (dow == Calendar.SUNDAY) 7 else dow - 1
    }

    /** 两个 yyyy-MM-dd 相差的整天数（b - a）。按字符串逐段转毫秒，避免时区干扰。 */
    private fun dayDiff(a: String, b: String): Long {
        val pa = a.split("-"); val pb = b.split("-")
        if (pa.size < 3 || pb.size < 3) return 0L
        val ca = Calendar.getInstance().apply {
            set(pa[0].toInt(), pa[1].toInt() - 1, pa[2].toInt(), 0, 0, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val cb = Calendar.getInstance().apply {
            set(pb[0].toInt(), pb[1].toInt() - 1, pb[2].toInt(), 0, 0, 0)
            set(Calendar.MILLISECOND, 0)
        }
        return ((cb.timeInMillis - ca.timeInMillis) / (24 * 60 * 60 * 1000L))
    }
}
