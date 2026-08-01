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

# 通用 Flutter/R8 兼容性保留
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
