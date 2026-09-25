import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/services/schedule_advisor.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/ui_durations.dart';
import 'test_helpers.dart';

/// v2.9.4 审计修复轮回归测试（《有条功能与操作审计报告（v2.9.4）》）。
///
/// 本文件只覆盖**可纯 Dart 断言**的行为；widget 层的 48dp 命中区、
/// SnackBar 队列语义等已在对应文件的注释中说明依据，不在此重复（需要
/// widget 绑定 + 真实文件 I/O 的用例容易在 FakeAsync 下挂死）。
///
/// 覆盖清单：
/// - P2-5 missedDue 改日期口径（当天内完成不算超期，跨天才算）；
/// - P2-7 progressLevelOn 四档分级（详情页与分享卡共用的单一真源）；
/// - P3-4 dailyTarget 读侧夹取（与写侧共用 Habit.maxDailyTarget）；
/// - P3-5 重复任务偏差抑制收窄为 isRepeating && !repeatEnded；
/// - P3-8 addHabit / setReminder 补触发 onHabitsChanged；
/// - P3-10 weeklyGoal 上界联动计划天数（写入侧夹取）；
/// - P3-10 附件还原统计透出（restoreFromJson 返回 RestoreBlobsStats）；
/// - P3-10 任务提醒重排责任显式化（rescheduleReminders）；
/// - P3-10 看板改状态可撤销（restoreTaskSnapshot 逐位还原）；
/// - P3-10 iCal 导出补 DURATION（预计时长此前单向丢失）；
/// - U3-2 未完成任务不判「高估 / 与预估接近」；
/// - U3-5 撤销窗口时长单一真源。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控列表构造 TaskProvider（绕过 load()，避免启动午夜守护定时器）。
/// 与 v290 / v294 同款；`notifications_enabled: false` 让重排路径不被触发。
Future<TaskProvider> buildWith(List<Task> tasks) async {
  final p = TaskProvider();
  final json = jsonEncode({
    'version': 2,
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'trash': <dynamic>[],
    'notifications_enabled': false,
    'sound_enabled': false,
  });
  await p.restoreFromJson(json);
  return p;
}

Future<HabitProvider> newHabitProvider() async {
  final hp = HabitProvider();
  await hp.load();
  return hp;
}

/// 建一个习惯并回传**已落库的那一份**。
///
/// [HabitProvider.addHabit] 的签名是 `Future<void>`（内部有 `return h;`，
/// 但 void 返回类型会丢弃该值），所以不能靠它的返回值拿实例 ——
/// 改为按标题从 [HabitProvider.habits] 里取回，避免每个用例各写一遍查找。
Future<Habit> _addHabit(
  HabitProvider hp, {
  required String title,
  List<int> weekdays = const [],
  int weeklyGoal = 0,
  int? dailyTarget,
  int? reminderMinute,
}) async {
  await hp.addHabit(
    title: title,
    emoji: '✅',
    colorValue: 0xFF0061A4,
    weekdays: weekdays,
    reminderMinute: reminderMinute,
    weeklyGoal: weeklyGoal,
    dailyTarget: dailyTarget,
  );
  return hp.habits.firstWhere((h) => h.title == title);
}

/// 测试用任务构造助手。[Task] 的 `priority` / `category` 是必填项，
/// 本文件只关心状态 / 预估 / 重复规则，故在此给默认值，避免每处重复。
Task _task(
  String id, {
  String title = '任务',
  DateTime? dueDate,
  TaskStatus status = TaskStatus.todo,
  RepeatType repeat = RepeatType.none,
  String? repeatUntil,
  int? estimateMinutes,
  int focusSecTotal = 0,
  List<String> skipDates = const [],
  List<String> doneDates = const [],
}) =>
    Task(
      id: id,
      title: title,
      priority: Priority.medium,
      category: Category.life,
      dueDate: dueDate,
      status: status,
      repeat: repeat,
      repeatUntil: repeatUntil,
      estimateMinutes: estimateMinutes,
      focusSecTotal: focusSecTotal,
      skipDates: skipDates,
      doneDates: doneDates,
    );

Habit _habit({
  String id = 'h1',
  List<int> weekdays = const [],
  int weeklyGoal = 0,
  int? dailyTarget,
  int graceDays = 0,
}) =>
    Habit(
      id: id,
      title: '测试习惯',
      weekdays: weekdays,
      weeklyGoal: weeklyGoal,
      dailyTarget: dailyTarget,
      graceDays: graceDays,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  setUp(_installMocks);

  // ── P2-5：missedDue 改日期口径 ────────────────────────────────
  group('P2-5 missedDue 按日期口径（当天完成不算超期）', () {
    test('今天 10:00 截止、从 10:00 起做 30 分钟 → 不算超期', () {
      final now = DateTime(2026, 3, 10, 10, 0);
      final t = _task('1', title: '模板式今日截止', dueDate: DateTime(2026, 3, 10)); // 当天 00:00（模板 dueInDays 的产物）
      final advice = buildScheduleAdvice([t], now: now);
      expect(advice.items.single.missedDue, isFalse,
          reason: '当天内完成不该被标「预计超过截止」');
    });

    test('跨天：昨天截止、今天才做 → 算超期', () {
      final now = DateTime(2026, 3, 10, 10, 0);
      final t = _task('2', title: '昨天截止', dueDate: DateTime(2026, 3, 9));
      final advice = buildScheduleAdvice([t], now: now);
      expect(advice.items.single.missedDue, isTrue);
    });

    test('当天 23:59 截止、上午 30 分钟 → 不算超期（date-only 双形态）', () {
      final now = DateTime(2026, 3, 10, 9, 0);
      final t = _task('3', title: '当天 23:59 截止', dueDate: DateTime(2026, 3, 10, 23, 59));
      final advice = buildScheduleAdvice([t], now: now);
      expect(advice.items.single.missedDue, isFalse);
    });
  });

  // ── P3-4：dailyTarget 读侧夹取 ───────────────────────────────
  group('P3-4 dailyTarget 读侧与写侧共用上界', () {
    test('超上界的脏数据读回时被夹到 maxDailyTarget（不再回落 null）', () {
      final h = Habit.fromJson({
        'id': 'h1',
        'title': '脏数据习惯',
        'createdAt': '2026-01-01T00:00:00.000',
        'dailyTarget': 99999,
      });
      expect(h.dailyTarget, Habit.maxDailyTarget,
          reason: '写侧上限 9999，读侧此前却回落 null → 两侧双档');
      expect(h.isQuantified, isTrue);
    });

    test('非数值 / <1 的 dailyTarget 仍回落 null（布尔习惯）', () {
      final bad = Habit.fromJson({
        'id': 'h2',
        'title': '坏值',
        'createdAt': '2026-01-01T00:00:00.000',
        'dailyTarget': 'abc',
      });
      expect(bad.dailyTarget, isNull);
      expect(bad.isQuantified, isFalse);

      final zero = Habit.fromJson({
        'id': 'h3',
        'title': '零值',
        'createdAt': '2026-01-01T00:00:00.000',
        'dailyTarget': 0,
      });
      expect(zero.dailyTarget, isNull);
    });

    test('写侧 addHabit 夹取到同一上界', () async {
      final hp = await newHabitProvider();
      final h = await _addHabit(hp, title: '脏目标量', dailyTarget: 99999);
      expect(h.dailyTarget, Habit.maxDailyTarget);
      expect(hp.habits.firstWhere((x) => x.id == h.id).dailyTarget,
          Habit.maxDailyTarget);
    });
  });

  // ── P3-10：weeklyGoal 上界联动计划天数 ───────────────────────
  group('P3-10 weeklyGoal 上界联动计划天数', () {
    test('plannedDaysOf / clampWeeklyGoalTo：空 weekdays=7，非空取个数', () {
      expect(Habit.plannedDaysOf(const []), 7);
      expect(Habit.plannedDaysOf(const [1, 3, 5]), 3);
      expect(Habit.clampWeeklyGoalTo(14, const [1, 3, 5]), 3,
          reason: '每周 3 天计划却能设 14 → 目标不可达');
      expect(Habit.clampWeeklyGoalTo(14, const []), 7);
      expect(Habit.clampWeeklyGoalTo(-5, const [1, 3, 5]), 0);
    });

    test('实例方法 clampWeeklyGoal 与静态判据一致', () {
      final h = _habit(weekdays: const [2, 4]);
      expect(h.plannedDaysPerWeek, 2);
      expect(h.clampWeeklyGoal(14), 2);
    });

    test('addHabit 写入侧按计划天数夹取', () async {
      final hp = await newHabitProvider();
      final h = await _addHabit(hp,
          title: '每周一三五', weekdays: const [1, 3, 5], weeklyGoal: 14);
      expect(h.weeklyGoal, 3);
      expect(hp.habits.firstWhere((x) => x.id == h.id).weeklyGoal, 3);
    });

    test('updateHabit 同一次编辑里改星期时按新计划天数夹取', () async {
      final hp = await newHabitProvider();
      // 计划天数从「每天」(7) 收到 2，周目标 7 此时不可达 → 应夹到 2。
      final h = await _addHabit(hp, title: '先每天', weeklyGoal: 7);
      await hp.updateHabit(h, weekdays: const [1, 3], weeklyGoal: 7);
      final stored = hp.habits.firstWhere((x) => x.id == h.id);
      expect(stored.weekdays, const [1, 3]);
      expect(stored.weeklyGoal, 2,
          reason: '必须按**编辑后**的 weekdays 夹取，不能沿用旧值');
    });
  });

  // ── P3-5：重复任务偏差抑制收窄 ───────────────────────────────
  group('P3-5 偏差抑制条件收窄为「仍在发生的重复」', () {
    test('仍在发生的重复任务：抑制偏差且给出说明', () {
      final t = _task('r1',
          title: '每天写日报',
          repeat: RepeatType.daily,
          estimateMinutes: 5,
          focusSecTotal: 3600);
      final now = DateTime.now();
      final item = buildScheduleAdvice([t], now: now).items.single;
      expect(item.biasSuppressed, isTrue);
      expect(item.biasLabel, isNull);
      expect(item.biasSuppressedNote, isNotNull,
          reason: '「有解释的沉默」：空白也要让用户知道是有意不给');
    });

    test('重复已结束（实际只发生一次）→ 恢复比较', () {
      final t = _task('r2',
          title: '已结束的重复',
          repeat: RepeatType.daily,
          repeatUntil: '2020-01-01',
          estimateMinutes: 30,
          focusSecTotal: 40 * 60,
          status: TaskStatus.done);
      expect(t.repeatEnded, isTrue);
      final item = buildScheduleAdvice([t], now: DateTime.now()).items.single;
      expect(item.biasSuppressed, isFalse);
      expect(item.biasLabel, isNotNull,
          reason: '这类任务历史累计专注就是那唯一一次的投入，可比');
    });

    test('一次性任务不抑制', () {
      final t = _task('r3',
          title: '一次性',
          estimateMinutes: 30,
          focusSecTotal: 40 * 60,
          status: TaskStatus.done);
      final item = buildScheduleAdvice([t], now: DateTime.now()).items.single;
      expect(item.biasSuppressed, isFalse);
    });
  });

  // ── U3-2：未完成不判高估 ────────────────────────────────────
  group('U3-2 未完成任务不判「高估 / 与预估接近」', () {
    test('未完成 + 投入远低于预估 → null（不判高估）', () {
      expect(
        estimateBiasLabel(
            estimatedMinutes: 60, actualMinutes: 5, completed: false),
        isNull,
      );
    });

    test('未完成 + 投入接近预估 → 也为 null（更不该下结论）', () {
      expect(
        estimateBiasLabel(
            estimatedMinutes: 60, actualMinutes: 58, completed: false),
        isNull,
      );
    });

    test('未完成 + 投入远超预估 → 仍给「可能低估」（投入在累积，不抑制）', () {
      final s = estimateBiasLabel(
          estimatedMinutes: 30, actualMinutes: 90, completed: false);
      expect(s, isNotNull);
      expect(s, contains('低估'));
    });

    test('已完成 + 投入远低于预估 → 判高估', () {
      expect(
        estimateBiasLabel(estimatedMinutes: 60, actualMinutes: 5),
        contains('高估'),
      );
    });

    test('默认 completed=true：既有直接调用点行为不变', () {
      expect(estimateBiasLabel(estimatedMinutes: 60, actualMinutes: 5),
          isNotNull);
    });
  });

  // ── P3-8：写入口补触发回调 ──────────────────────────────────
  group('P3-8 addHabit / setReminder 补触发 onHabitsChanged', () {
    // [HabitProvider.onHabitsChanged] 是 **static**（main.dart 注入一次，
    // 全局回调），因此每个用例都要复位，避免污染其它测试。
    tearDown(() => HabitProvider.onHabitsChanged = null);

    test('addHabit 触发 onHabitsChanged', () async {
      final hp = await newHabitProvider();
      var n = 0;
      HabitProvider.onHabitsChanged = (_) => n++;
      await hp.addHabit(
        title: '新习惯',
        emoji: '✅',
        colorValue: 0xFF0061A4,
        weekdays: const [],
      );
      expect(n, 1, reason: '新增习惯后首页/今日页必须重建，否则新卡不出现');
    });

    test('setReminder 触发 onHabitsChanged', () async {
      final hp = await newHabitProvider();
      final h = await _addHabit(hp, title: '待设提醒');
      var n = 0;
      HabitProvider.onHabitsChanged = (_) => n++;
      await hp.setReminder(h, 9 * 60);
      expect(n, 1, reason: '改提醒时刻后提醒卡/文案需重算');
      expect(hp.habits.firstWhere((x) => x.id == h.id).reminderMinute,
          9 * 60);
    });
  });

  // ── P2-7：热力图四档分级的单一真源 ──────────────────────────
  group('P2-7 progressLevelOn 四档分级（详情页与分享卡共用）', () {
    test('量化习惯：按达成度分 0..4 档', () async {
      final hp = await newHabitProvider();
      final h = await _addHabit(hp, title: '喝水', dailyTarget: 8);
      final day = DateTime(2026, 3, 10);

      await hp.setCheckInValue(h, day, 0);
      expect(hp.progressLevelOn(h, day), 0, reason: '无记录 = 0 档');
      await hp.setCheckInValue(h, day, 2); // 25%
      expect(hp.progressLevelOn(h, day), 1);
      await hp.setCheckInValue(h, day, 5); // 62.5%
      expect(hp.progressLevelOn(h, day), 2);
      await hp.setCheckInValue(h, day, 7); // 87.5%
      expect(hp.progressLevelOn(h, day), 3);
      await hp.setCheckInValue(h, day, 8); // 100%
      expect(hp.progressLevelOn(h, day), 4, reason: '达标 = 最高档');
      await hp.setCheckInValue(h, day, 20); // 超额仍封顶 4
      expect(hp.progressLevelOn(h, day), 4);
    });

    test('布尔习惯：有记录即 1 档（不分档）', () async {
      final hp = await newHabitProvider();
      final h = await _addHabit(hp, title: '布尔习惯');
      final day = DateTime(2026, 3, 10);
      expect(h.isQuantified, isFalse);
      expect(hp.progressLevelOn(h, day), 0);
      await hp.setCheckInValue(h, day, 1);
      expect(hp.progressLevelOn(h, day), 1);
    });

    test('写入侧夹取：setCheckInValue 与 maxDailyTarget 共用上界', () async {
      final hp = await newHabitProvider();
      final h = await _addHabit(hp, title: '上限测试', dailyTarget: 10);
      final day = DateTime(2026, 3, 10);
      await hp.setCheckInValue(h, day, 999999);
      expect(hp.checkInValueOn(h, day), Habit.maxDailyTarget);
    });
  });

  // ── P3-10：附件还原统计透出 ─────────────────────────────────
  group('P3-10 附件还原统计由 restoreFromJson 透出', () {
    test('返回值类型为 RestoreBlobsStats，无附件时 summary() 为 null', () async {
      final p = await buildWith(<Task>[
        _task('1', title: '无附件任务'),
      ]);
      // 再调一次拿到统计对象：buildWith 内部已消费过一次，这里独立验证契约。
      final json = jsonEncode({
        'version': 2,
        'tasks': [_task('9', title: 'x').toJson()],
        'trash': <dynamic>[],
        'notifications_enabled': false,
      });
      final stats = await p.restoreFromJson(json);
      expect(stats.hasSkipped, isFalse);
      expect(stats.summary(), isNull,
          reason: '无附件跳过时不该往恢复提示里塞噪音');
    });
  });

  // ── P3-10：任务提醒重排责任显式化 ───────────────────────────
  group('P3-10 任务提醒重排责任由 rescheduleReminders 显式控制', () {
    test('默认 true：既有调用点行为不变（备份无 prefs 时由本方法重排）', () async {
      final p = TaskProvider();
      final json = jsonEncode({
        'version': 2,
        'tasks': [_task('1', title: 'a').toJson()],
        'trash': <dynamic>[],
        'notifications_enabled': false,
        'sound_enabled': false,
      });
      // 不传该参数 → 走默认分支，不应抛错（签名兼容性回归）。
      final stats = await p.restoreFromJson(json);
      expect(stats.total, 0);
    });

    test('传 false 时不重排、且 cancelAll 后由调用方负责（不应抛错）', () async {
      final p = TaskProvider();
      final json = jsonEncode({
        'version': 2,
        'tasks': [_task('1', title: 'a').toJson()],
        'trash': <dynamic>[],
        'notifications_enabled': false,
        'sound_enabled': false,
        'prefs': <String, dynamic>{'dnd_enabled': false},
      });
      final stats =
          await p.restoreFromJson(json, rescheduleReminders: false);
      expect(stats.total, 0);
      expect(p.tasks.length, 1, reason: '跳过重排不影响数据恢复本身');
    });
  });

  // ── P3-10：看板改状态可撤销 ─────────────────────────────────
  group('P3-10 看板改状态可撤销（快照整体还原）', () {
    test('setStatus(done) → restoreTaskSnapshot 逐位还原', () async {
      // 必须用**今天**的 key：setStatus 走 _clearSkipFor(next, now)，
      // 只清「完成当天」的跳过记录（P2-1 的完成/跳过互斥口径），
      // 历史某天的跳过本就不该被清 —— 早先这里写死 '2026-03-10'，
      // 断言「skipDates 被清空」等于在测一个永远不成立的前提。
      final now = DateTime.now();
      final today = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final p = await buildWith(<Task>[
        _task('1', title: '待办', skipDates: [today]),
      ]);
      final before = p.byId('1')!;
      expect(before.done, isFalse);
      final snapshot = before;

      p.setStatus('1', TaskStatus.done);
      final after = p.byId('1')!;
      expect(after.done, isTrue);
      expect(after.completedAt, isNotNull);
      expect(after.skipDates, isEmpty,
          reason: '完成与跳过互斥：setStatus 会清**当日**跳过');

      // 撤销：不是「反向再切一次」，而是整体回滚。
      p.restoreTaskSnapshot(snapshot);
      final back = p.byId('1')!;
      expect(back.done, isFalse);
      expect(back.completedAt, isNull,
          reason: '反向 setStatus 会把 completedAt 置为 now，无法还原');
      expect(back.skipDates, [today],
          reason: '被 setStatus 清掉的当日 skipDates 必须一并回来');
    });

    test('只清「完成当天」的跳过：历史跳过不受影响', () async {
      // 与上一条互为对照，钉死 _clearSkipFor 的日期语义，
      // 避免以后有人误改成「清空整个 skipDates」。
      final p = await buildWith(<Task>[
        _task('4', title: '历史跳过', skipDates: const ['2026-03-10']),
      ]);
      p.setStatus('4', TaskStatus.done);
      expect(p.byId('4')!.skipDates, const ['2026-03-10'],
          reason: '非当天的跳过记录不在互斥清理范围内');
    });

    test('还原 doneDates（完成历史）——反向切换做不到', () async {
      final p = await buildWith(<Task>[
        _task('2', title: '带完成历史', doneDates: const ['2026-03-09']),
      ]);
      final snapshot = p.byId('2')!;
      p.setStatus('2', TaskStatus.done);
      expect(p.byId('2')!.doneDates, contains('2026-03-09'));
      expect(p.byId('2')!.doneDates.length, 2,
          reason: 'setStatus 会追加今天');

      p.restoreTaskSnapshot(snapshot);
      expect(p.byId('2')!.doneDates, const ['2026-03-09'],
          reason: '追加的今天必须被撤销掉');
    });

    test('任务已被删除时静默返回，不抛错', () async {
      final p = await buildWith(<Task>[_task('3', title: '存在')]);
      final ghost = _task('gone', title: '不存在');
      expect(() => p.restoreTaskSnapshot(ghost), returnsNormally);
    });
  });

  // ── P3-10：iCal 导出补 DURATION ─────────────────────────────
  group('P3-10 iCal 导出预计时长（DURATION）', () {
    test('有 estimateMinutes → 写 DURATION:PT..M', () {
      final ics = exportIcs([
        _task('1', title: '写周报', estimateMinutes: 45),
      ]);
      expect(ics, contains('DURATION:PT45M'));
    });

    test('无 estimateMinutes → 不写 DURATION（不引入空值噪音）', () {
      final ics = exportIcs([_task('1', title: '无预估')]);
      expect(ics, isNot(contains('DURATION')));
    });

    test('超过 1 小时的预估按分钟原样表达（RFC 5545 允许 PT90M）', () {
      final ics = exportIcs([
        _task('1', title: '长任务', estimateMinutes: 90),
      ]);
      expect(ics, contains('DURATION:PT90M'));
    });
  });

  // ── U3-5：撤销窗口单一真源 ─────────────────────────────────
  group('U3-5 撤销窗口时长单一真源', () {
    test('kUndoWindow 与 kUndoWindowSeconds 一致（10 秒）', () {
      expect(kUndoWindow, const Duration(seconds: 10));
      expect(kUndoWindowSeconds, 10);
      // 这条就是「秒数字面量与 Duration 常量同源」的守门断言。
      // 不能在 lib 侧写 const bool 做同一件事：`Duration` 重写了 `==`（非原始相等），
      // const 表达式里用 `==` 会编译失败（const_eval_primitive_equality），
      // 且该文件被 13 个测试文件间接 import，一个字面量错误会整批测试编译失败。
      // 同步校验只能在**运行时**做，即本条 expect。
      expect(kUndoWindowSeconds, kUndoWindow.inSeconds,
          reason: '文案用秒数、SnackBar 用 Duration，两者必须同源'
              '（秒数只能写字面量，inSeconds 非 const 可求值）');
    });
  });
}
