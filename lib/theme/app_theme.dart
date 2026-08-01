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
