import 'package:flutter/services.dart';

/// 应用内安装 APK：通过 MethodChannel 调 MainActivity 的 installApk，
/// 后者用 FileProvider 生成 content:// uri 并唤起系统安装器。
class ApkInstaller {
  static const _channel = MethodChannel('com.example.todolist/installer');

  /// [apkPath] 为已下载到外部缓存目录（与 FileProvider 配置一致）的 APK 文件路径。
  static Future<void> install(String apkPath) async {
    await _channel.invokeMethod<void>('installApk', {'path': apkPath});
  }
}
