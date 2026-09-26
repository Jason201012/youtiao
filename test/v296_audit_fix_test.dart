import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/review.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/daily_briefing.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/schedule_advisor.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// v2.9.5 审计修复轮回归测试（《有条功能与操作审计报告（v2.9.5）》）。
///
/// 本文件只覆盖**可纯 Dart 断言**的行为；widget 层的改动（模板下拉 P2-1、
/// 撤销横幅定时器 P2-4、详情抑制说明渲染 P3-2、庆祝入口 P3-6/P3-8、分享卡
/// 预计时长 P3-12、懒首建保活 U2-1、48dp 命中区 / 彩色回归黑白 / Tooltip
/// 下沉 U3-4~U3-7 等）依据写在对应文件的注释里，不在此重复——需要
/// widget 绑定 + 真实文件 I/O 的用例容易在 FakeAsync 下挂死（v2.9.4 轮教训）。
///
/// 覆盖清单：
/// - P2-2 iCal 导出 DUE 与 DURATION 互斥（RFC 5545 §3.6.2）；
/// - P2-3 iCal 预估时长的 X- 扩展往返 + 标准 DURATION 导入 + `hasEstimate` 口径；
/// - P2-5 weeklyGoal 读侧夹取（与写侧共用 `clampWeeklyGoalTo` 单一真源）；
/// - P2-6 晚简报分母按 `shouldCheckInOn` 过滤（分子分母同源）；
/// - P2-7 习惯达标后撤掉在途「稍后提醒」（snooze 独立 8 号槽 id 不被落点覆盖）；
/// - P3-1 分形态截止口径：`dueCompareKey`（纯日期按日比、带时刻按时刻比）
///   同时喂 `missedDue` 与排序（P3-1 实现曾被静态推演出「纯日期形态同日
///   恒超期」的回归，本组用例钉死两种形态 × 同日/跨天四象限）；
/// - P3-3 `taskTableCells` 数值列回 int（Excel 可求和），与 CSV 侧同源；
/// - P3-9 `HabitWeekStat.valueSum`（周报累计投入量）；
/// - P3-11 专注表列定义单一真源 + CSV 行 7 列对齐（钉死基线即存在的
///   「表头 7 列 / 数据行 6 字段」左移错位）。
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

/// 建一个习惯并回传**已落库的那一份**（`addHabit` 返回 void，按标题取回）。
Future<Habit> _addHabit(
  HabitProvider hp, {
  required String title,
  List<int> weekdays = const [],
  int weeklyGoal = 0,
  int? dailyTarget,
}) async {
  await hp.addHabit(
    title: title,
    emoji: '✅',
    colorValue: 0xFF0061A4,
    weekdays: weekdays,
    weeklyGoal: weeklyGoal,
    dailyTarget: dailyTarget,
  );
  return hp.habits.firstWhere((h) => h.title == title);
}

/// 测试用任务构造助手（`priority` / `category` 必填，在此给默认值）。
Task _task(
  String id, {
  String title = '任务',
  DateTime? dueDate,
  TaskStatus status = TaskStatus.todo,
  int? estimateMinutes,
  int focusSecTotal = 0,
}) =>
    Task(
      id: id,
      title: title,
      priority: Priority.medium,
      category: Category.life,
      dueDate: dueDate,
      status: status,
      estimateMinutes: estimateMinutes,
      focusSecTotal: focusSecTotal,
    );

/// 手工拼一个最小 VTODO（SUMMARY 必填，否则 `_blockToTask` 丢弃该块）。
String _vtodo(String body) => 'BEGIN:VCALENDAR\r\n'
    'VERSION:2.0\r\n'
    'BEGIN:VTODO\r\n'
    'UID:t1@youtiao\r\n'
    '$body'
    'END:VTODO\r\n'
    'END:VCALENDAR\r\n';

void main() {
  setUp(_installMocks);
  setUp(() {
    // 内存后端是 static Map，用例之间会互相串数据，每个用例开始前清空一次。
    LocalDatabase.resetMemoryForTest();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
  });
  tearDown(() {
    HabitProvider.onHabitsChanged = null;
  });

  // ── P2-2 / P2-3：iCal 预估时长（DUE/DURATION 互斥 + X- 往返）──────
  group('P2-2/P2-3 iCal 预估时长', () {
    test('有 DUE + 预估 → 只写 X- 扩展属性，绝不写 DURATION（RFC 5545 §3.6.2）',
        () {
      final t = _task('1',
          title: '截止今天 18:00',
          dueDate: DateTime(2026, 3, 10, 18, 0),
          estimateMinutes: 45);
      final ics = exportIcs([t]);
      expect(ics, contains('DUE:'));
      expect(ics, contains('X-YOUTIAO-ESTIMATE-MINUTES:45'),
          reason: '有 DUE 时预估走 X- 扩展属性往返，信息不丢');
      expect(ics.contains('DURATION:'), isFalse,
          reason: 'DUE 与 DURATION 同现会被 Google 日历等严格解析器整条丢弃');
    });

    test('无 DUE + 预估 → 标准 DURATION + X- 扩展都写', () {
      final t = _task('2', title: '无截止', estimateMinutes: 45);
      final ics = exportIcs([t]);
      expect(ics, contains('DURATION:PT45M'));
      expect(ics, contains('X-YOUTIAO-ESTIMATE-MINUTES:45'));
    });

    test('estimateMinutes: 0 → 两者都不写（hasEstimate 口径，不产 PT0M）', () {
      final t = _task('3', title: '零预估', estimateMinutes: 0);
      final ics = exportIcs([t]);
      expect(ics.contains('DURATION:'), isFalse);
      expect(ics.contains('X-YOUTIAO-ESTIMATE-MINUTES'), isFalse);
    });

    test('导入：X- 扩展属性 → estimateMinutes', () {
      final r = parseIcs(_vtodo('SUMMARY:带X预估\r\n'
          'DUE:20260310T180000\r\n'
          'X-YOUTIAO-ESTIMATE-MINUTES:30\r\n'));
      expect(r.tasks.single.estimateMinutes, 30);
    });

    test('导入：第三方标准 DURATION → estimateMinutes', () {
      final r = parseIcs(_vtodo('SUMMARY:第三方预估\r\n'
          'DURATION:PT45M\r\n'));
      expect(r.tasks.single.estimateMinutes, 45);
    });

    test('导入：无任何时长属性 → estimateMinutes 保持 null', () {
      final r = parseIcs(_vtodo('SUMMARY:无预估\r\n'));
      expect(r.tasks.single.estimateMinutes, isNull);
    });
  });

  // ── P2-5 / P3-7：weeklyGoal 读侧口径 ───────────────────────────
  // P3-7（v2.9.6 审计）：本 group 原断言「fromJson 即夹取」——该行为恰被
  // v2.9.6 审计判为缺陷：读侧夹取的收敛值会随下一次落盘写回库（`7 → 3`
  // 不可恢复）。现改为「模型保留原值（保真）+ effectiveWeeklyGoal 按计划天数
  // 夹取（展示/统计消费口径）」，写侧（addHabit/updateHabit）夹取不变。
  group('P2-5/P3-7 weeklyGoal：读侧保真，effectiveWeeklyGoal 按计划天数夹取', () {
    test('老数据 weeklyGoal=20 + 每周一三五 → 裸字段保真 20，生效值 3', () {
      final h = Habit.fromJson({
        'id': 'h1',
        'title': '脏数据习惯',
        'createdAt': '2026-01-01T00:00:00.000',
        'weekdays': [1, 3, 5],
        'weeklyGoal': 20,
      });
      expect(h.weeklyGoal, 20,
          reason: 'P3-7：fromJson 不再夹取，原值保留（ toJson 原样落库）');
      expect(h.effectiveWeeklyGoal, 3,
          reason: '展示/统计消费走生效值（clampWeeklyGoalTo 单一真源）');
      expect(h.toJson()['weeklyGoal'], 20,
          reason: '落盘仍是原值——用户改回「每天」即可恢复原目标');
    });

    test('weeklyGoal=20 + 每天（weekdays 空）→ 生效值 7', () {
      final h = Habit.fromJson({
        'id': 'h2',
        'title': '每天习惯',
        'createdAt': '2026-01-01T00:00:00.000',
        'weeklyGoal': 20,
      });
      expect(h.weeklyGoal, 20);
      expect(h.effectiveWeeklyGoal, 7);
    });

    test('weeklyGoal=0（不启用）→ 保持 0', () {
      final h = Habit.fromJson({
        'id': 'h3',
        'title': '不启用',
        'createdAt': '2026-01-01T00:00:00.000',
        'weeklyGoal': 0,
      });
      expect(h.weeklyGoal, 0);
      expect(h.effectiveWeeklyGoal, 0);
    });

    test('写侧对称：addHabit(weeklyGoal: 20, 一三五) → 落库 3', () async {
      final hp = await newHabitProvider();
      final h = await _addHabit(hp,
          title: '写侧夹取', weekdays: const [1, 3, 5], weeklyGoal: 20);
      expect(h.weeklyGoal, 3);
    });
  });

  // ── P2-6：晚简报分母 ──────────────────────────────────────────
  group('P2-6 晚简报分母按 shouldCheckInOn 过滤', () {
    test('周三-only 习惯：周二 0/0（—），周三 0/1（0%），周三达标 1/1（100%）',
        () async {
      final hp = await newHabitProvider();
      final h = await _addHabit(hp,
          title: '周三习惯', weekdays: const [3], dailyTarget: 1);
      final task = await buildWith(const []);
      final focus = FocusProvider();
      // 2026-03-10 是周二、2026-03-11 是周三（与星期几无关的固定日期钉死）。
      final tue = DateTime(2026, 3, 10);
      final wed = DateTime(2026, 3, 11);

      final bTue = buildEveningBriefFromState(task, focus, hp, forDay: tue);
      expect(bTue.lines.where((l) => l.startsWith('习惯达成')).single,
          '习惯达成：0 / 0（—）',
          reason: '休息日不进分母——旧实现恒给「0/1 · 未完成」的暗示');

      final bWed = buildEveningBriefFromState(task, focus, hp, forDay: wed);
      expect(bWed.lines.where((l) => l.startsWith('习惯达成')).single,
          '习惯达成：0 / 1（0%）');

      await hp.setCheckInValue(h, wed, 1);
      final bWedDone =
          buildEveningBriefFromState(task, focus, hp, forDay: wed);
      expect(bWedDone.lines.where((l) => l.startsWith('习惯达成')).single,
          '习惯达成：1 / 1（100%）');
    });
  });

  // ── P2-7：达标撤在途 snooze ───────────────────────────────────
  group('P2-7 达标后撤掉在途「稍后提醒」', () {
    test('snooze id 落在独立 8 号槽，与落点 0..7 槽位不重叠', () {
      for (final id in ['h1', 'habit-xyz', '42']) {
        final snooze = NotificationService.habitSnoozeNotifyIdOf(id);
        expect(snooze % 10, 8, reason: '8 号槽是 snooze 专属');
        for (var d = 0; d < 8; d++) {
          expect(snooze, isNot(NotificationService.habitNotifyIdOf(id, d)),
              reason: '落点重排（cancel 0..7）不得覆盖刚排的 snooze');
        }
      }
    });

    test('量化习惯未达标不清 snooze，达标后 cancel 精确命中 snooze id', () async {
      // 用记录型 handler 替换默认 mock，捕获通知插件调用。
      const ch = MethodChannel('dexterous.com/flutter/local_notifications');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
        calls.add(call);
        return null;
      });

      final hp = await newHabitProvider();
      final h = await _addHabit(hp, title: '量化撤snooze', dailyTarget: 2);
      // P2-6（v2.9.6 审计）：判据修正为「写入的是**今天**且今天达标」才撤在途
      // snooze——原用例写入的是历史日期（2026-03-10），在旧判据下会误撤今天
      // 的在途提醒。改用「今天」写入（weekdays 空 = 每天计划，与星期几无关）。
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // 先记 1/2：未达标 → 稍后提醒仍该响，不得 cancel。
      await hp.setCheckInValue(h, today, 1);
      expect(calls.where((c) => c.method == 'cancel'), isEmpty,
          reason: '未达标只是「先记 1/8」，在途 snooze 不清');

      // 记满 2/2：达标 → cancel 精确命中 snooze 的 8 号槽 id。
      await hp.setCheckInValue(h, today, 2);
      final cancelIds = calls
          .where((c) => c.method == 'cancel')
          .map((c) => c.arguments is Map
              ? (c.arguments as Map)['id']
              : c.arguments)
          .whereType<int>()
          .toSet();
      expect(cancelIds, contains(NotificationService.habitSnoozeNotifyIdOf(h.id)),
          reason: '任务侧「完成」会撤 snooze，习惯侧必须对称');
    });

    test('P2-6（v2.9.6 审计）：补卡历史日达标不得撤掉今天的在途 snooze',
        () async {
      const ch = MethodChannel('dexterous.com/flutter/local_notifications');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
        calls.add(call);
        return null;
      });

      final hp = await newHabitProvider();
      final h = await _addHabit(hp, title: '补卡不撤snooze', dailyTarget: 2);
      final now = DateTime.now();
      final yesterday = DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 1));

      // 补卡**昨天**并顶到达标：与今天 21:10 的在途 snooze 无关，不得 cancel。
      await hp.setCheckInValue(h, yesterday, 2);
      final snoozeId = NotificationService.habitSnoozeNotifyIdOf(h.id);
      final cancelCalls = calls
          .where((c) => c.method == 'cancel')
          .map((c) => c.arguments is Map
              ? (c.arguments as Map)['id']
              : c.arguments)
          .whereType<int>()
          .toSet();
      expect(cancelCalls, isNot(contains(snoozeId)),
          reason: '今天实际 0/8，21:10 的「稍后提醒」必须照常响——'
              '旧判据 isTargetMetOn(habit, day) 会把它静默撤掉');
    });
  });

  // ── P3-1：分形态截止口径 ──────────────────────────────────────
  group('P3-1 截止分形态口径（dueCompareKey 单一真源）', () {
    test('dueCompareKey：00:00 / 23:59 → date-only；带时刻原样', () {
      expect(dueCompareKey(DateTime(2026, 3, 10)), DateTime(2026, 3, 10));
      expect(dueCompareKey(DateTime(2026, 3, 10, 23, 59)),
          DateTime(2026, 3, 10));
      expect(dueCompareKey(DateTime(2026, 3, 10, 10, 20, 30)),
          DateTime(2026, 3, 10, 10, 20, 30));
    });

    test('纯日期形态：当天完成不算超期，跨天才算（v2.9.4 P2-5 结论保留）', () {
      final now = DateTime(2026, 3, 10, 10, 0);
      final sameDay = buildScheduleAdvice(
          [_task('1', dueDate: DateTime(2026, 3, 10))],
          now: now);
      expect(sameDay.items.single.missedDue, isFalse,
          reason: 'end 10:30 与 date-only 00:00 同日——按「日」比不按「时刻」比');
      final nextDay = buildScheduleAdvice(
          [_task('2', dueDate: DateTime(2026, 3, 9))],
          now: now);
      expect(nextDay.items.single.missedDue, isTrue);
    });

    test('带时刻形态：晚于截止时刻才提示（v2.9.4 一刀切的同日假阴性修复）', () {
      final late = buildScheduleAdvice(
          [_task('1', dueDate: DateTime(2026, 3, 10, 10, 20))],
          now: DateTime(2026, 3, 10, 10, 0)); // end 10:30 > 10:20
      expect(late.items.single.missedDue, isTrue);
      final early = buildScheduleAdvice(
          [_task('2', dueDate: DateTime(2026, 3, 10, 10, 20))],
          now: DateTime(2026, 3, 10, 9, 40)); // end 10:10 < 10:20
      expect(early.items.single.missedDue, isFalse);
    });

    test('排序与超期同键：同日 00:00 与 23:59 同键（语义都只是「当天截止」）',
        () {
      final a = _task('z', dueDate: DateTime(2026, 3, 10)); // 00:00 纯日期
      final b = _task('a', dueDate: DateTime(2026, 3, 10, 23, 59)); // 纯日期
      // 两者无预估（同 30 分钟兜底）、同优先级 → 只剩 id 比较。
      // 旧实现按完整时刻比较会让 00:00 恒排前；归一后两者同键，由 id 决定。
      // （带具体时刻的截止保持按时刻排序——归一只针对纯日期形态。）
      expect(compareForSchedule(a, b), greaterThan(0));
      expect(compareForSchedule(b, a), lessThan(0));
    });
  });

  // ── P3-3：任务表单元格真源 ────────────────────────────────────
  group('P3-3 taskTableCells 数值列回 int（Excel 可求和）', () {
    test('预计时长 / 累计专注列回 int；无值回空串', () {
      final t = _task('1', estimateMinutes: 45, focusSecTotal: 3000);
      final cells = TaskProvider.taskTableCells(t, deleted: false);
      expect(cells, hasLength(TaskProvider.taskTableHeaders.length),
          reason: '单元格数必须与表头逐列对齐（防列错位回归）');
      expect(cells[13], 45);
      expect(cells[13], isA<int>(), reason: 'Excel 侧据此写 IntCellValue');
      expect(cells[14], 50, reason: 'focusSecTotal 3000 → 50 分钟（四舍五入）');
      expect(cells[14], isA<int>());

      final empty = TaskProvider.taskTableCells(_task('2'), deleted: false);
      expect(empty[13], '');
      expect(empty[14], '');
    });

    test('CSV 侧 taskTableValues 与真源逐项 toString 一致', () {
      final t = _task('1', estimateMinutes: 45, focusSecTotal: 3000);
      final cells = TaskProvider.taskTableCells(t, deleted: true);
      final values = TaskProvider.taskTableValues(t, deleted: true);
      expect(values, cells.map((v) => v.toString()).toList());
    });
  });

  // ── P3-9：周报累计投入量 ──────────────────────────────────────
  group('P3-9 HabitWeekStat.valueSum', () {
    test('默认 0（布尔习惯不传也可构造），显式传值可带回', () {
      final h = Habit(
        id: 'h1',
        title: '量化',
        dailyTarget: 8,
        createdAt: DateTime(2026, 1, 1),
      );
      expect(
        HabitWeekStat(habit: h, expected: 7, done: 3, rate: 3 / 7).valueSum,
        0,
      );
      expect(
        HabitWeekStat(habit: h, expected: 7, done: 3, rate: 3 / 7, valueSum: 42)
            .valueSum,
        42,
      );
    });
  });

  // ── P3-11：专注表单一真源 + CSV 行对齐 ─────────────────────────
  group('P3-11 专注表列定义单一真源', () {
    test('focusExportCells 与表头逐列对齐：计划 int / 实际 double / 首列日期',
        () {
      final p = FocusProvider();
      p.addSession(FocusSession(
        id: 's1',
        taskTitle: '写作',
        plannedSec: 1500,
        durationSec: 1500,
        completed: true,
        startedAt: DateTime(2026, 3, 10, 10, 0),
        endedAt: DateTime(2026, 3, 10, 10, 25),
      ));
      final cells = p.focusExportCells(p.sessions.single);
      expect(cells, hasLength(FocusProvider.focusExportHeaders.length));
      expect(cells[0], '2026-03-10');
      expect(cells[3], 25);
      expect(cells[3], isA<int>());
      expect(cells[4], 25.0);
      expect(cells[4], isA<double>(),
          reason: 'CSV 侧统一 toStringAsFixed(1)，Excel 写原生数值');
      expect(cells[5], '是');
    });

    test('CSV 数据行 7 列与表头对齐（钉死基线缺「日期」列的左移错位）', () {
      final p = FocusProvider();
      p.addSession(FocusSession(
        id: 's1',
        plannedSec: 1500,
        durationSec: 1500,
        completed: false,
        startedAt: DateTime(2026, 3, 10, 10, 0),
        endedAt: DateTime(2026, 3, 10, 10, 25),
      ));
      final csv = p.exportCsv();
      final header = csv.split('\n').first;
      expect(header, FocusProvider.focusExportHeaders.join(','));
      // taskTitle 为 null 且数值不含逗号 → 可安全按逗号切分。
      final fields = csv.split('\n')[1].split(',');
      expect(fields, hasLength(FocusProvider.focusExportHeaders.length),
          reason: '基线上表头 7 列、数据行只有 6 字段，整行左移一列');
      expect(fields.first, '"2026-03-10"',
          reason: '首字段必须是「日期」列');
    });
  });
}
