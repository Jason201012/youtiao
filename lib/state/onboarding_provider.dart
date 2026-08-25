import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首次启动引导页状态。
///
/// 记录用户是否已看过首启引导，持久化于 [SharedPreferences]。
/// 全新安装默认未看过 —— 首启进入 3 屏引导；看过之后任何启动都直进主页，不再打扰。
/// 与现有「首启预置 7 条示例任务」解耦：本 Provider 只管「看没看过」这一个布尔标志，
/// 是否清空示例任务由引导页第 3 屏选择后调用 [TaskProvider.clearSampleTasks] 处理。
class OnboardingProvider extends ChangeNotifier {
  static const String _kSeen = 'onboarding_seen';

  bool _seen = false;

  /// 是否已看过引导页。true 表示首启流程已完成。
  bool get hasSeenIntro => _seen;

  /// 从 [SharedPreferences] 读取标志位，须在 [runApp] 前于 main() 调用。
  /// 读取失败（少见）一律降级为「未看过」，确保首启仍能进入引导页而非卡白屏。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _seen = prefs.getBool(_kSeen) ?? false;
    } catch (_) {
      _seen = false;
    }
    notifyListeners();
  }

  /// 标记引导已完成并落盘。
  /// 多次调用安全（已看过则直接返回，不重复写盘）。写入失败不影响本次进入主页，
  /// 最坏情况是下次启动再显示一次引导，可接受。
  Future<void> complete() async {
    if (_seen) return;
    _seen = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSeen, true);
    } catch (_) {
      // 持久化失败：保持内存态为 true，本次仍能进主页。
    }
  }

  /// 进程即将被杀（AppLifecycleState.paused/detached）时调用，把「是否看过引导」
  /// 重新落盘，防御 shared_preferences.apply() 在激进 ROM 杀进程时丢写。
  Future<void> persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSeen, _seen);
    } catch (_) {
      // 持久化失败不影响退出。
    }
  }
}
