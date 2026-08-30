import 'package:flutter/foundation.dart';

/// 统一日志出口（安全审计 L-11）。
///
/// 背景：Flutter **不会**在 release 构建中自动剥离 `debugPrint` / `print`，
/// 而工程里有 70 余处 `debugPrint` 会打印任务标题、提醒调度细节等业务内容。
/// 在开启 USB 调试、厂商 bug 报告、录屏式诊断工具的场景下，这些内容可被读出，
/// 与产品「离线、隐私优先」的定位不符。
///
/// 用法：
/// ```dart
/// AppLog.d('调度提醒：${task.title}');   // release 下 no-op
/// AppLog.e('自动备份失败', e, s);        // release 下 no-op
/// ```
///
/// 另外在 [main] 中把 `debugPrint` 在 release 下整体置空，作为存量调用的兜底
/// （见 main.dart 的 `_silenceDebugPrintInRelease`）。新增代码请直接用本类。
class AppLog {
  const AppLog._();

  /// 是否静默（release 模式恒为 true）。
  static bool get muted => kReleaseMode;

  /// 调试日志。release 下直接返回，不产生任何输出。
  static void d(String message) {
    if (kReleaseMode) return;
    debugPrint(message);
  }

  /// 错误日志（可附带异常与堆栈）。release 下直接返回。
  static void e(String message, [Object? error, StackTrace? stack]) {
    if (kReleaseMode) return;
    debugPrint(stack == null ? message : '$message\n$error\n$stack');
  }
}
