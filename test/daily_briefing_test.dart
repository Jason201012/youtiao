import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/daily_briefing.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// P1-8 回归测试：早晚简报文案在**排程时**烘焙，必须按**投递日**（而非排程当下）聚合数据。
///
/// 缺陷原委：晨报几乎总在「前一天」排好（如周一 21:00 排周二 07:30）。若按排程当下聚合，
/// 周二早上推给用户的「今日待办」其实是周一的口径 —— 不只是陈旧，是**日期整个串了**。
/// 故 [buildMorningBriefFromState] / [buildEveningBriefFromState] 新增 [forDay]，
/// 本文件锁死该行为。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控的 Task 列表构造 Provider（绕过 load()，避免启动午夜守护定时器）。
Future<TaskProvider> buildWith(List<Task> tasks) async {
  final p = TaskProvider();
  final json = jsonEncode({
    'version': 2,
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'trash': [],
    'notifications_enabled': false,
    'sound_enabled': false,
  });
  await p.restoreFromJson(json);
  return p;
}

Task mkTask(
  String id, {
  required String title,
  DateTime? due,
  bool done = false,
  DateTime? completedAt,
  bool repeating = false,
}) =>
    Task(
      id: id,
      title: title,
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
      status: done ? TaskStatus.done : TaskStatus.todo,
      completedAt: completedAt,
      repeat: repeating ? RepeatType.daily : RepeatType.none,
      repeatMinute: repeating ? 450 : null,
    );

void main() {
  setUpAll(_installMocks);

  // 内存后端是 static Map，用例之间会互相串数据，每个用例开始前清空一次。
  setUp(() {
    LocalDatabase.resetMemoryForTest();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  });

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));
  final yesterday = today.subtract(const Duration(days: 1));

  // 「今天到期」取当日 23:59:59，确保任何时刻跑测试都不会被判成逾期，结果稳定。
  final dueTodayLate = DateTime(today.year, today.month, today.day, 23, 59, 59);

  test('P1-8 晨报按投递日聚合：排到明天时用明天的口径', () async {
    final task = await buildWith([
      mkTask('a', title: '今天到期', due: dueTodayLate),
      mkTask('b', title: '明天到期', due: tomorrow.add(const Duration(hours: 10))),
      mkTask('c', title: '三天前逾期', due: today.subtract(const Duration(days: 3))),
    ]);
    final habit = HabitProvider();
    await habit.load();

    final bToday = buildMorningBriefFromState(task, FocusProvider(), habit);
    final bTomorrow =
        buildMorningBriefFromState(task, FocusProvider(), habit, forDay: tomorrow);

    // 按今天聚合：今日到期 = 今天到期那条。
    expect(bToday.lines.first, '今日到期：1 个');
    expect(bToday.lines, contains('• 今天到期'));

    // 按明天聚合：今日到期 = 明天到期的那条；今天到期那条相对明天已过期，落入逾期区。
    expect(bTomorrow.lines.first, '今日到期：1 个');
    expect(bTomorrow.lines, contains('• 明天到期'));
    final overdueIdx = bTomorrow.lines.indexOf('逾期积压（Top3）：');
    expect(overdueIdx, greaterThan(-1), reason: '明天口径下应存在逾期区');
    expect(bTomorrow.lines.sublist(overdueIdx), contains('• 今天到期'));
  });

  test('P1-8 晚间简报按投递日聚合：只统计投递日完成的任务', () async {
    final task = await buildWith([
      mkTask('a',
          title: '昨天完成', done: true, completedAt: yesterday.add(const Duration(hours: 9))),
    ]);
    final habit = HabitProvider();
    await habit.load();

    final bToday = buildEveningBriefFromState(task, FocusProvider(), habit);
    final bYesterday =
        buildEveningBriefFromState(task, FocusProvider(), habit, forDay: yesterday);

    expect(bToday.lines.first, '今日完成任务：0 个');
    expect(bYesterday.lines.first, '今日完成任务：1 个');
  });

  test('缺省 forDay 时按当下聚合（向后兼容，不传参行为不变）', () async {
    final task = await buildWith([
      mkTask('a', title: '今天到期', due: dueTodayLate),
    ]);
    final habit = HabitProvider();
    await habit.load();
    final b = buildMorningBriefFromState(task, FocusProvider(), habit);
    expect(b.lines.first, '今日到期：1 个');
    expect(b.lines, contains('• 今天到期'));
  });
}
