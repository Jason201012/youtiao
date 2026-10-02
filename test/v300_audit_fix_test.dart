import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/screens/calendar_screen.dart' show planMinutesOn;
import 'package:todolist/services/data_health_service.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/schedule_advisor.dart' show kDefaultEstimateMinutes;
import 'package:todolist/services/task_import_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/kanban_board.dart' show clampWipLimit;
import 'test_helpers.dart';

/// v3.0.0 审计修复轮（《有条功能与操作审计报告（v3.0.0）》P2×8 / P3×23 / U×11）
/// 回归测试。每条修复至少一个可区分用例；UI 接线与真机项不落（见修复对照表）。
///
/// 覆盖清单：
/// - **P2-1** 体检 purge 与可逆路径互斥 + 返回值分列 `(permanentDeleted, reversibleFixed)`；
/// - **P2-2** 覆盖更新不重置完成态 / 优先级 / 分类（源未提供 → 保留原值；显式提供 → 改写）；
/// - **P2-3** 恢复循环：窗口内无循环日也清 `pausedUntil`（不再 no-op 谎报）；
/// - **P2-4** 旧数据回退推导：扫未来被跳过循环日取最大者（非循环日可见可恢复）；
/// - **P2-5** CSV 段跳过整行指纹（标题恰为「日期」不再截断任务段）；
/// - **P2-6** CSV 状态 / 完成时间 / 是否已删除列（回收站条目不复活）；
/// - **P2-7** 批量落库 order 预取（行为等价性）；
/// - **P2-8 / P3-10** `clampWipLimit` 0..99 唯一口径；
/// - **P3-1** 覆盖合并月度四字段整套采纳；
/// - **P3-3** 重复表头行不产伪任务；
/// - **P3-11** `pausedUntil` 残留清理（非重复恒 null / 切不重复清 / endRepeat 清）；
/// - **P3-12** 当日统计排除「带截止但今天非循环日」的重复任务（与今日页同口径）；
/// - **P3-14** 日历占时 estimate=0 与排程同源（hasEstimate 口径）；
/// - **P3-17** iCal start-only 往返（X-YOUTIAO-START；带时刻 DTSTART 用 DATE-TIME）；
/// - **P3-20** 保留期 ≤0 归一「永不」；
/// - **U2-2** 批内指纹判重（同文件重复行不再双双导入）。
void main() {
  // 与 v299 同源的 mock 安装（内存库 + prefs 内存实现 + 通知/安全存储通道 mock）。
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  LocalDatabase.resetMemoryForTest();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureCh, (call) async => null);

  DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  Future<TaskProvider> buildWith(List<Task> tasks, {List<Task>? trash}) async {
    final p = TaskProvider();
    final json = jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': (trash ?? const <Task>[]).map((t) => t.toJson()).toList(),
      'notifications_enabled': false,
      'sound_enabled': false,
    });
    await p.restoreFromJson(json);
    return p;
  }

  Task mk({
    String id = '',
    String title = '任务',
    DateTime? due,
    int? estimate,
    TaskStatus status = TaskStatus.todo,
    DateTime? completedAt,
    Priority priority = Priority.medium,
    Category category = Category.work,
    String note = '',
    RepeatType repeat = RepeatType.none,
    List<int> repeatWeekdays = const [],
    int monthlyDay = 1,
    int monthlyFromEnd = 0,
    DateTime? startDate,
    DateTime? deletedAt,
  }) =>
      Task(
        id: id,
        title: title,
        priority: priority,
        category: category,
        dueDate: due,
        status: status,
        completedAt: completedAt,
        note: note,
        estimateMinutes: estimate,
        repeat: repeat,
        repeatWeekdays: repeatWeekdays,
        monthlyDay: monthlyDay,
        monthlyFromEnd: monthlyFromEnd,
        startDate: startDate,
        deletedAt: deletedAt,
      );

  /// weekly 重复任务（循环日 = [anchorOffset] 天后的星期几；与「今天」的
  /// 星期几无关——相差 3 天必不同 weekday，跨日期运行稳定）。
  Task weeklyAt({String id = 'w', int anchorOffset = 3, List<String> skip = const []}) {
    final wd = today().add(Duration(days: anchorOffset)).weekday;
    return Task(
      id: id,
      title: '每周任务',
      priority: Priority.medium,
      category: Category.work,
      repeat: RepeatType.weekly,
      repeatWeekdays: [wd],
      skipDates: skip,
    );
  }

  // ── P2-1：体检 purge 与可逆路径互斥 ──────────────────────────────
  group('P2-1 体检 purge 与可逆路径互斥', () {
    test('可逆路径返回值分列：reversibleFixed 计数、permanentDeleted 恒 0', () async {
      final p = await buildWith([
        mk(id: 'd1', title: '重复'),
        mk(id: 'd2', title: '重复'),
      ]);
      final report = await p.scanDataHealth();
      final r = await p.fixDataHealthIssues(report);
      expect(r.reversibleFixed, 1, reason: '重复组按移入回收站的条数计（d2 共 1 条）');
      expect(r.permanentDeleted, 0, reason: '可逆路径绝不产生永久删除');
      expect(p.trash, hasLength(1), reason: '重复任务软删入回收站');
    });

    test('purge 分支：备份门失败抛 StateError 时，可逆问题也原样保留（不连带软删）',
        () async {
      final p = await buildWith([
        mk(id: 'd1', title: '重复'),
        mk(id: 'd2', title: '重复'),
      ], trash: [
        mk(id: 'trash-old', deletedAt: today().add(const Duration(days: -31))),
      ]);
      final report = await p.scanDataHealth();
      expect(report.countOf(DataHealthIssueType.staleTrash), 1);
      expect(report.countOf(DataHealthIssueType.duplicateTask), 1);
      // 测试环境快照必失败 → StateError（P2-12 备份门）。修复后 purge 路径
      // 只含不可逆步骤：可逆修复（重复软删）已不在 purge 分支内。
      await expectLater(
        p.fixDataHealthIssues(report, includeStaleTrash: true),
        throwsStateError,
      );
      expect(p.tasks, hasLength(2),
          reason: '重复任务未被 purge 连带软删（互斥成立）');
      expect(p.trash, hasLength(1));
    });
  });

  // ── P2-2：覆盖更新不重置完成态 / 优先级 / 分类 ────────────────────
  group('P2-2 覆盖更新字段保真', () {
    test('源未提供状态/优先级/分类 → 已完成、高、工作 全部保留', () async {
      final day = DateTime(2026, 10, 15);
      final doneAt = DateTime(2026, 10, 14, 18, 0);
      final p = await buildWith([
        mk(id: '1', title: '写周报', due: day,
            status: TaskStatus.done, completedAt: doneAt,
            priority: Priority.high, category: Category.work),
      ]);
      final r = p.importDedup(
        [mk(id: '1', title: '写周报', due: day)],
        const ['1'],
        overwrite: true,
      );
      expect(r.overwritten, 1);
      final t = p.tasks.single;
      expect(t.status, TaskStatus.done,
          reason: 'CSV/iCal 草稿恒产出 todo，未提供状态列 → 不重置完成态');
      expect(t.completedAt, doneAt);
      expect(t.priority, Priority.high, reason: '源无优先级 → 保留原值');
      expect(t.category, Category.work, reason: '源无分类 → 保留原值');
    });

    test('源显式提供状态/优先级/分类 → 按来源改写（真「覆盖」）', () async {
      final day = DateTime(2026, 10, 15);
      final p = await buildWith([
        mk(id: '1', title: '写周报', due: day,
            status: TaskStatus.done, completedAt: day),
      ]);
      final r = p.importDedup(
        [mk(id: '1', title: '写周报', due: day,
            priority: Priority.low, category: Category.study)],
        const ['1'],
        overwrite: true,
        statuses: const [TaskStatus.todo],
        priorities: const [Priority.low],
        categories: const [Category.study],
      );
      expect(r.overwritten, 1);
      final t = p.tasks.single;
      expect(t.status, TaskStatus.todo, reason: '显式提供 todo → 改写');
      expect(t.completedAt, isNull, reason: 'todo 不再携带完成时间');
      expect(t.priority, Priority.low);
      expect(t.category, Category.study);
    });

    test('源显式提供「已完成」且无完成时间列 → 保留旧完成时间（往返不漂移）',
        () async {
      final day = DateTime(2026, 10, 15);
      final doneAt = DateTime(2026, 10, 14, 9, 0);
      final p = await buildWith([
        mk(id: '1', title: '写周报', due: day,
            status: TaskStatus.done, completedAt: doneAt),
      ]);
      p.importDedup(
        [mk(id: '1', title: '写周报', due: day, status: TaskStatus.done)],
        const ['1'],
        overwrite: true,
        statuses: const [TaskStatus.done],
      );
      expect(p.tasks.single.completedAt, doneAt,
          reason: '源说「已完成」但未写完成时间 → 保留原完成时间');
    });
  });

  // ── P2-3：恢复循环窗口内无循环日也清字段 ─────────────────────────
  group('P2-3 恢复循环 no-op 谎报', () {
    test('窗口 [今天, 终点] 不含循环日 → resumeRepeats 仍清 pausedUntil', () async {
      // 循环日 = 今天+2 的星期几；暂停窗口 = [今天, 今天+1]，两者都不含
      // 循环日（今天+1 与今天+2 的 weekday 必不同）→ 暂停侧不写 skipDates 键。
      final t = weeklyAt(anchorOffset: 2)
          .copyWith(pausedUntil: Task.ymdKey(today().add(const Duration(days: 1))));
      final p = await buildWith([t]);
      expect(p.tasks.single.pausedToday, isTrue);
      expect(p.tasks.single.skipDates, isEmpty,
          reason: '前提：窗口内确无循环日键（旧实现据此误判「无窗口」）');
      p.resumeRepeats(p.tasks.single.id);
      expect(p.tasks.single.pausedToday, isFalse,
          reason: '旧实现在此提前 return，字段清不掉、UI 弹「已恢复」谎报成功');
    });
  });

  // ── P2-4：旧数据回退推导（非循环日可见、可恢复）─────────────────
  group('P2-4 旧数据（无显式 pausedUntil）非 daily 暂停兼容', () {
    test('非循环日查看：回退推导 = 未来最后被跳过循环日（不再是 null）', () {
      // 循环日 = 今天+3 的星期几；旧版（v2.9.9）暂停写入 3 个未来循环日键。
      final d1 = Task.ymdKey(today().add(const Duration(days: 3)));
      final d2 = Task.ymdKey(today().add(const Duration(days: 10)));
      final d3 = Task.ymdKey(today().add(const Duration(days: 17)));
      final t = weeklyAt(anchorOffset: 3, skip: [d1, d2, d3]);
      expect(t.pausedToday, isTrue,
          reason: '今天不是循环日 → 旧推导要求「今天是循环日」恒 null（角标消失）');
      expect(t.pausedUntilDate, today().add(const Duration(days: 17)),
          reason: 'P2-4：取未来最后被跳过的循环日为窗口终点');
    });

    test('恢复：清 [今天, 终点] 内全部被跳过循环日（不再逐日点按）', () async {
      final d1 = Task.ymdKey(today().add(const Duration(days: 3)));
      final d2 = Task.ymdKey(today().add(const Duration(days: 10)));
      final d3 = Task.ymdKey(today().add(const Duration(days: 17)));
      final p = await buildWith([weeklyAt(anchorOffset: 3, skip: [d1, d2, d3])]);
      p.resumeRepeats(p.tasks.single.id);
      expect(p.tasks.single.skipDates, isEmpty,
          reason: '旧推导把窗口压缩为当天，只清 1 个键（P2-4b 回归）');
      expect(p.tasks.single.pausedToday, isFalse);
    });

    test('单独「跳过今天」（daily）回退推导不回归：仍以今天为窗口终点', () {
      final t = Task(
        id: 'd',
        title: '每日任务',
        priority: Priority.medium,
        category: Category.work,
        repeat: RepeatType.daily,
        skipDates: [Task.ymdKey(today())],
      );
      expect(t.pausedUntilDate, today());
    });
  });

  // ── P2-5：CSV 段跳过整行指纹 ────────────────────────────────────
  group('P2-5 CSV 段跳过判定收敛', () {
    test('任务标题恰为「日期」但整行不是段表头 → 正常解析（不再截断其后任务）',
        () {
      final csv = '标题,优先级\n'
          '日期,高\n'
          '正常任务,低\n';
      final r = parseTasksCsv(csv);
      expect(r.tasks, hasLength(2), reason: '旧实现从「日期」行起整体丢弃');
      expect(r.tasks.first.title, '日期');
      expect(r.skippedSections, 0);
    });

    test('任务标题恰为「习惯」但第二列不是表情/打卡日期 → 不误判', () {
      final csv = '标题,优先级\n'
          '习惯,高\n';
      final r = parseTasksCsv(csv);
      expect(r.tasks, hasLength(1));
      expect(r.tasks.single.title, '习惯');
    });
  });

  // ── P2-6：CSV 状态 / 完成时间 / 是否已删除列 ─────────────────────
  group('P2-6 CSV 可机器还原列解析', () {
    test('状态/完成时间/是否已删除列解析；回收站条目跳过并计数', () {
      final csv = '标题,状态,完成时间,是否已删除\n'
          '任务A,已完成,2026-10-01 10:00,否\n'
          '任务B,未完成,,否\n'
          '任务C,,,是\n';
      final r = parseTasksCsv(csv);
      expect(r.tasks, hasLength(2), reason: '已删除行不导入（不反向复活）');
      expect(r.skippedDeleted, 1);
      expect(r.tasks[0].title, '任务A');
      expect(r.meta[0].status, TaskStatus.done);
      expect(r.meta[0].completedAt, DateTime(2026, 10, 1, 10, 0));
      expect(r.tasks[1].title, '任务B');
      expect(r.meta[1].status, TaskStatus.todo);
    });

    test('无状态列 → meta.status 为 null（覆盖时保留原值的前提）', () {
      final csv = '标题\n任务A\n';
      final r = parseTasksCsv(csv);
      expect(r.tasks, hasLength(1));
      expect(r.meta[0].status, isNull);
      expect(r.meta[0].priority, isNull);
      expect(r.meta[0].category, isNull);
    });
  });

  // ── P2-7：批量落库 order 预取（行为等价）────────────────────────
  group('P2-7 批量落库 order', () {
    test('同批同分区 order 唯一且递增（与旧逐条扫 max 等价）', () async {
      final p = await buildWith(const []);
      final r = p.importDedup([
        mk(title: '甲'),
        mk(title: '乙'),
        mk(title: '丙'),
      ], const [null, null, null]);
      expect(r.added, 3);
      final orders = p.tasks.map((t) => t.order).toSet();
      expect(orders, hasLength(3), reason: 'order 两两不同（无并列）');
    });
  });

  // ── P2-8 / P3-10：WIP 上限值域 ──────────────────────────────────
  group('P2-8/P3-10 clampWipLimit 值域', () {
    test('负值 → 0；>99 → 99；合法值原样', () {
      expect(clampWipLimit(-5), 0);
      expect(clampWipLimit(0), 0);
      expect(clampWipLimit(7), 7);
      expect(clampWipLimit(99), 99);
      expect(clampWipLimit(150), 99, reason: '旧写入侧只夹负值，150 可直写');
    });
  });

  // ── P3-1：覆盖合并月度四字段整套采纳 ─────────────────────────────
  group('P3-1 覆盖合并月度字段', () {
    test('源非 monthly（无 RRULE）→ 既有「每月最后一天」整套保留', () async {
      final day = DateTime(2026, 10, 15);
      final p = await buildWith([
        mk(id: '1', title: '月度', due: day,
            repeat: RepeatType.monthly, monthlyFromEnd: 1),
      ]);
      p.importDedup(
        [mk(id: '1', title: '月度', due: day)],
        const ['1'],
        overwrite: true,
      );
      final t = p.tasks.single;
      expect(t.repeat, RepeatType.monthly, reason: '来源无 RRULE → 不降级');
      expect(t.monthlyFromEnd, 1,
          reason: '旧实现未合并 monthlyFromEnd →「最后一天」被重置');
      expect(t.monthlyDay, 1);
    });

    test('源显式 monthly（BYMONTHDAY=15）→ 四字段整套采纳（不再吞显式 1 号）',
        () async {
      final day = DateTime(2026, 10, 15);
      final p = await buildWith([
        mk(id: '1', title: '月度', due: day,
            repeat: RepeatType.monthly, monthlyDay: 1, monthlyFromEnd: 1),
      ]);
      p.importDedup(
        [mk(id: '1', title: '月度', due: day,
            repeat: RepeatType.monthly, monthlyDay: 15)],
        const ['1'],
        overwrite: true,
      );
      final t = p.tasks.single;
      expect(t.monthlyDay, 15, reason: '旧实现把 monthlyDay==1 当缺省 → 15 写不进');
      expect(t.monthlyFromEnd, 0, reason: '显式「每月 15 号」→ 倒数语义一并清');
    });
  });

  // ── P3-3：重复表头行不产伪任务 ──────────────────────────────────
  group('P3-3 重复表头行', () {
    test('拼接两份任务段：第二行表头被跳过（无「标题」伪任务、不计数据行）',
        () {
      final csv = '标题,截止时间\n'
          '任务A,2026-10-01\n'
          '标题,截止时间\n'
          '任务B,2026-10-02\n';
      final r = parseTasksCsv(csv);
      expect(r.tasks.map((t) => t.title), ['任务A', '任务B']);
      expect(r.totalRows, 2, reason: '表头行不计入数据行');
      expect(r.errors, isEmpty);
    });
  });

  // ── P3-11：pausedUntil 残留清理 ─────────────────────────────────
  group('P3-11 pausedUntil 残留清理', () {
    test('非重复任务携带 pausedUntil（手改备份）→ 恒非暂停态（无误显角标）', () {
      final t = Task(
        id: 'x',
        title: '一次性',
        priority: Priority.medium,
        category: Category.work,
        repeat: RepeatType.none,
        pausedUntil: '2099-12-31',
      );
      expect(t.pausedToday, isFalse);
      expect(t.pausedUntilDate, isNull);
    });

    test('编辑把重复切为不重复 → 清 pausedUntil（残留不再误显）', () async {
      final t = weeklyAt()
          .copyWith(pausedUntil: Task.ymdKey(today().add(const Duration(days: 7))));
      final p = await buildWith([t]);
      expect(p.tasks.single.pausedToday, isTrue);
      // copyWith 不传 pausedUntil（保留字段值）→ _applyTaskUpdate 检测
      // 「重复 → 不重复」主动清字段。
      p.updateTask(p.tasks.single.copyWith(repeat: RepeatType.none));
      expect(p.tasks.single.pausedToday, isFalse);
    });

    test('endRepeat 清 pausedUntil（重开重复不「复活」旧暂停）', () async {
      final t = weeklyAt()
          .copyWith(pausedUntil: Task.ymdKey(today().add(const Duration(days: 7))));
      final p = await buildWith([t]);
      p.endRepeat(p.tasks.single.id);
      expect(p.tasks.single.pausedToday, isFalse);
      expect(p.tasks.single.repeatEnded, isTrue);
    });
  });

  // ── P3-12：当日统计与今日页口径同步 ─────────────────────────────
  group('P3-12 当日统计口径', () {
    test('带 dueDate=今天 的重复任务在非循环日不计入 todayEventTotal', () async {
      final p = await buildWith([
        weeklyAt(anchorOffset: 3, id: 'w1')
            .copyWith(dueDate: today()), // 截止=今天，但今天非循环日
        mk(id: 'n1', title: '普通无截止'), // 非循环无截止 → 计入
      ]);
      expect(p.todayEventTotal, 1,
          reason: '旧实现按 dueDate 恒命中（与今日页已修口径分叉）');
    });
  });

  // ── P3-14：日历占时 estimate=0 口径 ─────────────────────────────
  group('P3-14 日历占时 estimate=0 与排程同源', () {
    test('estimateMinutes=0（手改备份可达）按兜底 30 计（不再计 0）', () async {
      final day = DateTime(2026, 10, 15);
      final p = await buildWith([
        mk(id: '1', title: '零预估', due: day, estimate: 0),
      ]);
      expect(planMinutesOn(p, day), kDefaultEstimateMinutes,
          reason: '旧实现 estimate ?? 30 在 0 时计 0，与排程 hasEstimate 口径分叉');
    });

    test('有效预估照常按原值计', () async {
      final day = DateTime(2026, 10, 15);
      final p = await buildWith([
        mk(id: '1', title: '有预估', due: day, estimate: 45),
      ]);
      expect(planMinutesOn(p, day), 45);
    });
  });

  // ── P3-17：iCal start-only 往返 ─────────────────────────────────
  group('P3-17 iCal start-only 往返', () {
    test('start-only 导出不再写 DTSTART（改 X-YOUTIAO-START）→ 往返不再凭空多截止',
        () {
      final t = mk(id: '1', title: '只有开始')
          .copyWith(startDate: DateTime(2026, 10, 10, 9, 30));
      final ics = exportIcs([t]);
      expect(ics.contains('DTSTART'), isFalse,
          reason: '无 DUE 时写 DTSTART 会被导入侧当 dueDate（开始→截止漂移）');
      expect(ics, contains('X-YOUTIAO-START:20261010T093000'));
      final back = parseIcs(ics);
      expect(back.tasks.single.dueDate, isNull,
          reason: '往返后不凭空产生截止日');
      expect(back.tasks.single.startDate, DateTime(2026, 10, 10, 9, 30));
    });

    test('区间任务带时刻开始：DTSTART 写 DATE-TIME（时分不再丢）', () {
      final t = mk(id: '1', title: '区间时段',
              due: DateTime(2026, 10, 18, 12, 0))
          .copyWith(startDate: DateTime(2026, 10, 10, 9, 30));
      final ics = exportIcs([t]);
      expect(ics, contains('DTSTART:20261010T093000'),
          reason: '旧实现一律 VALUE=DATE，时段开始时分静默丢失');
      final back = parseIcs(ics);
      expect(back.tasks.single.startDate, DateTime(2026, 10, 10, 9, 30));
      expect(back.tasks.single.dueDate, DateTime(2026, 10, 18, 12, 0));
    });

    test('纯日期区间维持 VALUE=DATE（v2.9.9 P3-20 行为不回归）', () {
      final t = mk(id: '1', title: '区间',
              due: DateTime(2026, 10, 18, 12, 0))
          .copyWith(startDate: DateTime(2026, 10, 10));
      final ics = exportIcs([t]);
      expect(ics, contains('DTSTART;VALUE=DATE:20261010'));
    });
  });

  // ── P3-20：保留期 ≤0 归一「永不」────────────────────────────────
  group('P3-20 保留期门槛归一', () {
    test('setTrashRetentionDays(0) → 归一 -1（永不）；负值同', () async {
      final p = await buildWith(const []);
      await p.setTrashRetentionDays(0);
      expect(p.trashRetentionDays, -1, reason: '旧实现 0 = cutoff=now 清空回收站');
      expect(p.trashRetentionLabel, '永不');
      await p.setTrashRetentionDays(-5);
      expect(p.trashRetentionDays, -1);
      expect(p.trashRetentionLabel, '永不');
    });
  });

  // ── U2-2：批内指纹判重 ──────────────────────────────────────────
  group('U2-2 批内指纹判重', () {
    test('跳过挡：同一文件两行完全相同 → 只导 1 条、另 1 条计 skipped', () async {
      final p = await buildWith(const []);
      final r = p.importDedup([
        mk(title: '买菜', due: DateTime(2026, 10, 15)),
        mk(title: '买菜', due: DateTime(2026, 10, 15)),
      ], const [null, null], fingerprint: true);
      expect(r.added, 1, reason: '旧实现双双导入（批内判重只查库）');
      expect(r.skipped, 1);
      expect(p.tasks, hasLength(1));
    });

    test('覆盖挡：批内重复行以后行为准（替换，不重复导入）', () async {
      final p = await buildWith(const []);
      final r = p.importDedup([
        mk(title: '买菜', due: DateTime(2026, 10, 15), note: '第一版'),
        mk(title: '买菜', due: DateTime(2026, 10, 15), note: '第二版'),
      ], const [null, null], fingerprint: true, overwrite: true);
      expect(r.added, 1);
      expect(r.overwritten, 0);
      expect(p.tasks.single.note, '第二版', reason: '后行覆盖前行');
    });
  });
}
