import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/period_review.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'test_helpers.dart';

void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控的 Task 列表构造 Provider（绕过 load()，避免启动午夜守护定时器）。
Future<TaskProvider> buildTasks(List<Task> tasks) async {
  final p = TaskProvider();
  await p.restoreFromJson(jsonEncode({
    'version': 2,
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'trash': <Map<String, dynamic>>[],
    'notifications_enabled': false,
    'sound_enabled': false,
  }));
  return p;
}

Task mkDone(
  String id,
  DateTime completedAt, {
  Category category = Category.work,
}) =>
    Task(
      id: id,
      title: 'T$id',
      priority: Priority.medium,
      category: category,
      status: TaskStatus.done,
      completedAt: completedAt,
    );

FocusSession mkSession(
  String id,
  DateTime endedAt, {
  int sec = 600,
  bool completed = true,
  FocusPhase phase = FocusPhase.focus,
  String? taskId,
  String? taskTitle,
}) =>
    FocusSession(
      id: id,
      taskId: taskId,
      taskTitle: taskTitle,
      plannedSec: sec,
      durationSec: sec,
      completed: completed,
      phase: phase,
      startedAt: endedAt.subtract(Duration(seconds: sec)),
      endedAt: endedAt,
    );

Habit mkHabit(
  String id, {
  List<int> weekdays = const [],
  DateTime? createdAt,
}) =>
    Habit(
      id: id,
      title: 'H$id',
      emoji: '💪',
      colorValue: 0xFF0061A4,
      weekdays: weekdays,
      createdAt: createdAt ?? DateTime(2020),
    );

Future<HabitProvider> buildHabits(List<Habit> habits) async {
  await LocalDatabase.instance.replaceHabits(habits);
  final hp = HabitProvider();
  await hp.load();
  return hp;
}

Future<FocusProvider> buildFocus(List<FocusSession> sessions) async {
  final fp = FocusProvider();
  await fp.load();
  for (final s in sessions) {
    fp.addSession(s);
  }
  return fp;
}

void main() {
  setUpAll(_installMocks);
  setUp(() {
    LocalDatabase.resetMemoryForTest();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
  });

  // ===== 区间边界 =====

  group('周期区间', () {
    test('月报取自然月首末（大月 31 天）', () async {
      final r = PeriodReview.fromProviders(
        await buildTasks([]),
        await buildFocus([]),
        await buildHabits([]),
        period: ReviewPeriod.month,
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.start, DateTime(2026, 8, 1));
      expect(r.end, DateTime(2026, 8, 31));
      expect(r.totalDays, 31);
      expect(r.buckets.length, 31);
      expect(r.title, '2026 年 8 月');
      expect(r.rangeLabel, '8月1日 – 8月31日');
    });

    test('月报处理平年 2 月（28 天）与闰年 2 月（29 天）', () async {
      final tasks = await buildTasks([]);
      final focus = await buildFocus([]);
      final habits = await buildHabits([]);
      final plain = PeriodReview.fromProviders(tasks, focus, habits,
          period: ReviewPeriod.month, anchor: DateTime(2026, 2, 10));
      final leap = PeriodReview.fromProviders(tasks, focus, habits,
          period: ReviewPeriod.month, anchor: DateTime(2024, 2, 10));
      expect(plain.end.day, 28);
      expect(leap.end.day, 29);
      expect(leap.buckets.length, 29);
    });

    test('年报取 1/1 – 12/31，桶为 12 个月', () async {
      final r = PeriodReview.fromProviders(
        await buildTasks([]),
        await buildFocus([]),
        await buildHabits([]),
        period: ReviewPeriod.year,
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.start, DateTime(2026, 1, 1));
      expect(r.end, DateTime(2026, 12, 31));
      expect(r.totalDays, 365);
      expect(r.buckets.length, 12);
      expect(r.bucketLabels.first, '1月');
      expect(r.bucketLabels.last, '12月');
      expect(r.title, '2026 年');
    });

    test('shiftAnchor 前后翻页且跨年正确', () {
      expect(
        PeriodReview.shiftAnchor(
            ReviewPeriod.month, DateTime(2026, 1, 15), -1),
        DateTime(2025, 12, 1),
      );
      expect(
        PeriodReview.shiftAnchor(
            ReviewPeriod.month, DateTime(2026, 12, 15), 1),
        DateTime(2027, 1, 1),
      );
      expect(
        PeriodReview.shiftAnchor(ReviewPeriod.year, DateTime(2026, 6, 1), -1),
        DateTime(2025, 1, 1),
      );
    });
  });

  // ===== 任务统计 =====

  group('任务完成统计', () {
    test('月报只统计当月完成的任务', () async {
      final tasks = await buildTasks([
        mkDone('1', DateTime(2026, 8, 1, 9)),
        mkDone('2', DateTime(2026, 8, 31, 23)),
        mkDone('3', DateTime(2026, 7, 31, 23)), // 上月
        mkDone('4', DateTime(2026, 9, 1, 0)), // 下月
      ]);
      final r = PeriodReview.fromProviders(
        tasks,
        await buildFocus([]),
        await buildHabits([]),
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.completedCount, 2);
    });

    test('环比取上一自然月，跨年时回到去年 12 月', () async {
      final tasks = await buildTasks([
        mkDone('1', DateTime(2026, 1, 5)),
        mkDone('2', DateTime(2025, 12, 20)),
        mkDone('3', DateTime(2025, 12, 21)),
        mkDone('4', DateTime(2025, 12, 22)),
      ]);
      final r = PeriodReview.fromProviders(
        tasks,
        await buildFocus([]),
        await buildHabits([]),
        anchor: DateTime(2026, 1, 15),
      );
      expect(r.completedCount, 1);
      expect(r.prevCompletedCount, 3);
      expect(r.completedDelta, -2);
      expect(r.completedDeltaLabel, '较上月 -2');
    });

    test('环比持平时文案为「与上月持平」', () async {
      final tasks = await buildTasks([
        mkDone('1', DateTime(2026, 8, 5)),
        mkDone('2', DateTime(2026, 7, 5)),
      ]);
      final r = PeriodReview.fromProviders(
        tasks,
        await buildFocus([]),
        await buildHabits([]),
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.completedDeltaLabel, '与上月持平');
    });

    test('年报环比取去年，桶按月聚合', () async {
      final tasks = await buildTasks([
        mkDone('1', DateTime(2026, 3, 5)),
        mkDone('2', DateTime(2026, 3, 20)),
        mkDone('3', DateTime(2026, 11, 1)),
        mkDone('4', DateTime(2025, 6, 1)),
      ]);
      final r = PeriodReview.fromProviders(
        tasks,
        await buildFocus([]),
        await buildHabits([]),
        period: ReviewPeriod.year,
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.completedCount, 3);
      expect(r.prevCompletedCount, 1);
      expect(r.buckets[2], 2); // 3 月
      expect(r.buckets[10], 1); // 11 月
      expect(r.bestBucketIndex, 2);
      expect(r.bestBucketCount, 2);
      expect(r.bestBucketLabel, '3月');
    });

    test('月报按日落桶并算出最高产的一天', () async {
      final tasks = await buildTasks([
        mkDone('1', DateTime(2026, 8, 14, 8)),
        mkDone('2', DateTime(2026, 8, 14, 18)),
        mkDone('3', DateTime(2026, 8, 14, 22)),
        mkDone('4', DateTime(2026, 8, 2, 10)),
      ]);
      final r = PeriodReview.fromProviders(
        tasks,
        await buildFocus([]),
        await buildHabits([]),
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.buckets[13], 3); // 8 月 14 日
      expect(r.buckets[1], 1); // 8 月 2 日
      expect(r.bestBucketIndex, 13);
      expect(r.bestBucketLabel, '8月14日');
    });

    test('activeDays 同日多任务只算一天，日均按区间天数摊', () async {
      final tasks = await buildTasks([
        mkDone('1', DateTime(2026, 8, 14, 8)),
        mkDone('2', DateTime(2026, 8, 14, 18)),
        mkDone('3', DateTime(2026, 8, 20, 10)),
      ]);
      final r = PeriodReview.fromProviders(
        tasks,
        await buildFocus([]),
        await buildHabits([]),
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.activeDays, 2);
      expect(r.completedCount, 3);
      expect(r.dailyAverage, closeTo(3 / 31, 0.0001));
    });

    test('分类完成数分别统计', () async {
      final tasks = await buildTasks([
        mkDone('1', DateTime(2026, 8, 3), category: Category.work),
        mkDone('2', DateTime(2026, 8, 4), category: Category.work),
        mkDone('3', DateTime(2026, 8, 5), category: Category.study),
      ]);
      final r = PeriodReview.fromProviders(
        tasks,
        await buildFocus([]),
        await buildHabits([]),
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.categoryCount[Category.work], 2);
      expect(r.categoryCount[Category.study], 1);
      expect(r.categoryCount[Category.life], 0);
    });
  });

  // ===== 专注统计 =====

  group('专注统计', () {
    test('只累计专注阶段，休息不计；完成的才算番茄', () async {
      final focus = await buildFocus([
        mkSession('1', DateTime(2026, 8, 3, 10), sec: 1500),
        mkSession('2', DateTime(2026, 8, 4, 10), sec: 600, completed: false),
        mkSession('3', DateTime(2026, 8, 5, 10),
            sec: 300, phase: FocusPhase.shortBreak),
        mkSession('4', DateTime(2026, 7, 5, 10), sec: 1500), // 上月
      ]);
      final r = PeriodReview.fromProviders(
        await buildTasks([]),
        focus,
        await buildHabits([]),
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.focusSec, 2100);
      expect(r.focusMinutes, 35);
      expect(r.pomodoroCount, 1);
      expect(r.prevFocusSec, 1500);
      expect(r.focusMinutesDelta, 10);
    });

    test('专注去向按时长降序且最多 3 条', () async {
      final focus = await buildFocus([
        mkSession('1', DateTime(2026, 8, 3, 10),
            sec: 600, taskId: 'a', taskTitle: 'A'),
        mkSession('2', DateTime(2026, 8, 4, 10),
            sec: 900, taskId: 'a', taskTitle: 'A'),
        mkSession('3', DateTime(2026, 8, 5, 10),
            sec: 1200, taskId: 'b', taskTitle: 'B'),
        mkSession('4', DateTime(2026, 8, 6, 10),
            sec: 300, taskId: 'c', taskTitle: 'C'),
        mkSession('5', DateTime(2026, 8, 7, 10),
            sec: 100, taskId: 'd', taskTitle: 'D'),
        mkSession('6', DateTime(2026, 8, 8, 10), sec: 5000), // 无任务，不入榜
      ]);
      final r = PeriodReview.fromProviders(
        await buildTasks([]),
        focus,
        await buildHabits([]),
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.focusTop.length, 3);
      expect(r.focusTop[0].title, 'A'); // 1500
      expect(r.focusTop[0].totalSec, 1500);
      expect(r.focusTop[0].count, 2);
      expect(r.focusTop[1].title, 'B');
      expect(r.focusTop[2].title, 'C');
    });
  });

  // ===== 习惯统计 =====

  group('习惯统计', () {
    test('每天型习惯：应打卡=当月天数，达成率按实际打卡算', () async {
      final hp = await buildHabits([mkHabit('h1')]);
      final h = hp.habits.first;
      await hp.checkInOnDay(h, DateTime(2026, 8, 1));
      await hp.checkInOnDay(h, DateTime(2026, 8, 2));
      await hp.checkInOnDay(h, DateTime(2026, 7, 30)); // 区间外
      final r = PeriodReview.fromProviders(
        await buildTasks([]),
        await buildFocus([]),
        hp,
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.habitExpected, 31);
      expect(r.habitDone, 2);
      expect(r.habitRate, closeTo(2 / 31, 0.0001));
      expect(r.habits.single.expected, 31);
      expect(r.habits.single.done, 2);
    });

    test('按星期设定的习惯只在设定日计入应打卡', () async {
      // 2026 年 8 月共 5 个周一（3/10/17/24/31）。
      final hp = await buildHabits([mkHabit('h1', weekdays: [1])]);
      final r = PeriodReview.fromProviders(
        await buildTasks([]),
        await buildFocus([]),
        hp,
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.habitExpected, 5);
    });

    test('习惯创建之前的日子不计入应打卡', () async {
      final hp = await buildHabits([
        mkHabit('h1', createdAt: DateTime(2026, 8, 20)),
      ]);
      final r = PeriodReview.fromProviders(
        await buildTasks([]),
        await buildFocus([]),
        hp,
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.habitExpected, 12); // 8/20 – 8/31
    });

    test('多习惯按达成率降序排列', () async {
      final hp = await buildHabits([mkHabit('low'), mkHabit('high')]);
      final low = hp.habits.firstWhere((h) => h.id == 'low');
      final high = hp.habits.firstWhere((h) => h.id == 'high');
      await hp.checkInOnDay(low, DateTime(2026, 8, 1));
      for (int i = 1; i <= 10; i++) {
        await hp.checkInOnDay(high, DateTime(2026, 8, i));
      }
      final r = PeriodReview.fromProviders(
        await buildTasks([]),
        await buildFocus([]),
        hp,
        anchor: DateTime(2026, 8, 9),
      );
      expect(r.habits.first.habit.id, 'high');
      expect(r.habits.last.habit.id, 'low');
      expect(r.habitDone, 11);
      expect(r.habitPercent, ((11 / 62) * 100).round());
    });
  });

  // ===== 空数据 =====

  test('空数据时所有指标为 0，无最高产桶', () async {
    final r = PeriodReview.fromProviders(
      await buildTasks([]),
      await buildFocus([]),
      await buildHabits([]),
      anchor: DateTime(2026, 8, 9),
    );
    expect(r.completedCount, 0);
    expect(r.focusSec, 0);
    expect(r.pomodoroCount, 0);
    expect(r.habitExpected, 0);
    expect(r.habitRate, 0.0);
    expect(r.activeDays, 0);
    expect(r.bestBucketIndex, -1);
    expect(r.bestBucketLabel, isNull);
    expect(r.dailyAverage, 0.0);
    expect(r.buckets.every((v) => v == 0), isTrue);
  });
}
