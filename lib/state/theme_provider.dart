import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';

/// 主题状态（浅/深、跟随系统、Material You 动态取色、自定义种子色、纯黑背景）。
///
/// 从旧版 TaskProvider 中剥离而来：主题与「任务数据」无关，独立成 Provider 后
/// 分层更干净，也让设置页的主题开关只驱动主题本身、不牵动任务状态。
///
/// 强调色来源优先级（[buildThemes] 内解析）：
///   1. 开启「Material You 跟随取色」且系统动态色可用且未单独选种子色 → 用系统色；
///   2. 否则用「种子色」（用户预设或默认品牌色）。
/// 无论哪种来源，最终都经 [buildAppTheme] 套用：结构性中性色沿用设计 token，
/// 仅 primary/accent 跟随来源色，从而自定义主题色/系统色自动作用于导航选中、
/// 开关、FAB、进度环等（它们都已绑定 colorScheme.primary / ext.accent）。
class ThemeProvider extends ChangeNotifier {
  static const String _kFollowSystem = 'theme_follow_system';
  static const String _kMode = 'theme_mode'; // 0=浅色, 1=深色（手动选择时）
  static const String _kUseDynamic = 'theme_use_dynamic';
  static const String _kSeed = 'theme_seed'; // hex value；-1 表示默认（无种子色）
  static const String _kPureBlack = 'theme_pure_black';

  /// 自定义主题色预设（不含「默认品牌」）。「默认」以 seed==null 表达。
  static const List<Color> seedPresets = [
    Color(0xFF0061A4), // 品牌蓝
    Color(0xFF6750A4), // M3 经典紫
    Color(0xFF00696E), // 青绿
    Color(0xFFB3261E), // 红
    Color(0xFF386A20), // 绿
    Color(0xFF965400), // 橙
    Color(0xFF8B4A82), // 玫红
  ];

  bool _followSystem = true;
  bool get followSystem => _followSystem;

  /// 手动选择的模式（未跟随系统时生效）。
  bool _dark = false;
  bool get dark => _dark;

  /// Material You：跟随系统取色。
  bool _useDynamic = true;
  bool get useDynamic => _useDynamic;

  /// 自定义种子色；-1 表示「默认品牌色」（不选具体色）。
  int _seedColor = -1;
  int get seedColorValue => _seedColor;
  Color? get seedColor => _seedColor < 0 ? null : Color(_seedColor);

  /// 深色模式纯黑背景（OLED 友好）。
  bool _pureBlack = false;
  bool get pureBlack => _pureBlack;

  /// 实际生效的主题模式：供 MaterialApp.themeMode 使用。
  ThemeMode get effectiveThemeMode =>
      _followSystem ? ThemeMode.system : (_dark ? ThemeMode.dark : ThemeMode.light);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _followSystem = prefs.getBool(_kFollowSystem) ?? true;
    _dark = prefs.getBool(_kMode) ?? false;
    _useDynamic = prefs.getBool(_kUseDynamic) ?? true;
    _seedColor = prefs.getInt(_kSeed) ?? -1;
    _pureBlack = prefs.getBool(_kPureBlack) ?? false;
  }

  Future<void> setFollowSystem(bool v) async {
    _followSystem = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFollowSystem, v);
  }

  /// 手动选择浅/深：自动退出「跟随系统」。
  Future<void> setDark(bool v) async {
    _followSystem = false;
    _dark = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFollowSystem, false);
    await prefs.setBool(_kMode, v);
  }

  Future<void> setUseDynamic(bool v) async {
    _useDynamic = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUseDynamic, v);
  }

  Future<void> setPureBlack(bool v) async {
    _pureBlack = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPureBlack, v);
  }

  /// 设置自定义种子色；传 null 表示恢复「默认品牌色」。
  Future<void> setSeedColor(Color? c) async {
    _seedColor = c == null ? -1 : c.value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeed, _seedColor);
  }

  /// 根据当前设置 + 系统动态色（若有）构建浅/深两套主题。
  /// [lightDynamic]/[darkDynamic] 来自 DynamicColorBuilder，不支持时为 null。
  (ThemeData, ThemeData) buildThemes(
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  ) {
    // 1) 系统动态取色优先（需开启且系统色可用且未单独选种子色）
    if (useDynamic &&
        seedColor == null &&
        lightDynamic != null &&
        darkDynamic != null) {
      return (
        buildAppTheme(lightDynamic, Brightness.light, pureBlack: pureBlack),
        buildAppTheme(darkDynamic, Brightness.dark, pureBlack: pureBlack),
      );
    }
    // 2) 否则用种子色（默认品牌色）
    final base = seedColor ?? AppColors.lightPrimary;
    final lightScheme =
        ColorScheme.fromSeed(seedColor: base, brightness: Brightness.light);
    final darkScheme =
        ColorScheme.fromSeed(seedColor: base, brightness: Brightness.dark);
    return (
      buildAppTheme(lightScheme, Brightness.light, pureBlack: pureBlack),
      buildAppTheme(darkScheme, Brightness.dark, pureBlack: pureBlack),
    );
  }
}
