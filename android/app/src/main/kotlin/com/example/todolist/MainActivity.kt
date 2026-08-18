package com.example.todolist

import android.app.AlarmManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.todolist/exact_alarm"
    private val CHANNEL_IO = "com.example.todolist/file_io"
    private val CHANNEL_BG = "com.example.todolist/background_service"
    private val CHANNEL_MIDNIGHT = "com.example.todolist/midnight_reset"
    private val CHANNEL_INSTALL = "com.example.todolist/installer"

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
    }

    private fun installApk(apk: File) {
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
}
