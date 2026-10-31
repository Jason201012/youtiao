import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/backup_validator.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/task_import_service.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/task_toggle_undo.dart';

import 'test_helpers.dart';

/// v3.0.8 审计修复轮（《有条功能与操作审计报告（v3.0.8）》+《youtiao-分析报告
/// （第 10 轮）》两报告合并修复）回归测试。每条修复至少一个「能区分修与未修」
/// 的用例；不落用例的项见文件尾说明。
///
/// 覆盖清单：
/// - **H1** 校验器豁免 `__skipped` 统计段（App 自产备份不再被自产校验拒绝），
///   且豁免不放松越界 taskId 校验；DATA_FORMAT.md 显式契约随测试钉死；
/// - **M8** 校验器补 habits / check_ins 逐条真实反序列化体检（脏条目整份拒绝）；
/// - **M2** 用户模板进备份：`exportAllForBackup` 收集、`restoreAllFromBackup`
///   覆盖恢复 + 单条损坏跳过（文件系统经 _FakePathProvider 指向临时目录）；
/// - **M4 / M5** iCal / CSV 单批 500 条上限 + `truncated` 截断标记；
/// - **L9** SP→SQLite 迁移解析失败抛错且**保留旧 key**（旧实现吞错当空数据，
///   覆盖写后连锚点一起删除）；合法 JSON 正常迁移并清 key；
/// - **L10** iCal 导出 UNTIL 用 date 值（无时间部分）；
/// - **U3-6** 模板套用改批量：`addTasksForTemplateApply` 一次插入 + 单次落盘，
///   落盘失败**整批回滚**（created=0），不再 N 次串行全表写；
/// - **H4** `setCheckInValue` 归档 / 休息日守卫改判 provider 当前对象（旧弹层
///   持过期快照不再击穿守卫）；
/// - **M3 / M18 / P3-6** importDedup / clearSampleTasks 透传落盘结果；
/// - **P3-7** 失败提示按「已回滚」分化（新建失败 →「新建未生效，请重试」）
///   与安全模式文案（widget）。
///
/// 不落用例：
/// - **H2 / H3 / L14 / L25 / P3-3 / U3-3 的 service 与 main 接线**——通知插件
///   交互与顶层私有回调库外不可达（v3.0.2 / v3.0.4-v3.0.7 轮同判）；service
///   层新增参数（showsUserInterface / force / taskUndo 文案）为静态配置，
///   真机验证项（历轮口径：插件行为以真机为准）；
/// - **P2-1 防重入 / M13-M17 / L16-L24 的 UI 内部**——`_saving` / `_applying` /
///   `_clampDate` / `_isDirty` 均为 State 私有字段或私有函数，FakeAsync 下
///   无法稳定构造双击窗口（v3.0.7 P3-4 同判）；以代码推演 + 对应 provider 层
///   契约（本文件 U3-6 / M3 用例）护住；
/// - **P3-5 文件删除顺序**——AttachmentService.removeDir 为静态文件操作，
///   DB 失败注入下文件系统不受控（沙箱删除语义），以代码顺序推演交付；
/// - **M11 番茄补录不自动续跑**——FocusProvider 的 _beginPhase 链依赖通知
///   插件 mock 全链路，构造代价高于收益（service 层已由 security_batch_focus
///   既有用例覆盖主链路）；
/// - **M6 / M10 / L12 / L22**——csvCell 委托、UpdatePolicy.isAllowedHost、
///   trimForExport 余量、纯日期显示均为既有单一真源函数的直接消费（既有
///   测试已覆盖真源本身），本轮改动属「接对线」，不重复钉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  // 记录型通知插件 mock：除返回 null 外，把全部方法调用留档。
  final notifCalls = <MethodCall>[];
  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(notifCh, (call) async {
    notifCalls.add(call);
    return null;
  });
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureCh, (call) async => null);

  setUp(() {
    // 🔴 内存库是同进程共享单例：每个用例前必须重置 DB + prefs 再 load()。
    LocalDatabase.resetMemoryForTest();
    // 🔴 testUseMemory 是进程级静态标志（v3.0.6 轮实证的泄漏教训）：setUp
    // 统一置真兜底，各用例内部仍须自负还原。
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    NotificationService.instance.enabled = true;
  });

  Future<void> drainMicrotasks() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  // ── 脚手架 ────────────────────────────────────────────────────────

  /// 用受控列表构造 TaskProvider（restoreFromJson 绕过 load()，不起午夜守护）。
  Future<TaskProvider> buildWith(
    List<Task> tasks, {
    List<Task>? trash,
  }) async {
    final p = TaskProvider();
    final json = jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': (trash ?? const <Task>[]).map((t) => t.toJson()).toList(),
      'notifications_enabled': false,
      'sound_enabled': false,
    });
    await p.restoreFromJson(json);
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return p;
  }

  /// 最小一次性任务工厂。
  Task mk({
    String id = '',
    String title = '任务',
    DateTime? due,
    TaskStatus status = TaskStatus.todo,
  }) =>
      Task(
        id: id,
        title: title,
        priority: Priority.medium,
        category: Category.work,
        dueDate: due,
        status: status,
      );

  /// 习惯 Provider 脚手架（setUp 已重置内存库 + prefs）：直接 load + add。
  Future<(HabitProvider, Habit)> habitWith({List<int> weekdays = const []}) async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '喝水',
      emoji: '💧',
      colorValue: 1,
      weekdays: weekdays,
    );
    return (hp, hp.habits.single);
  }

  /// 安全模式 provider（dbLoadFailed 真实注入路径，同 v3.0.7 口径）。
  /// load 失败会 rethrow——安全模式正是由此进入，须 try/catch 包裹。
  Future<TaskProvider> safeModeProvider() async {
    LocalDatabase.testUseMemory = false;
    final p = TaskProvider();
    try {
      await p.load();
    } catch (_) {
      // load 失败 rethrow = 安全模式入口。
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    return p;
  }

  // ══════════════════════════════════════════════════════════════════
  // H1：校验器豁免 __skipped 统计段
  // ══════════════════════════════════════════════════════════════════

  group('H1 校验器豁免 __skipped（v3.0.8 审计）', () {
    test('含 __skipped 统计段的合法备份通过（旧实现整份拒绝）', () {
      final raw = jsonEncode({
        'app': '有条',
        'version': 3,
        'tasks': [
          {'id': '1', 'title': 'a', 'priority': 'low', 'category': 'life'},
        ],
        'trash': <Map<String, dynamic>>[],
        // collectBlobs 的真实产出形态：taskId → 条目数组 + __skipped 统计段
        // （值为 Map 而非 List）。
        'attachments': {
          '1': [
            {'ref': {'fileName': 'a.txt'}, 'data': 'aGk='},
          ],
          '__skipped': {'oversize': 1, 'missingOrInvalid': 0},
        },
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isTrue,
          reason: 'H1：__skipped 是 App 自产的合法统计段，'
              '校验器拒绝它 = 备份→恢复闭环断裂（v2.8.1 起）');
    });

    test('豁免不放松其它校验：越界 taskId 仍被拒', () {
      final raw = jsonEncode({
        'app': '有条',
        'version': 3,
        'tasks': <Map<String, dynamic>>[],
        'trash': <Map<String, dynamic>>[],
        'attachments': {
          '../evil': [
            {'ref': {'fileName': 'a.txt'}, 'data': 'aGk='},
          ],
        },
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isFalse, reason: '路径穿越键必须仍然拒绝（CWE-22 防线不退）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // M8：校验器 habits / check_ins 体检
  // ══════════════════════════════════════════════════════════════════

  group('M8 校验器 habits/check_ins 体检（v3.0.8 审计）', () {
    test('habits 含脏条目（weekdays 字符串）→ 整份拒绝', () {
      final raw = jsonEncode({
        'app': '有条',
        'version': 3,
        'tasks': <Map<String, dynamic>>[],
        'trash': <Map<String, dynamic>>[],
        'habits': [
          {'id': 'h1', 'title': '喝水', 'weekdays': ['一']},
        ],
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isFalse, reason: '脏条目旧实现绕过校验，恢复中途抛错留半态');
      expect(r.message, contains('习惯'));
    });

    test('habits 条目缺 id → 拒绝（真实反序列化即抛）', () {
      final raw = jsonEncode({
        'app': '有条',
        'version': 3,
        'tasks': <Map<String, dynamic>>[],
        'trash': <Map<String, dynamic>>[],
        'habits': [
          {'title': '缺 id'},
        ],
      });
      expect(BackupValidator.validate(raw).ok, isFalse);
    });

    test('check_ins 含脏条目（缺 id）→ 拒绝', () {
      final raw = jsonEncode({
        'app': '有条',
        'version': 3,
        'tasks': <Map<String, dynamic>>[],
        'trash': <Map<String, dynamic>>[],
        'check_ins': [
          {'habitId': 'h1', 'date': '2026-01-01'},
        ],
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isFalse);
      expect(r.message, contains('打卡'));
    });

    test('合法 habits/check_ins 通过', () {
      final raw = jsonEncode({
        'app': '有条',
        'version': 3,
        'tasks': <Map<String, dynamic>>[],
        'trash': <Map<String, dynamic>>[],
        'habits': [
          {'id': 'h1', 'title': '喝水', 'createdAt': '2026-01-01T00:00:00.000'},
        ],
        'check_ins': [
          {'id': 'c1', 'habitId': 'h1', 'date': '2026-01-01', 'value': 1},
        ],
      });
      expect(BackupValidator.validate(raw).ok, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // M5 / M4：导入单批上限
  // ══════════════════════════════════════════════════════════════════

  group('M5 CSV 单批上限（v3.0.8 审计）', () {
    test('600 行 → 500 条 + truncated 标记', () {
      final buf = StringBuffer('标题\n');
      for (var i = 0; i < 600; i++) {
        buf.writeln('t$i');
      }
      final r = parseTasksCsv(buf.toString());
      expect(r.tasks.length, 500, reason: 'CSV 此前无上限，2MB 文件可灌数万行冻 UI');
      expect(r.truncated, isTrue, reason: 'M5：截断必须标记，调用方据此提示分批');
    });

    test('低于上限不标记', () {
      final buf = StringBuffer('标题\n');
      for (var i = 0; i < 100; i++) {
        buf.writeln('t$i');
      }
      final r = parseTasksCsv(buf.toString());
      expect(r.tasks.length, 100);
      expect(r.truncated, isFalse);
    });
  });

  group('M4 iCal 单批上限（既有 maxItems 的截断标记）', () {
    String ics(int n) {
      final buf = StringBuffer('BEGIN:VCALENDAR\n');
      for (var i = 0; i < n; i++) {
        buf.write('BEGIN:VEVENT\n');
        buf.write('UID:$i@youtiao\n');
        buf.write('SUMMARY:任务$i\n');
        buf.write('DTSTART:20261101T090000Z\n');
        buf.write('END:VEVENT\n');
      }
      buf.write('END:VCALENDAR\n');
      return buf.toString();
    }

    test('600 块 → 500 条 + truncated 标记', () {
      final r = parseIcs(ics(600));
      expect(r.tasks.length, 500);
      expect(r.truncated, isTrue,
          reason: 'M4：截断标记此前从未被 UI 消费，先保证解析层如实产出');
    });

    test('低于上限不标记', () {
      final r = parseIcs(ics(50));
      expect(r.tasks.length, 50);
      expect(r.truncated, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // L10：UNTIL 用 date 值；L9：迁移解析失败保留 key
  // ══════════════════════════════════════════════════════════════════

  group('L10 iCal 导出 UNTIL 值类型（v3.0.8 审计）', () {
    test('repeatUntil 导出为 UNTIL=yyyyMMddTHHMMSS（与 DUE 值类型一致）', () {
      final t = mk(
        id: '11',
        due: DateTime(2026, 11, 1, 9),
      ).copyWith(
        repeat: RepeatType.daily,
        repeatInterval: 1,
        repeatMinute: 9 * 60,
        repeatAnchor: DateTime(2026, 11, 1),
        repeatUntil: '2027-01-31',
      );
      final ics = exportIcs([t]);
      expect(ics, contains('UNTIL=20270131T235959'),
          reason: 'L10：本文件导出的 DUE 恒为 DATE-TIME，RFC 5545 要求同一 '
              'RRULE 内 UNTIL 与 DTSTART 值类型一致——旧实现 UNTIL 写 '
              'date-only，严格解析器（Google / Apple 日历）会把截止日当天'
              '最后一次 occurrence 排除（少一天）。改为当天 23:59:59，与'
              '「含当日仍循环」的产品语义一致');
      expect(ics, isNot(contains(';UNTIL=20270131\r')),
          reason: '不得再是 date-only 值');
    });
  });

  group('L9 SP→SQLite 迁移解析失败保留旧 key（v3.0.8 审计）', () {
    test('坏 JSON → 抛错且 key 保留（旧实现吞错当空数据覆盖写）', () async {
      SharedPreferences.setMockInitialValues({
        'tasks': '{"tasks": [bad json',
        'trash': '[1,',
      });
      final prefs = await SharedPreferences.getInstance();
      final db = LocalDatabase.instance;
      await expectLater(
        db.migrateTasksFromPrefs(prefs),
        throwsA(anything),
        reason: 'L9：解析失败必须上抛中止迁移，绝不 replaceTasks([])',
      );
      expect(prefs.getString('tasks'), isNotNull,
          reason: '旧 key 是唯一副本，迁移中止时必须原样保留');
      expect(prefs.getString('trash'), isNotNull);
    });

    test('合法 JSON → 正常迁移并清除 key（对照）', () async {
      final t = mk(id: '9', title: '正常迁移');
      SharedPreferences.setMockInitialValues({
        'tasks': jsonEncode([t.toJson()]),
      });
      final prefs = await SharedPreferences.getInstance();
      final db = LocalDatabase.instance;
      await db.migrateTasksFromPrefs(prefs);
      expect(prefs.getString('tasks'), isNull, reason: '成功迁移后清锚点');
      final loaded = await db.loadTasks();
      expect(loaded.map((x) => x.id), contains('9'));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // M2：用户模板进备份 / 自动快照
  // ══════════════════════════════════════════════════════════════════

  group('M2 用户模板进备份（v3.0.8 审计）', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('youtiao_m2_tpl');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('exportAllForBackup 收集已保存模板；save 覆盖写同 id', () async {
      await UserTemplateStore
          .save(UserTemplate(id: 'tpl1', name: '晨间例行'));
      // N5（v3.0.9 审计）：返回改为 (templates, failed) 记录型——失败信号
      // 供调用方提示「本次备份未包含自定义模板」。此处正常路径 failed=false。
      var all = (await UserTemplateStore.exportAllForBackup()).templates;
      expect(all.length, 1);
      expect((all.first as Map)['id'], 'tpl1');
      expect((all.first as Map)['name'], '晨间例行');

      // 同 id 再保存 = 覆盖（备份语义：导出的是当前最新态）。
      await UserTemplateStore
          .save(UserTemplate(id: 'tpl1', name: '晨间例行v2'));
      all = (await UserTemplateStore.exportAllForBackup()).templates;
      expect(all.length, 1, reason: '同 id 覆盖，不产生双份');
      expect((all.first as Map)['name'], '晨间例行v2');
    });

    test('restoreAllFromBackup 覆盖恢复 + 单条损坏跳过', () async {
      await UserTemplateStore
          .save(UserTemplate(id: 'tpl1', name: '旧名'));
      // N7（v3.0.9 审计）：返回改为 (restored, total)——恢复入口下沉进
      // provider.restoreFromJson 后由本体消费并透出统计。
      final r = await UserTemplateStore.restoreAllFromBackup([
        {
          'id': 'tpl1',
          'name': '备份名',
          'items': <Map<String, dynamic>>[],
        },
        'not-a-map', // 坏条目（非对象）：跳过不阻断
        {1: 'x'}, // 非字符串键 → Map<String,dynamic>.from 抛错 → 跳过
      ]);
      expect(r.restored, 1, reason: '只有 1 条合法条目被恢复');
      expect(r.total, 3, reason: 'total 含坏条目（供「恢复 x/y 条」文案）');
      final all = await UserTemplateStore.loadAll();
      expect(all.single.name, '备份名', reason: 'M2：以备份为准覆盖同 id');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // U3-6：模板套用批量一次落盘 + 整批回滚
  // ══════════════════════════════════════════════════════════════════

  group('U3-6 模板套用批量（v3.0.8 审计）', () {
    final items = [
      const TemplateItem('写周报', Category.work, Priority.high, 1),
      const TemplateItem('跑步', Category.life, Priority.medium, 2),
    ];

    test('正常库：整批一次落盘，created == total', () async {
      final p = await buildWith([]);
      final r = await applyTemplateItems(p, items);
      expect(r.created, 2);
      expect(r.total, 2);
      expect(p.tasks.length, 2);
      expect(p.tasks.map((t) => t.title), containsAll(['写周报', '跑步']));
    });

    test('落盘失败：整批回滚（created = 0，任务与提醒全撤）', () async {
      final p = await buildWith([]);
      LocalDatabase.testUseMemory = false;
      late ({int created, int total}) r;
      try {
        r = await applyTemplateItems(p, items);
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(r.created, 0, reason: 'U3-6：失败整批回滚，不再「部分落库 n<M」');
      expect(r.total, 2);
      expect(p.tasks, isEmpty, reason: '内存已整体回滚，UI 显示的即已落盘的');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // H4：setCheckInValue 守卫按 provider 当前对象
  // ══════════════════════════════════════════════════════════════════

  group('H4 setCheckInValue 守卫按当前对象（v3.0.8 审计）', () {
    test('旧弹层快照（未归档）写已归档习惯 → 拒绝写入', () async {
      final (hp, h) = await habitWith();
      await hp.updateHabit(h, archived: true);
      // 旧详情弹层仍持「归档前」的快照 h——守卫必须看当前对象（已归档）。
      final ok = await hp.setCheckInValue(h, today(), 1);
      // P3-8（v3.1.0 审计）：返回契约从「无操作成功（true）」改为 **false**——
      // 归档写入被拒必须如实上报，否则任何未来的批量/程序入口都会把「未写入」
      // 当成功（全仓「bool = 落盘成功」契约）。落盘结果不变：不真实写入。
      expect(ok, isFalse, reason: '归档写入 = 拒绝写入，如实返回 false');
      expect(hp.checkInValueOn(h, today()), 0, reason: '不得真实落盘');
    });

    test('旧弹层快照按旧 weekdays 写休息日 → 拒绝写入', () async {
      // 今天是周几动态取：先按「今天可打卡」建，再把 weekdays 改掉。
      final todayWd = today().weekday;
      final otherWd = todayWd == 1 ? 2 : 1;
      final (hp, h) = await habitWith(weekdays: [todayWd]);
      await hp.updateHabit(h, weekdays: [otherWd]);
      final ok = await hp.setCheckInValue(h, today(), 1);
      expect(ok, isTrue);
      expect(hp.checkInValueOn(h, today()), 0,
          reason: '改星期后旧弹层仍按旧 weekdays 放行的旁路必须封死');
    });

    test('正常路径不受影响：当前对象未归档且当天是计划日 → 正常写入', () async {
      final (hp, h) = await habitWith();
      final ok = await hp.setCheckInValue(h, today(), 1);
      expect(ok, isTrue);
      expect(hp.checkInValueOn(h, today()), 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // M3 / M18 / P3-6：落盘结果透传
  // ══════════════════════════════════════════════════════════════════

  group('M3 importDedup 透传落盘结果（v3.0.8 审计）', () {
    test('失败 → saved=false；正常 → saved=true', () async {
      final p = await buildWith([]);
      LocalDatabase.testUseMemory = false;
      late ({int added, int skipped, int overwritten, bool saved}) bad;
      try {
        bad = await p.importDedup([mk(id: '9001', title: '导入')], [null],
            fingerprint: true);
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(bad.saved, isFalse, reason: 'M3：saved 不再恒 true，调用方如实提示');
      expect(bad.added, 1, reason: '内存导入已生效（全量写自愈口径）');

      final good =
          await p.importDedup([mk(id: '9002', title: '再导')], [null],
              fingerprint: true);
      expect(good.saved, isTrue);
    });
  });

  group('M18 clearSampleTasks 透传落盘结果（v3.0.8 审计）', () {
    test('失败 → false；正常 → true', () async {
      final p = await buildWith([mk(id: '1'), mk(id: '2')]);
      LocalDatabase.testUseMemory = false;
      bool bad;
      try {
        bad = await p.clearSampleTasks();
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(bad, isFalse,
          reason: 'M18：引导页据此反馈；旧实现 await 但不消费，误报已清空');
      expect(p.tasks, isEmpty, reason: '内存清理已生效（撤提醒先行）');

      // 正常库再清一次 = true（幂等）。
      expect(await p.clearSampleTasks(), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-7：失败提示按「已回滚 / 安全模式」分化（widget）
  // ══════════════════════════════════════════════════════════════════

  group('P3-7 失败提示文案分化（v3.0.8 审计）', () {
    Future<(BuildContext, StateSetter)> pumpScaffold(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ));
      return (captured, ( (_) {} ) as StateSetter);
    }

    testWidgets('新建失败（已回滚）→「新建未生效，请重试」', (tester) async {
      final (ctx, _) = await pumpScaffold(tester);
      showTaskPersistFailedHint(ctx, rolledBack: true);
      await tester.pump();
      expect(find.text('新建未生效，请重试'), findsOneWidget,
          reason: 'P3-7：内存已回滚，通用文案「继续其它操作会自动一并保存」不成立');
    });

    testWidgets('默认（未回滚）→「继续其它操作会自动一并保存」', (tester) async {
      final (ctx, _) = await pumpScaffold(tester);
      showTaskPersistFailedHint(ctx);
      await tester.pump();
      expect(find.textContaining('自动一并保存'), findsOneWidget);
    });

    testWidgets('安全模式 → 不复读「请重试」，提示保护性阻止', (tester) async {
      final p = await safeModeProvider();
      expect(p.dbLoadFailed, isTrue, reason: '前提：已进入只读安全模式');
      final (ctx, _) = await pumpScaffold(tester);
      showTaskPersistFailedHint(ctx, provider: p);
      await tester.pump();
      expect(find.textContaining('安全模式'), findsOneWidget);
      expect(find.textContaining('请重试'), findsNothing,
          reason: '安全模式下「请重试」是错误指引（写入被系统性阻止）');
    });
  });
}

/// M2 用例：把应用文档目录指向临时目录（与 v289 回归测试同口径）。
class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
