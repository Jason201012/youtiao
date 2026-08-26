# flutter_local_notifications 在 release 模式下用 Gson 持久化定时通知，
# R8 会混淆/擦除模型类的泛型签名，导致 Gson 反射时抛出
# "Missing type parameter" / "java.lang.RuntimeException: Missing type parameter"。
# 必须保留插件内部模型类及其泛型签名。
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keepclassmembers class com.dexterous.flutterlocalnotifications.** { *; }

# Gson 需要保留泛型签名与注解，否则同样会报 Missing type parameter
-keep class com.google.gson.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken { *; }
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn com.google.gson.**

# Flutter 引擎引用了 Play Core 动态分发类，但本 App 未启用 deferred components，
# 且未引入 play:core 依赖；R8 开启后会报 missing class，用 dontwarn 放行。
-dontwarn com.google.android.play.core.**

# 本应用 MethodChannel（精确闹钟权限查询）相关类，避免被 R8 重命名后反射找不到
-keep class com.example.todolist.MainActivity { *; }

# 前台守护服务：避免 R8 混淆后 release 下服务类被移除 / 反射找不到导致崩溃
-keep class com.example.todolist.ReminderForegroundService { *; }

# 通用 Flutter/R8 兼容性保留
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# 桌面小组件（TodayWidgetProvider）：manifest 已声明，但显式保留避免被 R8 误删，
# 且避免其跨进程读库 / RemoteViews 相关逻辑因混淆而异常。
-keep class com.example.todolist.TodayWidgetProvider { *; }

# local_auth（生物识别 / 锁屏密码）：Android 端依赖 androidx.biometric 反射与 Fragment 事务，
# 混淆后可能导致解锁流程崩溃，整体保留其 Android 实现类。
-keep class com.example.todolist.** { *; }
-dontwarn androidx.biometric.**

# just_audio：底层经 exoplayer / Android 媒体 API，release 下若被裁剪可能播放异常，
# 放行其 missing-class 告警（仅 warning，不影响链接）。
-dontwarn com.google.android.exoplayer2.**
-dontwarn androidx.media3.**

# 其它第三方 Android 依赖的 missing-class 放行（不进入正式包体的引用）。
-dontwarn org.bouncycastle.**
-dontwarn org.joda.time.**
