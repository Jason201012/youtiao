import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/habit_share_card.dart';
import 'test_helpers.dart';

DateTime _d(DateTime d) => DateTime(d.year, d.month, d.day);

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

  test('HabitShareData.from 正确聚合当前/最长/累计与近 18 周打卡', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '阅读',
      emoji: '📚',
      colorValue: 0xFF0061A4,
      weekdays: [],
    );
    final habit = hp.habits.first;
    final now = DateTime.now();
    await hp.checkInOnDay(habit, now);
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 1)));

    final data = HabitShareData.from(hp, habit);
    expect(data.current, 2);
    expect(data.longest, 2);
    expect(data.total, 2);
    expect(data.weeks, 18);
    expect(data.emoji, habit.emoji);
    expect(data.title, habit.title);
    expect(data.checkedDays.contains(_d(now)), isTrue);
    expect(data.checkedDays.contains(_d(now.subtract(const Duration(days: 1)))),
        isTrue);
    // 18 周以外的旧打卡不应进入快照
    final far = now.subtract(const Duration(days: 200));
    await hp.checkInOnDay(habit, far);
    final data2 = HabitShareData.from(hp, habit);
    expect(data2.checkedDays.contains(_d(far)), isFalse);
    expect(data2.total, 3); // 累计仍统计全量
  });

  testWidgets('HabitShareCard 浅色/深色均渲染无异常', (tester) async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '阅读',
      emoji: '📚',
      colorValue: 0xFF0061A4,
      weekdays: [],
    );
    final habit = hp.habits.first;
    final now = DateTime.now();
    await hp.checkInOnDay(habit, now);
    final data = HabitShareData.from(hp, habit);

    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: FittedBox(
              fit: BoxFit.contain,
              child: HabitShareCard(data: data, dark: false),
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(MaterialApp(
      theme: darkTheme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: FittedBox(
              fit: BoxFit.contain,
              child: HabitShareCard(data: data, dark: true),
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
