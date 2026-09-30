import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/data_health_service.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/services/task_import_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// v2.9.2 功能增强**第二批**（《有条功能增强建议报告（v2.9.2）》T2/T3 系列）
/// 回归测试。T1 系列见 v292_feature_test.dart。
///
/// 覆盖清单（可纯 Dart / 可稳定观测部分）：
/// - **T2-5** 循环暂停/恢复：`pausedToday` / `pausedUntilDate` 派生判定（不加新
///   字段，skipDates 区间既有语义即暂停语义）；`pauseRepeatsUntil` 区间写入、
///   `resumeRepeats` 清未来保历史；
/// - **T3-2** 「完成即撤销」底层契约：toggleDone → restoreTaskSnapshot 快照回滚
///   （status + completedAt 一体还原）。UI 接线（task_toggle_undo.dart）横跨
///   SnackBar timer 链路，按惯例不落回归（timer 型 widget 用例不可稳定驱动）；
/// - **T2-6** CSV 批量导入：RFC 4180 子集解析（BOM/引号/双写转义）、中英表头
///   探测、无表头固定列序兜底、逐行校验（空标题 / 坏日期）、预估时长宽松解析；
/// - **T3-4** 数据体检：`DataHealthService.scan` 纯函数四类问题（重复任务 / 空白
///   子项 / 失效附件引用 / 超期回收站）与健康数据零误报；Provider 侧
///   `fixDataHealthIssues` 一键修复（重复软删可反悔 / 列表剔除）；
/// - **T3-1** 口令提示：明文本机存取、清口令联动清提示、**不进备份白名单**
///   （collectAppPrefs 不带走，钉死「不随备份文件导出」契约）。
///
/// 已知不可稳定钉死的残余（与实现注释共同保障，见各文件）：
/// - 小组件快速新建（T2-4）跨进程路由：Kotlin PendingIntent → MainActivity →
///   widget_nav 通道 → Dart，需真机/集成环境验证（单元层无 AppWidget 宿主）；
/// - 体检修复前 `_writeAutoBackup` 的真实落盘（Documents 目录 IO）；
/// - 超期回收站的彻底删除走 permanentDelete → 附件目录清理（path_provider
///   平台通道），单元层只钉 scan 判定与软删类修复。
void main() {
  _installMocks();

  // ── T2-5：循环暂停 / 恢复 ──────────────────────────────────────
  group('T2-5 循环暂停/恢复', () {
    test('pausedToday：daily 重复 + skipDates 含今天 → true', () {
      final today = _today();
      final t = _repeating(skipDates: [Task.ymdKey(today)]);
      expect(t.pausedToday, isTrue);
    });

    test('pausedToday：未被跳过 / 非重复任务 → false', () {
      final today = _today();
      // daily 重复但今天未被跳过。
      expect(_repeating(skipDates: const []).pausedToday, isFalse);
      // 跳过的是别的日子。
      expect(
        _repeating(
                skipDates: [Task.ymdKey(today.add(const Duration(days: 1)))])
            .pausedToday,
        isFalse,
        reason: '单独跳过未来日不构成「今天已暂停」',
      );
      // 非重复任务即便 skipDates 残留今天（历史数据）也不是暂停态。
      final none = Task(
        id: 't-none',
        title: '一次性',
        priority: Priority.medium,
        category: Category.life,
        skipDates: [Task.ymdKey(today)],
      );
      expect(none.pausedToday, isFalse);
    });

    test('pausedUntilDate：连续跳过区间终点；孤立未来日不撑长区间', () {
      final today = _today();
      final t1 = _repeating(skipDates: [
        Task.ymdKey(today),
        Task.ymdKey(today.add(const Duration(days: 1))),
        Task.ymdKey(today.add(const Duration(days: 2))),
      ]);
      expect(t1.pausedUntilDate, today.add(const Duration(days: 2)),
          reason: '从今天起连续 3 个循环日被跳过，终点 = 今天+2（含当天）');
      // 今天 + 后天被跳过、明天没跳：区间到今天即断（孤立未来日不误撑）。
      final t2 = _repeating(skipDates: [
        Task.ymdKey(today),
        Task.ymdKey(today.add(const Duration(days: 2))),
      ]);
      expect(t2.pausedUntilDate, today);
    });

    test('pauseRepeatsUntil：[today, until] 全部循环日写入 skipDates', () async {
      final p = await _buildWith([
        _repeating(id: 'r1', skipDates: const []),
      ]);
      final until = _today().add(const Duration(days: 2));
      p.pauseRepeatsUntil('r1', until);
      final t = p.tasks.firstWhere((x) => x.id == 'r1');
      final expected = [
        Task.ymdKey(_today()),
        Task.ymdKey(_today().add(const Duration(days: 1))),
        Task.ymdKey(_today().add(const Duration(days: 2))),
      ];
      for (final k in expected) {
        expect(t.skipDates.contains(k), isTrue, reason: '应含 $k');
      }
      expect(t.pausedToday, isTrue);
    });

    test('resumeRepeats：清今天及以后的跳过日，保留历史记录', () async {
      final today = _today();
      final yesterday = today.add(const Duration(days: -1));
      final p = await _buildWith([
        _repeating(id: 'r2', skipDates: [
          Task.ymdKey(yesterday), // 历史（统计口径）
          Task.ymdKey(today), // 今天起为暂停区间
          Task.ymdKey(today.add(const Duration(days: 3))),
        ]),
      ]);
      p.resumeRepeats('r2');
      final t = p.tasks.firstWhere((x) => x.id == 'r2');
      expect(t.skipDates, [Task.ymdKey(yesterday)],
          reason: '恢复 = 整段撤销未来的不出现；历史跳过保留');
      expect(t.pausedToday, isFalse);
    });

    test('非重复任务 pause/resume 幂等无操作', () async {
      final p = await _buildWith([
        Task(
          id: 'n1',
          title: '一次性',
          priority: Priority.low,
          category: Category.life,
        ),
      ]);
      p.pauseRepeatsUntil('n1', _today().add(const Duration(days: 5)));
      p.resumeRepeats('n1');
      expect(p.tasks.single.skipDates, isEmpty);
    });
  });

  // ── T3-2：完成即撤销（底层快照回滚契约）────────────────────────
  group('T3-2 完成即撤销底层契约', () {
    test('toggleDone 后 restoreTaskSnapshot 还原 status 与 completedAt',
        () async {
      final p = await _buildWith([
        Task(
          id: 'u1',
          title: '误触目标',
          priority: Priority.medium,
          category: Category.work,
        ),
      ]);
      final before = p.tasks.single;
      expect(before.done, isFalse);
      expect(before.completedAt, isNull);

      p.toggleDone('u1');
      final done = p.tasks.single;
      expect(done.done, isTrue);
      expect(done.completedAt, isNotNull);

      // 撤销入口的底层动作：整体快照回滚（T3-2 接线统一走这里）。
      expect(p.restoreTaskSnapshot(before), isTrue);
      final restored = p.tasks.single;
      expect(restored.done, isFalse);
      expect(restored.completedAt, isNull,
          reason: '快照回滚必须连 completedAt 一起还原，否则统计侧出现幽灵完成');
    });
  });

  // ── T2-6：CSV 批量导入 ─────────────────────────────────────────
  group('T2-6 CSV 导入解析', () {
    test('BOM 剥除 + 中英混合表头 + 引号内逗号与双写转义', () {
      final csv = '\uFEFF'
          '标题,Due,优先级,Category,Tags,备注,Estimate\n'
          '"买菜（鱼, 虾）",2026-10-01,高,生活,食材,"""带引号""的备注",90分\n';
      final r = parseTasksCsv(csv);
      expect(r.hasErrors, isFalse);
      expect(r.totalRows, 1);
      final t = r.tasks.single;
      expect(t.title, '买菜（鱼, 虾）');
      expect(t.priority, Priority.high);
      expect(t.category, Category.life);
      expect(t.tags, ['食材'], reason: 'Tags 列按表头别名映射对位');
      expect(t.estimateMinutes, 90);
      expect(t.dueDate, DateTime(2026, 10, 1));
      expect(t.note, '"带引号"的备注', reason: 'RFC 4180 双写引号转义还原');
    });

    test('无表头固定列序兜底 + 预估时长宽松解析', () {
      // 首行无任何标题类别名 → 按固定列序：
      // 标题, 截止, 优先级, 分类, 标签, 备注, 预计。
      final csv = '跑步\n'
          '写周报,2026/10/9,低,工作,周报|汇报,,2小时\n';
      final r = parseTasksCsv(csv);
      expect(r.tasks.length, 2);
      expect(r.tasks[0].title, '跑步');
      expect(r.tasks[0].estimateMinutes, isNull);
      final t = r.tasks[1];
      expect(t.title, '写周报');
      expect(t.priority, Priority.low);
      expect(t.category, Category.work);
      expect(t.tags, ['周报', '汇报']);
      expect(t.note, isEmpty, reason: '备注列为空串，与预估列严格对位');
      expect(t.estimateMinutes, 120, reason: '2小时 → 120 分钟');
      expect(t.dueDate, DateTime(2026, 10, 9));
    });

    test('逐行校验：空标题 / 坏日期进 errors 不阻断其余行', () {
      final csv = '标题,截止\n'
          ',2026-10-01\n'
          '正常任务,2026-10-02\n'
          '坏日期,10月猪日\n';
      final r = parseTasksCsv(csv);
      expect(r.totalRows, 3);
      expect(r.tasks.length, 1);
      expect(r.tasks.single.title, '正常任务');
      expect(r.errors.length, 2);
      // 物理行号：表头占第 1 行，数据从第 2 行起。
      expect(r.errors[0].row, 2);
      expect(r.errors[0].reason, contains('标题为空'));
      expect(r.errors[1].row, 4);
      expect(r.errors[1].reason, contains('无法识别'));
    });

    test('预估时长：h/小时/分钟/纯数字与小数', () {
      String est(String cell) {
        final csv = '标题,预计\n任务,$cell\n';
        return parseTasksCsv(csv).tasks.single.estimateMinutes?.toString() ??
            'null';
      }

      expect(est('90'), '90');
      expect(est('90分'), '90');
      expect(est('1.5h'), '90');
      expect(est('2小时'), '120');
      expect(est('abc'), 'null');
      expect(est('0'), 'null', reason: '<1 分钟视为无预估');
    });
  });

  // ── T3-4：数据体检 ─────────────────────────────────────────────
  group('T3-4 数据体检 scan 纯函数', () {
    test('健康数据零误报', () {
      final r = DataHealthService.scan(
        tasks: [
          Task(
            id: 'a',
            title: 'A',
            priority: Priority.medium,
            category: Category.work,
          ),
          Task(
            id: 'b',
            title: 'B',
            priority: Priority.low,
            category: Category.life,
            subtasks: const [SubTask(id: 's1', title: '步骤')],
          ),
        ],
        trash: const [],
        existingAttachmentKeys: {'a/f.png'},
        trashRetentionDays: 30,
        now: DateTime(2026, 10, 1),
      );
      expect(r.isHealthy, isTrue);
    });

    test('四类问题齐发（重复 / 空白子项 / 失效附件 / 超期回收站）', () {
      final now = DateTime(2026, 10, 1);
      final dupKeep = Task(
        id: 'dup-keep',
        title: '重复',
        priority: Priority.medium,
        category: Category.work,
      );
      final dupGone = Task(
        id: 'dup-gone',
        title: '重复',
        priority: Priority.medium,
        category: Category.work,
      );
      final withEmptySub = Task(
        id: 'sub',
        title: '有空子项',
        priority: Priority.medium,
        category: Category.life,
        subtasks: const [
          SubTask(id: 's1', title: '真步骤'),
          SubTask(id: 's2', title: '   '),
        ],
      );
      final noAtt = Task(
        id: 'att',
        title: '无附件',
        priority: Priority.medium,
        category: Category.life,
      );
      final withAtt = Task(
        id: 'att2',
        title: '缺附件',
        priority: Priority.medium,
        category: Category.life,
        attachments: [
          AttachmentRef(
            id: 'at1',
            type: AttachmentType.image,
            fileName: 'x.png',
            sizeBytes: 1,
            createdAt: DateTime(2026, 9, 1),
          ),
        ],
      );
      final staleTrash = Task(
        id: 'trash-old',
        title: '过期回收',
        priority: Priority.medium,
        category: Category.life,
        deletedAt: now.add(const Duration(days: -31)),
      );
      final freshTrash = Task(
        id: 'trash-new',
        title: '新鲜回收',
        priority: Priority.medium,
        category: Category.life,
        deletedAt: now.add(const Duration(days: -1)),
      );
      final r = DataHealthService.scan(
        tasks: [dupKeep, dupGone, withEmptySub, noAtt, withAtt],
        trash: [staleTrash, freshTrash],
        // withAtt 挂的 x.png 实体缺失 → 报失效引用；noAtt 无附件恒健康。
        existingAttachmentKeys: const {},
        trashRetentionDays: 30,
        now: now,
      );
      expect(r.countOf(DataHealthIssueType.duplicateTask), 1);
      final dup = r.issues
          .firstWhere((i) => i.type == DataHealthIssueType.duplicateTask);
      expect(dup.taskId, 'dup-keep', reason: '锚点 = 组内首条（保留）');
      expect(dup.relatedIds, ['dup-gone'], reason: '修复移入回收站的是其余项');
      expect(r.countOf(DataHealthIssueType.emptySubtask), 1);
      expect(r.countOf(DataHealthIssueType.missingAttachment), 1);
      expect(
        r.issues
            .firstWhere((i) => i.type == DataHealthIssueType.missingAttachment)
            .taskId,
        'att2',
      );
      expect(r.countOf(DataHealthIssueType.staleTrash), 1);
      expect(
        r.issues
            .firstWhere((i) => i.type == DataHealthIssueType.staleTrash)
            .taskId,
        'trash-old',
        reason: '新鲜回收条目不应报超期',
      );
      expect(r.isHealthy, isFalse);
      // 保留判据纯函数。
      expect(DataHealthService.keepIdsOfDuplicates(r.issues), {'dup-keep'});
    });

    test('保留期 -1（永不清理）时跳过超期回收站扫描', () {
      final now = DateTime(2026, 10, 1);
      final r = DataHealthService.scan(
        tasks: const [],
        trash: [
          Task(
            id: 'old',
            title: '很久以前',
            priority: Priority.medium,
            category: Category.life,
            deletedAt: DateTime(2020, 1, 1),
          ),
        ],
        existingAttachmentKeys: const {},
        trashRetentionDays: -1,
        now: now,
      );
      expect(r.isHealthy, isTrue);
    });

    test('dropEmptySubtasks / dropMissingAttachments 修复辅助', () {
      final cleaned = DataHealthService.dropEmptySubtasks(const [
        SubTask(id: 's1', title: '保留'),
        SubTask(id: 's2', title: ''),
        SubTask(id: 's3', title: '  '),
      ]);
      expect(cleaned.map((s) => s.id), ['s1']);

      final keys = {'t1/keep.png'};
      final refs = [
        AttachmentRef(
          id: 'a1',
          type: AttachmentType.image,
          fileName: 'keep.png',
          sizeBytes: 1,
          createdAt: DateTime(2026, 9, 1),
        ),
        AttachmentRef(
          id: 'a2',
          type: AttachmentType.file,
          fileName: 'lost.png',
          sizeBytes: 1,
          createdAt: DateTime(2026, 9, 1),
        ),
      ];
      final kept = DataHealthService.dropMissingAttachments(refs, 't1', keys);
      expect(kept.map((a) => a.fileName), ['keep.png']);
    });
  });

  group('T3-4 数据体检 Provider 一键修复', () {
    test('重复任务软删入回收站 + 空白子项剔除 + 失效附件引用剔除', () async {
      final p = await _buildWith([
        Task(
          id: 'd1',
          title: '重复任务',
          priority: Priority.medium,
          category: Category.work,
        ),
        Task(
          id: 'd2',
          title: '重复任务',
          priority: Priority.medium,
          category: Category.work,
        ),
        Task(
          id: 'd3',
          title: '重复任务',
          priority: Priority.medium,
          category: Category.work,
        ),
        Task(
          id: 's1',
          title: '带空子项',
          priority: Priority.medium,
          category: Category.life,
          subtasks: [
            const SubTask(id: 'k1', title: '真步骤'),
            const SubTask(id: 'k2', title: ' '),
          ],
        ),
        Task(
          id: 'a1',
          title: '带失效附件',
          priority: Priority.medium,
          category: Category.life,
          attachments: [
            AttachmentRef(
              id: 'x1',
              type: AttachmentType.image,
              fileName: 'gone.png',
              sizeBytes: 1,
              createdAt: DateTime(2026, 9, 1),
            ),
          ],
        ),
      ]);
      // 测试环境无 path_provider 平台实现：fileFor 抛异常被捕获 → 实体集合为空，
      // 所有附件引用判失效——正好构造出「失效附件」的确定性场景。
      final report = await p.scanDataHealth();
      expect(report.countOf(DataHealthIssueType.duplicateTask), 1);
      expect(report.countOf(DataHealthIssueType.emptySubtask), 1);
      expect(report.countOf(DataHealthIssueType.missingAttachment), 1);

      final fixed = await p.fixDataHealthIssues(report);
      expect(fixed, 3,
          reason: '三类问题各修 1 处（不含超期回收站——彻底删除依赖'
              'path_provider 平台通道，单元层不落）');

      // 重复：保留首条 d1，d2/d3 移入回收站（可反悔）。
      expect(p.tasks.any((t) => t.id == 'd1'), isTrue);
      expect(p.tasks.any((t) => t.id == 'd2'), isFalse);
      expect(p.tasks.any((t) => t.id == 'd3'), isFalse);
      expect(p.trash.any((t) => t.id == 'd2'), isTrue);
      expect(p.trash.any((t) => t.id == 'd3'), isTrue);

      // 空白子项剔除。
      final sub = p.tasks.firstWhere((t) => t.id == 's1');
      expect(sub.subtasks.map((s) => s.id), ['k1']);

      // 失效附件引用剔除（不动附件目录——文件本就不存在）。
      final att = p.tasks.firstWhere((t) => t.id == 'a1');
      expect(att.attachments, isEmpty);
    });
  });

  // ── T3-1：口令提示 ─────────────────────────────────────────────
  group('T3-1 加密备份口令提示', () {
    test('setAutoBackupPassHint 存取 + SharedPreferences 明文落盘读回',
        () async {
      final p = TaskProvider();
      expect(p.autoBackupPassHint, isEmpty);
      await p.setAutoBackupPassHint('  老家的门牌号  ');
      expect(p.autoBackupPassHint, '老家的门牌号', reason: 'trim 后存储');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auto_backup_pass_hint'), '老家的门牌号');
      // 空串 = 清除本机存储。
      await p.setAutoBackupPassHint('');
      expect(p.autoBackupPassHint, isEmpty);
      expect(prefs.containsKey('auto_backup_pass_hint'), isFalse);
    });

    test('清空口令联动清除提示（提示与口令一一对应）', () async {
      final p = TaskProvider();
      await p.setAutoBackupPassHint('提示 A');
      await p.setAutoBackupPassphrase('');
      expect(p.autoBackupPassHint, isEmpty,
          reason: '口令清空后提示失去对应关系，必须一并清掉防误导回忆');
    });

    test('提示键不进备份白名单（collectAppPrefs 不带走 → 不随备份文件导出）',
        () async {
      final p = TaskProvider();
      await p.setAutoBackupPassHint('不该被导出的提示');
      final exported = await collectAppPrefs();
      expect(exported.containsKey('auto_backup_pass_hint'), isFalse,
          reason: 'prefs_backup 白名单为显式枚举制；T3-1 依赖「未列出 = 不导出」'
              '保证提示不进任何备份文件（换机后同样不可得，与口令同口径）');
    });
  });
}

// ── 脚手架 ────────────────────────────────────────────────────────

/// 与 v298_audit_fix_test 同源的 mock 安装 + flutter_secure_storage 通道 mock
/// （setAutoBackupPassphrase('') 走 _secureStore.delete，无平台实现会抛
/// MissingPluginException；DELETE 语义下返回 null 即成功）。
void _installMocks() {
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
}

/// 用受控列表构造 TaskProvider（restoreFromJson 绕过 load()，不起午夜守护定时器）。
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

DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// 构造 daily 重复任务（daily 纯规则恒命中，无需锚点 / 周几注入，跨日期稳定）。
Task _repeating({String id = 'r', List<String> skipDates = const []}) => Task(
      id: id,
      title: '每日循环$id',
      priority: Priority.medium,
      category: Category.life,
      repeat: RepeatType.daily,
      skipDates: skipDates,
    );
