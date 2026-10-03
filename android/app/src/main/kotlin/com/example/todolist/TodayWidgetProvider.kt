package com.example.todolist

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.net.Uri
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.Calendar

/**
 * 桌面小组件（4×2）：展示「今日相关」任务列表（未完成 且 [循环命中今天 ∨ 一次性任务今天到期 ∨ 已逾期]）。
 *
 * 新P3-5（v2.9.7 审计）：已结束的重复任务不再展示（App 侧 `_effectiveDue` 中性化
 * 会把它们中性地落进「今天」分区，但小组件名额仅 8 个，已退场任务占位会把
 * 真正的今日任务挤出列表）。重复任务 meta 显示当天时刻（repeatMinute → HH:mm）。
 *
 * 与 App 内首页同源：直接跨进程只读打开 youtiao.db（复用 :guard 进程的 WAL + busy_timeout + 重试三件套），
 * 不引入 home_widget 等第三方包。点击任务项经 MainActivity 的 EXTRA_TASK_ID → MethodChannel → Dart
 * 直达任务详情页（与通知点击同构）。刷新三路并进：
 *   1) 系统 updatePeriodMillis 兜底（见 today_widget_info.xml）；
 *   2) Dart 侧每次 _persist 后经 widget_refresh 通道调 [refreshAll]（主要保鲜来源）；
 *   3) MidnightResetReceiver 午夜重置后顺带刷新一次。
 */
class TodayWidgetProvider : AppWidgetProvider() {

    companion object {
        /** 小组件任务项点击时，原生侧带此 extra 启动 MainActivity，再由 Dart 直达任务详情页。 */
        const val EXTRA_TASK_ID = "com.example.todolist.EXTRA_TASK_ID"

        /** T2-4（v2.9.2 功能增强）：小组件「＋」快速新建。带此 extra 启动 MainActivity，
         *  再经 widget_nav 通道让 Dart 弹出快速录入层（无预填文本）。 */
        const val EXTRA_QUICK_ADD = "com.example.todolist.EXTRA_QUICK_ADD"
        private const val TAG = "TodayWidget"
        private const val kDbName = "youtiao.db"
        private const val MAX_ITEMS = 8

        /** 主动刷新所有已添加部件：Dart _persist 后 / 午夜重置后调用。 */
        fun refreshAll(context: Context) {
            try {
                val mgr = AppWidgetManager.getInstance(context)
                val ids = mgr.getAppWidgetIds(ComponentName(context, TodayWidgetProvider::class.java))
                if (ids.isEmpty()) return
                val views = buildRemoteViews(context)
                for (id in ids) mgr.updateAppWidget(id, views)
            } catch (_: Exception) {
                // 刷新失败不应影响主流程
            }
        }

        private fun buildRemoteViews(context: Context): RemoteViews {
            return try {
                buildRemoteViewsInternal(context)
            } catch (e: Exception) {
                // 任何构建异常都不应导致系统小组件宿主直接失败（MIUI 等会报「载入窗口小部件时出现问题」）。
                Log.e(TAG, "buildRemoteViews failed, using fallback", e)
                fallbackRemoteViews(context)
            }
        }

        private fun buildRemoteViewsInternal(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_today)
            views.setTextViewText(R.id.date, todayDisplay())

            // 头部点击 → 打开 App（不带 task id，仅唤起首页）。
            val openApp = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).apply {
                    action = Intent.ACTION_MAIN
                    addCategory(Intent.CATEGORY_LAUNCHER)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.header, openApp)
            // T2-4：「＋」按钮 → 唤起 App 直达快速录入层。
            views.setOnClickPendingIntent(R.id.quick_add, quickAddPendingIntent(context))

            val tasks = readTodayTasks(context)
            if (tasks.isEmpty()) {
                views.setViewVisibility(R.id.empty, View.VISIBLE)
                views.setViewVisibility(R.id.list, View.GONE)
                return views
            }
            views.setViewVisibility(R.id.empty, View.GONE)
            views.setViewVisibility(R.id.list, View.VISIBLE)

            for (t in tasks) {
                val item = RemoteViews(context.packageName, R.layout.widget_today_item)
                item.setTextViewText(R.id.item_title, t.title)
                item.setTextViewText(R.id.item_meta, t.meta)
                // requestCode 用任务 id hashCode，配合 data URI 确保每个任务项 PendingIntent 唯一。
                val pi = PendingIntent.getActivity(
                    context, t.id.hashCode(),
                    Intent(context, MainActivity::class.java).apply {
                        putExtra(EXTRA_TASK_ID, t.id)
                        data = Uri.parse("widget://task/${t.id}")
                        action = "com.example.todolist.WIDGET_OPEN_TASK"
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                item.setOnClickPendingIntent(R.id.item_root, pi)
                views.addView(R.id.list, item)
            }
            return views
        }

        /** 构建失败时的兜底视图：只显示头部和空状态，避免系统小组件宿主报错。 */
        private fun fallbackRemoteViews(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_today)
            views.setTextViewText(R.id.date, todayDisplay())
            views.setTextViewText(R.id.empty, "今天没有任务 🎉")
            views.setViewVisibility(R.id.empty, View.VISIBLE)
            views.setViewVisibility(R.id.list, View.GONE)
            val openApp = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).apply {
                    action = Intent.ACTION_MAIN
                    addCategory(Intent.CATEGORY_LAUNCHER)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.header, openApp)
            // T2-4：兜底视图同样给「＋」入口可用。
            views.setOnClickPendingIntent(R.id.quick_add, quickAddPendingIntent(context))
            return views
        }

        /** T2-4（v2.9.2 功能增强）：「＋」快速新建的点击意图。
         *  requestCode 固定 + 独立 data URI（widget://quick-add），与任务项
         *  （widget://task/&lt;id&gt;）互不混淆；每次构建统一重建，FLAG_UPDATE_CURRENT 幂等。 */
        private fun quickAddPendingIntent(context: Context): PendingIntent =
            PendingIntent.getActivity(
                context, 10001,
                Intent(context, MainActivity::class.java).apply {
                    action = "com.example.todolist.WIDGET_QUICK_ADD"
                    data = Uri.parse("widget://quick-add")
                    putExtra(EXTRA_QUICK_ADD, "1")
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        /** 读库筛出今日相关任务：未完成 且 [循环命中今天 ∨ 今天到期 ∨ 已逾期]，置顶优先、order 升序，取前 8。 */
        private fun readTodayTasks(context: Context): List<WidgetTask> {
            val dbFile = runCatching { context.getDatabasePath(kDbName) }.getOrNull()
            if (dbFile == null || !dbFile.exists()) return emptyList()
            val today = todayStr()
            val list = mutableListOf<WidgetTask>()
            val path = dbFile.absolutePath
            withGuardDb(path) { db ->
                val cursor = db.query("tasks", arrayOf("id", "data"), null, null, null, null, null)
                cursor.use {
                    while (it.moveToNext()) {
                        val id = it.getString(0)
                        val obj = runCatching { JSONObject(it.getString(1)) }.getOrNull() ?: continue
                        if (!isActive(obj)) continue
                        if (isTodayRelevant(obj, today)) {
                            list.add(
                                WidgetTask(
                                    id, titleOf(obj), metaOf(obj, today),
                                    pinnedOf(obj), orderOf(obj),
                                ),
                            )
                        }
                    }
                }
            }
            list.sortWith(compareByDescending<WidgetTask> { it.pinned }.thenBy { it.order })
            return list.take(MAX_ITEMS)
        }

        // ===== 任务 JSON 字段解析（与 Dart Task 完全一致）=====
        private fun isActive(obj: JSONObject): Boolean {
            val status = obj.optString("status", "todo")
            val done = obj.optBoolean("done", false)
            return status != "done" && !done
        }

        private fun isTodayRelevant(obj: JSONObject, today: String): Boolean {
            // 新P3-9（v2.9.7 审计）：`repeat == NONE` 前置口径——重复任务的出现
            // 与否**只**由「今天是否循环日」决定（下行已含 repeatUntil / skipDates
            // 判定）；一次性任务才进入 dueDate 比较，两条路径互不渗透（与 P2-10
            // 同源的口径声明，防止后续改动把两条路径重新纠缠）。
            val repeat = parseRepeat(obj)
            if (repeat != RepeatMode.NONE) {
                return isRecurrenceToday(obj, repeat, today)
            }
            // 新P3-5（v2.9.7 审计）：删除 P2-10 轮的「已结束重复恒显示」回落——
            // App 侧 `_effectiveDue` 中性化让已结束重复落进「今天」分区，但小组件
            // 名额仅 8 个，已退场任务永久占位会把真正的今日任务挤出列表（只解决
            // 「逾期」标签、未解决占位）。不再复刻该中性化。
            // P2-10（v2.9.6 审计）：与 App 侧口径对齐（`Task.isOverdue`）——
            // 一次性任务「今天到期 ∨ 已逾期」显示，未来截止不显示。
            val due = datePart(obj.opt("dueDate")) ?: return false
            return due <= today
        }

        private fun titleOf(obj: JSONObject): String = obj.optString("title", "（无标题）")
        private fun pinnedOf(obj: JSONObject): Boolean = obj.optBoolean("pinned", false)
        private fun orderOf(obj: JSONObject): Double = obj.optDouble("order", 0.0)

        private fun metaOf(obj: JSONObject, today: String): String {
            // P2-10（v2.9.6 审计）：重复任务不再报「逾期」——App 内重复任务不计
            // 逾期，已结束重复也不会出现在列表（新P3-5）。
            // 新P3-5（v2.9.7 审计）：重复任务 meta 不再一律清空——「每周二 08:00、
            // 今日命中」这类**当天时刻**是有用信息。repeatMinute 有值时显示
            // HH:mm（与 App 内重复任务行的展示口径一致），无值留空。
            if (parseRepeat(obj) != RepeatMode.NONE) {
                val rm = obj.optInt("repeatMinute", -1)
                if (rm in 0 until 24 * 60) {
                    return String.format("%02d:%02d", rm / 60, rm % 60)
                }
                return ""
            }
            val dueStr = datePart(obj.opt("dueDate")) ?: return ""
            if (dueStr < today) return "逾期"
            if (dueStr == today) {
                val s = obj.opt("dueDate").toString()
                if (s.length >= 16) return "${s.substring(11, 13)}:${s.substring(14, 16)}"
                return "今天"
            }
            // 未来某天：显示 MM/dd
            return try {
                "${dueStr.substring(5, 7)}/${dueStr.substring(8, 10)}"
            } catch (_: Exception) {
                ""
            }
        }

        // ===== 重复判定（与 MidnightResetReceiver.isRecurrenceToday 保持一致； =====
        // ===== 月度规则以两侧 monthlyTargetDay 同款实现对齐，见 P2-4 修复）=====
        private fun parseRepeat(obj: JSONObject): RepeatMode {
            return when (obj.optString("repeat", null)) {
                "daily" -> RepeatMode.DAILY
                "weekly" -> RepeatMode.WEEKLY
                "interval" -> RepeatMode.INTERVAL
                "weekday" -> RepeatMode.WEEKDAY
                "monthly" -> RepeatMode.MONTHLY
                else -> RepeatMode.NONE
            }
        }

        private fun isRecurrenceToday(obj: JSONObject, repeat: RepeatMode, today: String): Boolean {
            val until = obj.optString("repeatUntil", "")
            if (until.isNotEmpty() && today > until) return false
            // 矩阵 C2（v3.0.0 审计）：显式暂停窗口——App 侧 v3.0.0 起对重复任务
            // 写入 `pausedUntil`（'yyyy-MM-dd'，窗口终点含当天）。窗口内任何一天
            // 都不该出现在小组件；旧实现只读 skipDates，窗口内的**循环日**虽被
            // 覆盖，但非循环日（如「每周一任务」窗口内的周三）不在 skipDates 中，
            // 桌件照常显示该任务，与 App 侧「暂停中不出现」口径不一致。窗口已过
            // （today > 终点）不影响展示。
            val paused = obj.optString("pausedUntil", "")
            if (paused.isNotEmpty() && today <= paused) return false
            val skip = obj.optJSONArray("skipDates")
            if (skip != null) {
                for (j in 0 until skip.length()) {
                    if (skip.optString(j, "") == today) return false
                }
            }
            return when (repeat) {
                RepeatMode.NONE -> false
                RepeatMode.DAILY -> true
                RepeatMode.WEEKDAY -> weekdayOf(today) in 1..5
                RepeatMode.WEEKLY -> {
                    val wd = weekdayOf(today)
                    val days = obj.optJSONArray("repeatWeekdays") ?: return false
                    for (j in 0 until days.length()) {
                        if (days.optInt(j, -1) == wd) return true
                    }
                    false
                }
                RepeatMode.INTERVAL -> {
                    val anchor = datePart(obj.opt("repeatAnchor")) ?: return false
                    val diff = dayDiff(anchor, today)
                    if (diff < 0) return false
                    val n = obj.optInt("repeatInterval", 2).coerceAtLeast(1)
                    diff % n == 0L
                }
                RepeatMode.MONTHLY -> {
                    val parts = today.split("-")
                    val y = parts[0].toInt()
                    val m = parts[1].toInt()
                    val target = monthlyTargetDay(obj, y, m)
                    String.format("%04d-%02d-%02d", y, m, target) == today
                }
            }
        }

        private fun weekdayOf(dateStr: String): Int {
            val parts = dateStr.split("-")
            if (parts.size < 3) return -1
            val cal = Calendar.getInstance()
            cal.set(parts[0].toInt(), parts[1].toInt() - 1, parts[2].toInt())
            val dow = cal.get(Calendar.DAY_OF_WEEK) // 1=Sun..7=Sat
            return if (dow == Calendar.SUNDAY) 7 else dow - 1
        }

        private fun dayDiff(a: String, b: String): Long {
            val pa = a.split("-")
            val pb = b.split("-")
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

    /** 每月重复在 [y]年[m]月的目标「日」(1-28/29/30/31)；与 Dart Task._baseRepeatsOn 一致。
     *  P2-4（v3.0.1 审计）：补上 [monthlyFromEnd]（每月倒数第 N 天 / 最后一天）
     *  分支——Dart 侧它优先级最高（task.dart _baseRepeatsOn），午夜重置层
     *  （MidnightResetReceiver.monthlyTargetDay）v2.9.8 起已实现；桌件此前
     *  缺失该分支，fromEnd 任务回落 monthlyDay（缺省 1）→ 每月 1 号错日显示、
     *  真正的月末反而不出现（v3.0.1 改过本文件补 pausedUntil，仍未顺带补齐——
     *  「只修点名处」通病的 Kotlin 侧复现）。与 MidnightResetReceiver.kt 同款实现。
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

    private fun datePart(v: Any?): String? {
            if (v == null || v === JSONObject.NULL) return null
            val s = v.toString()
            if (s.length < 10) return null
            return s.substring(0, 10)
        }

        private fun todayStr(): String {
            val now = Calendar.getInstance()
            return String.format(
                "%04d-%02d-%02d",
                now.get(Calendar.YEAR),
                now.get(Calendar.MONTH) + 1,
                now.get(Calendar.DAY_OF_MONTH),
            )
        }

        private fun todayDisplay(): String {
            val now = Calendar.getInstance()
            return String.format("%d月%d日", now.get(Calendar.MONTH) + 1, now.get(Calendar.DAY_OF_MONTH))
        }

        // ===== 跨进程只读打开 youtiao.db（与 :guard 进程读库同理：WAL + busy_timeout + 重试）=====
        private fun openGuardDb(dbPath: String): SQLiteDatabase? {
            val db = try {
                SQLiteDatabase.openDatabase(
                    dbPath,
                    null,
                    SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
                )
            } catch (e: Exception) {
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

        private fun <R> withGuardDb(dbPath: String, block: (SQLiteDatabase) -> R): R? {
            var lastErr: Exception? = null
            for (attempt in 1..3) {
                val db = openGuardDb(dbPath) ?: return null
                try {
                    return block(db)
                } catch (e: Exception) {
                    lastErr = e
                    val busy = e is SQLiteException &&
                        e.message?.contains("locked", ignoreCase = true) == true
                    if (!busy) break
                    if (attempt < 3) Thread.sleep(800)
                } finally {
                    try {
                        db.close()
                    } catch (_: Exception) {
                        // 忽略
                    }
                }
            }
            return null
        }

        private data class WidgetTask(
            val id: String,
            val title: String,
            val meta: String,
            val pinned: Boolean,
            val order: Double,
        )

        private enum class RepeatMode { NONE, DAILY, WEEKLY, INTERVAL, WEEKDAY, MONTHLY }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        try {
            // 多个 widget 复用同一 RemoteViews 即可。
            val views = Companion.buildRemoteViews(context)
            for (appWidgetId in appWidgetIds) {
                appWidgetManager.updateAppWidget(appWidgetId, views)
            }
        } catch (e: Exception) {
            // 最后一道防线：onUpdate 绝不能把异常抛给系统小组件宿主。
            Log.e(TAG, "onUpdate failed", e)
        }
    }
}
