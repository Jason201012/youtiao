import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/achievement.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/focus_session.dart';
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

Achievement byId(String id) => allAchievements.firstWhere((a) => a.id == id);

Task mkDone(String id, DateTime completedAt) => Task(
      id: id,
      title: 'T$id',
      priority: Priority.medium,
      category: Category.work,
      status: TaskStatus.done,
      completedAt: completedAt,
    );

FocusSession mkSession(
  String id,
  DateTime endedAt, {
  int sec = 1500,
  bool completed = true,
  FocusPhase phase = FocusPhase.focus,
}) =>
    FocusSession(
      id: id,
      plannedSec: sec,
      durationSec: sec,
      completed: completed,
      phase: phase,
      startedAt: endedAt.subtract(Duration(seconds: sec)),
      endedAt: endedAt,
    );

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

Future<FocusProvider> buildFocus(List<FocusSession> sessions) async {
  final fp = FocusProvider();
  await fp.load();
  for (final s in sessions) {
    fp.addSession(s);
  }
  return fp;
}

Future<HabitProvider> buildHabits(List<Habit> habits) async {
  await LocalDatabase.instance.replaceHabits(habits);
  final hp = HabitProvider();
  await hp.load();
  return hp;
}

void main() {
  setUpAll(_installMocks);
  setUp(() {
    LocalDatabase.resetMemoryForTest();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
  });

  // ===== 计数型成就：解锁 + 进度 =====

  group('计数型成就', () {
    test('未达标不解锁，达标即解锁', () {
      final a = byId('tasks_50');
      expect(a.unlocked(const AchievementContext(completedTasks: 49)), isFalse);
      expect(a.unlocked(const AchievementContext(completedTasks: 50)), isTrue);
      expect(a.unlocked(const AchievementContext(completedTasks: 99)), isTrue);
    });

    test('进度按目标值归一化，超额封顶 1.0', () {
      final a = byId('tasks_50');
      expect(a.hasProgress, isTrue);
      expect(a.progress(const AchievementContext(completedTasks: 0)), 0.0);
      expect(a.progress(const AchievementContext(completedTasks: 25)), 0.5);
      expect(a.progress(const AchievementContext(completedTasks: 80)), 1.0);
    });

    test('进度文案形如 32/50，超额不越界', () {
      final a = byId('tasks_50');
      expect(a.progressLabel(const AchievementContext(completedTasks: 32)),
          '32/50');
      expect(a.progressLabel(const AchievementContext(completedTasks: 80)),
          '50/50');
    });

    test('新增的进阶成就阈值正确', () {
      expect(byId('streak_30').unlocked(const AchievementContext(longestStreak: 29)),
          isFalse);
      expect(byId('streak_30').unlocked(const AchievementContext(longestStreak: 30)),
          isTrue);
      expect(
          byId('checkin_500')
              .unlocked(const AchievementContext(totalCheckIns: 500)),
          isTrue);
      expect(
          byId('tasks_200')
              .unlocked(const AchievementContext(completedTasks: 200)),
          isTrue);
      expect(byId('focus_600').unlocked(const AchievementContext(focusMinutes: 600)),
          isTrue);
      expect(byId('pomo_50').unlocked(const AchievementContext(pomodoroCount: 50)),
          isTrue);
      expect(byId('focus_days_30').unlocked(const AchievementContext(focusDays: 30)),
          isTrue);
      expect(byId('day_10').unlocked(const AchievementContext(maxTasksInDay: 10)),
          isTrue);
      expect(byId('early_bird').unlocked(const AchievementContext(earlyTasks: 10)),
          isTrue);
      expect(byId('night_owl').unlocked(const AchievementContext(nightTasks: 10)),
          isTrue);
    });
  });

  // ===== 复合成就 =====

  group('复合成就', () {
    test('习惯大师需同时满足习惯数与打卡数', () {
      final a = byId('master');
      expect(a.hasProgress, isFalse);
      expect(a.progressLabel(const AchievementContext()), isNull);
      expect(
          a.unlocked(
              const AchievementContext(habitCount: 5, totalCheckIns: 199)),
          isFalse);
      expect(
          a.unlocked(
              const AchievementContext(habitCount: 4, totalCheckIns: 200)),
          isFalse);
      expect(
          a.unlocked(
              const AchievementContext(habitCount: 5, totalCheckIns: 200)),
          isTrue);
    });

    test('全面开花需三线同时达标，进度只有 0 / 1', () {
      final a = byId('all_round');
      const partial = AchievementContext(
          completedTasks: 20, totalCheckIns: 20, focusMinutes: 59);
      const full = AchievementContext(
          completedTasks: 20, totalCheckIns: 20, focusMinutes: 60);
      expect(a.unlocked(partial), isFalse);
      expect(a.progress(partial), 0.0);
      expect(a.unlocked(full), isTrue);
      expect(a.progress(full), 1.0);
    });
  });

  // ===== 分组与汇总 =====

  group('分组与汇总', () {
    test('成就 id 唯一', () {
      final ids = allAchievements.map((a) => a.id).toSet();
      expect(ids.length, allAchievements.length);
    });

    test('四个分组都有成就，且分组总数等于全部', () {
      final map = achievementsByGroup();
      expect(map.keys.length, AchievementGroup.values.length);
      final sum = map.values.fold(0, (a, list) => a + list.length);
      expect(sum, allAchievements.length);
      expect(map[AchievementGroup.habit]!.first.id, 'first_checkin');
      expect(map[AchievementGroup.mixed]!.map((a) => a.id),
          containsAll(['master', 'all_round']));
    });

    test('空上下文下解锁数为 0，满配下全部解锁', () {
      expect(unlockedAchievementCount(const AchievementContext()), 0);
      const full = AchievementContext(
        totalCheckIns: 1000,
        longestStreak: 100,
        currentStreak: 100,
        habitCount: 10,
        completedTasks: 1000,
        focusMinutes: 5000,
        pomodoroCount: 200,
        focusDays: 200,
        maxTasksInDay: 30,
        earlyTasks: 50,
        nightTasks: 50,
        // 「周目标达人」(habit_goal_4w) 依赖 maxGoalWeeks：此前漏填该字段，
        // 导致所谓「满配」上下文实际只解锁 19/20。
        maxGoalWeeks: 4,
      );
      expect(unlockedAchievementCount(full), allAchievements.length);
    });

    test('即将解锁按进度降序取前 N 个未解锁项', () {
      // 任务 40/50（0.8）领先于打卡 1/3（0.33）。
      const ctx = AchievementContext(completedTasks: 40, totalCheckIns: 1);
      final next = nextAchievements(ctx, limit: 2);
      expect(next.length, 2);
      expect(next.first.id, 'tasks_50');
      expect(next.every((a) => !a.unlocked(ctx)), isTrue);
    });
  });

  // ===== 从 Provider 现算上下文 =====

  group('AchievementContext.fromProviders', () {
    test('单日峰值 / 早鸟 / 夜猫按完成时刻统计', () async {
      final task = await buildTasks([
        mkDone('1', DateTime(2026, 8, 3, 7)), // 早
        mkDone('2', DateTime(2026, 8, 3, 8, 30)), // 早
        mkDone('3', DateTime(2026, 8, 3, 14)),
        mkDone('4', DateTime(2026, 8, 4, 23)), // 夜
        mkDone('5', DateTime(2026, 8, 5, 22)), // 夜（边界含）
        mkDone('6', DateTime(2026, 8, 5, 9)), // 9 点整不算早鸟
      ]);
      final ctx = AchievementContext.fromProviders(
        task,
        await buildFocus([]),
        await buildHabits([]),
      );
      expect(ctx.completedTasks, 6);
      expect(ctx.maxTasksInDay, 3); // 8/3 有 3 个
      expect(ctx.earlyTasks, 2);
      expect(ctx.nightTasks, 2);
    });

    test('番茄数与专注天数只算专注阶段，按天去重', () async {
      final focus = await buildFocus([
        mkSession('1', DateTime(2026, 8, 3, 10)),
        mkSession('2', DateTime(2026, 8, 3, 15)), // 同一天
        mkSession('3', DateTime(2026, 8, 4, 10), completed: false),
        mkSession('4', DateTime(2026, 8, 5, 10), phase: FocusPhase.shortBreak),
      ]);
      final ctx = AchievementContext.fromProviders(
        await buildTasks([]),
        focus,
        await buildHabits([]),
      );
      expect(ctx.pomodoroCount, 2); // 只有两条 completed 的专注
      expect(ctx.focusDays, 2); // 8/3、8/4（休息那天不算）
      expect(ctx.focusMinutes, (1500 * 3 + 1500) ~/ 60); // 含休息的历史口径
    });

    test('习惯侧字段接自 HabitProvider', () async {
      final hp = await buildHabits([
        Habit(
            id: 'h1',
            title: 'A',
            emoji: '💪',
            colorValue: 0xFF0061A4,
            createdAt: DateTime(2020)),
        Habit(
            id: 'h2',
            title: 'B',
            emoji: '📚',
            colorValue: 0xFF0061A4,
            createdAt: DateTime(2020)),
      ]);
      await hp.checkInOnDay(hp.habits.first, DateTime(2026, 8, 1));
      await hp.checkInOnDay(hp.habits.first, DateTime(2026, 8, 2));
      await hp.checkInOnDay(hp.habits.last, DateTime(2026, 8, 2));
      final ctx = AchievementContext.fromProviders(
        await buildTasks([]),
        await buildFocus([]),
        hp,
      );
      expect(ctx.habitCount, 2);
      expect(ctx.totalCheckIns, 3);
      expect(ctx.longestStreak, 2); // 8/1、8/2 连续（跨习惯同日只计一次）
    });

    test('空数据下上下文全为 0，无成就解锁', () async {
      final ctx = AchievementContext.fromProviders(
        await buildTasks([]),
        await buildFocus([]),
        await buildHabits([]),
      );
      expect(ctx.completedTasks, 0);
      expect(ctx.maxTasksInDay, 0);
      expect(ctx.pomodoroCount, 0);
      expect(ctx.focusDays, 0);
      expect(unlockedAchievementCount(ctx), 0);
    });
  });
}
