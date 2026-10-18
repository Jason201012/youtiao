import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// 「有条」v2.8.4 功能与操作审计报告（F-1 ~ F-11）的回归测试。
///
/// 报告的核心结论是：**重复任务提醒这条主链路存在一组相互关联的静默失效缺陷**，
/// 且都躲在历次修复（F-04 / P1-2 / F3 / P2-2）没有覆盖到的分支上。
/// 本文件按「纯函数契约 + Provider 状态机」两层把它们钉死：
/// - F-1：调度门槛只由 repeatUntil 决定（不因 dueDate 已过而停挂）；
/// - F-2：落点必须消费 skipDates / repeatUntil / doneDates；
/// - F-3：勿扰顺延逐落点生效；
/// - F-4：改期副本取原重复的提醒时刻；
/// - F-5：结束重复后干净退场（不入逾期分区）；
/// - F-7 / F-8 / F-9 / F-10：历史裁剪、备份数值夹取、月内字段清空哨兵、未来预完成。
///
/// 固定时间坐标（避免用 DateTime.now() 让断言随运行日漂移）：
///   2026-09-12（周六）09:00 → 下一个周一 = 2026-09-14。
const int _kRep = 7 * 60; // 07:00

Task _task({
  String id = '1',
  RepeatType repeat = RepeatType.daily,
  int? repeatMinute = _kRep,
  DateTime? due,
  String? repeatUntil,
  List<int> weekdays = const [],
  int interval = 1,
  DateTime? anchor,
  List<String> skipDates = const [],
  List<String> doneDates = const [],
  int monthlyDay = 1,
  int? monthlyWeekday,
  int? monthlyWeekIndex,
  int monthlyFromEnd = 0,
  TaskStatus status = TaskStatus.todo,
  DateTime? completedAt,
}) =>
    Task(
      id: id,
      title: 'T$id',
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
      repeat: repeat,
      repeatMinute: repeatMinute,
      repeatUntil: repeatUntil,
      repeatWeekdays: weekdays,
      repeatInterval: interval,
      repeatAnchor: anchor,
      skipDates: skipDates,
      doneDates: doneDates,
      monthlyDay: monthlyDay,
      monthlyWeekday: monthlyWeekday,
      monthlyWeekIndex: monthlyWeekIndex,
      monthlyFromEnd: monthlyFromEnd,
      status: status,
      completedAt: completedAt,
    );

DateTime _d(int y, int m, int day, [int h = 0, int min = 0]) =>
    DateTime(y, m, day, h, min);

void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控列表构造 Provider（绕过 load()，避免启动午夜守护定时器）。
Future<TaskProvider> _buildWith(List<Task> tasks) async {
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

void main() {
  setUp(() {
    _installMocks();
    NotificationService.dndDefer = null;
  });

  // ─────────────────────────────────────────────────────────────
  group('F-1 重复提醒门槛：唯一判据是 repeatUntil，与 dueDate 无关', () {
    final yesterday2359 = () {
      final y = DateTime.now().subtract(const Duration(days: 1));
      return DateTime(y.year, y.month, y.day, 23, 59);
    }();

    test('截止日期是「创建当天 23:59」（已过）时，全部重复类型仍必须挂提醒', () {
      // 复现路径：第一天建「每天 7:00 喝水」（内部 due = 第一天 23:59），
      // 第二天点一次「本次跳过」/改一次提醒时间/关→开一次通知总开关，
      // 旧门槛因 `_dateHasPassed(due)` 恒为 true 而不再重挂 → 此后永久静默。
      final cases = <RepeatType, Task>{
        RepeatType.daily: _task(repeat: RepeatType.daily, due: yesterday2359),
        RepeatType.weekly: _task(
            repeat: RepeatType.weekly, weekdays: const [1], due: yesterday2359),
        RepeatType.weekday:
            _task(repeat: RepeatType.weekday, due: yesterday2359),
        RepeatType.monthly:
            _task(repeat: RepeatType.monthly, due: yesterday2359),
        RepeatType.interval: _task(
            repeat: RepeatType.interval,
            interval: 3,
            anchor: DateTime(2026, 1, 1),
            due: yesterday2359),
      };
      cases.forEach((type, t) {
        expect(TaskProvider.shouldScheduleRepeatReminder(t), isTrue,
            reason: '$type 不应因 dueDate 已过而停挂提醒（F-1 根因②）');
      });
    });

    test('完全不设截止日期也仍必须挂提醒（旧门槛直接 false）', () {
      expect(
        TaskProvider.shouldScheduleRepeatReminder(_task(due: null)),
        isTrue,
      );
    });

    test('非重复任务 / 缺提醒时刻 → 不挂', () {
      expect(
        TaskProvider.shouldScheduleRepeatReminder(
            _task(repeat: RepeatType.none, repeatMinute: null)),
        isFalse,
      );
      expect(
        TaskProvider.shouldScheduleRepeatReminder(_task(repeatMinute: null)),
        isFalse,
      );
    });

    test('repeatUntil = 昨天 → 停挂；= 今天 → 仍挂（结束日含当日）', () {
      final now = DateTime.now();
      String ymd(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      expect(
        TaskProvider.shouldScheduleRepeatReminder(
            _task(repeatUntil: ymd(now.subtract(const Duration(days: 1))))),
        isFalse,
      );
      expect(
        TaskProvider.shouldScheduleRepeatReminder(_task(repeatUntil: ymd(now))),
        isTrue,
      );
      expect(
        TaskProvider.shouldScheduleRepeatReminder(
            _task(repeatUntil: ymd(now.add(const Duration(days: 7))))),
        isTrue,
      );
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('F-2 落点计算：消费 skipDates / repeatUntil / doneDates', () {
    final now = _d(2026, 9, 12, 9, 0); // 周六 09:00

    test('今天该响但时刻未到 → 挂今天；时刻已过 → 顺延明天', () {
      expect(
        NotificationService.repeatOccurrenceTimes(_task(),
            now: _d(2026, 9, 12, 6, 0), count: 1),
        [DateTime(2026, 9, 12, 7, 0)],
      );
      expect(
        NotificationService.repeatOccurrenceTimes(_task(), now: now, count: 1),
        [DateTime(2026, 9, 13, 7, 0)],
      );
    });

    test('「没到点就本次跳过」必须生效（skipDates 命中今天）', () {
      // 旧实现（OS 周期闹钟）只认「今天已完成」，不读 skipDates：
      // 今天 07:00 还没到就点「本次跳过」，重排后落点仍是今天 07:00 → 今天照响。
      final t = _task(skipDates: const ['2026-09-12']);
      expect(
        NotificationService.repeatOccurrenceTimes(t,
            now: _d(2026, 9, 12, 6, 0), count: 1),
        [DateTime(2026, 9, 13, 7, 0)],
      );
    });

    test('「提前跳过未来某个星期」必须生效（weekly 命中 skipDates）', () {
      // 旧实现 nextWeekday() 只按星期几找，不校验该日是否在 skipDates。
      final t = _task(
        repeat: RepeatType.weekly,
        weekdays: const [1], // 周一
        skipDates: const ['2026-09-14'], // 下周一
      );
      final occ = NotificationService.repeatOccurrenceTimes(t, now: now, count: 2);
      expect(occ.first, DateTime(2026, 9, 21, 7, 0),
          reason: '被跳过的 09-14 必须被跳过，落点顺延到再下一个周一');
      expect(occ[1], DateTime(2026, 9, 28, 7, 0));
    });

    test('repeatUntil 到期后不再产生落点（不依赖打开 App 才停止）', () {
      final t = _task(repeatUntil: '2026-09-15');
      final occ = NotificationService.repeatOccurrenceTimes(t, now: now, count: 8);
      expect(occ, [
        DateTime(2026, 9, 13, 7, 0),
        DateTime(2026, 9, 14, 7, 0),
        DateTime(2026, 9, 15, 7, 0),
      ], reason: '结束日含当日，之后不得再排（旧 OS 周期闹钟会继续按天弹）');
    });

    test('今天已完成 → 跳过今天（done + completedAt=今天）', () {
      final t = _task(
        status: TaskStatus.done,
        completedAt: _d(2026, 9, 12, 8, 0),
      );
      expect(
        NotificationService.repeatOccurrenceTimes(t, now: now, count: 1),
        [DateTime(2026, 9, 13, 7, 0)],
      );
    });

    test('F-10：未来循环日被「预标记完成」后当天不再响', () {
      final t = _task(doneDates: const ['2026-09-13']);
      expect(
        NotificationService.repeatOccurrenceTimes(t, now: now, count: 1),
        [DateTime(2026, 9, 14, 7, 0)],
      );
    });

    test('每隔 N 天：按锚点相位逐日落点（复刻既有 interval 语义）', () {
      final t = _task(
        repeat: RepeatType.interval,
        interval: 3,
        anchor: DateTime(2026, 9, 9), // 09-09 起每 3 天 → 09-12 恰为循环日
      );
      final occ = NotificationService.repeatOccurrenceTimes(t, now: now, count: 3);
      expect(occ, [
        // 09-12 虽是循环日，但 today 的 07:00 已过（now=09:00）→ 不补弹，跳到下个周期日
        DateTime(2026, 9, 15, 7, 0),
        DateTime(2026, 9, 18, 7, 0),
        DateTime(2026, 9, 21, 7, 0),
      ]);
    });

    test('每月规则：复杂月规则逐月命中（月内规则一律一次性落点）', () {
      final t = _task(
        repeat: RepeatType.monthly,
        monthlyFromEnd: 1, // 每月最后一天
        skipDates: const ['2026-09-30'],
      );
      final occ = NotificationService.repeatOccurrenceTimes(t, now: now, count: 2);
      expect(occ.first, DateTime(2026, 10, 31, 7, 0),
          reason: '9 月最后一天被跳过 → 顺延到 10 月最后一天');
      expect(occ[1], DateTime(2026, 11, 30, 7, 0));
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('F-3 勿扰顺延：逐落点作用于首个与后续落点', () {
    final now = _d(2026, 9, 12, 9, 0);

    test('重复任务提醒落在勿扰区间 → 顺延到勿扰结束 + 5 分钟', () {
      // 复刻 main.dart 注入的 dndDefer：勿扰 23:00–08:00，顺延到次日 08:05。
      DateTime? defer(DateTime s) {
        if (s.hour < 8) {
          return DateTime(s.year, s.month, s.day, 8, 5);
        }
        return null;
      }

      final occ = NotificationService.repeatOccurrenceTimes(
        _task(repeatMinute: 7 * 60), // 每天 07:00，落在勿扰区间内
        now: now,
        count: 2,
        defer: defer,
      );
      expect(occ, [
        DateTime(2026, 9, 13, 8, 5),
        DateTime(2026, 9, 14, 8, 5),
      ], reason: '逐个落点独立顺延（一次性闹钟不会把顺延写进周期分量而漂移）');
    });

    test('习惯每日提醒同样顺延（F-3 的第二处漏接点）', () {
      DateTime? defer(DateTime s) =>
          s.hour < 8 ? DateTime(s.year, s.month, s.day, 8, 5) : null;
      final habit = Habit(
        id: 'h1',
        title: '起床',
        reminderMinute: 7 * 60,
        createdAt: DateTime(2026, 1, 1),
      );
      final occ = NotificationService.habitOccurrenceTimes(habit,
          now: now, count: 2, defer: defer);
      expect(occ, [
        DateTime(2026, 9, 13, 8, 5),
        DateTime(2026, 9, 14, 8, 5),
      ]);
    });

    test('不在勿扰区间 → 原样投递；今天已打卡 → 跳过今天', () {
      DateTime? noDefer(DateTime s) => null;
      final habit = Habit(
        id: 'h1',
        title: '喝水',
        reminderMinute: 12 * 60,
        createdAt: DateTime(2026, 1, 1),
      );
      expect(
        NotificationService.habitOccurrenceTimes(habit,
            now: _d(2026, 9, 12, 6, 0), count: 1, defer: noDefer),
        [DateTime(2026, 9, 12, 12, 0)],
      );
      expect(
        NotificationService.habitOccurrenceTimes(habit,
            now: _d(2026, 9, 12, 6, 0),
            checkedToday: true,
            count: 1,
            defer: noDefer),
        [DateTime(2026, 9, 13, 12, 0)],
      );
    });

    test('习惯按星期筛选（空列表 = 每天）', () {
      final weekly = Habit(
        id: 'h2',
        title: '跑步',
        weekdays: const [1, 3], // 周一、周三
        reminderMinute: 7 * 60,
        createdAt: DateTime(2026, 1, 1),
      );
      final occ = NotificationService.habitOccurrenceTimes(weekly,
          now: _d(2026, 9, 12, 9, 0), count: 2);
      expect(occ, [
        DateTime(2026, 9, 14, 7, 0), // 周一
        DateTime(2026, 9, 16, 7, 0), // 周三
      ]);
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('F-4 改期副本使用原重复的提醒时刻', () {
    test('「仅此一次改期」副本时刻取 repeatMinute，而非被钉成 23:59 的 dueDate', () async {
      // 旧实现取 src.dueDate（重复任务的 dueDate 被录入侧钉成「创建当天 23:59」），
      // 于是「把今天 7 点这件事挪到明天」实际得到「明天 23:59」。
      // F-2（v2.8.5 审计）后源任务改用「每周一」：目标日 2026-09-13 是周日、
      // 不是循环日 → 仍建一次性副本（daily 改到明天会被防撞合并进原循环，
      // 该分支由 v285_audit_fix_test 的 F-2 组钉死）。
      final created = DateTime(2026, 9, 10);
      final p = await _buildWith([
        _task(
          repeat: RepeatType.weekly,
          weekdays: const [DateTime.monday],
          due: DateTime(created.year, created.month, created.day, 23, 59),
          skipDates: const [],
        ),
      ]);
      // P2-2（v3.0.7 审计）：rescheduleOnceOccurrence 随 addTask 异步化。
      final copy =
          (await p.rescheduleOnceOccurrence('1', DateTime(2026, 9, 13)))!;
      expect(copy.dueDate, DateTime(2026, 9, 13, 7, 0));
      expect(copy.repeat, RepeatType.none);
      expect(copy.isRepeating, isFalse);
      expect(copy.repeatMinute, isNull);
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('F-5 结束重复 / 自然到期后干净退场', () {
    test('endRepeat 清空占位截止日，任务不再落入「逾期」分区', () async {
      final p = await _buildWith([
        _task(
          due: DateTime(2026, 8, 1, 23, 59),
          repeat: RepeatType.daily,
        ),
      ]);
      expect(p.homeTasks['repeat']!.map((t) => t.id), contains('1'),
          reason: '前置：仍在循环期内 → 归「每天」分区');

      p.endRepeat('1');
      final t = p.byId('1')!;
      expect(t.isRepeatEnded(DateTime.now()), isTrue);
      expect(t.dueDate, isNull, reason: 'F-5：结束重复应解除那个过期的占位截止日');
      // 旧实现保留了 dueDate=2026-08-01 → 已结束的重复任务回落日期分区时
      // `dayDiff < 0`，被永久归入「逾期」每天挂在列表里等用户手动处理。
      expect(p.homeTasks['overdue'], isEmpty);
      expect(p.homeTasks['repeat'], isEmpty);
      expect(p.homeTasks['today']!.map((e) => e.id), contains('1'));
      expect(p.sectionCounts['overdue'], 0);
    });

    test('自然到期（repeatUntil = 昨天）同样不落逾期分区', () async {
      final p = await _buildWith([
        _task(
          due: DateTime(2026, 8, 1, 23, 59),
          repeat: RepeatType.daily,
          repeatUntil: '2020-01-01',
        ),
      ]);
      // 数据层无法改写（判定是派生的），由 [_effectiveDue] 中性化其占位截止日。
      expect(p.homeTasks['overdue'], isEmpty);
      expect(p.homeTasks['repeat'], isEmpty);
      expect(p.sectionCounts['overdue'], 0);
    });

    test('仍在循环期内的重复任务不受影响（仍归「每天」）', () async {
      final p = await _buildWith([
        _task(due: DateTime(2026, 8, 1, 23, 59), repeat: RepeatType.daily),
      ]);
      expect(p.homeTasks['repeat']!.map((t) => t.id), contains('1'));
      expect(p.homeTasks['overdue'], isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('F-7 完成 / 跳过历史的滚动保留窗口', () {
    final now = DateTime(2026, 9, 12);

    test('超出保留窗口的日期被裁掉，窗口内的保留', () {
      final kept = Task.pruneHistory(
          ['2019-01-01', '2026-09-01', '2026-09-12'], now);
      expect(kept, ['2026-09-01', '2026-09-12']);
    });

    test('窗口边界：恰好等于 keepDays 之前的日期保留，再早一天被裁', () {
      final cutoff = DateTime(2026, 9, 12).subtract(const Duration(days: 400));
      final onEdge = '${cutoff.year}-${cutoff.month.toString().padLeft(2, '0')}'
          '-${cutoff.day.toString().padLeft(2, '0')}';
      final before = cutoff.subtract(const Duration(days: 1));
      final beforeKey = '${before.year}-${before.month.toString().padLeft(2, '0')}'
          '-${before.day.toString().padLeft(2, '0')}';
      expect(Task.pruneHistory([onEdge], now), isNull,
          reason: '边界日仍有效 → 无需改动');
      expect(Task.pruneHistory([beforeKey], now), isEmpty);
    });

    test('全部有效且无重复 → 返回 null（不触发无谓写回）', () {
      expect(Task.pruneHistory(['2026-09-01', '2026-09-12'], now), isNull);
    });

    test('重复项去重、形态非法的脏串剔除', () {
      final out = Task.pruneHistory(
          ['2026-09-01', '2026-09-01', 'abc', '2026-9-1'], now);
      expect(out, ['2026-09-01']);
    });

    test('「每天」任务连续三年只保留约 400 天，长度有上界', () {
      final all = <String>[];
      for (var i = 0; i < 3 * 365; i++) {
        final d = now.subtract(Duration(days: i));
        all.add('${d.year}-${d.month.toString().padLeft(2, '0')}'
            '-${d.day.toString().padLeft(2, '0')}');
      }
      final pruned = Task.pruneHistory(all, now)!;
      expect(pruned.length, Task.historyRetentionDays + 1);
      expect(pruned.length, lessThan(all.length));
    });

    test('Provider 写入路径真的裁剪（skipOccurrence）', () async {
      final old = <String>[];
      for (var i = 0; i < 450; i++) {
        final d = DateTime.now().subtract(Duration(days: i + 30));
        old.add('${d.year}-${d.month.toString().padLeft(2, '0')}'
            '-${d.day.toString().padLeft(2, '0')}');
      }
      final p = await _buildWith([_task(skipDates: old)]);
      p.skipOccurrence('1'); // 把今天加入 skipDates
      final t = p.byId('1')!;
      expect(t.skipDates.length, lessThanOrEqualTo(Task.historyRetentionDays + 1));
      expect(t.skipDates, contains(Task.ymdKey(DateTime.now())));
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('F-8 备份 / 手改 JSON 的数值字段范围夹取', () {
    Map<String, dynamic> base(Map<String, dynamic> extra) => {
          'id': '1',
          'title': 'T',
          'priority': 'medium',
          'category': 'work',
          'repeat': 'monthly',
          ...extra,
        };

    test('repeatMinute 越界 → 置空（不再显示「每天 166:39」）', () {
      expect(Task.fromJson(base({'repeatMinute': 9999})).repeatMinute, isNull);
      expect(Task.fromJson(base({'repeatMinute': -5})).repeatMinute, isNull);
      expect(Task.fromJson(base({'repeatMinute': 1439})).repeatMinute, 1439);
      expect(Task.fromJson(base({'repeatMinute': 0})).repeatMinute, 0);
    });

    test('非法 monthlyWeekday / monthlyWeekIndex → 回退 null（不再制造哑任务）', () {
      final t = Task.fromJson(base({'monthlyWeekday': 9, 'monthlyWeekIndex': 0}));
      expect(t.monthlyWeekday, isNull);
      expect(t.monthlyWeekIndex, isNull);
      expect(Task.fromJson(base({'monthlyWeekday': 7})).monthlyWeekday, 7);
      expect(Task.fromJson(base({'monthlyWeekIndex': 5})).monthlyWeekIndex, 5);
    });

    test('monthlyDay / monthlyFromEnd 越界回退默认值', () {
      expect(Task.fromJson(base({'monthlyDay': 0})).monthlyDay, 1);
      expect(Task.fromJson(base({'monthlyDay': 99})).monthlyDay, 1);
      expect(Task.fromJson(base({'monthlyDay': 31})).monthlyDay, 31);
      expect(Task.fromJson(base({'monthlyFromEnd': -3})).monthlyFromEnd, 0);
      expect(Task.fromJson(base({'monthlyFromEnd': 3})).monthlyFromEnd, 3);
    });

    test('repeatInterval 0/负数 → 1（防调度侧步进为 0）', () {
      expect(Task.fromJson(base({'repeatInterval': 0})).repeatInterval, 1);
      expect(Task.fromJson(base({'repeatInterval': -7})).repeatInterval, 1);
      expect(Task.fromJson(base({'repeatInterval': 30})).repeatInterval, 30);
    });

    test('reminderOffsetMin 负数 → 0', () {
      expect(Task.fromJson(base({'reminderOffsetMin': -60})).reminderOffsetMin, 0);
      expect(Task.fromJson(base({'reminderOffsetMin': 15})).reminderOffsetMin, 15);
    });

    test('repeatWeekdays 过滤越界值与重复值并升序', () {
      final t = Task.fromJson(base({
        'repeat': 'weekly',
        'repeatWeekdays': [3, 3, 9, 0, 1],
      }));
      expect(t.repeatWeekdays, [1, 3]);
    });

    test('字段形态非法（字符串）不再整体抛异常', () {
      expect(Task.fromJson(base({'repeatMinute': 'oops'})).repeatMinute, isNull);
      expect(Task.fromJson(base({'monthlyDay': 'oops'})).monthlyDay, 1);
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('F-9 copyWith 能显式清空月内规则（_kKeep 哨兵）', () {
    test('传 null 清空 monthlyWeekday / monthlyWeekIndex（改回「固定几号」）', () {
      final t = _task(
        repeat: RepeatType.monthly,
        monthlyWeekday: 7,
        monthlyWeekIndex: 5,
      );
      final back = t.copyWith(monthlyWeekday: null, monthlyWeekIndex: null);
      expect(back.monthlyWeekday, isNull);
      expect(back.monthlyWeekIndex, isNull);
      // 清空后每月命中回落到 monthlyDay，而不是永远匹配不到任何一天。
      expect(back.repeatsOn(DateTime(2026, 9, t.monthlyDay)), isTrue);
    });

    test('不传参数时保留旧值（哨兵未被破坏）', () {
      final t = _task(
        repeat: RepeatType.monthly,
        monthlyWeekday: 3,
        monthlyWeekIndex: 2,
      );
      final same = t.copyWith(title: 'X');
      expect(same.monthlyWeekday, 3);
      expect(same.monthlyWeekIndex, 2);
    });

    test('normalizedRepeatFields：切到非 monthly 时清空月内规则并回落默认', () {
      final t = _task(
        repeat: RepeatType.monthly,
        monthlyDay: 15,
        monthlyWeekday: 7,
        monthlyWeekIndex: 5,
        monthlyFromEnd: 2,
      ).copyWith(repeat: RepeatType.daily).normalizedRepeatFields();
      expect(t.monthlyDay, 1);
      expect(t.monthlyWeekday, isNull);
      expect(t.monthlyWeekIndex, isNull);
      expect(t.monthlyFromEnd, 0);
    });

    test('normalizedRepeatFields 对 monthly 保持月内规则不动', () {
      final t = _task(
        repeat: RepeatType.monthly,
        monthlyDay: 15,
      ).normalizedRepeatFields();
      expect(t.monthlyDay, 15);
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('F-10 未来循环日不再提供「预打卡」语义', () {
    test('isDoneOn 覆盖 doneDates（调度层抑制未来预完成的依据）', () {
      final t = _task(doneDates: const ['2026-09-20']);
      expect(t.isDoneOn(DateTime(2026, 9, 20)), isTrue);
      expect(t.isDoneOn(DateTime(2026, 9, 21)), isFalse);
    });
  });
}
