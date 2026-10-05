package com.example.todolist

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Calendar
import java.util.TimeZone

/**
 * 每日任务「当天 00:00 自动重置」接收器（运行于 :guard 进程，与 ScheduledNotificationReceiver 一致）。
 *
 * 触发时机：
 *  1) 由 setAlarmClock 在每天 00:00 唤醒（ColorOS 上 setAlarmClock 不被 Doze / 电池优化拦截，
 *     与现有 07:00 每日提醒同机制，无需用户打开 App）；
 *  2) 设备开机（BOOT_COMPLETED）后重新挂上闹钟。
 *
 * 处理逻辑：v2.2.4 起任务数据唯一真相来源为 SQLite（youtiao.db，tasks 表，data 列存完整 Task JSON）。
 * 本接收器直接打开该 DB，把「已完成且 completedAt 日期早于今天、且未过截止日、今天为其循环日」的
 * 重复任务重置为未完成，实现「每天循环打卡」。与 Dart 侧 TaskProvider._resetDailyIfNeeded 完全一致。
 * 仅当数据库文件尚不存在（极老、从未迁移的设备）时回退到旧版 SharedPreferences 的 tasks JSON。
 */
class MidnightResetReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_MIDNIGHT = "com.example.todolist.MIDNIGHT_RESET"
        const val PREFS_NAME = "FlutterSharedPreferences"
        const val KEY_TASKS = "tasks"
        const val kDbName = "youtiao.db"
        const val ALARM_REQUEST = 7723
        /** 回收站保留天数 pref key，与 Dart TaskProvider._kTrashRetention 完全一致。 */
        const val kTrashRetention = "trash_retention_days"

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
                // F8：setAlarmClock **不需要** SCHEDULE_EXACT_ALARM 权限
                // （Android 官方：使用 setAlarmClock / setAndAllowWhileIdle 无需申请精确闹钟权限），
                // 而 Android 14+ 该权限默认拒绝。旧实现在此加了 canScheduleExactAlarms() 守卫
                // 且**没有 else 降级** → Android 14+ 用户只要当天不开 App，
                // 每日 00:00 的重复任务重置 / 回收站清理 / 小组件跨天刷新完全不发生，
                // 核心循环名存实亡。现去掉守卫，直接排；失败再降级为非精确窗口闹钟。
                try {
                    am.setAlarmClock(
                        AlarmManager.AlarmClockInfo(midnight.timeInMillis, pi),
                        pi,
                    )
                } catch (se: SecurityException) {
                    // 极少数 ROM 仍拒绝：降级为窗口闹钟，至少保证「跨天一定会被唤醒」。
                    android.util.Log.d(
                        "MidnightReset",
                        "setAlarmClock 被拒绝，降级 setWindow：${se.message}",
                    )
                    runCatching {
                        am.setWindow(
                            AlarmManager.RTC_WAKEUP,
                            midnight.timeInMillis,
                            60_000L,
                            pi,
                        )
                    }
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

    /** 轻量日志：用于排查每日重置 / 回收站清理问题（日志量极小，保留）。 */
    private fun debugLog(msg: String) {
        android.util.Log.d("MidnightReset", msg)
    }

    /** SQLITE_BUSY（并发写冲突）标志，主进程与 :guard 进程并发写 youtiao.db 时可能出现。 */
    private const val SQLITE_BUSY_RETRY = 3

    /**
     * S10 修复：以跨进程安全方式打开主进程的 youtiao.db。
     * - 尽力启用 WAL（PRAGMA journal_mode=WAL），降低 :guard 进程与主进程 sqflite 并发访问的锁冲突；
     * - 设置 PRAGMA busy_timeout，使并发写入时等待而非立即抛 SQLITE_BUSY；
     * - 打开失败不再静默吞掉，而是记录日志，便于排查每日重置未生效的问题。
     * 若主进程当前以 DELETE 日志模式占用该 DB，WAL PRAGMA 会失败（SQLITE_BUSY），
     * 此时退化为 busy_timeout 重试，不会破坏现有数据。
     */
    private fun openGuardDb(dbPath: String): SQLiteDatabase? {
        val db = try {
            SQLiteDatabase.openDatabase(
                dbPath,
                null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
            )
        } catch (e: Exception) {
            debugLog("打开 youtiao.db 失败（:guard 进程）：${e.message}")
            return null
        }
        try {
            db.execSQL("PRAGMA journal_mode=WAL")
        } catch (_: Exception) {
            // 主进程占用时 WAL 切换失败属正常，退化为 busy_timeout 重试。
        }
        try {
            db.execSQL("PRAGMA busy_timeout=5000")
        } catch (_: Exception) {
            // 忽略
        }
        return db
    }

    /**
     * S10 修复：在 :guard 进程中对主进程 DB 执行写入操作，带 SQLITE_BUSY 重试。
     * 主进程（App）可能正持有该 DB 连接，并发写会触发 SQLITE_BUSY（"database is locked"）；
     * 此处重试并等待 busy_timeout 释放锁，而不是像旧代码那样静默放弃每日重置。
     */
    private fun <R> withGuardDb(dbPath: String, block: (SQLiteDatabase) -> R): R? {
        var lastErr: Exception? = null
        for (attempt in 1..SQLITE_BUSY_RETRY) {
            val db = openGuardDb(dbPath) ?: return null
            try {
                return block(db)
            } catch (e: Exception) {
                lastErr = e
                val busy = e is SQLiteException &&
                    e.message?.contains("locked", ignoreCase = true) == true
                debugLog("youtiao.db 写入失败（尝试 $attempt/$SQLITE_BUSY_RETRY）：${e.message}")
                if (!busy) break
                if (attempt < SQLITE_BUSY_RETRY) Thread.sleep(800)
            } finally {
                try {
                    db.close()
                } catch (_: Exception) {
                    // 忽略
                }
            }
        }
        if (lastErr != null) {
            debugLog("youtiao.db 每日重置最终失败：${lastErr.message}")
        }
        return null
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
        // 顺带刷新桌面小组件（今日任务列表），使重置后的循环任务即时反映。
        runCatching { TodayWidgetProvider.refreshAll(context) }
    }

    /** 读取回收站保留天数（天）。与 Dart prefs key [kTrashRetention] 一致；
     *  默认 30 天；负数表示「永不自动清理」。 */
    private fun readTrashRetention(context: Context): Int {
        return runCatching {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.getInt(kTrashRetention, 30)
        }.getOrDefault(30)
    }

    /** 重置每日任务：优先直接读写 SQLite（v2.2.4 起任务数据的唯一真相来源）；
     *  仅当数据库尚未建立（极少数从未迁移的极老设备）时回退到旧版 SharedPreferences。 */
    private fun resetDailyTasks(context: Context) {
        val dbFile = runCatching { context.getDatabasePath(kDbName) }.getOrNull()
        if (dbFile != null && dbFile.exists()) {
            val path = dbFile.absolutePath
            resetDailyTasksSqlite(path)
            // 回收站自动清理：删除早于保留期的过期条目。
            // P2-2（v3.0.2 审计）：捕获返回的过期 id 列表并**接线** F-5（v2.8.5 审计）
            // 补写的 [cleanupExpiredTrashResources]——该函数自 v2.8.6 引入起全仓零调用，
            // 原生路径的「到期即销毁」只删 trash 表记录，附件目录 / 展示态通知从未
            // 清理，attachments/<taskId>/ 孤儿目录无限累积（与 Dart 侧
            // TaskProvider._cleanupTrashIfNeeded 的「三件事一体」口径不一致）。
            val expired = cleanupTrashSqlite(path, readTrashRetention(context))
            if (expired.isNotEmpty()) {
                cleanupExpiredTrashResources(context, expired)
            }
            return
        }
        // 回退路径：旧版 SP（tasks JSON 整体）
        resetDailyTasksPrefs(context)
    }

    /** 直接打开 SQLite（youtiao.db，与 sqflite 同路径），重置 tasks 表中符合条件的重复任务。
     * 复用与 Dart Task 完全一致的 JSON 字段（status/done/completedAt/dueDate/repeat 等）。 */
    private fun resetDailyTasksSqlite(dbPath: String) {
        // S10 修复：经 withGuardDb 打开，带 WAL + busy_timeout + SQLITE_BUSY 重试与失败日志。
        withGuardDb(dbPath) { db ->
            val cursor = db.query("tasks", arrayOf("id", "data"), null, null, null, null, null)
            val updates = mutableListOf<Pair<String, String>>()
            cursor.use {
                while (it.moveToNext()) {
                    val id = it.getString(0)
                    val dataStr = it.getString(1)
                    val obj = runCatching { JSONObject(dataStr) }.getOrNull() ?: continue
                    if (shouldResetTask(obj)) {
                        obj.put("status", "todo")
                        obj.put("done", false)
                        obj.remove("completedAt")
                        updates.add(Pair(id, obj.toString()))
                    }
                }
            }
            for ((id, newData) in updates) {
                val cv = ContentValues()
                cv.put("data", newData)
                db.update("tasks", cv, "id = ?", arrayOf(id))
            }
        }
    }

    /** 直接打开 SQLite 清理 [trash] 表：删除 deletedAt（JSON data 内）早于保留期的条目。
     * 与 Dart TaskProvider._cleanupTrashIfNeeded 一致；保留期天数由 [retentionDays] 传入，
     * ≤ 0 表示「永不自动清理」（对齐 Dart _normalizeTrashRetention 的 P3-20 口径）。
     * data 列存完整 Task JSON，deletedAt 为 ISO 时间戳。
     * F-5（v2.8.5 审计）：返回被清理的 id 列表，交由 [cleanupExpiredTrashResources]
     * 补齐 Dart 侧到期即销毁的其余动作（删附件目录、取消通知）——原生路径此前只删
     * 库记录，产生孤儿附件目录，与 Dart 侧口径不一致。 */
    private fun cleanupTrashSqlite(dbPath: String, retentionDays: Int): List<String> {
        if (retentionDays <= 0) return emptyList() // P3-20 口径：保留期 ≤ 0 = 永不自动清理
        // S10 修复：经 withGuardDb 打开，带 WAL + busy_timeout + SQLITE_BUSY 重试与失败日志。
        return withGuardDb(dbPath) { db ->
            // 锚点保持**本地**时区（与 Dart DateTime.now() 同为「本地的今天」；勿改 UTC，
            // 凌晨 0-8 点会把「今天」错成昨天——见 dayDiff 的 UTC 口径注释）。
            val cutoff = Calendar.getInstance().apply {
                add(Calendar.DAY_OF_MONTH, -retentionDays)
            }
            val cutoffStr = String.format(
                "%04d-%02d-%02d",
                cutoff.get(Calendar.YEAR),
                cutoff.get(Calendar.MONTH) + 1,
                cutoff.get(Calendar.DAY_OF_MONTH),
            )
            val cursor = db.query("trash", arrayOf("id", "data"), null, null, null, null, null)
            val expired = mutableListOf<String>()
            cursor.use {
                while (it.moveToNext()) {
                    val id = it.getString(0)
                    val dataStr = it.getString(1)
                    val obj = runCatching { JSONObject(dataStr) }.getOrNull() ?: continue
                    val del = datePart(obj.opt("deletedAt")) ?: continue
                    // P3-3（v3.0.3 审计）date-only 统一口径：deletedDate <= cutoff 即过期
                    //（保留 N 整天：deletedAt 日期 = 今天−N 的条目今天删除，与 Dart 侧
                    // _cleanupTrashIfNeeded / trashRemainingDays / trashExpiringTomorrow
                    // 一致；原严格 `<` 会比 Dart 多保留一天，双端口径漂移）。
                    if (del <= cutoffStr) expired.add(id)
                }
            }
            for (id in expired) {
                db.delete("trash", "id = ?", arrayOf(id))
            }
            if (expired.isNotEmpty()) {
                debugLog("回收站自动清理：删除 ${expired.size} 条过期条目（保留 ${retentionDays} 天）")
            }
            expired
        } ?: emptyList()
    }

    /**
     * F-5（v2.8.5 审计）：对原生路径清理掉的过期回收站任务，补齐与 Dart 侧
     * TaskProvider._cleanupTrashIfNeeded 一致的「到期即销毁」其余两件事。
     * 双端口径注释（防再次漂移，改动时必须两侧同步）：
     *  1) 附件目录：`attachments/<taskId>/` 整目录递归删除。
     *     P2-2（v3.0.2 审计）口径修正：Dart 侧 AttachmentService 的**全部**访问器
     *     （dirFor / stagingDir / removeDir / promoteStaging / scanAll / _planOrphans）
     *     均为「_base()（<docs>/attachments）再拼一段 _attachmentsDirName」——真实布局
     *     是 <docs>/attachments/attachments/<taskId>/ 双层嵌套，自 v2.6.9（e0c81c4）
     *     引入附件功能起从未变过。旧注释声称的单层路径（app_flutter/attachments/<taskId>）
     *     从未命中真实目录（F-5 的第二个「未接线」形态）。现双层为主、单层兜底
     *     （幂等，防未知历史布局），全部尝试删除。
     *     Dart 的 `getApplicationDocumentsDirectory()` 在 Android 上实际返回
     *     **`dataDir/app_flutter`**（path_provider 2.x，`dataDir` 即
     *     `applicationInfo.dataDir`，与 `filesDir` 是兄弟目录）。
     *  2) 通知 id 段（与 Dart NotificationService 完全一致，均为 int32）：
     *     - 一次性截止提醒 = 任务数字 id 本身；
     *     - 重复提醒 = 1600000000 + (id % 30000000) * 8 + 0..7；
     *     - 稍后提醒(snooze) = 1900000000 + id % 10000000。
     *     任务入回收站时 Dart 已按同段取消过，这里兜底清掉展示态残留。
     * 全部失败仅记日志，不阻断清理主流程。
     */
    private fun cleanupExpiredTrashResources(context: Context, ids: List<String>) {
        val nm = runCatching {
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        }.getOrNull()
        // 附件根目录候选：双层（真实布局，见上方口径修正）为主，单层兜底；
        // 同一 id 在多处尝试删除是幂等的，不会误删兄弟任务目录。
        val attachmentRoots = listOf(
            File(File(File(context.applicationInfo.dataDir, "app_flutter"), "attachments"), "attachments"),
            File(File(context.filesDir, "attachments"), "attachments"),
            File(File(context.applicationInfo.dataDir, "app_flutter"), "attachments"),
            File(context.filesDir, "attachments"),
        )
        for (id in ids) {
            // 1) 附件目录
            for (root in attachmentRoots) {
                runCatching {
                    val dir = File(root, id)
                    if (dir.exists()) dir.deleteRecursively()
                }.onFailure { debugLog("清理附件目录失败 id=$id: ${it.message}") }
            }
            // 2) 通知（仅取消展示态；非数字 id 走过 Dart hashCode 映射，原生无法复现，跳过）
            if (nm == null) continue
            runCatching {
                val base = id.toLongOrNull() ?: return@runCatching
                if (base < 0 || base > Int.MAX_VALUE) return@runCatching
                nm.cancel(base.toInt())
                val slot = (base % 30000000).toInt()
                for (d in 0 until 8) nm.cancel(1600000000 + slot * 8 + d)
                nm.cancel((1900000000 + (base % 10000000)).toInt())
            }.onFailure { debugLog("取消残留通知失败 id=$id: ${it.message}") }
        }
    }

    /** 回退路径：读取旧版 SharedPreferences 的 tasks JSON 并重置（仅未迁移设备）。 */
    private fun resetDailyTasksPrefs(context: Context) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(KEY_TASKS, null) ?: return
            val arr = JSONArray(raw)
            var changed = false
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                if (shouldResetTask(obj)) {
                    obj.put("status", "todo")
                    obj.put("done", false)
                    obj.remove("completedAt")
                    changed = true
                }
            }
            if (changed) {
                // S10 修复：:guard 进程在 onReceive 返回后可能被系统立即回收，
                // .apply() 为异步写，存在未落盘即被杀死导致重置丢失的风险；
                // 改用同步 .commit() 保证写入落盘后再返回。
                prefs.edit().putString(KEY_TASKS, arr.toString()).commit()
            }
        } catch (_: Exception) {
            // 解析/写入失败不崩溃
        }
    }

    /** 判断该任务 JSON 是否应在今天被重置：已完成的重复任务，今天是其循环日，
     *  且上次完成早于今天（与 Dart TaskProvider._resetDailyIfNeeded 一致）。
     *
     *  F-1 连带：此前这里额外要求 `dueDate == null || dueDate >= today`，
     *  而 Dart 侧录入重复任务时会把截止日钉成「创建当天 23:59」——创建次日该条件
     *  恒为 false，于是「每天喝水」第二天起**永远不会被重置回未完成**（App 不开时
     *  由本接收器负责重置，这一条同样失效）。重复任务是否继续循环只由 repeatUntil
     *  与 skipDates（见 [isRecurrenceToday]）决定，Dart 侧已同步去掉该门槛。 */
    private fun shouldResetTask(obj: JSONObject): Boolean {
        val repeat = parseRepeat(obj)
        if (repeat == RepeatMode.NONE) return false
        val status = obj.optString("status", "todo")
        val done = obj.optBoolean("done", false)
        if (status != "done" && !done) return false
        val today = todayStr()
        if (!isRecurrenceToday(obj, repeat, today)) return false
        val compDate = datePart(obj.opt("completedAt"))
        return compDate == null || compDate < today
    }

    /** 重复规则枚举，与 Dart RepeatType 对应。 */
    private enum class RepeatMode { NONE, DAILY, WEEKLY, INTERVAL, WEEKDAY, MONTHLY }

    /** 从 task JSON 解析重复规则：兼容旧版 dailyReminder 布尔字段。 */
    private fun parseRepeat(obj: JSONObject): RepeatMode {
        val r = obj.optString("repeat", null)
        if (r != null) {
            return when (r) {
                "daily" -> RepeatMode.DAILY
                "weekly" -> RepeatMode.WEEKLY
                "interval" -> RepeatMode.INTERVAL
                "weekday" -> RepeatMode.WEEKDAY
                "monthly" -> RepeatMode.MONTHLY
                else -> RepeatMode.NONE
            }
        }
        // 旧数据：dailyReminder=true 视作「每天」
        return if (obj.optBoolean("dailyReminder", false)) RepeatMode.DAILY else RepeatMode.NONE
    }

    /** 判断今天（yyyy-MM-dd）是否为该重复任务的循环日。与 Dart Task.repeatsOn 完全一致。 */
    private fun isRecurrenceToday(obj: JSONObject, repeat: RepeatMode, today: String): Boolean {
        // B2：结束日期（repeatUntil，yyyy-MM-dd，含当日仍生效 → 用字典序 > 排除次日及之后）。
        val until = obj.optString("repeatUntil", "")
        if (until.isNotEmpty() && today > until) return false
        // B1：跳过日期（skipDates 列表命中今天 → 当天不出现、不打卡、不影响连续天数）。
        val skip = obj.optJSONArray("skipDates")
        if (skip != null) {
            for (j in 0 until skip.length()) {
                if (skip.optString(j, "") == today) return false
            }
        }
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
                val n = obj.optInt("repeatInterval", 1).coerceAtLeast(1)
                return diff % n == 0L
            }
            RepeatMode.MONTHLY -> {
                val parts = today.split("-")
                val y = parts[0].toInt()
                val m = parts[1].toInt()
                val target = monthlyTargetDay(obj, y, m)
                val targetStr = String.format("%04d-%02d-%02d", y, m, target)
                return targetStr == today
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

    /** 两个 yyyy-MM-dd 相差的整天数（b - a）。
     *  P3-2（v3.0.3 审计）：锚定 **UTC** 解析——原实现用本地时区 Calendar，DST 回拨日
     *  （当日只有 23 小时）毫秒差整除 86400000 会 off-by-one。date-only 差值与任何时区
     *  无关，UTC 无 DST、恒为 24 小时日，是最稳锚点（与 Dart 侧 v2.9.1 同款口径）。
     *  ⚠️ 本文件 [cleanupTrashSqlite] 的 cutoff 锚点保持**本地**时区（与 Dart
     *  DateTime.now() 同锚「本地的今天」），勿一并改 UTC（凌晨 0-8 点会把
     *  「今天」错成昨天）——UTC 化仅适用于 date-only 纯差值场景。 */
    private fun dayDiff(a: String, b: String): Long {
        val pa = a.split("-"); val pb = b.split("-")
        if (pa.size < 3 || pb.size < 3) return 0L
        val ca = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            set(pa[0].toInt(), pa[1].toInt() - 1, pa[2].toInt(), 0, 0, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val cb = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            set(pb[0].toInt(), pb[1].toInt() - 1, pb[2].toInt(), 0, 0, 0)
            set(Calendar.MILLISECOND, 0)
        }
        return ((cb.timeInMillis - ca.timeInMillis) / (24 * 60 * 60 * 1000L))
    }

    /** 每月重复在 [y]年[m]月的目标「日」(1-28/29/30/31)；与 Dart Task._baseRepeatsOn 一致。
     *  P2-3：补上 [monthlyFromEnd]（每月倒数第 N 天 / 最后一天）分支——Dart 侧它优先级
     *  最高，而原生侧此前完全缺失：App 不在前台时，原生层会在**每月 1 号**误判为循环日
     *  （monthlyDay 默认 1）并重置任务，真正的月末当天若 App 全天未开则无人重置（整月漏打卡）。
     *  - monthlyFromEnd > 0：倒数第 N 天（1 = 当月最后一天），优先级最高；
     *  - monthlyWeekday+monthlyWeekIndex 命中：第 N 个周几（idx=5 为最后一个）；
     *  - 否则用 monthlyDay（溢出夹到当月最后一天）。 */
    private fun monthlyTargetDay(obj: JSONObject, y: Int, m: Int): Int {
        val fromEnd = obj.optInt("monthlyFromEnd", 0)
        if (fromEnd > 0) {
            val dim = daysInMonth(y, m)
            return (dim - fromEnd + 1).coerceIn(1, dim)
        }
        val wd = obj.optInt("monthlyWeekday", -1)
        val idx = obj.optInt("monthlyWeekIndex", -1)
        if (wd in 1..7 && idx in 1..5) {
            var day = 1
            while (weekdayOf(String.format("%04d-%02d-%02d", y, m, day)) != wd) {
                day++
                if (day > 31) return 1 // 安全兜底，理论不可达
            }
            day += (idx - 1) * 7
            val dim = daysInMonth(y, m)
            if (day > dim) day -= 7 // 「最后一个」时第 5 个不存在则回退到第 4 个
            return day
        }
        val md = obj.optInt("monthlyDay", 1).coerceIn(1, daysInMonth(y, m))
        return md
    }

    /** [y]年[m]月的总天数（用于每月重复溢出夹取）。 */
    private fun daysInMonth(y: Int, m: Int): Int {
        val cal = Calendar.getInstance()
        cal.set(y, m - 1, 1)
        return cal.getActualMaximum(Calendar.DAY_OF_MONTH)
    }
}
