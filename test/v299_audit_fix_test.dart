import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/screens/calendar_screen.dart' show planMinutesOn;
import 'package:todolist/services/data_health_service.dart';
import 'package:todolist/services/gbk_codec.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/schedule_advisor.dart' show kDefaultEstimateMinutes;
import 'package:todolist/services/task_import_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/kanban_board.dart';
import 'test_helpers.dart';

/// v2.9.9 审计修复轮（《有条功能与操作审计报告（v2.9.9）》P1×5 / P2×13 / P3×23）
/// 回归测试。与 v292b（功能增强轮）互补；本文件只钉**可纯 Dart / 可稳定观测**
/// 的契约，每条修复至少一个可区分用例。
///
/// 覆盖清单：
/// - **P1-1** 三表拼接 CSV 的分段识别（skippedSections 如实上报）；
/// - **P1-2 / P3-2** 指纹去重（fingerprint: true 强制口径 + 标题归一）；
/// - **P1-4** `pausedUntil` 显式窗口字段（显式优先 / 过期失效 / repeatUntil 夹取 /
///   fromJson 守卫）；回退推导已被 v292b 覆盖，不重复；
/// - **P1-5 / P2-12** 不可逆删除拆分 + 备份门（快照失败 → StateError 拒绝）；
/// - **P2-1 / P2-2** 导入导出往返字段保真（覆盖合并保留旧值 / 表头别名 / 标签「、」）；
/// - **P2-3** GBK/UTF-16 文本解码链（BOM → 严格 UTF-8 → GBK 查表）；
/// - **P2-5 / P3-3 / P3-4** 暂停窗口的写入夹取、恢复口径、已结束重复守卫；
/// - **P2-8 / P2-9 / P2-11** 日历占时口径（经 calendar_screen 顶层纯函数
///   `planMinutesOn` 直测——widget 层 pump 日历页有持续帧源，会超时，不落）；
/// - **P2-13** 附件探测异常 ≠ 缺失（uncertain 不报失效不剔除；确认缺失照常报修）；
/// - **P3-7** `kanbanWipBlocked` / `kanbanTodoCountOf` 判据钉死；
/// - **P3-11 / P3-12 / P3-13** 重复组计数口径、分组键归一、超期门槛 > 0；
/// - **P3-20** iCal 区间任务 DTSTART 往返。
///
/// 不落回归（按既有惯例 / 无法单元层稳定观测）：
/// UI 接线类（P2-4 isolate 解析、P2-6 弹窗文案、P2-7 批量完成撤销、P3-1 明细
/// 拼接、P3-6 设置入口、P3-9/P3-10 视图渲染、P3-14/P3-15/P3-16/P3-21 文案与
/// 入口、P3-17 XML 命中区、P3-18 Kotlin pending、P3-19/P3-23 角标与文案、
/// P3-22 通知 action）——真机/人工验收，见修复对照表。
void main() {
  _installMocks();

  // ── P1-1：三表拼接 CSV 分段识别 ─────────────────────────────────
  group('P1-1 三表拼接 CSV 分段识别', () {
    test('任务段后遇专注/习惯段表头即止，skippedSections 如实计数', () {
      // 本 App 导出把任务/专注/习惯三表依次拼接（各自带独立表头）。
      final csv = '标题,截止时间,优先级,分类,标签,备注,预计时长(分钟)\n'
          '写周报,2026-10-09,低,工作,,,\n'
          '日期,总时长(分钟),专注任务,开始,结束\n'
          '2026-10-01,25,写周报,10:00,10:25\n'
          '习惯,打卡日,当前连击\n'
          '喝水,2026-10-01,3\n';
      final r = parseTasksCsv(csv);
      expect(r.tasks, hasLength(1), reason: '只解析任务段');
      expect(r.tasks.single.title, '写周报');
      expect(r.skippedSections, 2, reason: '专注段 + 习惯段都被识别并忽略');
      expect(r.errors, isEmpty);
    });

    test('无后续段 → skippedSections 为 0（不误报）', () {
      final csv = '标题\n买菜\n跑步\n';
      final r = parseTasksCsv(csv);
      expect(r.tasks, hasLength(2));
      expect(r.skippedSections, 0);
    });
  });

  // ── P2-2：导入导出往返字段保真 ──────────────────────────────────
  group('P2-2 导入导出往返字段保真', () {
    test('导出表头「预计时长(分钟)」经括号归一后命中别名（往返不再丢预计）', () {
      final csv = '标题,预计时长(分钟)\n读书,45\n';
      final r = parseTasksCsv(csv);
      expect(r.hasErrors, isFalse);
      expect(r.tasks.single.estimateMinutes, 45);
    });

    test('标签「、」连接的导出列可被导入按分隔符还原', () {
      final t = _mk(id: '1', title: '多标签', tags: const ['周报', '汇报']);
      final cells = TaskProvider.taskTableCells(t, deleted: false);
      final tagIdx = TaskProvider.taskTableHeaders.indexOf('标签');
      expect(cells[tagIdx], '周报、汇报', reason: '导出以「、」连接（P2-2②）');
      final csv = '标题,标签\n多标签,${cells[tagIdx]}\n';
      final r = parseTasksCsv(csv);
      expect(r.tasks.single.tags, ['周报', '汇报'], reason: '导入按 、 切回两条');
    });
  });

  // ── P2-3：GBK/UTF-16 文本解码链 ─────────────────────────────────
  group('P2-3 GBK/UTF-16 文本解码链', () {
    test('decodeGbkBytes：ASCII 直通 + GBK 双字节 + 欧元符 + 无效序列', () {
      expect(decodeGbkBytes('task,due\r\n'.codeUnits), 'task,due\r\n');
      // 「中文」= D6 D0 CE C4（CP936，生成脚本同源样例）。
      expect(decodeGbkBytes(const [0xD6, 0xD0, 0xCE, 0xC4]), '中文');
      // 「有条」= D3 D0 CC F5。
      expect(decodeGbkBytes(const [0xD3, 0xD0, 0xCC, 0xF5]), '有条');
      // 0x80 单字节 → €（CP936 扩展）。
      expect(decodeGbkBytes(const [0x80]), '\u20AC');
      // 孤立 lead（D3 后接 ASCII '?'）→ U+FFFD + '?'（宽松语义不抛异常）。
      expect(decodeGbkBytes(const [0xD3, 0x3F]), '\uFFFD?');
      // 尾部孤字节 → U+FFFD。
      expect(decodeGbkBytes(const [0xD6]), '\uFFFD');
    });

    test('decodeTextFileBytes：无 BOM 严格 UTF-8 优先', () {
      final bytes = utf8.encode('标题,Due\n买菜,2026-10-01\n');
      expect(decodeTextFileBytes(bytes), '标题,Due\n买菜,2026-10-01\n');
    });

    test('decodeTextFileBytes：UTF-8 BOM 剥除', () {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('标题\n')];
      expect(decodeTextFileBytes(bytes), '标题\n');
    });

    test('decodeTextFileBytes：UTF-16 LE/BE BOM（含代理对）', () {
      // 「中」U+4E2D → LE 字节 2D 4E。
      expect(decodeTextFileBytes(const [0xFF, 0xFE, 0x2D, 0x4E]), '中');
      // BE：FE FF + 4E 2D。
      expect(decodeTextFileBytes(const [0xFE, 0xFF, 0x4E, 0x2D]), '中');
      // U+1F600 → UTF-16LE：3D D8 00 DE（代理对合成）。
      expect(decodeTextFileBytes(
          const [0xFF, 0xFE, 0x3D, 0xD8, 0x00, 0xDE]), '\u{1F600}');
      // 尾部孤字节 → U+FFFD。
      expect(decodeTextFileBytes(const [0xFF, 0xFE, 0x2D]), '\uFFFD');
    });

    test('decodeTextFileBytes：GBK 回退（Excel 另存 CSV 的真实形态）', () {
      // 「中文」的 GBK 双字节不是合法 UTF-8（lead 后接非续字节）→ 回退。
      expect(decodeTextFileBytes(const [0xD6, 0xD0, 0xCE, 0xC4]), '中文');
    });

    test('GBK CSV 端到端：解码产物可直接被 parseTasksCsv 解析', () {
      // Title,Due\n买,2026-10-01\n（「买」= C2 F2）。
      final bytes = <int>[
        ...'Title,Due\n'.codeUnits,
        0xC2, 0xF2, // 买
        ...',2026-10-01\n'.codeUnits,
      ];
      final r = parseTasksCsv(decodeTextFileBytes(bytes));
      expect(r.hasErrors, isFalse);
      expect(r.tasks.single.title, '买');
      expect(r.tasks.single.dueDate, DateTime(2026, 10, 1));
    });
  });

  // ── P1-4：pausedUntil 显式窗口字段（模型层）─────────────────────
  group('P1-4 pausedUntil 显式窗口字段（模型层）', () {
    test('显式未来窗口 → 暂停中；窗口已过 → 自然恢复', () {
      final today = _today();
      final inWin = _repeating().copyWith(
          pausedUntil: Task.ymdKey(today.add(const Duration(days: 3))));
      expect(inWin.pausedToday, isTrue);
      expect(inWin.pausedUntilDate, today.add(const Duration(days: 3)));
      final expired = _repeating().copyWith(
          pausedUntil: Task.ymdKey(today.add(const Duration(days: -1))));
      expect(expired.pausedToday, isFalse, reason: '窗口过期自然失效');
    });

    test('显式窗口晚于 repeatUntil → 夹到 repeatUntil（P3-3）', () {
      final today = _today();
      final clipped = _repeating()
          .copyWith(
              pausedUntil: Task.ymdKey(today.add(const Duration(days: 30))),
              repeatUntil: Task.ymdKey(today.add(const Duration(days: 5))));
      expect(clipped.pausedUntilDate, today.add(const Duration(days: 5)),
          reason: '重复已结束时暂停不再夸大展示');
      // repeatUntil 本身已过 → 窗口视为无效。
      final ended = _repeating().copyWith(
          pausedUntil: Task.ymdKey(today.add(const Duration(days: 30))),
          repeatUntil: Task.ymdKey(today.add(const Duration(days: -1))));
      expect(ended.pausedUntilDate, isNull);
    });

    test('fromJson 非法 pausedUntil 串被守卫（不抛异常、按无字段处理）', () {
      final src = _repeating()
          .copyWith(pausedUntil: Task.ymdKey(_today().add(const Duration(days: 2))));
      final raw = src.toJson();
      expect(src.pausedToday, isTrue);
      raw['pausedUntil'] = 'garbage!!';
      final back = Task.fromJson(raw);
      expect(back.pausedUntil, isNull, reason: '_sanitizeYmd 正则守卫丢弃非法串');
      expect(back.pausedToday, isFalse);
    });
  });

  // ── P1-2 / P2-1 / P3-2：importDedup 指纹与字段级合并 ─────────────
  group('P1-2/P2-1/P3-2 importDedup 指纹与字段级合并', () {
    test('P1-2/P3-2 指纹去重：同标题异写命中；不同截止不命中', () async {
      final p = await _buildWith([
        _mk(id: '1', title: 'Buy milk', due: DateTime(2026, 10, 1)),
      ]);
      // 大小写 + 首尾空白 + 内部空格差异 → 归一后同指纹（P3-2）→ 跳过不重加。
      final r1 = p.importDedup(
        [_mk(title: '  buy   MILK ', due: DateTime(2026, 10, 1))],
        const [null],
        fingerprint: true,
      );
      expect(r1.skipped, 1, reason: '指纹命中现有任务');
      expect(r1.added, 0);
      expect(p.tasks, hasLength(1));

      // 不同截止 → 指纹不同 → 新增。
      final r2 = p.importDedup(
        [_mk(title: 'buy milk', due: DateTime(2026, 10, 2))],
        const [null],
        fingerprint: true,
      );
      expect(r2.added, 1);
      expect(p.tasks, hasLength(2));
    });

    test('P2-1 覆盖合并：来源为空的字段保留原值（iCal/CSV 往返不丢数据）',
        () async {
      final day = DateTime(2026, 10, 15);
      final p = await _buildWith([
        _mk(
          id: '1',
          title: '写周报',
          due: day,
          note: '重要备注',
          tags: const ['工作'],
          estimate: 30,
          reminderOffsetMin: 15,
          repeat: RepeatType.daily,
        ).copyWith(startDate: DateTime(2026, 10, 10)),
      ]);
      // 来源方（iCal 典型）只有标题 + 截止：note/tags/预计/提醒偏移/区间开始
      // 全部为空，repeat 未携带 → 逐一保留原值。
      final r = p.importDedup(
        [_mk(id: '1', title: '写周报', due: day)],
        const ['1'],
        overwrite: true,
      );
      expect(r.overwritten, 1);
      expect(r.added, 0);
      expect(p.tasks, hasLength(1));
      final t = p.tasks.single;
      expect(t.note, '重要备注', reason: '来源备注为空 → 保留');
      expect(t.tags, ['工作'], reason: '来源标签为空 → 保留');
      expect(t.estimateMinutes, 30, reason: '来源未带预计 → ?? 旧值');
      expect(t.reminderOffsetMin, 15, reason: '来源 0 = 未提供 → 保留');
      expect(t.repeat, RepeatType.daily, reason: '来源无 RRULE → 不降级一次性');
      expect(t.startDate, DateTime(2026, 10, 10), reason: '来源未带开始日 → ?? 旧值');
    });
  });

  // ── P1-5 / P2-12：数据体检不可逆拆分与备份门 ─────────────────────
  group('P1-5/P2-12 数据体检不可逆拆分与备份门', () {
    test('默认可逆修复：不动回收站（P1-5 拆分）', () async {
      final p = await _buildWith(const [], trash: [
        _mk(id: 'trash-old', deletedAt: _today().add(const Duration(days: -31))),
      ]);
      final report = await p.scanDataHealth();
      expect(report.countOf(DataHealthIssueType.staleTrash), 1);
      final fixed = await p.fixDataHealthIssues(report); // includeStaleTrash=false
      expect(fixed, 0, reason: '可逆分支不处理超期回收站');
      expect(p.trash, hasLength(1), reason: '回收站条目原样保留');
    });

    test('P2-12 不可逆分支：备份失败 → StateError 拒绝执行', () async {
      final p = await _buildWith(const [], trash: [
        _mk(id: 'trash-old', deletedAt: _today().add(const Duration(days: -31))),
      ]);
      final report = await p.scanDataHealth();
      // 测试环境无 path_provider 平台实现 → 修复前自动快照必失败 →
      // 正好构造出「无还原依据」的确定性场景。
      await expectLater(
        p.fixDataHealthIssues(report, includeStaleTrash: true),
        throwsStateError,
        reason: '快照未成功必须拒绝「彻底删除」，杜绝无依据的不可逆丢失',
      );
      // 拒绝后数据原样（StateError 在任何写动作之前抛出）。
      expect(p.trash, hasLength(1));
    });
  });

  // ── P2-5 / P3-3 / P3-4：暂停窗口写入与恢复 ───────────────────────
  group('P2-5/P3-3/P3-4 暂停窗口写入与恢复', () {
    test('P2-5 恢复只清暂停窗口：区间内键清空、显式字段复位', () async {
      final p = await _buildWith([_repeating(id: 'r1', skipDates: const [])]);
      final until = _today().add(const Duration(days: 5));
      final eff = p.pauseRepeatsUntil('r1', until);
      expect(eff, until, reason: '正常场景生效终点 = 指定日');
      expect(p.tasks.single.pausedToday, isTrue);
      p.resumeRepeats('r1');
      final t = p.tasks.single;
      expect(t.skipDates, isEmpty, reason: '窗口 [今天..until] 内的键全部清空');
      expect(t.pausedUntil, isNull, reason: 'P1-4 显式窗口字段随恢复一并清除');
      expect(t.pausedToday, isFalse);
    });

    test('P3-3 暂停「直到」晚于重复结束日 → 夹到 repeatUntil', () async {
      final untilRepeat = _today().add(const Duration(days: 10));
      final p = await _buildWith([
        _repeating(id: 'r2', skipDates: const [])
            .copyWith(repeatUntil: Task.ymdKey(untilRepeat)),
      ]);
      final eff =
          p.pauseRepeatsUntil('r2', _today().add(const Duration(days: 100)));
      expect(eff, untilRepeat, reason: '生效终点被夹到重复结束日');
      final t = p.tasks.single;
      expect(t.pausedUntil, Task.ymdKey(untilRepeat));
      // skipDates 只写到 repeatUntil（今天..repeatUntil 共 11 个循环日）。
      expect(t.skipDates, hasLength(11));
      expect(t.skipDates, contains(Task.ymdKey(untilRepeat)));
      expect(
        t.skipDates,
        isNot(contains(Task.ymdKey(
            untilRepeat.add(const Duration(days: 1))))),
        reason: '重复结束日之后不再空写跳过键',
      );
    });

    test('P3-4 已结束重复：pause 幂等返回 null、不产生副作用', () async {
      final p = await _buildWith([
        _repeating(id: 'r3', skipDates: const []).copyWith(
            repeatUntil:
                Task.ymdKey(_today().add(const Duration(days: -1)))),
      ]);
      final eff =
          p.pauseRepeatsUntil('r3', _today().add(const Duration(days: 3)));
      expect(eff, isNull, reason: '重复已结束 → 不空写暂停窗口');
      final t = p.tasks.single;
      expect(t.skipDates, isEmpty);
      expect(t.pausedUntil, isNull);
    });
  });

  // ── P3-11 / P3-12：重复任务分组与计数 ────────────────────────────
  group('P3-11/P3-12 重复任务分组与计数', () {
    test('P3-12 分组键归一：trim/大小写/内部空白折叠后同组', () {
      final a = _mk(id: '1', title: '买菜');
      final b = _mk(id: '2', title: '  买菜  ');
      final c = _mk(id: '3', title: 'Buy   Milk');
      final d = _mk(id: '4', title: 'buy milk');
      expect(DataHealthService.duplicateKeyOf(a),
          DataHealthService.duplicateKeyOf(b));
      expect(DataHealthService.duplicateKeyOf(c),
          DataHealthService.duplicateKeyOf(d));
      // 分类不同不并组。
      final e = _mk(id: '5', title: '买菜', category: Category.life);
      expect(DataHealthService.duplicateKeyOf(a),
          isNot(DataHealthService.duplicateKeyOf(e)));
    });

    test('P3-11 修复计数 = 实际移入回收站条数（4 条同标题 → fixed=3）', () async {
      final p = await _buildWith([
        _mk(id: 'd1', title: '重复'),
        _mk(id: 'd2', title: '重复'),
        _mk(id: 'd3', title: '重复'),
        _mk(id: 'd4', title: '重复'),
      ]);
      final report = await p.scanDataHealth();
      expect(report.countOf(DataHealthIssueType.duplicateTask), 1);
      expect(report.issues.single.relatedIds, ['d2', 'd3', 'd4']);
      final fixed = await p.fixDataHealthIssues(report);
      expect(fixed, 3, reason: 'P3-11：按 relatedIds.length 计，不再一组只计 1');
      expect(p.tasks.single.id, 'd1', reason: '锚点（组内首条）保留');
      expect(p.trash, hasLength(3));
    });
  });

  // ── P2-13：附件探测异常 ≠ 缺失 ──────────────────────────────────
  group('P2-13 附件探测异常分离', () {
    final now = DateTime(2026, 10, 1);
    AttachmentRef ref(String name) => AttachmentRef(
          id: 'a-$name',
          type: AttachmentType.image,
          fileName: name,
          sizeBytes: 1,
          createdAt: DateTime(2026, 9, 1),
        );

    test('uncertain（探测异常）不报失效、修复时保留', () {
      final t = Task(
        id: 't1',
        title: '带附件',
        priority: Priority.medium,
        category: Category.life,
        attachments: [ref('a.png'), ref('b.png')],
      );
      final r = DataHealthService.scan(
        tasks: [t],
        trash: const [],
        existingAttachmentKeys: const {'t1/a.png'},
        uncertainAttachmentKeys: const {'t1/b.png'},
        trashRetentionDays: 30,
        now: now,
      );
      expect(r.countOf(DataHealthIssueType.missingAttachment), 0,
          reason: '探测异常 ≠ 缺失：uncertain 引用不判失效');
      final kept = DataHealthService.dropMissingAttachments(
          t.attachments, 't1', const {'t1/a.png'},
          uncertainKeys: const {'t1/b.png'});
      expect(kept.map((a) => a.fileName), ['a.png', 'b.png'],
          reason: '修复绝不基于一次失败的探测删数据');
    });

    test('确认缺失（探测成功且实体不在）仍正常报修', () {
      final t = Task(
        id: 't1',
        title: '带附件',
        priority: Priority.medium,
        category: Category.life,
        attachments: [ref('a.png'), ref('b.png')],
      );
      final r = DataHealthService.scan(
        tasks: [t],
        trash: const [],
        existingAttachmentKeys: const {'t1/a.png'},
        trashRetentionDays: 30,
        now: now,
      );
      expect(r.countOf(DataHealthIssueType.missingAttachment), 1,
          reason: 'b.png 确认缺失 → 照常报失效（P2-13 只豁免探测异常）');
      final cleaned = DataHealthService.dropMissingAttachments(
          t.attachments, 't1', const {'t1/a.png'});
      expect(cleaned.map((a) => a.fileName), ['a.png']);
    });
  });

  // ── P3-13：超期回收站门槛 > 0 ───────────────────────────────────
  group('P3-13 超期回收站门槛', () {
    test('保留期 0 时不扫描（防 0 被误当「永不清理」时 cutoff=now 全判超期）', () {
      final now = DateTime(2026, 10, 1);
      final r = DataHealthService.scan(
        tasks: const [],
        trash: [
          Task(
            id: 'x',
            title: '很久以前',
            priority: Priority.medium,
            category: Category.life,
            deletedAt: DateTime(2026, 1, 1),
          ),
        ],
        existingAttachmentKeys: const {},
        trashRetentionDays: 0,
        now: now,
      );
      expect(r.isHealthy, isTrue, reason: 'retention=0 与 -1 同为不清理语义，不扫描');
    });
  });

  // ── P3-7：看板 WIP 判据 ─────────────────────────────────────────
  group('P3-7 看板 WIP 判据', () {
    test('kanbanWipBlocked：达到上限拦、未达不拦、limit<=0 恒不拦（P1-3 全局口径）',
        () {
      expect(kanbanWipBlocked(2, 2), isTrue, reason: '已达上限 → 拦截');
      expect(kanbanWipBlocked(1, 2), isFalse);
      expect(kanbanWipBlocked(2, 0), isFalse, reason: '0 = 不限');
      expect(kanbanWipBlocked(5, -1), isFalse, reason: '负值同不限');
    });

    test('kanbanTodoCountOf：与待办泳道同口径（未删 + todo）', () async {
      final p = await _buildWith([
        _mk(id: '1', title: '待办1'),
        _mk(id: '2', title: '待办2'),
        _mk(id: '3', title: '已完成',
            status: TaskStatus.done, completedAt: _today()),
        _mk(id: '5', title: '已删', deletedAt: _today()),
      ]);
      expect(kanbanTodoCountOf(p), 2);
    });
  });

  // ── P3-20：iCal 区间任务 DTSTART 往返 ────────────────────────────
  group('P3-20 iCal 区间任务 DTSTART 往返', () {
    test('导出：span 任务写 DTSTART;VALUE=DATE 且位于 DUE 之前', () {
      final span = _mk(id: '1', title: '区间任务',
              due: DateTime(2026, 10, 18, 12, 0))
          .copyWith(startDate: DateTime(2026, 10, 15));
      final ics = exportIcs([span]);
      final iDt = ics.indexOf('DTSTART;VALUE=DATE:20261015');
      final iDue = ics.indexOf('DUE:20261018T120000');
      expect(iDt, greaterThanOrEqualTo(0), reason: '开始日落进 .ics（此前完全丢失）');
      expect(iDue, greaterThan(iDt), reason: 'DTSTART 位于 DUE 之前');
    });

    test('导入：DUE 存在时 DTSTART 解析为 startDate（不再当落点）', () {
      final r = parseIcs('BEGIN:VCALENDAR\nVERSION:2.0\n'
          'BEGIN:VTODO\n'
          'SUMMARY:区间\n'
          'DTSTART;VALUE=DATE:20261015\n'
          'DUE:20261018T120000\n'
          'END:VTODO\n'
          'END:VCALENDAR\n');
      expect(r.tasks, hasLength(1));
      final t = r.tasks.single;
      expect(t.startDate, DateTime(2026, 10, 15), reason: 'P3-20：开始日恢复');
      expect(t.dueDate, DateTime(2026, 10, 18, 12, 0),
          reason: 'DUE 优先语义不变');
    });

    test('导入：仅 DTSTART（无 DUE）维持旧口径回退当落点', () {
      final r = parseIcs('BEGIN:VCALENDAR\nVERSION:2.0\n'
          'BEGIN:VTODO\n'
          'SUMMARY:只有开始\n'
          'DTSTART;VALUE=DATE:20261015\n'
          'END:VTODO\n'
          'END:VCALENDAR\n');
      final t = r.tasks.single;
      expect(t.dueDate, DateTime(2026, 10, 15));
      expect(t.startDate, isNull, reason: '无 DUE 时不重复解释为开始日');
    });

    test('导出→导入往返：区间起点与截止都还原', () {
      final span = _mk(id: '42', title: '往返',
              due: DateTime(2026, 10, 18, 12, 0))
          .copyWith(startDate: DateTime(2026, 10, 15));
      final back = parseIcs(exportIcs([span]));
      expect(back.tasks.single.startDate, DateTime(2026, 10, 15));
      expect(back.tasks.single.dueDate, DateTime(2026, 10, 18, 12, 0));
    });
  });

  // ── P2-8 / P2-9 / P2-11：日历占时口径 ───────────────────────────
  group('P2-8/P2-9/P2-11 日历占时口径', () {
    // planMinutesOn 等已上提为 calendar_screen.dart 顶层纯函数
    //（provider + date → 结果），纯 Dart 直测——widget 层 pump 日历页存在
    // 持续帧源（pumpAndSettle / 固定 pump 均曾 10 分钟超时），不再经 UI。
    test('兜底 30 分钟 / 区间仅首日计入 / 暂停重复被过滤 / 完成不计', () async {
      final day = DateTime(2026, 10, 15);
      final p = await _buildWith([
        // 当天到期、无预估 → kDefaultEstimateMinutes 兜底（P2-8）。
        _mk(id: 'a', title: '无预估',
            due: DateTime(2026, 10, 15, 9, 0)),
        // 当天到期、预估 45。
        _mk(id: 'b', title: '有预估',
            due: DateTime(2026, 10, 15, 10, 0), estimate: 45),
        // 当天到期但已完成 → 不计。
        _mk(id: 'c', title: '已完成',
            due: DateTime(2026, 10, 15, 11, 0),
            status: TaskStatus.done,
            completedAt: DateTime(2026, 10, 15, 12, 0)),
        // 区间任务 15~17、预估 60 → 首日（15）计 60（P2-9）。
        _mk(id: 'd', title: '区间', estimate: 60)
            .copyWith(
                startDate: DateTime(2026, 10, 15),
                dueDate: DateTime(2026, 10, 17)),
        // daily 重复 + dueDate 落在当天 + skipDates 含当天 → 被 P2-11 过滤。
        _repeating(id: 'e', skipDates: [Task.ymdKey(day)])
            .copyWith(dueDate: DateTime(2026, 10, 15, 9, 30)),
      ]);
      final plan15 = planMinutesOn(p, day);
      expect(plan15, kDefaultEstimateMinutes + 45 + 60,
          reason: '兜底 30（P2-8）+ 预估 45 + 区间首日 60（P2-9）；'
              '完成不计、暂停/已跳过的重复不计（P2-11）');
      final plan16 = planMinutesOn(p, DateTime(2026, 10, 16));
      expect(plan16, 0, reason: 'P2-9：区间次日不再重复计入完整预估');
    });
  });
}

// ── 脚手架 ────────────────────────────────────────────────────────

/// 与 v292b 同源的 mock 安装（内存库 + prefs 内存实现 + 通知/安全存储通道 mock）。
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
Future<TaskProvider> _buildWith(List<Task> tasks, {List<Task>? trash}) async {
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

DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// 构造 daily 重复任务（daily 纯规则恒命中，无需锚点 / 周几注入，跨日期稳定）。
Task _repeating({String id = 'r', List<String> skipDates = const []}) => Task(
      id: id,
      title: '每日任务',
      priority: Priority.medium,
      category: Category.work,
      repeat: RepeatType.daily,
      skipDates: skipDates,
    );

/// 最小一次性任务工厂（title/priority/category 必填，其余按需）。
Task _mk({
  String id = '',
  String title = '任务',
  DateTime? due,
  int? estimate,
  TaskStatus status = TaskStatus.todo,
  DateTime? completedAt,
  Category category = Category.work,
  String note = '',
  List<String> tags = const [],
  int reminderOffsetMin = 0,
  RepeatType repeat = RepeatType.none,
  DateTime? deletedAt,
}) =>
    Task(
      id: id,
      title: title,
      priority: Priority.medium,
      category: category,
      dueDate: due,
      status: status,
      completedAt: completedAt,
      note: note,
      tags: tags,
      estimateMinutes: estimate,
      reminderOffsetMin: reminderOffsetMin,
      repeat: repeat,
      deletedAt: deletedAt,
    );
