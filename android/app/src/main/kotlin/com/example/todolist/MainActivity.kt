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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.todolist/exact_alarm"
    private val CHANNEL_IO = "com.example.todolist/file_io"

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
                    else -> result.notImplemented()
                }
            }
    }
}
