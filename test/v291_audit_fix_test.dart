import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/csv_safe.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/services/update_checker.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/kanban_board.dart';
import 'test_helpers.dart';

/// v2.9.1 审计修复回归：P2-1（完成 / 跳过互斥横向推广）、P2-2（iCal 转义单趟解码）、
/// P2-4（BYDAY MO-SU 不得误判工作日）、P2-5（CSV BOM）、P2-6（导出补列）、
/// P3-1（导出 DUE 自提醒未过起算）、P3-5（属性值不 trim）、P3-6（WEEKLY 无 BYDAY）、
/// P3-7（秒级 TRIGGER 取最近分钟 + 重复提醒迁移统计）、P3-8（BOM/NBSP 补单引号）、
/// P3-9（泳道宽度 gap 口径）、P3-10（MD 不套 csvCell）、P3-11（标签同频稳定排序）、
/// P3-13（清单字段 toString 容错）。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控列表构造 Provider（绕过 load()，避免启动午夜守护定时器）。
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

Task mk(
  String id, {
  String? title,
  DateTime? due,
  RepeatType repeat = RepeatType.none,
  List<int> weekdays = const [],
  int? repeatMinute,
  String? until,
  int offset = 0,
  List<String> tags = const [],
  String note = '',
}) =>
    Task(
      id: id,
      title: title ?? 'T$id',
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
      repeat: repeat,
      repeatWeekdays: weekdays,
      repeatMinute: repeat == RepeatType.none ? null : repeatMinute,
      repeatUntil: until,
      reminderOffsetMin: offset,
      tags: tags,
      note: note,
    );

/// 把「BEGIN:VTODO …」块包成完整 .ics（CRLF，贴合 RFC 5545）。
String icsOf(String body) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//t//CN\r\n'
    '$body\r\nEND:VCALENDAR\r\n';

String _ymd(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

void main() {
  setUpAll(_installMocks);

  // ─────────────────────────────────────────────────────────────
  group('P2-1 完成 / 跳过互斥（横向推广到全部入口）', () {
    test('首页勾选完成（toggleDone）会清掉当日的「跳过一次」', () async {
      final now = DateTime.now();
      final p = await buildWith([
        mk('1', repeat: RepeatType.daily, repeatMinute: 7 * 60),
      ]);
      p.skipOccurrence('1');
      expect(p.byId('1')!.skipDates, contains(Task.ymdKey(now)),
          reason: '先跳过今天');

      p.toggleDone('1');
      final t = p.byId('1')!;
      expect(t.doneDates, contains(Task.ymdKey(now)));
      expect(t.skipDates, isEmpty,
          reason: '完成与跳过互斥：同日不得双态并存（否则撤销跳过后仍判为已完成）');
    });

    test('看板 setStatus(done) 同样清掉当日跳过', () async {
      final now = DateTime.now();
      final p = await buildWith([
        mk('1', repeat: RepeatType.daily, repeatMinute: 7 * 60),
      ]);
      p.skipOccurrence('1');
      p.setStatus('1', TaskStatus.done);
      final t = p.byId('1')!;
      expect(t.done, isTrue);
      expect(t.skipDates, isEmpty);
      expect(t.isDoneOn(now), isTrue);
    });

    test('反向：跳过某日会撤销该日的完成记录并复位今日完成态', () async {
      final now = DateTime.now();
      final p = await buildWith([
        mk('1', repeat: RepeatType.daily, repeatMinute: 7 * 60),
      ]);
      p.toggleDone('1'); // 今天已完成
      expect(p.byId('1')!.done, isTrue);

      p.skipOccurrence('1');
      final t = p.byId('1')!;
      expect(t.skipDates, contains(Task.ymdKey(now)));
      expect(t.doneDates, isEmpty, reason: '互斥：跳过当天必须撤销完成记录');
      expect(t.done, isFalse, reason: '完成态必须复位，否则提醒不回弹');
      expect(t.completedAt, isNull);
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('P2-2 iCal 转义单趟解码（字面反斜杠序列往返不损坏）', () {
    test('标题含字面 \\n / \\t / \\\\ 时导出 → 导入完全还原', () {
      const raw = r'a\nb\tc\\d';
      final ics = exportIcs([mk('1', title: raw)]);
      final back = parseIcs(ics);
      expect(back.tasks.single.title, raw,
          reason: '两趟 replaceAll 会把字面 \\n 变成真换行，单趟左到右解码不会');
    });

    test('真换行仍按换行还原（RFC 5545 \\N 语义不受影响）', () {
      final ics = exportIcs([mk('1', title: '第一行\n第二行')]);
      expect(parseIcs(ics).tasks.single.title, '第一行\n第二行');
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('P2-4 / P3-6 周重复 BYDAY 判定', () {
    test('BYDAY=MO,TU,WE,TH,FR,SA,SU（7 天全选）不得被误判为「仅工作日」', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:全周\r\n'
          'DUE:20260921T090000\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU\r\n'
          'END:VTODO'));
      final t = r.tasks.single;
      expect(t.repeat, RepeatType.weekly);
      expect(t.repeatWeekdays.toSet(), {1, 2, 3, 4, 5, 6, 7},
          reason: '周六日不得静默丢失');
      expect(t.repeatsOn(DateTime(2026, 9, 26)), isTrue, reason: '2026-09-26 是周六');
    });

    test('BYDAY 恰好等于 MO-FR 时仍映射为「仅工作日」', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:工作日\r\n'
          'DUE:20260921T090000\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR\r\n'
          'END:VTODO'));
      expect(r.tasks.single.repeat, RepeatType.weekday);
    });

    test('FREQ=WEEKLY 不带 BYDAY：以 DUE 的周几为锚（不再默认周一）', () {
      // 2026-09-23 是周三
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:x\r\n'
          'DUE:20260923T090000\r\nRRULE:FREQ=WEEKLY\r\nEND:VTODO'));
      final t = r.tasks.single;
      expect(t.repeat, RepeatType.weekly);
      expect(t.repeatWeekdays, [DateTime.wednesday]);
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('P3-1 导出 DUE 自「提醒未过」起算', () {
    test('每天 00:00 的任务（今天该时刻已过）导出 DUE 落在明天而非今天', () {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final ics = exportIcs([
        mk('1', repeat: RepeatType.daily, repeatMinute: 0),
      ]);
      expect(ics.contains('DUE:${_ymd(tomorrow)}T000000'), isTrue,
          reason: '今天 00:00 的落点已过，第三方日历不应立刻补响过期提醒');
    });

    test('每天 23:59 的任务（今天该时刻未过）导出 DUE 仍落在今天', () {
      final now = DateTime.now();
      // 若当前已过 23:59（即 23:59:xx），跳过本断言避免边界抖动。
      final passed = now.hour == 23 && now.minute == 59;
      final ics = exportIcs([
        mk('1', repeat: RepeatType.daily, repeatMinute: 23 * 60 + 59),
      ]);
      if (!passed) {
        expect(ics.contains('DUE:${_ymd(now)}T235900'), isTrue);
      }
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('P3-5 / P3-7 属性值与提醒解析', () {
    test('属性值首尾空白不被削掉（RFC 值内空白有意义）', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:  foo\r\n'
          'DUE:20260920T090000\r\nEND:VTODO'));
      expect(r.tasks.single.title, '  foo');
    });

    test('秒级 TRIGGER 取最近分钟：-PT90S → 2 分钟（而非向下取整的 1）', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:x\r\n'
          'DUE:20260920T090000\r\nTRIGGER:-PT90S\r\nEND:VTODO'));
      expect(r.tasks.single.reminderOffsetMin, 2);
    });

    test('-PT30S 不再被吞成「准点提醒」（取最近分钟 = 1）', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:x\r\n'
          'DUE:20260920T090000\r\nTRIGGER:-PT30S\r\nEND:VTODO'));
      expect(r.tasks.single.reminderOffsetMin, 1);
    });

    test('重复任务 + 非零提前量：如实计入「提醒未迁移」而非「已迁移」', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:x\r\n'
          'DUE:20260920T070000\r\nRRULE:FREQ=DAILY\r\n'
          'TRIGGER:-PT30M\r\nEND:VTODO'));
      expect(r.reminderMigrated, 0);
      expect(r.reminderDropped, 1);
      expect(r.tasks.single.repeatMinute, isNull);
    });

    test('重复任务 + PT0S：回填 repeatMinute 并计入「已迁移」', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:x\r\n'
          'DUE:20260920T070000\r\nRRULE:FREQ=DAILY\r\n'
          'TRIGGER:PT0S\r\nEND:VTODO'));
      expect(r.tasks.single.repeatMinute, 7 * 60);
      expect(r.reminderMigrated, 1);
      expect(r.reminderDropped, 0);
    });

    test('VALARM 的 DESCRIPTION 不得顶替成任务备注（往返污染）', () {
      final ics = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:9@youtiao\r\n'
          'SUMMARY:晨跑\r\nDUE:20260920T070000\r\n'
          'BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:晨跑\r\n'
          'TRIGGER:PT0S\r\nEND:VALARM\r\nEND:VTODO\r\nEND:VCALENDAR\r\n';
      final t = parseIcs(ics).tasks.single;
      expect(t.note, isEmpty, reason: '提醒段的 DESCRIPTION 不是任务备注');
      expect(t.title, '晨跑');
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('P2-5 / P2-6 / P3-8 / P3-10 导出链路', () {
    test('CSV 文件首字节为 UTF-8 BOM（withUtf8Bom 幂等）', () {
      final csv = withUtf8Bom('标题,优先级\n');
      expect(csv.codeUnitAt(0), 0xFEFF);
      expect(withUtf8Bom(csv), csv, reason: '已带 BOM 不得重复补');
      expect(utf8.encode(csv).sublist(0, 3), [0xEF, 0xBB, 0xBF],
          reason: '落盘字节必须是 EF BB BF');
    });

    test('CSV 表头补齐 P2-6 列（备注 / 标签 / 子任务 / 重复规则 / 提醒 / 累计专注）', () async {
      final p = await buildWith([mk('1')]);
      final header = p.exportCsv().split('\n').first;
      for (final h in const [
        '标题',
        '优先级',
        '分类',
        '截止时间',
        '状态',
        '完成时间',
        '是否已删除',
        '开始时间',
        '备注',
        '标签',
        '子任务',
        '重复规则',
        '提醒',
        '累计专注(分钟)',
        '附件',
      ]) {
        expect(header.contains(h), isTrue, reason: '缺少列：$h');
      }
    });

    test('CSV 数据行携带标签 / 备注 / 子任务 / 提醒口径', () async {
      final p = await buildWith([
        Task(
          id: '1',
          title: '周会',
          priority: Priority.high,
          category: Category.work,
          dueDate: DateTime(2026, 9, 20, 10, 0),
          reminderOffsetMin: 30,
          tags: const ['会议', '团队'],
          note: '带上下线\n第二行',
          subtasks: const [
            SubTask(id: 's1', title: 'a', done: true),
            SubTask(id: 's2', title: 'b'),
          ],
        ),
      ]);
      final row = p.exportCsv().split('\n')[1];
      // 改口径（v2.9.9 审计 P2-2）：导出标签分隔符由空格改为「、」——导入解析
      // 只按 ,，、;；/| 切分，空格连接的多标签导回后被并成一条（往返丢数据）。
      expect(row.contains('会议、团队'), isTrue, reason: '标签列（、「」连接可被导入拆回）');
      expect(row.contains('带上下线 第二行'), isTrue, reason: '备注换行需归一为空格');
      expect(row.contains('1/2'), isTrue, reason: '子任务进度');
      expect(row.contains('提前 30 分钟'), isTrue, reason: '提醒提前量');
    });

    test('Markdown 导出不再套用 csvCell（= 开头标题不被加单引号）', () async {
      final p = await buildWith([mk('1', title: '=SUM(A1)')]);
      final md = p.exportMarkdown();
      expect(md.contains('- [ ] =SUM(A1)'), isTrue,
          reason: 'MD 无公式执行面，不得污染可读副本');
      expect(md.contains("'=SUM(A1)"), isFalse, reason: '不得前置单引号');
      // 同一份数据在 CSV 里仍必须被当成公式注入防住（口径不能一起放松）。
      expect(p.exportCsv().contains("'=SUM(A1)"), isTrue);
    });

    test('csvCell 剥离集覆盖 BOM 与 NBSP（前导 Unicode 空白后接公式也要补单引号）', () {
      expect(csvCell('\uFEFF=evil'), startsWith("'"));
      expect(csvCell('\u00A0=1+1'), startsWith("'"));
      expect(csvCell('\u3000@SUM(1)'), startsWith("'"));
      expect(csvCell('=1+1'), startsWith("'"));
      expect(csvCell('正常文本'), '正常文本');
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('P3-9 / P3-11 看板', () {
    test('kanbanLaneWidthFor 扣掉的是「列数」份 margin（未夹取时整行不溢出）', () {
      // 1000dp / 4 列：(1000 - 8*4)/4 = 242，整行 = 4*(242+8) = 1000。
      final w = kanbanLaneWidthFor(1000, 4);
      expect(w, closeTo(242, 0.001));
      expect(w * 4 + 8 * 4, closeTo(1000, 0.001));
      // 窄屏仍走基准宽
      expect(kanbanLaneWidthFor(400, 4), 220);
      // 夹取上限
      expect(kanbanLaneWidthFor(2000, 2), 280);
    });

    test('标签同频时按字典序次级排序（顺序完全确定）', () {
      final tasks = [
        mk('1', tags: const ['beta', 'alpha']),
        mk('2', tags: const ['beta']),
        mk('3', tags: const ['alpha']),
        mk('4', tags: const ['gamma']),
        mk('5'), // 无标签 → 归入「其他」
      ];
      final lanes = buildKanbanLanes(KanbanGroupMode.tag, tasks);
      final titles = lanes.map((l) => l.title).toList();
      expect(titles, ['alpha', 'beta', 'gamma', '其他'],
          reason: 'alpha 与 beta 同频（各 2），必须按字典序而不是依赖 sort 的内部顺序');
      expect(lanes.fold<int>(0, (a, l) => a + l.tasks.length), tasks.length,
          reason: '每个任务恰好归入一条泳道');
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('P3-13 清单字段容错读取', () {
    test('version 写成 JSON 数字时返回 null 而非抛 TypeError', () {
      expect(UpdateChecker.parseManifest(const {'version': 2.9}), isNull);
      expect(
        UpdateChecker.parseManifest(const {'version': 2026}),
        isNull,
      );
    });

    test('apkSha256 / tag 写成非字符串时不崩溃，只按形态判定丢弃', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.9.2',
        'apkSha256': 12345,
        'tag': 20260919,
      });
      expect(info, isNotNull);
      expect(info!.apkSha256, isNull, reason: '非字符串哈希形态非法 → 丢弃');
      expect(info.tagName, '20260919', reason: 'tag 走 toString + 字符集净化');
    });
  });
}
