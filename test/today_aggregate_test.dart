import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/today.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'test_helpers.dart';

void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控的 Task 列表构造 Provider（绕过 load()，避免启动午夜守护定时器）。
Future<TaskProvider> buildWith(
  List<Task> tasks, {
  List<Task> trash = const [],
}) async {
  final p = TaskProvider();
  final json = jsonEncode({
    'version': 2,
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'trash': trash.map((t) => t.toJson()).toList(),
    'notifications_enabled': false,
    'sound_enabled': false,
  });
  await p.restoreFromJson(json);
  return p;
}

Task mkTask(
  String id, {
  DateTime? due,
  bool done = false,
  DateTime? completedAt,
  bool repeating = false,
  DateTime? deletedAt,
  String? title,
}) =>
    Task(
      id: id,
      title: title ?? 'T$id',
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
      status: done ? TaskStatus.done : TaskStatus.todo,
      completedAt: completedAt,
      repeat: repeating ? RepeatType.daily : RepeatType.none,
      repeatMinute: repeating ? 450 : null,
      deletedAt: deletedAt,
    );

FocusSession mkSession(
  int id,
  int dur, {
  bool completed = true,
  DateTime? endedAt,
  FocusPhase phase = FocusPhase.focus,
}) {
  final end = endedAt ?? DateTime.now();
  return FocusSession(
    id: '$id',
    plannedSec: dur,
    durationSec: dur,
    completed: completed,
    phase: phase,
    startedAt: end.subtract(Duration(seconds: dur)),
    endedAt: end,
  );
}

void main() {
  setUpAll(_installMocks);

  // 内存后端是 static Map，用例之间会互相串数据（上一个用例加的习惯会被
  // 下一个用例的 load() 读回来），每个用例开始前清空一次。
  setUp(() {
    LocalDatabase.resetMemoryForTest();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  });

  final today = () => DateTime.now();
  final todayNoon = () =>
      DateTime(today().year, today().month, today().day, 10);

  test('今日聚合：待办/已完成/专注/习惯 口径正确', () async {
    final task = await buildWith([
      mkTask('1', due: todayNoon()), // 今天待办
      mkTask('2', due: todayNoon(), done: true, completedAt: today()), // 今天已完成
      mkTask('3'), // 无截止 → 今天待办
      mkTask('4', repeating: true), // 每天 → 今天待办
      mkTask('5', due: today().add(const Duration(days: 2))), // 未来，不计
      mkTask('6', deletedAt: today()), // 已删除，不计
    ]);
    final focus = FocusProvider();
    focus.addSession(mkSession(1, 600, endedAt: today())); // 今日专注 10 分，1 番茄
    final habit = HabitProvider();
    await habit.load();
    await habit.addHabit(
      title: '晨跑',
      emoji: '🏃',
      colorValue: 0xFF0061A4,
      weekdays: [],
    );
    await habit.addHabit(
      title: '阅读',
      emoji: '📚',
      colorValue: 0xFF0061A4,
      weekdays: [],
    );
    final habits = habit.activeHabits;
    await habit.toggleCheckInToday(habits.first); // 晨跑已打卡

    final t = TodayAggregate.fromProviders(task, focus, habit);
    expect(t.pendingTasks.length, 3); // 1,3,4
    expect(t.completedToday, 1); // 2
    expect(t.todoCount, 4);
    expect(t.focusMinutes, 10);
    expect(t.pomodoroCount, 1);
    expect(t.focusGoalMinutes, 120);
    expect(t.focusProgress, closeTo(10 / 120, 1e-9));
    expect(t.sessions.length, 1);
    expect(t.habitExpected, 2);
    expect(t.habitDone, 1);
  });

  test('空数据：全部为 0', () async {
    final task = await buildWith([]);
    final focus = FocusProvider();
    final habit = HabitProvider();
    await habit.load();
    final t = TodayAggregate.fromProviders(task, focus, habit);
    expect(t.todoCount, 0);
    expect(t.focusMinutes, 0);
    expect(t.pomodoroCount, 0);
    expect(t.habitExpected, 0);
    expect(t.habitDone, 0);
    expect(t.sessions.length, 0);
  });

  test('习惯 shouldCheckIn 按 weekday 过滤', () async {
    final habit = HabitProvider();
    await habit.load();
    final wd = DateTime.now().weekday;
    final other = wd == 1 ? 7 : wd - 1; // 一定不是今天
    await habit.addHabit(title: 'A', emoji: 'A', colorValue: 1, weekdays: [wd]);
    await habit.addHabit(title: 'B', emoji: 'B', colorValue: 1, weekdays: [other]);
    final task = await buildWith([]);
    final t = TodayAggregate.fromProviders(task, FocusProvider(), habit);
    final a = t.habits.firstWhere((h) => h.habit.title == 'A');
    final b = t.habits.firstWhere((h) => h.habit.title == 'B');
    expect(a.shouldCheckIn, isTrue);
    expect(b.shouldCheckIn, isFalse);
  });

  test('勾选任务即时反映到聚合快照', () async {
    final task = await buildWith([mkTask('1', due: todayNoon())]);
    final focus = FocusProvider();
    final habit = HabitProvider();
    await habit.load();
    var snap = TodayAggregate.fromProviders(task, focus, habit);
    expect(snap.pendingTasks.length, 1);
    expect(snap.completedToday, 0);
    task.toggleDone('1');
    snap = TodayAggregate.fromProviders(task, focus, habit);
    expect(snap.pendingTasks.length, 0);
    expect(snap.completedToday, 1);
    expect(snap.todoCount, 1);
  });

  test('dateLabel 含「周」', () async {
    final task = await buildWith([]);
    final habit = HabitProvider();
    await habit.load();
    final t = TodayAggregate.fromProviders(task, FocusProvider(), habit);
    expect(t.dateLabel, contains('周'));
  });
}
