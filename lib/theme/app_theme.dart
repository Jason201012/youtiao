import 'package:flutter/material.dart';
import 'tokens.dart';

/// 设计稿扩展色（ColorScheme 未覆盖的语义色）
class AppColorsExt extends ThemeExtension<AppColorsExt> {
  final Color meta;
  final Color track;
  final Color chip;
  final Color navFill;
  final Color navBorder;
  final Color accent;
  final Color high;
  final Color medium;
  final Color low;

  const AppColorsExt({
    required this.meta,
    required this.track,
    required this.chip,
    required this.navFill,
    required this.navBorder,
    required this.accent,
    required this.high,
    required this.medium,
    required this.low,
  });

  @override
  AppColorsExt copyWith({
    Color? meta,
    Color? track,
    Color? chip,
    Color? navFill,
    Color? navBorder,
    Color? accent,
    Color? high,
    Color? medium,
    Color? low,
  }) =>
      AppColorsExt(
        meta: meta ?? this.meta,
        track: track ?? this.track,
        chip: chip ?? this.chip,
        navFill: navFill ?? this.navFill,
        navBorder: navBorder ?? this.navBorder,
        accent: accent ?? this.accent,
        high: high ?? this.high,
        medium: medium ?? this.medium,
        low: low ?? this.low,
      );

  @override
  ThemeExtension<AppColorsExt> lerp(ThemeExtension<AppColorsExt>? other, double t) {
    if (other is! AppColorsExt) return this;
    return AppColorsExt(
      meta: Color.lerp(meta, other.meta, t)!,
      track: Color.lerp(track, other.track, t)!,
      chip: Color.lerp(chip, other.chip, t)!,
      navFill: Color.lerp(navFill, other.navFill, t)!,
      navBorder: Color.lerp(navBorder, other.navBorder, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      high: Color.lerp(high, other.high, t)!,
      medium: Color.lerp(medium, other.medium, t)!,
      low: Color.lerp(low, other.low, t)!,
    );
  }

  static const light = AppColorsExt(
    meta: AppColors.lightMeta,
    track: AppColors.lightTrack,
    chip: AppColors.lightChip,
    navFill: AppColors.lightNavFill,
    navBorder: AppColors.lightNavBorder,
    accent: AppColors.lightAccent,
    high: AppColors.lightHigh,
    medium: AppColors.lightMedium,
    low: AppColors.lightLow,
  );

  static const dark = AppColorsExt(
    meta: AppColors.darkMeta,
    track: AppColors.darkTrack,
    chip: AppColors.darkChip,
    navFill: AppColors.darkNavFill,
    navBorder: AppColors.darkNavBorder,
    accent: AppColors.darkAccent,
    high: AppColors.darkHigh,
    medium: AppColors.darkMedium,
    low: AppColors.darkLow,
  );

  /// 由「当前强调色 + 亮度」构造扩展色：结构性中性色沿用设计 token，
  /// 仅 [accent] 跟随用户/系统取色（自定义主题色、Material You 系统色均经此生效）。
  static AppColorsExt fromColors({
    required Color accent,
    required bool isDark,
  }) {
    return AppColorsExt(
      meta: isDark ? AppColors.darkMeta : AppColors.lightMeta,
      track: isDark ? AppColors.darkTrack : AppColors.lightTrack,
      chip: isDark ? AppColors.darkChip : AppColors.lightChip,
      navFill: isDark ? AppColors.darkNavFill : AppColors.lightNavFill,
      navBorder: isDark ? AppColors.darkNavBorder : AppColors.lightNavBorder,
      accent: accent,
      high: isDark ? AppColors.darkHigh : AppColors.lightHigh,
      medium: isDark ? AppColors.darkMedium : AppColors.lightMedium,
      low: isDark ? AppColors.darkLow : AppColors.lightLow,
    );
  }
}

/// 便捷获取扩展色
AppColorsExt appColors(BuildContext context) =>
    Theme.of(context).extension<AppColorsExt>()!;

final lightTheme = ThemeData(
  brightness: Brightness.light,
  scaffoldBackgroundColor: AppColors.lightBackground,
  colorScheme: ColorScheme.light(
    primary: AppColors.lightPrimary,
    surface: AppColors.lightSurface,
    background: AppColors.lightBackground,
    onBackground: AppColors.lightOnBackground,
    onSurface: AppColors.lightOnBackground,
    onSurfaceVariant: AppColors.lightMeta,
    outline: AppColors.lightMeta,
  ),
  extensions: const [AppColorsExt.light],
  fontFamily: 'Inter',
  fontFamilyFallback: const ['Noto Sans SC', 'PingFang SC', 'Microsoft YaHei'],
  textTheme: const TextTheme(
    headlineSmall: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 15),
    bodyMedium: TextStyle(fontSize: 13),
    labelSmall: TextStyle(fontSize: 12),
  ),
);

final darkTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: AppColors.darkBackground,
  colorScheme: ColorScheme.dark(
    primary: AppColors.darkPrimary,
    surface: AppColors.darkSurface,
    background: AppColors.darkBackground,
    onBackground: AppColors.darkOnBackground,
    onSurface: AppColors.darkOnBackground,
    onSurfaceVariant: AppColors.darkMeta,
    outline: AppColors.darkMeta,
  ),
  extensions: const [AppColorsExt.dark],
  fontFamily: 'Inter',
  fontFamilyFallback: const ['Noto Sans SC', 'PingFang SC', 'Microsoft YaHei'],
  textTheme: const TextTheme(
    headlineSmall: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 15),
    bodyMedium: TextStyle(fontSize: 13),
    labelSmall: TextStyle(fontSize: 12),
  ),
);

/// 由给定的 [ColorScheme]（来自系统动态取色，或 [ColorScheme.fromSeed] 生成的种子色）
/// 构建一套 Material 3 主题。结构性的背景/表面/中性色沿用设计 token，[scheme.primary]
/// 作为强调色驱动导航选中、开关、FAB、进度环等（它们都已绑定 colorScheme.primary /
/// ext.accent）。
ThemeData buildAppTheme(
  ColorScheme scheme,
  Brightness brightness, {
  bool pureBlack = false,
}) {
  final isDark = brightness == Brightness.dark;
  final background = pureBlack && isDark
      ? const Color(0xFF000000)
      : (isDark ? AppColors.darkBackground : AppColors.lightBackground);
  final surface = isDark ? AppColors.darkSurface : AppColors.lightSurface;
  final onBackground =
      isDark ? AppColors.darkOnBackground : AppColors.lightOnBackground;
  final meta = isDark ? AppColors.darkMeta : AppColors.lightMeta;
  final cs = scheme.copyWith(
    surface: surface,
    background: background,
    onBackground: onBackground,
    onSurface: onBackground,
    onSurfaceVariant: meta,
    outline: meta,
  );
  final ext = AppColorsExt.fromColors(accent: cs.primary, isDark: isDark);
  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: background,
    colorScheme: cs,
    extensions: [ext],
    fontFamily: 'Inter',
    fontFamilyFallback: const ['Noto Sans SC', 'PingFang SC', 'Microsoft YaHei'],
    textTheme: const TextTheme(
      headlineSmall: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 15),
      bodyMedium: TextStyle(fontSize: 13),
      labelSmall: TextStyle(fontSize: 12),
    ),
  );
}
