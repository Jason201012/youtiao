import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/task_parser.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// v2.8.5 功能与操作审计报告（2026-09-12）修复回归测试。
///
/// 覆盖：F-1（重复任务不再挂一次性截止提醒）、F-2（仅此一次改期防撞循环日）、
/// F-3（结束重复·标记完成归属「已完成」分区）、F-4（weekdays 习惯连续天数）、
/// F-7（重复默认时刻统一 07:00）、F-8（fromJson 容错 + interval 锚点自愈）、
/// F-10（ics 部分保留计数）、F-11（大间隔扫描窗自适应）。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 捕获通知插件 zonedSchedule/show 的调用 id，按段位分类。
/// 段位口径与 NotificationService 一致：
/// - 一次性截止提醒 = 任务数字 id 本身（测试内远小于 1e6）；
/// - 重复提醒 = [1600000000, 1840000000)；
/// - snooze = [1900000000, 2000000000)。
class _NotifySpy {
  final List<String> calls = [];

  int get deadlineCount => calls.where((id) {
        final n = int.tryParse(id) ?? -1;
        return n >= 0 && n < 1000000;
      }).length;

  int get repeatCount => calls.where((id) {
        final n = int.tryParse(id) ?? -1;
        return n >= 1600000000 && n < 1840000000;
      }).length;

  void install() {
    const ch = MethodChannel('dexterous.com/flutter/local_notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
      if (call.method == 'zonedSchedule' || call.method == 'show') {
        final id = call.arguments is Map ? call.arguments['id'] : null;
        if (id is int) calls.add('$id');
      }
      return null;
    });
  }
}

Task _repeatTask(
  String id, {
  RepeatType repeat = RepeatType.daily,
  int? repeatMinute = 420,
  DateTime? due,
  List<int> weekdays = const [],
  int interval = 1,
  DateTime? anchor,
}) =>
    Task(
      id: id,
      title: 'T$id',
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
      repeat: repeat,
      repeatWeekdays: weekdays,
      repeatInterval: interval,
      repeatMinute: repeatMinute,
      repeatAnchor: anchor,
    );

void main() {
  setUpAll(_installMocks);
  setUp(() => LocalDatabase.resetMemoryForTest());

  group('F-1 重复任务不挂一次性截止提醒（调度互斥）', () {
    test('shouldScheduleDeadlineReminder：重复+dueDate=false，一次性+dueDate=true', () {
      final now = DateTime.now();
      final repeating =
          _repeatTask('101', due: now.add(const Duration(days: 5)));
      final oneShot = Task(
        id: '102',
        title: 'one-shot',
        priority: Priority.medium,
        category: Category.work,
        dueDate: now.add(const Duration(days: 5)),
      );
      expect(TaskProvider.shouldScheduleDeadlineReminder(repeating), isFalse,
          reason: '重复任务的提醒只由重复链路负责，即便带 dueDate 也不挂截止提醒');
      expect(TaskProvider.shouldScheduleDeadlineReminder(oneShot), isTrue);
    });

    test('通知 id 唯一性：重复任务带 dueDate，只产生重复提醒段的通知', () async {
      final spy = _NotifySpy();
      spy.install();
      final now = DateTime.now();
      final p = TaskProvider();
      final json = jsonEncode({
        'version': 2,
        'tasks': [
          _repeatTask('201',
                due: DateTime(now.year, now.month, now.day)
                    .add(const Duration(days: 8, hours: 9)))
              .toJson(),
        ],
        'trash': [],
        'notifications_enabled': true,
        'sound_enabled': false,
      });
      await p.restoreFromJson(json);
      // 恢复后全量重排：一次性截止段（0 号段）必须为 0，重复段必须 > 0。
      expect(spy.deadlineCount, 0,
          reason: '重复任务带 dueDate 不得再挂一次性截止提醒（双响根因）');
      expect(spy.repeatCount, greaterThan(0));
    });
  });

  group('F-2 仅此一次改期 / 移到下一天防撞循环日', () {
    test('daily 任务改期到明天（循环日）：不建副本、仅 skip 今天、任务数不净增', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final p = TaskProvider();
      await p.restoreFromJson(jsonEncode({
        'version': 2,
        'tasks': [_repeatTask('301', repeatMinute: 420).toJson()],
        'trash': [],
        'notifications_enabled': false,
      }));
      final before = p.tasks.length;
      // P2-2（v3.0.7 审计）：rescheduleOnceOccurrence 异步化（下同）。
      // P3-2（v3.0.8 审计）：coveredByLoop 是显式分支，不再靠 copy==null 反推。
      final r = await p.rescheduleOnceOccurrence(
        '301',
        today.add(const Duration(days: 1)),
        origDay: today,
      );
      expect(r.coveredByLoop, isTrue,
          reason: '明天本身就是循环日，原循环已覆盖，不得另建副本');
      expect(r.copy, isNull);
      expect(p.tasks.length, before, reason: '活动任务数不得净增');
      final t = p.byId('301')!;
      expect(t.skipDates, contains(Task.ymdKey(today)));
    });

    test('weekly 任务改期到非循环日：照常建一次性副本', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      // 周日 = 7：若今天是周日，「明天」= 周一不是循环日；否则找一个确定不是
      // 循环日的日子——循环日为周一，取今天 +1 后直到命中非周一的那天。
      var target = today.add(const Duration(days: 1));
      while (target.weekday == DateTime.monday) {
        target = target.add(const Duration(days: 1));
      }
      final p = TaskProvider();
      await p.restoreFromJson(jsonEncode({
        'version': 2,
        'tasks': [
          _repeatTask('302',
                  repeat: RepeatType.weekly,
                  weekdays: const [DateTime.monday],
                  repeatMinute: 480)
              .toJson(),
        ],
        'trash': [],
        'notifications_enabled': false,
      }));
      final before = p.tasks.length;
      final r = await p.rescheduleOnceOccurrence('302', target, origDay: today);
      final copy = r.copy;
      expect(r.coveredByLoop, isFalse);
      expect(copy, isNotNull, reason: '目标日不是循环日 → 副本仍需承载这一次');
      expect(p.tasks.length, before + 1);
      expect(copy!.repeat, RepeatType.none);
      expect(p.byId('302')!.skipDates, contains(Task.ymdKey(today)));
    });

    test('改期目标日 == 原日（用户把今天改到今天）：整体无操作（P3-3 / v2.9.1）', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final p = TaskProvider();
      await p.restoreFromJson(jsonEncode({
        'version': 2,
        'tasks': [_repeatTask('303', repeatMinute: 600).toJson()],
        'trash': [],
        'notifications_enabled': false,
      }));
      final before = p.tasks.length;
      final r = await p.rescheduleOnceOccurrence('303', today, origDay: today);
      // P3-3（v2.9.1 审计）：原实现会「skip 今天 + 新建一条 dueDate=今天的一次性副本」，
      // 于是同一天出现两条任务，且副本的提醒时刻（原 repeatMinute）多半已过、静默不响。
      // 现在目标日 == 原日属**整体无操作**：不跳过、不建副本（P3-2，v3.0.8：noop 显式分支）。
      expect(r.noop, isTrue, reason: '目标日即原日时没有任何需要改期的东西');
      expect(r.copy, isNull);
      expect(p.tasks.length, before, reason: '不得新建同日副本');
      expect(p.byId('303')!.skipDates, isEmpty, reason: '不得把今天标记为跳过');
    });
  });

  group('F-3 结束重复（含标记完成）', () {
    test('endRepeat 默认：repeatUntil=昨天、dueDate 清空、状态保留待办', () async {
      final p = TaskProvider();
      await p.restoreFromJson(jsonEncode({
        'version': 2,
        'tasks': [_repeatTask('401', repeatMinute: 420).toJson()],
        'trash': [],
        'notifications_enabled': false,
      }));
      p.endRepeat('401');
      final t = p.byId('401')!;
      expect(t.isRepeatEnded(DateTime.now()), isTrue);
      expect(t.dueDate, isNull);
      expect(t.done, isFalse, reason: '默认保留为普通待办，落在「今天」分区由用户处置');
      expect(p.homeTasks['today']!.any((e) => e.id == '401'), isTrue);
    });

    test('endRepeat(markDone: true)：置为已完成并计入今日完成历史，落「已完成」分区',
        () async {
      final p = TaskProvider();
      await p.restoreFromJson(jsonEncode({
        'version': 2,
        'tasks': [_repeatTask('402', repeatMinute: 420).toJson()],
        'trash': [],
        'notifications_enabled': false,
      }));
      p.endRepeat('402', markDone: true);
      final t = p.byId('402')!;
      expect(t.done, isTrue);
      expect(t.completedAt, isNotNull);
      expect(t.isDoneOn(DateTime.now()), isTrue, reason: '完成历史（doneDates）计入今天');
      expect(t.isRepeatEnded(DateTime.now()), isTrue);
      expect(p.homeTasks['done']!.any((e) => e.id == '402'), isTrue);
      expect(p.homeTasks['today']!.any((e) => e.id == '402'), isFalse);
    });
  });

  group('F-4 习惯连续天数按计划打卡日计算（weekdays）', () {
    Future<(HabitProvider, Habit)> makeHabit(List<int> weekdays) async {
      final hp = HabitProvider();
      await hp.load();
      await hp.addHabit(
        title: 'W',
        emoji: 'W',
        colorValue: 1,
        weekdays: weekdays,
      );
      return (hp, hp.habits.first);
    }

    /// 习惯计划日序列（weekdays 命中的日期，均严格早于今天）中倒数第
    /// [offset] 个（0 = 最近一个）的日期。不依赖「今天是星期几」，用例确定。
    DateTime plannedDayBack(Habit h, int offset) {
      final wd = h.weekdays.toSet();
      var d = DateTime.now();
      d = DateTime(d.year, d.month, d.day);
      var seen = -1;
      while (true) {
        d = d.subtract(const Duration(days: 1));
        if (wd.contains(d.weekday)) {
          seen++;
          if (seen == offset) return d;
        }
      }
    }

    /// 严格早于今天、且不是计划日（休息日）的最近一天。
    DateTime nonPlannedDay(Habit h) {
      final wd = h.weekdays.toSet();
      var d = DateTime.now();
      d = DateTime(d.year, d.month, d.day);
      while (true) {
        d = d.subtract(const Duration(days: 1));
        if (!wd.contains(d.weekday)) return d;
      }
    }

    test('每周一/三/五：最近三个计划日都打卡 → current=3，longest=3', () async {
      final (hp, h) = await makeHabit(const [1, 3, 5]);
      await hp.checkInOnDay(h, plannedDayBack(h, 0));
      await hp.checkInOnDay(h, plannedDayBack(h, 1));
      await hp.checkInOnDay(h, plannedDayBack(h, 2));
      expect(hp.currentStreak(h), 3,
          reason: '休息日（周二/四/周末）不再被当成断签');
      expect(hp.longestStreak(h), 3);
    });

    test('缺最近一个计划日 → current=0；其前两个连续 → longest=2', () async {
      final (hp, h) = await makeHabit(const [1, 3, 5]);
      await hp.checkInOnDay(h, plannedDayBack(h, 1));
      await hp.checkInOnDay(h, plannedDayBack(h, 2));
      expect(hp.currentStreak(h), 0, reason: '最近的计划日缺卡即断（自然日口径下不会是 0）');
      expect(hp.longestStreak(h), 2);
    });

    test('缺中间一个计划日 → current=1，longest=2', () async {
      final (hp, h) = await makeHabit(const [1, 3, 5]);
      await hp.checkInOnDay(h, plannedDayBack(h, 0));
      await hp.checkInOnDay(h, plannedDayBack(h, 2));
      await hp.checkInOnDay(h, plannedDayBack(h, 3));
      expect(hp.currentStreak(h), 1, reason: 'back:0 已打，back:1 缺 → 只计 1');
      expect(hp.longestStreak(h), 2, reason: 'back:2 + back:3 连续两个计划日');
    });

    test('计划外休息日打卡：中性，不打断也不增加', () async {
      final (hp, h) = await makeHabit(const [1, 3, 5]);
      await hp.checkInOnDay(h, plannedDayBack(h, 0));
      await hp.checkInOnDay(h, plannedDayBack(h, 1));
      await hp.checkInOnDay(h, plannedDayBack(h, 2));
      await hp.checkInOnDay(h, nonPlannedDay(h));
      expect(hp.currentStreak(h), 3);
    });

    test('今天是计划日但尚未打卡：不算断（当天空缺容忍）', () async {
      final (hp, h) = await makeHabit(const [1, 2, 3, 4, 5, 6, 7]);
      // 昨天、前天都打卡，今天未打 → current=2。
      final now = DateTime.now();
      await hp.checkInOnDay(h, now.subtract(const Duration(days: 1)));
      await hp.checkInOnDay(h, now.subtract(const Duration(days: 2)));
      expect(hp.currentStreak(h), 2);
    });

    test('weekdays 为空（每天习惯）：维持自然日口径', () async {
      final (hp, h) = await makeHabit(const []);
      final now = DateTime.now();
      await hp.checkInOnDay(h, now);
      await hp.checkInOnDay(h, now.subtract(const Duration(days: 1)));
      await hp.checkInOnDay(h, now.subtract(const Duration(days: 2)));
      expect(hp.currentStreak(h), 3);
      expect(hp.longestStreak(h), 3);
    });
  });

  group('F-7 重复默认提醒时刻统一 07:00', () {
    test('快速录入「每天」无时刻 → repeatMinute = kDefaultRepeatMinute（07:00）', () {
      final r = TaskParser.parse('每天喝水', now: DateTime(2026, 9, 12, 10));
      expect(r.repeatMinute, kDefaultRepeatMinute);
      expect(r.repeatMinute, 7 * 60, reason: '与编辑弹层共用同一常量，两条创建路径一致');
    });
  });

  group('F-8 fromJson 容错与 interval 锚点自愈', () {
    test('repeatUntil 非法串 → 清空（视为无限循环），不再被 1970 判为已结束', () {
      final t = Task.fromJson({
        'id': '501',
        'title': 'X',
        'repeat': 'daily',
        'repeatMinute': 420,
        'repeatUntil': 'not-a-date',
      });
      expect(t.repeatUntil, isNull);
      expect(t.isRepeatEnded(DateTime(2026, 9, 12)), isFalse);
    });

    test('repeatUntil 合法串 → 原样保留', () {
      final t = Task.fromJson({
        'id': '502',
        'title': 'X',
        'repeat': 'daily',
        'repeatMinute': 420,
        'repeatUntil': '2026-12-31',
      });
      expect(t.repeatUntil, '2026-12-31');
      expect(t.isRepeatEnded(DateTime(2026, 9, 12)), isFalse);
      expect(t.isRepeatEnded(DateTime(2027, 1, 1)), isTrue);
    });

    test('interval 任务缺 repeatAnchor：restoreFromJson 自愈为今天并可循环', () async {
      final p = TaskProvider();
      await p.restoreFromJson(jsonEncode({
        'version': 2,
        'tasks': [
          {
            'id': '503',
            'title': 'interval-no-anchor',
            'repeat': 'interval',
            'repeatInterval': 2,
            'repeatMinute': 420,
            // 注意：不带 repeatAnchor
          },
        ],
        'trash': [],
        'notifications_enabled': false,
      }));
      final t = p.byId('503')!;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      expect(t.repeatAnchor, isNotNull, reason: '缺锚点必须在恢复时自愈，不得静默变哑循环');
      expect(t.repeatsOn(today), isTrue, reason: '自愈后今天（锚点日）是循环日');
      expect(t.repeatsOn(today.add(const Duration(days: 2))), isTrue);
      expect(t.repeatsOn(today.add(const Duration(days: 1))), isFalse);
    });
  });

  group('F-10 iCal 导入部分保留计数', () {
    String icsOf(String rrule) => [
          'BEGIN:VCALENDAR',
          'VERSION:2.0',
          'BEGIN:VTODO',
          'UID:9001@youtiao',
          'SUMMARY:RRULE-TEST',
          'DTSTART:20260901T090000',
          'RRULE:$rrule',
          'END:VTODO',
          'END:VCALENDAR',
        ].join('\r\n');

    test('FREQ=WEEKLY;INTERVAL=2 → 映射为 weekly，但计入 partialRepeat', () {
      final r = parseIcs(icsOf('FREQ=WEEKLY;INTERVAL=2;BYDAY=MO'));
      expect(r.tasks.length, 1);
      expect(r.tasks.first.repeat, RepeatType.weekly);
      expect(r.partialRepeat, 1, reason: '双周间隔未被保留，必须计数提示');
      expect(r.simplifiedRepeat, 0);
    });

    test('普通 FREQ=WEEKLY;BYDAY=MO → 完整映射，partialRepeat=0', () {
      final r = parseIcs(icsOf('FREQ=WEEKLY;BYDAY=MO'));
      expect(r.tasks.first.repeat, RepeatType.weekly);
      expect(r.partialRepeat, 0);
    });

    test('FREQ=DAILY;BYDAY=MO,WE → 映射为 daily，但计入 partialRepeat', () {
      final r = parseIcs(icsOf('FREQ=DAILY;BYDAY=MO,WE'));
      expect(r.tasks.first.repeat, RepeatType.daily);
      expect(r.partialRepeat, 1);
    });

    test('FREQ=YEARLY → 降级一次性，计入 simplifiedRepeat', () {
      final r = parseIcs(icsOf('FREQ=YEARLY'));
      expect(r.tasks.first.repeat, RepeatType.none);
      expect(r.simplifiedRepeat, 1);
      expect(r.report, contains('复杂重复已简化'));
    });
  });

  group('F-11 大间隔重复任务的扫描窗自适应', () {
    test('每隔 365 天：400 天窗凑不齐，自适应窗必须给出 8 个落点', () {
      final now = DateTime(2026, 9, 12, 10);
      final anchor = DateTime(2026, 9, 12);
      final t = _repeatTask('601',
          repeat: RepeatType.interval,
          interval: 365,
          repeatMinute: 8 * 60,
          anchor: anchor);
      final occ = NotificationService.repeatOccurrenceTimes(t, now: now);
      expect(occ.length, 8, reason: '窗口须抬到 count×interval+60 才能预挂满 8 槽');
      for (var i = 0; i < occ.length; i++) {
        final expected = anchor.add(Duration(days: 365 * (i + 1)));
        expect(occ[i].year, expected.year, reason: '落点 $i 应为锚点+${365 * (i + 1)} 天');
        expect(occ[i].month, expected.month);
        expect(occ[i].day, expected.day);
        expect(occ[i].hour, 8);
      }
    });

    test('daily 仍受 400 天窗约束（窗口不变）', () {
      final now = DateTime(2026, 9, 12, 10);
      final t = _repeatTask('602', repeatMinute: 8 * 60);
      final occ = NotificationService.repeatOccurrenceTimes(t, now: now);
      expect(occ.length, 8);
      // daily 第 8 个落点距今天 8 天。
      expect(occ.last.difference(DateTime(2026, 9, 12)).inDays, 8);
    });

    test('repeatUntil 临近时窗口内凑不满：返回可用落点且不抛', () {
      final now = DateTime(2026, 9, 12, 10);
      final t = _repeatTask('603', repeatMinute: 8 * 60);
      final json = t.toJson();
      json['repeatUntil'] = '2026-09-14';
      final limited = Task.fromJson(json);
      final occ = NotificationService.repeatOccurrenceTimes(limited, now: now);
      expect(occ.length, 2, reason: '9/13、9/14 两个落点，结束日后不再有');
    });
  });
}
