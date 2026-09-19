import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/screens/habit_screen.dart';
import 'package:todolist/services/habit_migration.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/schedule_advisor.dart';
import 'package:todolist/services/task_parser.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'test_helpers.dart';

/// v2.9.2 功能增强（《有条功能增强建议报告（v2.9.2）》T1-1 ~ T1-4）回归测试。
///
/// - T1-1 预计时长落库（Task.estimateMinutes）+ 今日排程建议（纯函数）；
/// - T1-2 习惯量化目标值打卡（Habit.dailyTarget / CheckIn.value 与统计口径）；
/// - T1-3 任务一键转习惯的字段映射（HabitDraft.fromTask）；
/// - T1-4 习惯管理入口（提醒时刻编辑 / 删除撤销 / 宽限日 streak）。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 新建一个已 load 的 HabitProvider（内存库由 setUp 重置）。
Future<HabitProvider> newHabitProvider() async {
  final hp = HabitProvider();
  await hp.load();
  return hp;
}

/// 今天往前第 [i] 天的 date-only。
DateTime daysAgo(int i) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day).subtract(Duration(days: i));
}

Task taskOf(
  String id, {
  String? title,
  DateTime? due,
  int? estimate,
  Priority priority = Priority.medium,
  RepeatType repeat = RepeatType.none,
  List<int> weekdays = const [],
  int? repeatMinute,
  int interval = 1,
  int monthlyDay = 1,
  int monthlyFromEnd = 0,
}) =>
    Task(
      id: id,
      title: title ?? 'T$id',
      priority: priority,
      category: Category.work,
      dueDate: due,
      repeat: repeat,
      repeatWeekdays: weekdays,
      repeatInterval: interval,
      repeatMinute: repeatMinute,
      monthlyDay: monthlyDay,
      monthlyFromEnd: monthlyFromEnd,
      estimateMinutes: estimate,
    );

void main() {
  setUpAll(_installMocks);
  setUp(() => LocalDatabase.resetMemoryForTest());

  // ===================== T1-1 预计时长落库 =====================

  group('T1-1 Task.estimateMinutes 落库（零迁移）', () {
    test('JSON 往返保留预估时长', () {
      final t = taskOf('1', estimate: 45);
      final back = Task.fromJson(t.toJson());
      expect(back.estimateMinutes, 45);
      expect(back.hasEstimate, isTrue);
    });

    test('旧 JSON 无该字段 → null（向后兼容，不影响既有任务）', () {
      final j = taskOf('1').toJson()..remove('estimateMinutes');
      expect(Task.fromJson(j).estimateMinutes, isNull);
      expect(Task.fromJson(j).hasEstimate, isFalse);
    });

    test('越界 / 非法值一律视为「无预估」（备份是不可信输入）', () {
      for (final bad in <Object>[0, -5, 30 * 24 * 60 + 1, '45', true]) {
        final j = taskOf('1').toJson()..['estimateMinutes'] = bad;
        expect(Task.fromJson(j).estimateMinutes, isNull, reason: '$bad');
      }
      // 边界值本身合法
      final edge = taskOf('1').toJson()..['estimateMinutes'] = 30 * 24 * 60;
      expect(Task.fromJson(edge).estimateMinutes, 30 * 24 * 60);
    });

    test('copyWith 可显式清空预估（_kKeep 哨兵）', () {
      final t = taskOf('1', estimate: 60);
      expect(t.copyWith(estimateMinutes: null).estimateMinutes, isNull);
      // 不传 → 保留旧值
      expect(t.copyWith(title: 'x').estimateMinutes, 60);
      // 改值
      expect(t.copyWith(estimateMinutes: 15).estimateMinutes, 15);
    });

    test('自然语言解析结果落库为结构化字段（不再写进备注）', () {
      final t = TaskParser.parse('看书 2小时30分').toTask();
      expect(t.estimateMinutes, 150);
      expect(t.note, '');
      final t2 = TaskParser.parse('面试 @公司 45分钟').toTask();
      expect(t2.estimateMinutes, 45);
      expect(t2.note, '@公司');
    });
  });

  group('T1-1 今日排程建议（buildScheduleAdvice 纯函数）', () {
    final now = DateTime(2026, 9, 19, 10, 0);
    DateTime at(int h, int m, {int dayOffset = 0}) =>
        DateTime(2026, 9, 19 + dayOffset, h, m);

    test('排序：截止时间 → 预计时长 → 优先级', () {
      final b = taskOf('b', due: at(12, 0), estimate: 30);
      final a = taskOf('a', due: at(18, 0), estimate: 5);
      final d = taskOf('d', due: at(9, 0, dayOffset: 1), estimate: 10);
      final c = taskOf('c', estimate: 15); // 无截止 → 排末
      final advice = buildScheduleAdvice([a, b, c, d], now: now);
      expect(advice.items.map((i) => i.task.id).toList(), ['b', 'a', 'd', 'c']);
    });

    test('无截止时按时长升序，再按优先级（高→中→低），最后 id 兜底全序', () {
      final long = taskOf('x', estimate: 90, priority: Priority.high);
      final short = taskOf('y', estimate: 15, priority: Priority.low);
      final sameA = taskOf('a', estimate: 30, priority: Priority.medium);
      final sameB = taskOf('b', estimate: 30, priority: Priority.medium);
      final advice = buildScheduleAdvice([long, sameB, short, sameA], now: now);
      expect(advice.items.map((i) => i.task.id).toList(),
          ['y', 'a', 'b', 'x']);
    });

    test('无预估按 defaultMinutes 兜底并标记为「非显式」', () {
      final guessed = taskOf('g');
      final advice =
          buildScheduleAdvice([guessed], now: now, defaultMinutes: 25);
      expect(advice.items.single.minutes, 25);
      expect(advice.items.single.explicit, isFalse);
      expect(advice.guessedCount, 1);
      // 显式预估不受 defaultMinutes 影响
      final explicit = taskOf('e', estimate: 5);
      final advice2 = buildScheduleAdvice([explicit], now: now, defaultMinutes: 25);
      expect(advice2.items.single.minutes, 5);
      expect(advice2.items.single.explicit, isTrue);
      expect(advice2.guessedCount, 0);
    });

    test('串行顺延：起止时刻首尾相接，finishAt = 末条结束', () {
      final first = taskOf('1', estimate: 30);
      final second = taskOf('2', estimate: 45);
      final advice = buildScheduleAdvice([first, second], now: now);
      final i0 = advice.items[0];
      final i1 = advice.items[1];
      expect(i0.start, now);
      expect(i0.end, now.add(const Duration(minutes: 30)));
      expect(i1.start, i0.end); // 首尾相接
      expect(i1.end, DateTime(2026, 9, 19, 11, 15));
      expect(advice.finishAt, i1.end);
      expect(advice.totalMinutes, 75);
      expect(advice.summary, contains('11:15'));
      expect(i0.windowLabel, '10:00–10:30');
    });

    test('预计结束晚于截止 → missedDue；无截止任务恒为 false', () {
      final tight = taskOf('t', due: at(10, 20), estimate: 30);
      final noDue = taskOf('n', estimate: 600);
      final advice = buildScheduleAdvice([noDue, tight], now: now);
      final tightItem = advice.items.firstWhere((i) => i.task.id == 't');
      final noDueItem = advice.items.firstWhere((i) => i.task.id == 'n');
      expect(tightItem.missedDue, isTrue);
      expect(noDueItem.missedDue, isFalse);
      expect(advice.missedDueCount, 1);
    });

    test('超出当天剩余时间 → overrunMinutes（23:00 起 120 分钟 → 超 60 分钟）', () {
      final advice = buildScheduleAdvice(
        [taskOf('1', estimate: 120)],
        now: DateTime(2026, 9, 19, 23, 0),
      );
      expect(advice.overrunMinutes, 60);
      expect(advice.finishAt, DateTime(2026, 9, 20, 1, 0));
    });

    test('空列表：无条目、汇总给出「无需排程」、overrun 为 0', () {
      final advice = buildScheduleAdvice(const [], now: now);
      expect(advice.isEmpty, isTrue);
      expect(advice.totalMinutes, 0);
      expect(advice.overrunMinutes, 0);
      expect(advice.finishAt, now);
      expect(advice.summary, contains('无需排程'));
    });
  });

  group('T1-1 预估 vs 实际偏差（estimateBiasLabel）', () {
    test('超出容差 → 可能低估；低于容差 → 可能高估；带内 → 接近', () {
      expect(estimateBiasLabel(estimatedMinutes: 30, actualMinutes: 60),
          contains('可能低估'));
      expect(estimateBiasLabel(estimatedMinutes: 60, actualMinutes: 20),
          contains('可能高估'));
      expect(estimateBiasLabel(estimatedMinutes: 30, actualMinutes: 32),
          '与预估接近');
    });

    test('无从比较时返回 null（不弹无依据的偏差文案）', () {
      expect(estimateBiasLabel(estimatedMinutes: null, actualMinutes: 30), isNull);
      expect(estimateBiasLabel(estimatedMinutes: 30, actualMinutes: 0), isNull);
      expect(estimateBiasLabel(estimatedMinutes: 0, actualMinutes: 30), isNull);
      expect(estimateBiasLabel(estimatedMinutes: null, actualMinutes: null), isNull);
    });

    test('小预估也保底 5 分钟容差（不被 1–2 分钟抖动触发）', () {
      expect(estimateBiasLabel(estimatedMinutes: 5, actualMinutes: 7), '与预估接近');
      expect(estimateBiasLabel(estimatedMinutes: 5, actualMinutes: 12),
          contains('可能低估'));
    });
  });

  // ===================== T1-2 量化打卡 =====================

  group('T1-2 模型层（Habit.dailyTarget / CheckIn.value 零迁移）', () {
    test('Habit JSON 往返保留 dailyTarget / graceDays', () {
      final h = Habit(
        id: 'h1',
        title: '喝水',
        dailyTarget: 8,
        graceDays: 2,
        createdAt: _epoch,
      );
      final back = Habit.fromJson(h.toJson());
      expect(back.dailyTarget, 8);
      expect(back.graceDays, 2);
      expect(back.isQuantified, isTrue);
      expect(back.effectiveTarget, 8);
    });

    test('旧 JSON 缺字段 → 布尔习惯 / 宽限 0', () {
      final j = Habit(id: 'h1', title: 'x', createdAt: _epoch).toJson()
        ..remove('dailyTarget')
        ..remove('graceDays');
      final back = Habit.fromJson(j);
      expect(back.dailyTarget, isNull);
      expect(back.isQuantified, isFalse);
      expect(back.effectiveTarget, 1);
      expect(back.graceDays, 0);
    });

    test('非法 dailyTarget / graceDays 被夹取（备份不可信输入）', () {
      for (final bad in <Object>[0, -8, '8', true]) {
        final j = Habit(id: 'h', title: 'x', createdAt: _epoch).toJson()
          ..['dailyTarget'] = bad;
        expect(Habit.fromJson(j).dailyTarget, isNull, reason: '$bad');
      }
      final j2 = Habit(id: 'h', title: 'x', createdAt: _epoch).toJson()
        ..['graceDays'] = 99;
      expect(Habit.fromJson(j2).graceDays, 3);
    });

    test('copyWith 可显式取消量化（clearDailyTarget 哨兵）', () {
      final h = Habit(id: 'h', title: 'x', dailyTarget: 8, createdAt: _epoch);
      expect(h.copyWith(clearDailyTarget: true).dailyTarget, isNull);
      expect(h.copyWith(title: 'y').dailyTarget, 8);
    });

    test('CheckIn.value JSON 往返 + 旧记录缺省 1', () {
      final c = CheckIn.forDay('h1', DateTime(2026, 9, 19), value: 3);
      expect(CheckIn.fromJson(c.toJson()).value, 3);
      final legacy = c.toJson()..remove('value');
      expect(CheckIn.fromJson(legacy).value, 1);
      // 脏值夹到 1
      final dirty = c.toJson()..['value'] = 0;
      expect(CheckIn.fromJson(dirty).value, 1);
    });

    test('Habit.targetMetBy / progressRatioOf 口径', () {
      final q = Habit(id: 'q', title: '水', dailyTarget: 8, createdAt: _epoch);
      final b = Habit(id: 'b', title: '跑', createdAt: _epoch);
      expect(q.targetMetBy(7), isFalse);
      expect(q.targetMetBy(8), isTrue);
      expect(q.progressRatioOf(4), 0.5);
      expect(q.progressRatioOf(20), 1.0); // 超额不溢出
      expect(b.targetMetBy(1), isTrue);
      expect(b.effectiveTarget, 1);
    });
  });

  group('T1-2 打卡量与统计口径', () {
    test('setCheckInValue：0 删除记录，>0 建/改记录（幂等无副作用）', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水', emoji: '💧', colorValue: 1, weekdays: const [], dailyTarget: 8);
      final h = hp.habits.first;
      final today = daysAgo(0);

      await hp.setCheckInValue(h, today, 3);
      expect(hp.checkInValueOn(h, today), 3);
      expect(hp.isCheckedOn(h, today), isTrue);
      expect(hp.isTargetMetOn(h, today), isFalse);

      await hp.setCheckInValue(h, today, 0);
      expect(hp.checkInValueOn(h, today), 0);
      expect(hp.isCheckedOn(h, today), isFalse);
    });

    test('adjustCheckInValue / completeTodayTarget / clearToday', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水', emoji: '💧', colorValue: 1, weekdays: const [], dailyTarget: 8);
      final h = hp.habits.first;

      await hp.adjustCheckInValue(h, DateTime.now(), 1);
      await hp.adjustCheckInValue(h, DateTime.now(), 1);
      expect(hp.todayValue(h), 2);

      await hp.completeTodayTarget(h);
      expect(hp.todayValue(h), 8);
      expect(hp.isTargetMetToday(h), isTrue);

      await hp.clearToday(h);
      expect(hp.todayValue(h), 0);
      expect(hp.isTargetMetToday(h), isFalse);
    });

    test('量化习惯「打卡」只记 1 个单位（不一键顶满），再点即撤卡', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水', emoji: '💧', colorValue: 1, weekdays: const [], dailyTarget: 8);
      final h = hp.habits.first;

      await hp.toggleCheckInToday(h);
      expect(hp.todayValue(h), 1);
      expect(hp.isTargetMetToday(h), isFalse);

      await hp.toggleCheckInToday(h);
      expect(hp.todayValue(h), 0);
    });

    test('未达标日不计入连续天数 / 达标天数 / 周目标进度', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水',
          emoji: '💧',
          colorValue: 1,
          weekdays: const [],
          dailyTarget: 8,
          weeklyGoal: 5);
      final h = hp.habits.first;

      // 昨天只喝 1 杯（有记录但不达标）
      await hp.setCheckInValue(h, daysAgo(1), 1);
      expect(hp.isCheckedOn(h, daysAgo(1)), isTrue);
      expect(hp.checkInCount(h), 0);
      expect(hp.currentStreak(h), 0);
      expect(hp.weeklyCheckIns(h), 0);

      // 今天喝满 8 杯 → 计入
      await hp.setCheckInValue(h, daysAgo(0), 8);
      expect(hp.checkInCount(h), 1);
      expect(hp.currentStreak(h), 1);
    });

    test('本周量化进度：累计量 / 目标量 / 达成率', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水', emoji: '💧', colorValue: 1, weekdays: const [], dailyTarget: 8);
      final h = hp.habits.first;
      await hp.setCheckInValue(h, daysAgo(0), 6);

      expect(hp.weeklyValue(h), 6);
      expect(hp.weeklyValueTarget(h), 7 * 8); // 空 weekdays = 每天 → 本周 7 天
      expect(hp.weeklyValueRatio(h), closeTo(6 / 56, 1e-9));
      // 布尔习惯不参与量化比例
      await hp.addHabit(title: '跑', emoji: '🏃', colorValue: 1, weekdays: const []);
      final b = hp.habits[1];
      expect(hp.weeklyValueRatio(b), 0.0);
      expect(hp.weeklyValueTarget(b), 0);
    });

    test('补卡可指定数量（checkInOnDay value）；撤卡走同一路径', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水', emoji: '💧', colorValue: 1, weekdays: const [], dailyTarget: 8);
      final h = hp.habits.first;

      await hp.checkInOnDay(h, daysAgo(2), value: 6);
      expect(hp.checkInValueOn(h, daysAgo(2)), 6);

      // 不传 value 且已有记录 → 幂等跳过
      await hp.checkInOnDay(h, daysAgo(2));
      expect(hp.checkInValueOn(h, daysAgo(2)), 6);

      await hp.uncheckInOnDay(h, daysAgo(2));
      expect(hp.checkInValueOn(h, daysAgo(2)), 0);
    });

    test('导出 CSV 带「每日目标」「宽限日」与打卡记录的「累计量」', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水',
          emoji: '💧',
          colorValue: 1,
          weekdays: const [],
          dailyTarget: 8,
          graceDays: 2);
      final h = hp.habits.first;
      await hp.setCheckInValue(h, daysAgo(0), 5);

      final csv = hp.exportCsv();
      expect(csv, contains('每日目标'));
      expect(csv, contains('宽限日(天)'));
      expect(csv, contains('累计量'));
      expect(csv, contains('"8"'));
      expect(csv, contains('5'));
    });
  });

  // ===================== T1-3 任务转习惯 =====================

  group('T1-3 HabitDraft.fromTask 字段映射', () {
    test('每周一/三/五 → 相同星期 + 周目标 3', () {
      final d = HabitDraft.fromTask(taskOf('1',
          repeat: RepeatType.weekly, weekdays: const [1, 3, 5]));
      expect(d.weekdays, [1, 3, 5]);
      expect(d.weeklyGoal, 3);
      expect(d.weekdaysLabel, '每周 一、三、五');
    });

    test('仅工作日 → 周一~周五 + 周目标 5', () {
      final d = HabitDraft.fromTask(taskOf('1', repeat: RepeatType.weekday));
      expect(d.weekdays, [1, 2, 3, 4, 5]);
      expect(d.weeklyGoal, 5);
    });

    test('每天 → 空星期（每天）+ 周目标 7', () {
      final d = HabitDraft.fromTask(taskOf('1', repeat: RepeatType.daily));
      expect(d.weekdays, isEmpty);
      expect(d.weekdaysLabel, '每天');
      expect(d.weeklyGoal, 7);
    });

    test('每隔 3 天 → 每天 + 周目标 ⌈7/3⌉=3，并如实告知折算', () {
      final d = HabitDraft.fromTask(
          taskOf('1', repeat: RepeatType.interval, interval: 3));
      expect(d.weeklyGoal, 3);
      expect(d.droppedNotes, isNotEmpty);
      expect(d.droppedNotes.first, contains('每隔 3 天'));
    });

    test('每隔 1 天 等价每天（周目标 7，无折算告警）', () {
      final d = HabitDraft.fromTask(
          taskOf('1', repeat: RepeatType.interval, interval: 1));
      expect(d.weeklyGoal, 7);
      expect(d.droppedNotes, isEmpty);
    });

    test('每月 → 周目标 1 并告警无法用星期表达', () {
      final d = HabitDraft.fromTask(taskOf('1',
          repeat: RepeatType.monthly, monthlyDay: 15));
      expect(d.weeklyGoal, 1);
      expect(d.droppedNotes.first, contains('每月'));
    });

    test('一次性任务 → 每天 + 无周目标', () {
      final d = HabitDraft.fromTask(taskOf('1'));
      expect(d.weekdays, isEmpty);
      expect(d.weeklyGoal, 0);
    });

    test('提醒时刻：优先重复提醒时刻，其次截止时间时分，皆无则不提醒', () {
      expect(
          HabitDraft.fromTask(taskOf('1',
                  repeat: RepeatType.daily, repeatMinute: 8 * 60))
              .reminderMinute,
          8 * 60);
      // 重复任务未写时刻 → 取截止时间 09:30（570 分钟）
      final due = DateTime(2026, 9, 19, 9, 30);
      expect(
          HabitDraft.fromTask(
                  taskOf('1', due: due, repeat: RepeatType.daily))
              .reminderMinute,
          9 * 60 + 30);
      // 两者皆无 → 不提醒
      expect(HabitDraft.fromTask(taskOf('1')).reminderMinute, isNull);
      // 重复提醒时刻优先于截止时间
      expect(
          HabitDraft.fromTask(taskOf('1',
                  due: due,
                  repeat: RepeatType.daily,
                  repeatMinute: 7 * 60))
              .reminderMinute,
          7 * 60);
    });

    test('标题 trim；空标题回退「未命名习惯」', () {
      expect(HabitDraft.fromTask(taskOf('1', title: '  背单词  ')).title, '背单词');
      expect(HabitDraft.fromTask(taskOf('1', title: '   ')).title, '未命名习惯');
    });

    test('addHabitFromDraft 建出的习惯与草稿一致', () async {
      final hp = await newHabitProvider();
      final draft = HabitDraft.fromTask(taskOf('1',
          title: '背单词',
          repeat: RepeatType.weekly,
          weekdays: const [1, 3],
          repeatMinute: 21 * 60));
      final created =
          await hp.addHabitFromDraft(draft, emoji: '📚', colorValue: 0xFF112233);

      final back = hp.byId(created.id)!;
      expect(back.title, '背单词');
      expect(back.emoji, '📚');
      expect(back.weekdays, [1, 3]);
      expect(back.weeklyGoal, 2);
      expect(back.reminderMinute, 21 * 60);
      expect(back.isQuantified, isFalse);
    });
  });

  // ===================== T1-4 习惯管理入口 =====================

  group('T1-4 编辑：提醒时刻 / 每日目标量 / 宽限日', () {
    test('updateHabit 可设置与清除提醒时刻（先取消旧提醒再重挂）', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(title: '跑', emoji: '🏃', colorValue: 1, weekdays: const []);
      final h = hp.habits.first;
      expect(h.reminderMinute, isNull);

      await hp.updateHabit(h, reminderMinute: 8 * 60);
      expect(hp.byId(h.id)!.reminderMinute, 8 * 60);

      // 改时间
      await hp.updateHabit(hp.byId(h.id)!, reminderMinute: 21 * 60);
      expect(hp.byId(h.id)!.reminderMinute, 21 * 60);

      // 清除
      await hp.updateHabit(hp.byId(h.id)!, clearReminder: true);
      expect(hp.byId(h.id)!.reminderMinute, isNull);
    });

    test('updateHabit 可开启 / 关闭量化目标与调整宽限日', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(title: '喝水', emoji: '💧', colorValue: 1, weekdays: const []);
      final h = hp.habits.first;

      await hp.updateHabit(h, dailyTarget: 8, graceDays: 2);
      expect(hp.byId(h.id)!.dailyTarget, 8);
      expect(hp.byId(h.id)!.graceDays, 2);

      // 传 0 → 取消量化（与弹层「关闭」语义一致）
      await hp.updateHabit(hp.byId(h.id)!, dailyTarget: 0);
      expect(hp.byId(h.id)!.dailyTarget, isNull);
      // 宽限日夹到 0..3
      await hp.updateHabit(hp.byId(h.id)!, graceDays: 9);
      expect(hp.byId(h.id)!.graceDays, 3);
    });

    test('重命名仍生效（回归：原编辑能力不回退）', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(title: '跑', emoji: '🏃', colorValue: 1, weekdays: const []);
      final h = hp.habits.first;
      await hp.updateHabit(h, title: '晨跑');
      expect(hp.byId(h.id)!.title, '晨跑');
    });
  });

  group('T1-4 删除可撤销', () {
    test('deleteHabit 返回快照，restoreHabit 原样放回（含打卡记录与原位置）',
        () async {
      final hp = await newHabitProvider();
      await hp.addHabit(title: 'A', emoji: '🅰', colorValue: 1, weekdays: const []);
      await hp.addHabit(title: 'B', emoji: '🅱', colorValue: 1, weekdays: const []);
      final b = hp.habits[1];
      await hp.checkInOnDay(b, daysAgo(1));
      await hp.checkInOnDay(b, daysAgo(2));

      final snap = await hp.deleteHabit(b.id);
      expect(snap, isNotNull);
      expect(snap!.checkIns.length, 2);
      expect(snap.undoLabel, contains('2 条打卡记录'));
      expect(hp.habits.length, 1);
      expect(hp.checkInCount(b), 0); // 记录随删除一并移除

      final restored = await hp.restoreHabit(snap);
      expect(restored?.id, b.id);
      expect(hp.habits.length, 2);
      expect(hp.habits[1].id, b.id); // 回到原下标
      expect(hp.checkInCount(hp.habits[1]), 2); // 打卡记录一起回来
      expect(hp.currentStreak(hp.habits[1]), 2);
    });

    test('restoreHabit 幂等：同 id 已存在时不重复插入', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(title: 'A', emoji: '🅰', colorValue: 1, weekdays: const []);
      final a = hp.habits.first;
      final snap = await hp.deleteHabit(a.id);
      expect(await hp.restoreHabit(snap!), isNotNull);
      expect(await hp.restoreHabit(snap), isNull);
      expect(hp.habits.length, 1);
    });

    test('删除不存在的 id 返回 null（不抛）', () async {
      final hp = await newHabitProvider();
      expect(await hp.deleteHabit('nope'), isNull);
    });
  });

  group('T1-4 宽限日（每周允许漏卡不断签）', () {
    test('缺 1 天：严格模式断签（连续 2 → 实际 2），宽限 1 天后继续（4）', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(title: '跑', emoji: '🏃', colorValue: 1, weekdays: const []);
      final h = hp.habits.first;
      // 达标日 = 今天 / 昨天 / 前天缺 / 大前天 / 4 天前
      for (final i in [0, 1, 3, 4]) {
        await hp.checkInOnDay(h, daysAgo(i));
      }

      // 严格模式：往前数到「前天」即断 → 连续 2 天
      expect(hp.currentStreak(h), 2);

      // 开启宽限日后同一份数据 → 连续 4 天（缺的那 1 天被宽限吸收）
      await hp.updateHabit(hp.byId(h.id)!, graceDays: 1);
      expect(hp.currentStreak(hp.byId(h.id)!), 4);
    });

    test('宽限额度按「自然周」计：相隔一周的两次缺卡各自可用额度', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '跑',
          emoji: '🏃',
          colorValue: 1,
          weekdays: const [],
          graceDays: 1);
      final h = hp.habits.first;
      // 今天起 10 天内只缺「1 天前」与「8 天前」——二者相隔 7 天，必然落在不同自然周，
      // 因此各自都能消耗当周的 1 次宽限额度，连续段不被切断。
      for (final i in [0, 2, 3, 4, 5, 6, 7, 9, 10]) {
        await hp.checkInOnDay(h, daysAgo(i));
      }
      expect(hp.currentStreak(h), 9);

      // 反证：关掉宽限 → 只数到今天为止的连续段（今天达标、昨天缺卡）→ 1
      await hp.updateHabit(hp.byId(h.id)!, graceDays: 0);
      expect(hp.currentStreak(hp.byId(h.id)!), 1);
    });

    test('周部分天习惯 + 宽限日：休息日中性，计划日缺卡可用宽限', () async {
      final hp = await newHabitProvider();
      // 每周一/三/五
      await hp.addHabit(
          title: '跑',
          emoji: '🏃',
          colorValue: 1,
          weekdays: const [1, 3, 5],
          graceDays: 1);
      final h = hp.habits.first;
      // 从今天往回取最近 4 个「计划日」，跳过最近的第 2 个（= 缺一次计划日）
      final planned = <DateTime>[];
      var cursor = daysAgo(0);
      while (planned.length < 4) {
        if (h.shouldCheckInOn(cursor)) planned.add(cursor);
        cursor = cursor.subtract(const Duration(days: 1));
      }
      for (final d in planned) {
        if (d == planned[1]) continue;
        await hp.checkInOnDay(h, d);
      }
      // 3 个达标计划日 + 1 次计划日缺卡被宽限吸收 → 3
      expect(hp.currentStreak(hp.byId(h.id)!), 3);

      // 反证：关掉宽限 → 最早的那个「计划日缺卡」直接切断 → 1
      await hp.updateHabit(hp.byId(h.id)!, graceDays: 0);
      expect(hp.currentStreak(hp.byId(h.id)!), 1);
    });
  });

  // ===================== UI 入口（widget 层） =====================

  group('T1-2 / T1-4 UI 入口', () {
    Future<void> pumpDetailSheet(WidgetTester tester, HabitProvider hp,
        Habit habit) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<HabitProvider>.value(
          value: hp,
          child: MaterialApp(
            theme: lightTheme,
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () => showHabitDetailSheet(ctx, habit),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('量化习惯详情层显示今日进度、+1 与「设置数量」入口', (tester) async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水',
          emoji: '💧',
          colorValue: 1,
          weekdays: const [],
          dailyTarget: 8);
      final h = hp.habits.first;
      await hp.setCheckInValue(h, DateTime.now(), 3);

      await pumpDetailSheet(tester, hp, h);

      expect(find.text('今日进度'), findsOneWidget);
      expect(find.text('3 / 8'), findsOneWidget);
      expect(find.text('设置数量'), findsOneWidget);
      expect(find.text('清空今日'), findsOneWidget);
      // 主按钮是「+1」而不是布尔习惯的「已打卡」
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('今日已打卡'), findsNothing);
    });

    testWidgets('编辑层含「每日提醒时刻」「每日目标量」「宽限日」三项（T1-4）',
        (tester) async {
      final hp = await newHabitProvider();
      await hp.addHabit(title: '跑', emoji: '🏃', colorValue: 1, weekdays: const []);
      final h = hp.habits.first;

      await pumpDetailSheet(tester, hp, h);
      // 顶栏「编辑习惯」→ 打开编辑层
      await tester.tap(find.byTooltip('编辑习惯'));
      await tester.pumpAndSettle();

      expect(find.text('编辑习惯'), findsOneWidget);
      expect(find.text('每日提醒时刻'), findsOneWidget);
      expect(find.text('每日目标量'), findsOneWidget);
      expect(find.text('宽限日'), findsOneWidget);
      expect(find.text('未设置'), findsOneWidget); // 提醒未设置时的值
    });
  });
}

/// 固定时间戳（避免 Habit 构造里 DateTime.now() 带来的不稳定）。
final DateTime _epoch = DateTime(2026, 9, 19);
