import 'package:flutter/services.dart';

/// 窗口防截屏 / 防录屏开关（安全审计 L-07）。
///
/// 未设置 `FLAG_SECURE` 时：
/// - 最近任务列表里的 App 缩略图会完整定格任务内容；
/// - 任意录屏 / 投屏软件可录制界面；
/// - 恶意辅助功能可窥屏。
///
/// 开启后系统会在最近任务里显示空白缩略图，并阻止截屏与录屏。
/// 实现在 MainActivity（MethodChannel `com.example.todolist/window_flags`），
/// 支持运行时开关；原生侧在 onCreate 时按持久化值先应用一次。
class SecureWindow {
  static const MethodChannel _channel =
      MethodChannel('com.example.todolist/window_flags');

  /// 应用/取消 FLAG_SECURE。失败静默（.desktop / Web 平台无此概念，不影响使用）。
  static Future<void> setFlagSecure(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setFlagSecure', {'enabled': enabled});
    } on MissingPluginException {
      // 非 Android 平台：无此通道，忽略。
    } catch (_) {
      // 原生侧失败不应影响 UI 流程。
    }
  }
}
