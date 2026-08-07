import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/state/habit_provider.dart';
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

Habit mk(String id, {List<int> weekdays = const []}) => Habit(
      id: id,
      title: 'H$id',
      emoji: '💪',
      colorValue: 0xFF0061A4,
      weekdays: weekdays,
      createdAt: DateTime(2020),
    );

void main() {
  setUpAll(_installMocks);
  setUp(() => LocalDatabase.resetMemoryForTest());

  test('addHabit + 今日打卡切换', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '阅读',
      emoji: '📚',
      colorValue: 0xFF0061A4,
      weekdays: [],
    );
    expect(hp.habits.length, 1);
    final habit = hp.habits.first;
    expect(hp.isCheckedToday(habit), isFalse);
    await hp.toggleCheckInToday(habit);
    expect(hp.isCheckedToday(habit), isTrue);
    expect(hp.checkInCount(habit), 1);
    await hp.toggleCheckInToday(habit);
    expect(hp.isCheckedToday(habit), isFalse);
    expect(hp.checkInCount(habit), 0);
  });

  test('deleteHabit 同时清掉打卡记录', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: 'A',
      emoji: 'A',
      colorValue: 1,
      weekdays: [],
    );
    final habit = hp.habits.first;
    await hp.toggleCheckInToday(habit);
    expect(hp.totalCheckIns, 1);
    await hp.deleteHabit(habit.id);
    expect(hp.habits.length, 0);
    expect(hp.totalCheckIns, 0);
  });

  test('连续天数：今天/昨天/前天连打 = 3', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: 'B',
      emoji: 'B',
      colorValue: 1,
      weekdays: [],
    );
    final habit = hp.habits.first;
    final now = DateTime.now();
    await hp.checkInOnDay(habit, now);
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 1)));
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 2)));
    expect(hp.currentStreak(habit), 3);
    expect(hp.longestStreak(habit), 3);
  });

  test('今天未打卡但昨天连打：当前连续仍计（allowTodayGap）', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: 'C',
      emoji: 'C',
      colorValue: 1,
      weekdays: [],
    );
    final habit = hp.habits.first;
    final now = DateTime.now();
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 1)));
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 2)));
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 3)));
    expect(hp.currentStreak(habit), 3);
    expect(hp.longestStreak(habit), 3);
  });

  test('断档超过 1 天：当前连续归零', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: 'D',
      emoji: 'D',
      colorValue: 1,
      weekdays: [],
    );
    final habit = hp.habits.first;
    final now = DateTime.now();
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 3)));
    await hp.checkInOnDay(habit, now.subtract(const Duration(days: 4)));
    expect(hp.currentStreak(habit), 0);
    expect(hp.longestStreak(habit), 2);
  });

  test('跨习惯整体统计：最长连续取并集', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(title: 'E', emoji: 'E', colorValue: 1, weekdays: []);
    await hp.addHabit(title: 'F', emoji: 'F', colorValue: 1, weekdays: []);
    final now = DateTime.now();
    final e = hp.habits[0];
    final f = hp.habits[1];
    // E：今天、昨天；F：前天 → 并集连成 3 天
    await hp.checkInOnDay(e, now);
    await hp.checkInOnDay(e, now.subtract(const Duration(days: 1)));
    await hp.checkInOnDay(f, now.subtract(const Duration(days: 2)));
    expect(hp.totalCheckIns, 3);
    expect(hp.overallLongestStreak, 3);
    expect(hp.overallCurrentStreak, 3);
    expect(hp.habitCount, 2);
  });

  test('addHabit 带提醒时间并可改/可清除', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '喝水',
      emoji: '💧',
      colorValue: 1,
      weekdays: [],
      reminderMinute: 9 * 60, // 09:00
    );
    var h = hp.habits.first;
    expect(h.reminderMinute, 540);

    // 改时间
    await hp.setReminder(h, 21 * 60 + 30);
    h = hp.habits.first;
    expect(h.reminderMinute, 1290);

    // 重新加载后仍在（已落库）
    final hp2 = HabitProvider();
    await hp2.load();
    expect(hp2.habits.first.reminderMinute, 1290);

    // 清除
    await hp.setReminder(h, null);
    expect(hp.habits.first.reminderMinute, isNull);
    final hp3 = HabitProvider();
    await hp3.load();
    expect(hp3.habits.first.reminderMinute, isNull);
  });

  test('scheduleAllReminders 不抛异常（无提醒也安全）', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(title: '无提醒', emoji: 'N', colorValue: 1, weekdays: []);
    await hp.addHabit(
      title: '有提醒',
      emoji: 'Y',
      colorValue: 1,
      weekdays: [1, 3, 5],
      reminderMinute: 8 * 60,
    );
    await expectLater(hp.scheduleAllReminders(), completes);
  });

  test('activeHabits 过滤归档', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(title: 'G', emoji: 'G', colorValue: 1, weekdays: []);
    final h = hp.habits.first;
    await hp.deleteHabit(h.id);
    expect(hp.activeHabits.length, 0);
  });
}
