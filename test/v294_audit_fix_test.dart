import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/schedule_advisor.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// v2.9.3 审计修复轮回归测试（《有条功能与操作审计报告（v2.9.3）》）。
///
/// - P2-1 量化习惯「打卡提醒抑制」改用达标口径（isTargetMetToday），且
///   updateHabit 的 reminderChanged 增补 dailyTarget 变化；
/// - P2-2 通知打卡确认按实际进度分文案（量化未达标不谎报「已打卡 ✓」）；
/// - P2-3 「可能高估 / 低估」偏差：重复任务不比较（累计专注 vs 单次预估）；
/// - P2-4 任务模板携带 estimateMinutes（模型 / 两个 JSON / 套用）；
/// - P2-5 Excel 习惯表 / 打卡表与 CSV 共用列定义（单一真源）；
/// - P3-2 概览热力图按「达标习惯数」聚合（metCountsByDay）；
/// - P3-3 restoreFromJson 补触发 onHabitsChanged；
/// - P3-4 写入侧 clamp（dailyTarget 1..9999 / weeklyGoal 0..14）；
/// - P3-6 删除零消费的 weeklyValueRatio（量化叙事接入 UI 后只剩两个 API）。
void _installMocks({
  void Function(MethodCall call)? onCall,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async {
    onCall?.call(call);
    return null;
  });
}

/// 新建一个已 load 的 HabitProvider（内存库由 setUp 重置）。
Future<HabitProvider> newHabitProvider() async {
  final hp = HabitProvider();
  await hp.load();
  return hp;
}

/// 用受控列表构造 TaskProvider（绕过 load()，避免启动午夜守护定时器）。
/// 与 v290_audit_fix_test 的 buildWith 同款。
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

/// 今天往前第 [i] 天的 date-only。
DateTime daysAgo(int i) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day).subtract(Duration(days: i));
}

/// 轮询等待异步调度链落盘（setCheckInValue → _rescheduleReminder 是
/// fire-and-forget 的 Future，需要真实的宏任务排水）。
Future<void> pumpUntil(bool Function() cond) async {
  for (var i = 0; i < 100 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Task mkTask(
  String id, {
  String? title,
  int? estimate,
  int focusSecTotal = 0,
  RepeatType repeat = RepeatType.none,
}) =>
    Task(
      id: id,
      title: title ?? 'T$id',
      priority: Priority.medium,
      category: Category.work,
      repeat: repeat,
      estimateMinutes: estimate,
      focusSecTotal: focusSecTotal,
    );

void main() {
  setUp(() {
    _installMocks();
    LocalDatabase.resetMemoryForTest();
  });

  // ===================== P2-1 提醒抑制口径 =====================

  group('P2-1 量化习惯提醒抑制改「达标」口径', () {
    test('部分打卡（1/8）不再抑制当天提醒；达标（8/8）才跳过今日落点',
        () async {
      // 记录 zonedSchedule 的落点（Map 键见插件 tz_datetime_mapper.toMap）。
      // 只留 date-only：断言比较的是「今天 / 明天有没有落点」，与具体时钟无关。
      final scheduledDates = <DateTime>{};
      _installMocks(onCall: (call) {
        if (call.method == 'zonedSchedule' && call.arguments is Map) {
          final args = call.arguments as Map;
          final iso = args['scheduledDateTime'] as String?;
          if (iso != null) {
            final dt = DateTime.parse(iso);
            scheduledDates.add(DateTime(dt.year, dt.month, dt.day));
          }
        }
      });

      // 提醒时刻取「UTC 墙钟 + 2 分钟」：调度内核 (_loc ?? tz.UTC) 按 UTC 墙钟
      // 展开落点，因此今天/明天的判定也按 UTC 日期做，避免宿主时区干扰。
      final nowUtc = DateTime.now().toUtc();
      var minute = nowUtc.hour * 60 + nowUtc.minute + 2;
      // 23:58/23:59 边缘：+2 分钟跨过 UTC 午夜 → 今天该时刻已过，今日落点断言降级。
      final bool todaySlotInFuture = minute < 1440;
      if (!todaySlotInFuture) minute -= 1440;
      final todayUtc = DateTime(nowUtc.year, nowUtc.month, nowUtc.day);
      final tomorrowUtc = todayUtc.add(const Duration(days: 1));

      final hp = await newHabitProvider();
      await hp.addHabit(
        title: '喝水',
        emoji: '💧',
        colorValue: 1,
        weekdays: const [],
        dailyTarget: 8,
        reminderMinute: minute,
      );
      final h = hp.habits.first;

      // 撤掉已挂闹钟（清空 armed 签名），随后每次写盘都会触发真正的重排。
      await NotificationService.instance.cancelHabitReminder(h.id);

      // ① 部分打卡：1/8 未达标 → 当天提醒必须仍在（修复前 isCheckedToday=true
      //    会把今日落点吞掉，且 updateHabit 改目标也救不回来）。
      scheduledDates.clear();
      await hp.setCheckInValue(h, DateTime.now(), 1);
      await pumpUntil(() => scheduledDates.isNotEmpty);
      expect(hp.todayValue(h), 1);
      expect(hp.isTargetMetToday(h), isFalse);
      if (todaySlotInFuture) {
        expect(scheduledDates, contains(todayUtc),
            reason: 'P2-1：部分打卡（1/8）不得抑制当天提醒');
      }
      expect(scheduledDates, contains(tomorrowUtc));

      // ② 达标：8/8 → 今日落点被跳过（达标口径的另一半，与旧「有记录即抑制」
      //    在布尔习惯上等价，量化习惯上以「达标」为准）。
      scheduledDates.clear();
      await hp.setCheckInValue(h, DateTime.now(), 8);
      await pumpUntil(() => scheduledDates.isNotEmpty);
      expect(hp.isTargetMetToday(h), isTrue);
      expect(scheduledDates, isNot(contains(todayUtc)));
      expect(scheduledDates, contains(tomorrowUtc));
    });

    test('updateHabit 改 dailyTarget 触发重排：门槛变化当天提醒随之增减',
        () async {
      // 同上：只留 date-only 再比较。
      final scheduledDates = <DateTime>{};
      _installMocks(onCall: (call) {
        if (call.method == 'zonedSchedule' && call.arguments is Map) {
          final args = call.arguments as Map;
          final iso = args['scheduledDateTime'] as String?;
          if (iso != null) {
            final dt = DateTime.parse(iso);
            scheduledDates.add(DateTime(dt.year, dt.month, dt.day));
          }
        }
      });

      final nowUtc = DateTime.now().toUtc();
      var minute = nowUtc.hour * 60 + nowUtc.minute + 2;
      final bool todaySlotInFuture = minute < 1440;
      if (!todaySlotInFuture) minute -= 1440;
      final todayUtc = DateTime(nowUtc.year, nowUtc.month, nowUtc.day);
      final tomorrowUtc = todayUtc.add(const Duration(days: 1));

      final hp = await newHabitProvider();
      await hp.addHabit(
        title: '喝水',
        emoji: '💧',
        colorValue: 1,
        weekdays: const [],
        dailyTarget: 8,
        reminderMinute: minute,
      );
      final h = hp.habits.first;
      await hp.setCheckInValue(h, DateTime.now(), 8); // 已记 8，达标（目标 8）

      // ① 目标 8 → 3：已记 8 由达标变超额达标？8>=3 仍达标 → 今日跳过。
      scheduledDates.clear();
      await hp.updateHabit(hp.byId(h.id)!, dailyTarget: 3);
      await pumpUntil(() => scheduledDates.isNotEmpty);
      expect(hp.byId(h.id)!.dailyTarget, 3);
      expect(scheduledDates, isNot(contains(todayUtc)));

      // ② 目标 3 → 12：已记 8 < 12 变未达标 → 当天提醒恢复。
      //    （修复前 reminderChanged 不含 dailyTarget：完全不会重排，当日提醒
      //    永远回不来；修复后按新门槛重排并恢复今日落点。）
      scheduledDates.clear();
      await hp.updateHabit(hp.byId(h.id)!, dailyTarget: 12);
      await pumpUntil(() => scheduledDates.isNotEmpty);
      expect(hp.byId(h.id)!.dailyTarget, 12);
      if (todaySlotInFuture) {
        expect(scheduledDates, contains(todayUtc),
            reason: 'P2-1：门槛调高变未达标后，当天提醒应恢复');
      }
      expect(scheduledDates, contains(tomorrowUtc));
    });
  });

  // ===================== P2-2 通知确认文案 =====================

  group('P2-2 通知打卡确认按实际进度分文案', () {
    test('量化未达标显示「已记 x/y」，达标 / 布尔保持「已打卡 ✓」', () async {
      final shown = <Map<String, dynamic>>[];
      _installMocks(onCall: (call) {
        if (call.method == 'show' && call.arguments is Map) {
          shown.add(Map<String, dynamic>.from(call.arguments as Map));
        }
      });

      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水', emoji: '💧', colorValue: 1, weekdays: const [], dailyTarget: 8);
      final h = hp.habits.first;

      // 未达标：不得谎报「已打卡 ✓」（修复前无论进度只回「已打卡 ✓」）。
      await NotificationService.instance.showHabitCheckedConfirm(h,
          value: 3, target: 8);
      expect(shown.last['title'], '已记 3/8');
      expect(shown.last['body'], contains('未达标'));

      // 已达标：维持原确认文案。
      await NotificationService.instance.showHabitCheckedConfirm(h,
          value: 8, target: 8);
      expect(shown.last['title'], '已打卡 ✓');
      expect(shown.last['body'], isNot(contains('未达标')));

      // 不带进度参数（布尔习惯路径）：原文案不变。
      await NotificationService.instance.showHabitCheckedConfirm(h);
      expect(shown.last['title'], '已打卡 ✓');
    });
  });

  // ===================== P2-3 偏差口径 =====================

  group('P2-3 重复任务不展示「高估 / 低估」偏差', () {
    test('重复任务 biasLabel 为 null；一次性任务照常比较', () {
      final advice = buildScheduleAdvice([
        // 重复任务：预计 5 分钟，历史累计专注 60 分钟 → 累计 vs 单次不可比。
        mkTask('r', estimate: 5, focusSecTotal: 3600, repeat: RepeatType.daily),
        // 一次性任务：预计 30 分钟，已专注 60 分钟 → 单次超预估 30 分钟。
        mkTask('s', estimate: 30, focusSecTotal: 3600),
      ]);

      final rowR = advice.items.firstWhere((i) => i.task.id == 'r');
      final rowS = advice.items.firstWhere((i) => i.task.id == 's');
      expect(rowR.biasLabel, isNull,
          reason: 'P2-3：重复任务累计专注 vs 单次预估必然「低估」，不得展示');
      expect(rowS.biasLabel, '可能低估：已超预估 30 分钟');
    });

    test('重复任务无偏差文案时不误报「与预估接近」', () {
      // 边界：重复任务即使进度接近预估（±20% 内）也不给任何偏差文案。
      final advice = buildScheduleAdvice([
        mkTask('r2', estimate: 30, focusSecTotal: 1800, repeat: RepeatType.daily),
      ]);
      expect(advice.items.single.biasLabel, isNull);
    });
  });

  // ===================== P2-4 模板携带预估时长 =====================

  group('P2-4 任务模板携带 estimateMinutes', () {
    test('fromTask → toJson → fromJson 往返保留预估', () {
      final t = mkTask('1', estimate: 45);
      final item = TemplateItem.fromTask(t);
      expect(item.estimateMinutes, 45);
      final back = TemplateItem.fromJson(item.toJson());
      expect(back.estimateMinutes, 45);
    });

    test('旧模板 JSON 缺键 / 越界值 → null（零迁移 + 不可信输入兜底）', () {
      final item = TemplateItem.fromTask(mkTask('1', estimate: 45));
      final missing = item.toJson()..remove('estimateMinutes');
      expect(TemplateItem.fromJson(missing).estimateMinutes, isNull);

      final bad = TemplateItem.fromJson(<String, dynamic>{
        'title': 'x',
        'estimateMinutes': 0, // 0 / 负数 / 超 43200 视为未设
      });
      expect(bad.estimateMinutes, isNull);
      final over = TemplateItem.fromJson(<String, dynamic>{
        'title': 'x',
        'estimateMinutes': 30 * 24 * 60 + 1,
      });
      expect(over.estimateMinutes, isNull);
    });

    test('applyTemplateItems 套用后任务带预估（不再退回 30 分钟兜底）', () async {
      _installMocks();
      final provider = await buildWith([]);
      final created = applyTemplateItems(provider, [
        TemplateItem('写周报', Category.work, Priority.high, 1,
            estimateMinutes: 25),
      ]);
      expect(created, 1);
      final t = provider.tasks.firstWhere((t) => t.title == '写周报');
      expect(t.estimateMinutes, 25);
      expect(t.hasEstimate, isTrue);
    });
  });

  // ===================== P2-5 导出列单一真源 =====================

  group('P2-5 CSV / Excel 共用习惯表与打卡表列定义', () {
    test('habitExportCells / checkInExportCells 与表头逐列对齐', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
        title: '喝水',
        emoji: '💧',
        colorValue: 1,
        weekdays: const [],
        dailyTarget: 8,
        graceDays: 2,
      );
      final h = hp.habits.first;
      await hp.setCheckInValue(h, daysAgo(0), 8);

      expect(hp.habitExportCells(h).length,
          HabitProvider.habitExportHeaders.length);
      final c = hp.checkIns.first;
      expect(
          hp.checkInExportCells(c, name: '喝水').length,
          HabitProvider.checkInExportHeaders.length);
    });

    test('CSV 量化列齐全且格式与旧版逐字节兼容（每日目标带引号）', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
        title: '喝水',
        emoji: '💧',
        colorValue: 1,
        weekdays: const [],
        dailyTarget: 8,
        graceDays: 2,
        reminderMinute: 8 * 60,
      );
      final h = hp.habits.first;
      await hp.setCheckInValue(h, daysAgo(0), 8);

      final csv = hp.exportCsv();
      final lines = csv.trim().split('\n');
      expect(lines.first,
          '习惯,表情,创建时间,当前连续(天),最长连续(天),累计达标(天),提醒,每日目标,宽限日(天),是否归档');
      // 习惯行：每日目标 "8"（带引号，与 v2.9.3 既有格式一致）、宽限日 2。
      expect(lines[1], contains(',"8",2,"否"'));
      // lines[2] 是两表之间的空行；打卡表表头与「累计量」列在其后。
      expect(lines[2].trim(), isEmpty);
      expect(lines[3], '习惯,打卡日期,累计量');
      expect(lines[4], contains(',8'));
    });
  });

  // ===================== P3-2 概览热力图达标口径 =====================

  group('P3-2 概览热力图按达标习惯数聚合', () {
    test('metCountsByDay 只计达标记录（1/8 不计数，8/8 计数）', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水', emoji: '💧', colorValue: 1, weekdays: const [], dailyTarget: 8);
      final h = hp.habits.first;

      // 昨天只喝 1 杯：旧口径（有记录）计数 1，新口径（达标）计数 0。
      await hp.setCheckInValue(h, daysAgo(1), 1);
      final part = hp.metCountsByDay(7);
      expect(part.containsKey(daysAgo(1)), isFalse,
          reason: 'P3-2：1/8 未达标日不得与达标日同色');
      // P3-10（v2.9.4 审计）：旧口径 API checkInCountsByDay 已删除（死代码），
      // 改用 public 单一真源校验「确实存在记录」这一前提本身。
      expect(hp.checkInValueOn(h, daysAgo(1)), 1,
          reason: '前提：1/8 当天确有记录，只是未达标');

      // 喝满 8 杯：新口径计数 1。
      await hp.setCheckInValue(h, daysAgo(0), 8);
      final full = hp.metCountsByDay(7);
      expect(full[daysAgo(0)], 1);

      // 布尔习惯：达标 = 有记录，两口径逐位一致（防回归）。
      await hp.addHabit(title: '跑', emoji: '🏃', colorValue: 1, weekdays: const []);
      final b = hp.habits[1];
      await hp.setCheckInValue(b, daysAgo(2), 1);
      expect(hp.metCountsByDay(7)[daysAgo(2)], 1);
      // P3-10：旧 checkInCountsByDay 已删；布尔习惯「有记录 == 达标」，
      // 用 isCheckedOn 锁定这条等价前提。
      expect(hp.isCheckedOn(b, daysAgo(2)), isTrue);
    });
  });

  // ===================== P3-3 恢复回调 =====================

  group('P3-3 restoreFromJson 补触发 onHabitsChanged', () {
    test('备份恢复后 23:00 挽留重排回调被触发', () async {
      final hp = await newHabitProvider();
      var called = 0;
      final prev = HabitProvider.onHabitsChanged;
      HabitProvider.onHabitsChanged = (_) => called++;
      addTearDown(() => HabitProvider.onHabitsChanged = prev);

      await hp.restoreFromJson(<String, dynamic>{
        'habits': <dynamic>[
          Habit(
            id: 'restore-1',
            title: '恢复的习惯',
            colorValue: 1,
            weekdays: const [],
            createdAt: DateTime(2026, 1, 1),
          ).toJson(),
        ],
        'check_ins': <dynamic>[],
      });
      expect(called, greaterThan(0), reason: 'P3-3：其他写入口均已触发，恢复不得遗漏');
    });
  });

  // ===================== P3-4 写入侧夹取 =====================

  group('P3-4 写入侧 clamp（与反序列化侧同区间）', () {
    test('addHabit / updateHabit 对 dailyTarget / weeklyGoal 夹取', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
        title: '喝水',
        emoji: '💧',
        colorValue: 1,
        weekdays: const [],
        dailyTarget: 99999,
        weeklyGoal: 99,
      );
      final h = hp.habits.first;
      expect(h.dailyTarget, 9999, reason: 'P3-4：写入侧上界 9999，避免重载被静默降级');
      // P3-10（v2.9.4 审计）：weeklyGoal 上界由写死 14 改为**联动计划天数**。
      // `weekdays: []` = 每天都做 = 计划 7 天，所以上界是 7 而非 14。
      // 旧断言写的 14 编码的是被审计报告点名的缺陷（目标不可达）。
      expect(h.weeklyGoal, 7, reason: 'P3-10：上界 = 计划天数（空 weekdays = 7 天）');

      await hp.updateHabit(h, dailyTarget: 50000, weeklyGoal: 50);
      final updated = hp.byId(h.id)!;
      expect(updated.dailyTarget, 9999);
      expect(updated.weeklyGoal, 7);

      // 正常值不受影响。
      await hp.updateHabit(updated, dailyTarget: 8, weeklyGoal: 5);
      expect(hp.byId(h.id)!.dailyTarget, 8);
      expect(hp.byId(h.id)!.weeklyGoal, 5);
    });

    test('P3-10：weeklyGoal 上界随 weekdays 收紧（每周一三五 → 3）', () async {
      // 这正是审计报告点名的病根：「每周 5 天」的习惯此前能设 14 次 → 目标不可达。
      // 详细的静态判据 / addHabit / updateHabit 同次改星期覆盖在
      // test/v295_audit_fix_test.dart 的 P3-10 组，这里只钉住 v294 原本断言的那个上界。
      final hp = await newHabitProvider();
      await hp.addHabit(
        title: '周一三五',
        emoji: '📅',
        colorValue: 1,
        weekdays: const [1, 3, 5],
        weeklyGoal: 99,
      );
      expect(hp.habits.first.weeklyGoal, 3);
    });
  });

  // ===================== P3-6 删除零消费 API =====================

  group('P3-6 量化叙事 API 收敛', () {
    test('weeklyValue / weeklyValueTarget 可用（weeklyValueRatio 已删）',
        () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水', emoji: '💧', colorValue: 1, weekdays: const [], dailyTarget: 8);
      final h = hp.habits.first;
      await hp.setCheckInValue(h, daysAgo(0), 6);
      expect(hp.weeklyValue(h), 6);
      expect(hp.weeklyValueTarget(h), 7 * 8);
      expect(hp.weeklyValue(h) / hp.weeklyValueTarget(h), closeTo(6 / 56, 1e-9));
    });
  });
}
