import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/task_event.dart';
import 'package:todolist/services/calendar_date.dart';
import 'package:todolist/services/data_health_service.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/update_checker.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';

import 'test_helpers.dart';

/// v3.2.1 审计修复轮回归测试（《有条功能与操作审计报告（v3.2.1）》）。
///
/// 覆盖报告点名的 6 条探针（A-F）+ 本轮新增的边界：
/// - N-P2-1 批量改期 / 顺延的时间段整体平移；
/// - N-P2-2 一次性副本 startDate 锚点（创建日 ≠ 改期日）与 start > due；
/// - N-P2-3 存量打卡目标快照回填 + 总览热力图口径；
/// - N-P3-1 今日完成按完成日统计；
/// - N-P3-3 起止时间非法进入数据体检；
/// - N-P3-8 外部活动豁免失败即清除；
/// - N-P3-10 恢复删除与今日三件名额结算。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(notifCh, (call) async => null);

  late Directory docs;
  setUp(() async {
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    NotificationService.instance.enabled = true;
    docs = await Directory.systemTemp.createTemp('yt-audit-321-');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
  });

  tearDown(() {
    try {
      docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> drain() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

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
    await drain();
    return p;
  }

  Task mk(
    String id, {
    String title = '任务',
    DateTime? due,
    DateTime? start,
    TaskStatus status = TaskStatus.todo,
    DateTime? completedAt,
    RepeatType repeat = RepeatType.none,
    int? repeatMinute,
    List<String> skipDates = const [],
  }) =>
      Task(
        id: id,
        title: title,
        priority: Priority.medium,
        category: Category.work,
        dueDate: due,
        startDate: start,
        status: status,
        completedAt: completedAt,
        repeat: repeat,
        repeatMinute: repeatMinute,
        skipDates: skipDates,
      );

  // ═════════════ N-P2-1 批量改期 / 顺延整体平移 ═════════════
  group('N-P2-1 顺延不再撕裂时间段任务', () {
    test('postponeToAs 同步平移 startDate（同日 14:00–15:00 → 次日同时段）', () async {
      final p = await buildWith([
        mk('1',
            start: DateTime(2026, 11, 28, 14),
            due: DateTime(2026, 11, 28, 15)),
      ]);
      final r = await p.postponeToAs(['1'], DateTime(2026, 11, 29));
      expect(r.$2, 1);
      final t = p.byId('1')!;
      expect(t.dueDate, DateTime(2026, 11, 29, 15));
      // 探针 C 的核心：旧实现只改 due → start 留在 11/28，区间跨天。
      expect(t.startDate, DateTime(2026, 11, 29, 14));
      expect(t.hasInvalidTimeRange, isFalse);
      expect(calendarDaysBetween(t.startDate!, t.dueDate!), 0);
    });

    test('跨天区间整体平移保持日差，无截止任务仍是 no-op', () async {
      final p = await buildWith([
        mk('span',
            start: DateTime(2026, 11, 27, 22),
            due: DateTime(2026, 11, 29, 2)),
        mk('nodue'),
      ]);
      final r = await p.postponeToAs(['span', 'nodue'], DateTime(2026, 12, 1));
      expect(r.$2, 1, reason: '无截止任务不产生变更，不计入条数');
      final t = p.byId('span')!;
      expect(t.dueDate, DateTime(2026, 12, 1, 2));
      expect(t.startDate, DateTime(2026, 11, 29, 22));
    });
  });

  // ═════════════ N-P2-2 副本 startDate 锚点 ═════════════
  group('N-P2-2 一次性副本起止时间', () {
    test('创建日 ≠ 改期日：副本 start 落在目标日同一时分（探针 A）', () async {
      // 11/20 创建「每天 14:00–15:00」，11/28 改到 11/29。
      final origDay = DateTime(2026, 11, 28);
      final target = DateTime(2026, 11, 29);
      final p = await buildWith([
        mk('1',
            start: DateTime(2026, 11, 20, 14),
            due: DateTime(2026, 11, 20, 15),
            repeat: RepeatType.daily,
            repeatMinute: 7 * 60,
            skipDates: [Task.ymdKey(target)]),
      ]);
      final r = await p.rescheduleOnceOccurrence('1', target, origDay: origDay);
      final copy = r.copy!;
      expect(copy.startDate, DateTime(2026, 11, 29, 14),
          reason: '旧实现锚在「今天→目标日」，start 会留在 11/21 14:00');
      // repeatMinute(07:00) 早于开始时刻 → 截止对齐到区间末端，不再 start>due。
      expect(copy.dueDate, DateTime(2026, 11, 29, 15));
      expect(copy.hasInvalidTimeRange, isFalse);
    });

    test('start 与 due 同在今天、repeatMinute 更早（探针 B）：不得出现非法区间', () async {
      final origDay = DateTime(2026, 11, 28);
      final target = DateTime(2026, 11, 29);
      final p = await buildWith([
        mk('1',
            start: DateTime(2026, 11, 28, 14),
            due: DateTime(2026, 11, 28, 15),
            repeat: RepeatType.daily,
            repeatMinute: 7 * 60,
            skipDates: [Task.ymdKey(target)]),
      ]);
      final copy =
          (await p.rescheduleOnceOccurrence('1', target, origDay: origDay)).copy!;
      expect(copy.hasInvalidTimeRange, isFalse,
          reason: '旧实现得到 start 14:00 > due 07:00');
      expect(copy.startDate, DateTime(2026, 11, 29, 14));
      expect(copy.dueDate, DateTime(2026, 11, 29, 15));
    });

    test('原本跨天区间：保持「开始 → 截止」日差', () async {
      final origDay = DateTime(2026, 11, 28);
      final target = DateTime(2026, 12, 1);
      final p = await buildWith([
        mk('1',
            start: DateTime(2026, 11, 27, 22),
            due: DateTime(2026, 11, 28, 2),
            repeat: RepeatType.daily,
            repeatMinute: 8 * 60,
            skipDates: [Task.ymdKey(target)]),
      ]);
      final copy =
          (await p.rescheduleOnceOccurrence('1', target, origDay: origDay)).copy!;
      // due 日 = 目标日，start = 目标日 − 1 天，时分保留。
      expect(copy.startDate, DateTime(2026, 11, 30, 22));
      expect(copy.dueDate, DateTime(2026, 12, 1, 8));
    });
  });

  // ═════════════ N-P2-3 存量快照回填 ═════════════
  group('N-P2-3 习惯历史目标快照', () {
    test('无快照的旧打卡在 load() 后回填，改目标不再追溯归零（探针 D）', () async {
      final yesterday = addCalendarDays(DateTime.now(), -1);
      final hp0 = HabitProvider();
      await hp0.load();
      await hp0.addHabit(
        title: '喝水',
        emoji: '💧',
        colorValue: 0xFF0061A4,
        weekdays: const [],
        dailyTarget: 8,
      );
      final habit = hp0.activeHabits.single;
      // 旧版本写入的打卡：没有 targetAtWrite 快照。
      await LocalDatabase.instance.replaceCheckIns([
        CheckIn.forDay(habit.id, yesterday, value: 8),
      ]);
      expect(
          (await LocalDatabase.instance.loadCheckIns()).single.targetAtWrite,
          isNull);

      // 冷启动：load() 走回填。
      final hp = HabitProvider();
      await hp.load();
      final h = hp.activeHabits.single;
      expect(hp.isTargetMetOn(h, yesterday), isTrue);
      final countsBefore = hp.metCountsByDay(7);
      expect(countsBefore[DateTime(yesterday.year, yesterday.month, yesterday.day)],
          1,
          reason: '总览热力图必须与 metDays 同口径');

      // 目标 8 → 12：历史仍按写入时的目标判定。
      final ok = await hp.updateHabit(h, dailyTarget: 12);
      expect(ok, isTrue);
      final h2 = hp.activeHabits.single;
      expect(hp.isTargetMetOn(h2, yesterday), isTrue,
          reason: '升级用户的旧记录改目标后仍应达标（探针 D 的 before=1 after=0 已修）');
      expect(
          hp.metCountsByDay(7)[
              DateTime(yesterday.year, yesterday.month, yesterday.day)],
          1);
      // 回填已落库：重启后仍然有快照。
      final hp2 = HabitProvider();
      await hp2.load();
      expect((await LocalDatabase.instance.loadCheckIns()).single.targetAtWrite,
          isNotNull);
    });
  });

  // ═════════════ N-P3-1 今日完成按完成日 ═════════════
  group('N-P3-1 今日完成口径', () {
    test('今天到期但三天前已勾掉，不计入「今日完成」（探针 F）', () async {
      final now = DateTime.now();
      final p = await buildWith([
        mk('early',
            due: now,
            status: TaskStatus.done,
            completedAt: now.subtract(const Duration(days: 3))),
        mk('today', due: now),
      ]);
      expect(p.todayEventTotal, 2);
      expect(p.todayCompleted, 0, reason: '完成日不在今天');
      expect(p.todayEventsCompleted, 1, reason: '事件口径仍把提前完成算作已勾选');
      expect(p.todayCompletionRate, closeTo(0.5, 1e-9));
      expect(isTaskCompletedOn(p.byId('early')!, now), isFalse);
    });

    test('今天勾掉的任务（即使截止在未来）计入「今日完成」', () async {
      final now = DateTime.now();
      final p = await buildWith([
        mk('future',
            due: now.add(const Duration(days: 5)),
            status: TaskStatus.done,
            completedAt: now),
      ]);
      expect(p.todayCompleted, 1);
      expect(p.todayEventTotal, 0);
      expect(p.todayCompletionRate, 0);
    });
  });

  // ═════════════ N-P3-3 起止时间非法 ═════════════
  group('N-P3-3 起止时间校验进体检', () {
    test('体检报出 start > due 并可修复（保留截止、清空开始）', () {
      final t = mk('bad',
          start: DateTime(2026, 11, 28, 15), due: DateTime(2026, 11, 28, 9));
      expect(t.hasInvalidTimeRange, isTrue);
      final report = DataHealthService.scan(
        tasks: [t],
        trash: const [],
        existingAttachmentKeys: const {},
        trashRetentionDays: -1,
        now: DateTime(2026, 11, 28),
      );
      expect(report.countOf(DataHealthIssueType.invalidTimeRange), 1);
      final fixed = DataHealthService.dropInvalidStart(t);
      expect(fixed.startDate, isNull);
      expect(fixed.dueDate, DateTime(2026, 11, 28, 9));
      expect(fixed.hasInvalidTimeRange, isFalse);
    });
  });

  // ═════════════ N-P3-8 外部活动豁免 ═════════════
  group('N-P3-8 应用锁豁免失败即清除', () {
    test('成功保留、返回 false 与抛异常都立即清除', () async {
      AppLockProvider.clearExternalActivity();
      expect(AppLockProvider.hasExternalActivityExemption, isFalse);

      expect(await AppLockProvider.launchWithExemption(() async => true), isTrue);
      expect(AppLockProvider.hasExternalActivityExemption, isTrue);
      AppLockProvider.clearExternalActivity();

      expect(
          await AppLockProvider.launchWithExemption(() async => false), isFalse);
      expect(AppLockProvider.hasExternalActivityExemption, isFalse,
          reason: '没有可打开的应用时不得留下 90 秒免验证窗口');

      await expectLater(
        AppLockProvider.launchWithExemption(
            () async => throw StateError('picker failed')),
        throwsA(isA<StateError>()),
      );
      expect(AppLockProvider.hasExternalActivityExemption, isFalse);
    });
  });

  // ═════════════ N-P3-10 今日三件名额 ═════════════
  group('N-P3-10 恢复删除后今日三件结算', () {
    test('删除 B → 补选 D → 撤销删除：D 被显式挤出并给出提示', () async {
      final p = await buildWith([
        mk('A', title: 'A'),
        mk('B', title: 'B'),
        mk('C', title: 'C'),
        mk('D', title: 'D'),
      ]);
      await p.setTodayMit(['A', 'B', 'C']);
      final (batchId, removed) = await p.deleteTaskAs('B');
      expect(removed?.id, 'B');
      // 删除后补选 D（B 的悬空 id 仍在原始列表里）。
      await p.setTodayMit(['A', 'C', 'D']);
      expect(p.todayMit, ['A', 'C', 'D']);

      final r = await p.undoDelete(batchId);
      expect(r.applied, isTrue);
      // B 回到今日三件，D 让位——顺序确定，不再依赖读取层静默截断。
      // （悬空 id 按既有契约留在原始列表前部，故恢复后的 B 排在最前。）
      expect(p.todayMit, ['B', 'A', 'C']);
      final note = p.takeMitEvictionNote();
      expect(note, isNotNull);
      expect(note, contains('D'));
      // 提示一次性消费。
      expect(p.takeMitEvictionNote(), isNull);
    });
  });

  // ═════════════ N-P3-7 更新开关落盘结果 ═════════════
  group('N-P3-7 自动检查更新开关', () {
    test('setAutoCheckEnabled 返回落盘结果', () async {
      expect(await UpdateChecker.setAutoCheckEnabled(false), isTrue);
      expect(await UpdateChecker.autoCheckEnabled(), isFalse);
      expect(await UpdateChecker.setAutoCheckEnabled(true), isTrue);
      expect(await UpdateChecker.autoCheckEnabled(), isTrue);
    });
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
