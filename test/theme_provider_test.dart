import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/state/theme_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/services/local_database.dart';
import 'test_helpers.dart';

void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

void main() {
  setUpAll(_installMocks);
  // SharedPreferences.getInstance() 在用例间缓存同一实例，setXxx 写入会泄漏到后续
  // 用例的 load()。每个用例清空该缓存实例 + 内存数据库，保证隔离。
  setUp(() async {
    // SharedPreferences.getInstance() 在用例间缓存同一实例；setXxx 写入会泄漏到后续
    // 用例的 load()。每个用例通过缓存实例清空，保证隔离。
    final sp = await SharedPreferences.getInstance();
    await sp.clear();
    LocalDatabase.resetMemoryForTest();
  });

  test('默认值：跟随系统 + 浅色 + 开启动态取色 + 无种子色', () async {
    final t = ThemeProvider();
    await t.load();
    expect(t.followSystem, isTrue);
    expect(t.dark, isFalse);
    expect(t.useDynamic, isTrue);
    expect(t.seedColor, isNull);
    expect(t.effectiveThemeMode, ThemeMode.system);
  });

  test('setDark 退出跟随系统并切换深浅', () async {
    final t = ThemeProvider();
    await t.load();
    await t.setDark(true);
    expect(t.followSystem, isFalse);
    expect(t.dark, isTrue);
    expect(t.effectiveThemeMode, ThemeMode.dark);
    await t.setDark(false);
    expect(t.effectiveThemeMode, ThemeMode.light);
  });

  test('setFollowSystem 回到跟随系统', () async {
    final t = ThemeProvider();
    await t.load();
    await t.setDark(true);
    await t.setFollowSystem(true);
    expect(t.followSystem, isTrue);
    expect(t.effectiveThemeMode, ThemeMode.system);
  });

  test('setSeedColor 优先于动态取色（buildThemes 用种子色）', () async {
    final t = ThemeProvider();
    await t.load();
    await t.setSeedColor(const Color(0xFF6750A4));
    expect(t.seedColorValue, 0xFF6750A4);
    final themes = t.buildThemes(null, null);
    final brandPrimary = ColorScheme.fromSeed(
      seedColor: AppColors.lightPrimary,
      brightness: Brightness.light,
    ).primary;
    // 种子色生效：浅色 primary 不再是默认品牌色。
    expect(themes.$1.colorScheme.primary, isNot(equals(brandPrimary)));
    // 扩展色 accent 跟随 primary。
    expect(
      themes.$1.extension<AppColorsExt>()!.accent,
      themes.$1.colorScheme.primary,
    );
  });

  test('useDynamic 关闭且种子色为空 → 用默认品牌色', () async {
    final t = ThemeProvider();
    await t.load();
    await t.setUseDynamic(false);
    final themes = t.buildThemes(null, null);
    final brandPrimary = ColorScheme.fromSeed(
      seedColor: AppColors.lightPrimary,
      brightness: Brightness.light,
    ).primary;
    expect(themes.$1.colorScheme.primary, brandPrimary);
  });

  test('setPureBlack 仅把深色背景置为纯黑', () async {
    final t = ThemeProvider();
    await t.load();
    await t.setPureBlack(true);
    final themes = t.buildThemes(null, null);
    expect(themes.$2.scaffoldBackgroundColor, const Color(0xFF000000));
    // 浅色不受影响。
    expect(themes.$1.scaffoldBackgroundColor, isNot(equals(const Color(0xFF000000))));
  });
}
