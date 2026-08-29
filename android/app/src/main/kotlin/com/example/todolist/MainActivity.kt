package com.example.todolist

import android.app.AlarmManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.example.todolist/exact_alarm"
    private val CHANNEL_IO = "com.example.todolist/file_io"
    private val CHANNEL_BG = "com.example.todolist/background_service"
    private val CHANNEL_MIDNIGHT = "com.example.todolist/midnight_reset"
    private val CHANNEL_INSTALL = "com.example.todolist/installer"
    /// 分享文本通道：其他 App（微信/QQ 等）通过 ACTION_SEND 把文字转发给「有条」时，
    /// 原生侧把文本经此通道传给 Dart，由 QuickEntrySheet 预填并解析。
    private val CHANNEL_SHARE = "com.example.todolist/share_intent"
    private var shareHandler: MethodChannel? = null
    /// Flutter 引擎尚未就绪时（冷启动）收到的分享文本先缓存，引擎就绪后补发。
    private var pendingShareText: String? = null
    /// 冷启动时分享的来源包名（P2-8：用于展示「来自 XX」）。
    private var pendingShareSource: String? = null
    /// P1-11：系统分享接收图片/文件：其他 App 经 ACTION_SEND + EXTRA_STREAM 把单个 content Uri
    /// 发给「有条」，原生侧把二进制复制进应用私有缓存后，经此通道把本地临时路径 + 类型/大小
    /// 等元数据传给 Dart，由 QuickEntrySheet 预填附件并解析标题，用户确认后落盘。
    /// （这是「接收系统分发」，App 自身不发起任何网络请求。）
    private val CHANNEL_SHARE_URI = "com.example.todolist/share_uri"
    private var shareUriHandler: MethodChannel? = null
    /// Flutter 引擎尚未就绪时（冷启动）收到的分享附件元数据先缓存，引擎就绪后补发。
    private var pendingShareUriMeta: Map<String, Any>? = null
    /// P1-11：分享附件单次导入的体积上限（字节），与 AttachmentService.maxImportFileBytes 对齐（200 MB）。
    /// 超过则直接拒绝落盘，防止本地超大文件被当作附件滥用。
    private val MAX_SHARE_BYTES = 200L * 1024 * 1024
    /// P2-D：`share_inbox` 会话目录的最大存活时长（与 AttachmentService.staleStagingMaxAge 对齐）。
    /// 超过则启动时兜底清理，避免异常路径残留让私有缓存无限增长。
    private val SHARE_INBOX_MAX_AGE_MS = 24L * 60 * 60 * 1000
    /// 桌面小组件点击任务项：原生带 EXTRA_TASK_ID 启动 MainActivity，再经此通道让 Dart 直达详情页。
    private val CHANNEL_WIDGET_NAV = "com.example.todolist/widget_nav"
    private var widgetNavHandler: MethodChannel? = null
    /// Flutter 引擎尚未就绪时（冷启动）缓存小组件点击的任务 id，引擎就绪后补发。
    private var pendingWidgetTaskId: String? = null
    /// 小组件刷新通道：Dart 侧每次 _persist 后调用，主动刷新桌面部件（今日任务列表）。
    private val CHANNEL_WIDGET_REFRESH = "com.example.todolist/widget_refresh"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canScheduleExactAlarms" -> {
                        val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            // Android 12+：需用户授予 SCHEDULE_EXACT_ALARM
                            result.success(am.canScheduleExactAlarms())
                        } else {
                            // Android 12 以下无需该权限，setExact 默认可用
                            result.success(true)
                        }
                    }
                    "openExactAlarmSettings" -> {
                        try {
                            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                    .apply { data = Uri.parse("package:$packageName") }
                            } else {
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                    .apply { data = Uri.parse("package:$packageName") }
                            }
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // 兜底：直接打开应用详情页，让用户自行找「精确闹钟 / 电池」设置
                            try {
                                val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                    .apply { data = Uri.parse("package:$packageName") }
                                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(fallback)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("OPEN_FAILED", e2.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 文件落盘通道：把内容写入系统「下载 / Downloads」目录（MediaStore，免存储权限）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_IO)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val fileName = call.argument<String>("fileName")
                        val content = call.argument<String>("content")
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        if (fileName == null || content == null) {
                            result.error("BAD_ARGS", "fileName 与 content 必填", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            try {
                                val resolver = contentResolver
                                val values = ContentValues().apply {
                                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                                    put(MediaStore.Downloads.IS_PENDING, 1)
                                }
                                val uri = resolver.insert(
                                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                                    values,
                                )
                                if (uri == null) {
                                    result.error(
                                        "INSERT_FAIL",
                                        "无法在 Downloads 创建文件（可能被系统拦截）",
                                        null,
                                    )
                                    return@setMethodCallHandler
                                }
                                resolver.openOutputStream(uri)?.use { os ->
                                    os.write(content.toByteArray(Charsets.UTF_8))
                                }
                                values.clear()
                                values.put(MediaStore.Downloads.IS_PENDING, 0)
                                resolver.update(uri, values, null, null)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("SAVE_FAIL", e.message, null)
                            }
                        } else {
                            result.error(
                                "UNSUPPORTED",
                                "Android 10 以下不支持直接写入 Downloads",
                                null,
                            )
                        }
                    }
                    // 把 PNG 字节写入系统相册（Pictures/有条），Android 10+ 免存储权限。
                    // 用于「看板分享长图」的保存到相册。
                    "saveImageToGallery" -> {
                        val fileName = call.argument<String>("fileName")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (fileName == null || bytes == null) {
                            result.error("BAD_ARGS", "fileName 与 bytes 必填", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            try {
                                val resolver = contentResolver
                                val values = ContentValues().apply {
                                    put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                                    put(
                                        MediaStore.Images.Media.RELATIVE_PATH,
                                        Environment.DIRECTORY_PICTURES + "/有条",
                                    )
                                    put(MediaStore.Images.Media.IS_PENDING, 1)
                                }
                                val uri = resolver.insert(
                                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                    values,
                                )
                                if (uri == null) {
                                    result.error(
                                        "INSERT_FAIL",
                                        "无法在相册创建图片（可能被系统拦截）",
                                        null,
                                    )
                                    return@setMethodCallHandler
                                }
                                resolver.openOutputStream(uri)?.use { os ->
                                    os.write(bytes)
                                }
                                values.clear()
                                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                                resolver.update(uri, values, null, null)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("SAVE_FAIL", e.message, null)
                            }
                        } else {
                            result.error(
                                "UNSUPPORTED",
                                "Android 10 以下不支持免权限写入相册",
                                null,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 前台守护服务通道：start/stop 让 App 在后台常驻，
        // 保证定时提醒在 ColorOS 等国产 ROM 上划掉后台后仍准时送达。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_BG)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            val intent =
                                Intent(this, ReminderForegroundService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("START_FAIL", e.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            stopService(
                                Intent(this, ReminderForegroundService::class.java),
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("STOP_FAIL", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 午夜重置闹钟通道：Dart 侧在启动时挂上「当天 00:00 自动重置每日任务」的
        // setAlarmClock 闹钟（ColorOS 可靠）；关闭每日重置时取消。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_MIDNIGHT)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "schedule" -> {
                        try {
                            MidnightResetReceiver.schedule(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SCHED_FAIL", e.message, null)
                        }
                    }
                    "cancel" -> {
                        try {
                            MidnightResetReceiver.cancel(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("CANCEL_FAIL", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 应用内更新：接收 APK 文件路径，经 FileProvider 生成 content:// uri 后
        // 唤起系统安装器（Android 7+ 不允许以 file:// 跨应用传递，否则抛 FileUriExposedException）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_INSTALL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("NO_PATH", "path 为空", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(File(path))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 分享文本通道：注册后，冷启动时 pendingShareText 由引擎就绪后的首帧补发到 Dart 侧。
        shareHandler = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_SHARE)
        // 若冷启动期间已收到分享文本（onCreate 早于引擎就绪），此刻补发给 Dart。
        val pending = pendingShareText
        val pendingSrc = pendingShareSource
        if (pending != null) {
            pendingShareText = null
            pendingShareSource = null
            shareHandler?.invokeMethod("onSharedText", mapOf("text" to pending, "source" to pendingSrc))
        }

        // 分享附件（图片/文件）通道：注册后，冷启动时 pendingShareUriMeta 由引擎就绪后的首帧补发到 Dart 侧。
        shareUriHandler = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_SHARE_URI)
        val pendingUri = pendingShareUriMeta
        if (pendingUri != null) {
            pendingShareUriMeta = null
            shareUriHandler?.invokeMethod("onSharedUri", pendingUri)
        }

        // 小组件导航通道：原生点击任务项带 EXTRA_TASK_ID 启动 Activity 后，经此通道让 Dart 打开详情页。
        widgetNavHandler = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_WIDGET_NAV)
        // 冷启动期间由小组件点击拉起：onCreate 早于引擎就绪，此刻补发给 Dart。
        val pw = pendingWidgetTaskId
        if (pw != null) {
            pendingWidgetTaskId = null
            widgetNavHandler?.invokeMethod("openTask", pw)
        }

        // 小组件刷新通道：Dart 侧 _persist 后调用，主动刷新桌面部件（今日任务列表）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_WIDGET_REFRESH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "refresh" -> {
                        try {
                            TodayWidgetProvider.refreshAll(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("REFRESH_FAIL", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(apk: File) {
        // 路径归属校验：仅允许安装应用自身外部缓存目录（file_paths.xml 限定的
        // external-cache/updates/）下的 APK，杜绝传入任意路径导致安装外部文件。
        //
        // 🔒 安全加固：此前用 `apk.absolutePath.startsWith(cacheDir.absolutePath)`
        // 前缀匹配，理论上 `"…/cache/../files/x.apk"` 可绕过前缀检查。改为比较
        // canonicalPath（解析 `..` 与符号链接后的真实路径），确保 APK 确实落在
        // 应用外部缓存目录内。FileProvider 的 paths 白名单仍作为二次兜底。
        val cacheDir = externalCacheDir
        if (cacheDir == null) {
            throw SecurityException("无法获取应用缓存目录")
        }
        val canonicalApk = apk.canonicalPath
        val canonicalCache = cacheDir.canonicalPath
        if (!canonicalApk.startsWith(canonicalCache)) {
            throw SecurityException("APK 路径不在应用缓存目录内：$canonicalApk")
        }
        val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        } else {
            Uri.fromFile(apk)
        }
        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            data = uri
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(intent)
    }

    /// 冷启动：若由「分享」入口拉起（ACTION_SEND + 文本），在引擎就绪前先接到 intent。
    /// 缓存文本，待 configureFlutterEngine 注册通道后补发；引擎已就绪则直接发送。
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // P2-D：先把上次异常退出残留的 share_inbox 旧目录清掉，再处理本次 intent。
        cleanupStaleShareInbox()
        dispatchShareText(intent)
        dispatchShareStream(intent)
        dispatchWidgetTask(intent)
    }

    /// P2-D：`share_inbox` 启动兜底清理。正常路径下 Dart 侧消费完附件后会删除缓存目录，
    /// 但「引擎被系统杀死 / pendingShareUriMeta 从未被消费 / 导入前 return」等异常路径会
    /// 留下 `<cache>/share_inbox/<sessionId>/`。这里清掉超过 24h 的旧会话目录。
    private fun cleanupStaleShareInbox() {
        try {
            val root = File(cacheDir, "share_inbox")
            if (!root.exists()) return
            val cutoff = System.currentTimeMillis() - SHARE_INBOX_MAX_AGE_MS
            root.listFiles()?.forEach { dir ->
                if (dir.isDirectory && dir.lastModified() < cutoff) {
                    dir.deleteRecursively()
                }
            }
        } catch (_: Exception) {
            // 清理失败不阻断启动。
        }
    }

    /// 热分享（App 已在前台，launchMode=singleTop）：新分享 intent 走 onNewIntent 而非重建 Activity，
    /// 避免重复开 Activity，并把文本实时推送进 Dart 侧预填录入层。
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        dispatchShareText(intent)
        dispatchShareStream(intent)
        dispatchWidgetTask(intent)
    }

    /// 从 SEND intent 取出 EXTRA_TEXT（纯文本），缓存并在引擎就绪后发给 Dart。
    /// 末尾独立的分享页 URL（如 \nhttps://...）会被截掉，仅保留正文，交给 TaskParser 解析。
    private fun dispatchShareText(i: Intent?) {
        val text = i?.takeIf { it.action == Intent.ACTION_SEND }
            ?.getStringExtra(Intent.EXTRA_TEXT)?.trim() ?: return
        if (text.isEmpty()) return
        // 去掉末尾独立的分享页 URL 行（微信/QQ 常附一条链接），避免污染任务标题。
        val body = text
            .replace(Regex("(?m)\\n?https?://\\S+$"), "")
            .trim()
        if (body.isEmpty()) return
        // P2-8：记录分享来源包名（来自 getCallingActivity），用于预填录入层展示「来自 XX」。
        val source = callingActivity?.packageName
        // 引擎未就绪（冷启动）时 invokeMethod 会失败 → 缓存，configureFlutterEngine 末尾补发。
        pendingShareText = body
        pendingShareSource = source
        shareHandler?.invokeMethod("onSharedText", mapOf("text" to body, "source" to source))
    }

    /// P1-11：从 SEND intent 取出 EXTRA_STREAM（单个 content Uri，图片/文件），复制其二进制流到
    /// 应用私有缓存目录，并把本地路径 + 类型/大小等元数据经 [CHANNEL_SHARE_URI] 通道发给 Dart。
    /// 复制成功后立即 [revokeUriPermission] 收回读取授权（消费完即释放），不长期持有来源 App 的授权。
    /// 类型/大小预检：仅接受 image/audio/file 三类；超限文件拒绝落盘（防本地超大文件滥用）。
    /// 与 [dispatchShareText] 互斥：文本分享走 EXTRA_TEXT、附件分享走 EXTRA_STREAM，互不干扰。
    @Suppress("DEPRECATION")
    private fun dispatchShareStream(i: Intent?) {
        val uri = i?.takeIf { it.action == Intent.ACTION_SEND }
            ?.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: return
        // 读 content URI 的显示名 / 大小 / MIME（部分来源不返回大小，记为 -1，复制后二次校验）。
        val cr = contentResolver
        var mimeType: String? = i.type
        var displayName: String? = null
        var size: Long = -1
        try {
            cr.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIdx >= 0) displayName = c.getString(nameIdx)
                    val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIdx >= 0 && !c.isNull(sizeIdx)) size = c.getLong(sizeIdx)
                }
            }
        } catch (_: Exception) {
            // 查询元数据失败不阻断，仍尝试按 intent.type 复制。
        }
        if (mimeType == null) {
            try {
                mimeType = cr.getType(uri)
            } catch (_: Exception) {
                // 退回 */*，Dart 侧归为 file 类型。
            }
        }
        // 类型归并：image/* → image，audio/* → audio，其余（含 */*）→ file。
        val type = when {
            mimeType?.startsWith("image/") == true -> "image"
            mimeType?.startsWith("audio/") == true -> "audio"
            else -> "file"
        }
        // 已知大小超限：直接拒绝（引用 MAX_SHARE_BYTES 与 Dart 侧 importFile 上限一致）。
        if (size > MAX_SHARE_BYTES) {
            runOnUiThread { Toast.makeText(this, "附件过大，已忽略", Toast.LENGTH_SHORT).show() }
            return
        }
        // 复制到应用私有缓存目录（getCacheDir == Flutter getTemporaryDirectory），离线、不联网。
        val sessionId = "${System.currentTimeMillis()}_${(Math.random() * 100000).toInt()}"
        val fallbackName = "shared_$sessionId"
        val safeName = sanitizeSharedName(displayName ?: fallbackName, fallbackName)
        val outDir = File(getCacheDir(), "share_inbox/$sessionId")
        if (!outDir.mkdirs() && !outDir.exists()) return
        val outFile = File(outDir, safeName)
        try {
            cr.openInputStream(uri)?.use { input ->
                outFile.outputStream().use { output -> input.copyTo(output) }
            } ?: run {
                // 无法打开输入流（来源撤销授权等）：放弃。
                return
            }
        } catch (_: Exception) {
            // 读取/写入失败：清理残留，放弃分享。
            try { outDir.deleteRecursively() } catch (_: Exception) {}
            return
        }
        // 复制后按实际体积二次校验（未知大小时 size=-1，此处用真实落盘大小兜底）。
        val realSize = outFile.length()
        if (realSize > MAX_SHARE_BYTES) {
            try { outDir.deleteRecursively() } catch (_: Exception) {}
            runOnUiThread { Toast.makeText(this, "附件过大，已忽略", Toast.LENGTH_SHORT).show() }
            return
        }
        // 复制成功：立即收回读取授权（消费完 content URI 即释放，不长期持有）。
        try {
            revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) {
            // 无授权可收回时静默忽略。
        }
        // 分享来源包名（用于 Dart 侧预填层展示「来自 XX」）。
        val source = callingActivity?.packageName
        val meta = mapOf(
            "localPath" to outFile.absolutePath,
            "fileName" to safeName,
            "mimeType" to (mimeType ?: ""),
            "sizeBytes" to realSize,
            "type" to type,
            "source" to (source ?: ""),
        )
        // 引擎未就绪（冷启动）时 invokeMethod 会失败 → 缓存，configureFlutterEngine 末尾补发。
        pendingShareUriMeta = meta
        shareUriHandler?.invokeMethod("onSharedUri", meta)
    }

    /// P1-11：把来源提供的显示名净化为安全文件名（仅保留字母数字、点、下划线、连字符与中文，
    /// 其余替换为下划线），杜绝 content URI 显示名携带路径穿越字符写入私有缓存目录。
    private fun sanitizeSharedName(raw: String, fallback: String): String {
        val cleaned = raw.replace(Regex("[^\\w.\\-一-龥]"), "_")
        // 安全（P2-B）：正则白名单保留了点号，来源显示名恰为 "." / ".." 时结果仍是危险的
        // 相对路径段（File(outDir, "..") 指向父目录）。这里显式拒绝并回退，而不是依赖
        // 「OS 写目录会失败」兜底。
        if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") return fallback
        return cleaned
    }

    /// 桌面小组件点击任务项：原生带 EXTRA_TASK_ID 启动 MainActivity 后，把任务 id
    /// 经 widget_nav 通道转给 Dart，由 _navigateFromPayload('task:<id>') 直达详情页。
    /// 引擎未就绪（冷启动）时先缓存 id，待 configureFlutterEngine 注册通道后补发。
    private fun dispatchWidgetTask(i: Intent?) {
        val id = i?.getStringExtra(TodayWidgetProvider.EXTRA_TASK_ID) ?: return
        if (id.isEmpty()) return
        pendingWidgetTaskId = id
        widgetNavHandler?.invokeMethod("openTask", id)
    }
}
