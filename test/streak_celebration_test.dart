import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/screens/habit_screen.dart';
import 'package:todolist/widgets/streak_celebration.dart';
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
  setUp(() => LocalDatabase.resetMemoryForTest());

  testWidgets('showStreakCelebration 插入全屏庆祝（新纪录文案 + 天数）',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: const Scaffold(body: SizedBox()),
    ));
    final ctx = tester.element(find.byType(Scaffold));
    showStreakCelebration(ctx, 5);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('新纪录！'), findsOneWidget);
    expect(find.text('连续 5 天'), findsOneWidget);
    // 冲刷自带的 2s 移除定时器，否则测试结束仍 pending timer
    await tester.pump(const Duration(milliseconds: 2300));
  });

  testWidgets('打破历史最长连续时触发庆祝动效', (tester) async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
        title: '破纪录', emoji: '🔥', colorValue: 1, weekdays: []);
    final habit = hp.habits.first;
    final now = DateTime.now();
    // 先打前天、昨天（历史最长 = 2），今天不打
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 1)));
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 2)));
    expect(hp.longestStreak(habit), 2);

    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: const Scaffold(body: SizedBox()),
    ));
    final ctx = tester.element(find.byType(Scaffold));
    await checkInWithCelebration(ctx, hp, habit);
    // 打完今天后当前连续 = 3 > 2，应触发庆祝
    expect(hp.currentStreak(habit), 3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('新纪录！'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2300));
  });

  testWidgets('未打破纪录（当前连续 ≤ 历史最长）不触发庆祝', (tester) async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
        title: '保持', emoji: '💧', colorValue: 1, weekdays: []);
    final habit = hp.habits.first;
    final now = DateTime.now();
    // 历史最长 = 3（前天/大前天/3天前，不含昨天），今天缺 → 今天补打后孤立，当前连续 = 1
    for (var i = 2; i <= 4; i++) {
      await hp.checkInOnDay(habit, now.subtract(Duration(days: i)));
    }
    expect(hp.longestStreak(habit), 3);

    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: const Scaffold(body: SizedBox()),
    ));
    final ctx = tester.element(find.byType(Scaffold));
    await checkInWithCelebration(ctx, hp, habit);
    expect(hp.currentStreak(habit), 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('新纪录！'), findsNothing);
  });
}
