import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/kanban_board.dart';
import 'test_helpers.dart';

/// v2.9.0 审计修复回归：P2-1（iCal 提醒段）/ P3-2（预览窗口口径）/
/// P3-3（跳过与完成互斥）/ P3-4（看板视图偏好）/ U3（已结束重复角标）/
/// U4（宽屏泳道宽度自适应）。
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
  DateTime? due,
  RepeatType repeat = RepeatType.none,
  int? repeatMinute,
  String? until,
  int offset = 0,
}) =>
    Task(
      id: id,
      title: 'T$id',
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
      repeat: repeat,
      repeatMinute: repeat == RepeatType.none ? null : repeatMinute,
      repeatUntil: until,
      reminderOffsetMin: offset,
    );

/// 把「BEGIN:VTODO …」块包成完整 .ics（CRLF，贴合 RFC 5545）。
String icsOf(String body) =>
    'BEGIN:VCALENDAR\r\n$body\r\nEND:VCALENDAR\r\n';

void main() {
  setUp(_installMocks);

  group('P2-1 iCal 提醒段（导出侧）', () {
    test('非重复任务按 reminderOffsetMin 导出 VALARM（提前 30 分钟）', () {
      final ics = exportIcs([mk('1', due: DateTime(2026, 9, 20, 9, 0), offset: 30)]);
      expect(ics.contains('BEGIN:VALARM'), isTrue);
      expect(ics.contains('ACTION:DISPLAY'), isTrue);
      expect(ics.contains('TRIGGER:-PT30M'), isTrue);
      // 提醒段必须落在 VTODO 内部（END:VTODO 之前）。
      expect(ics.indexOf('BEGIN:VALARM'), lessThan(ics.indexOf('END:VTODO')));
    });

    test('准时提醒写零时长 PT0S（不写非法形态 -PT0M）', () {
      final ics = exportIcs([mk('1', due: DateTime(2026, 9, 20, 9, 0))]);
      expect(ics.contains('TRIGGER:PT0S'), isTrue);
      expect(ics.contains('-PT0M'), isFalse);
    });

    test('重复任务：DUE 落在「今天（首个循环日）+ repeatMinute」，提醒随落点触发', () {
      final ics = exportIcs([mk('1', repeat: RepeatType.daily, repeatMinute: 7 * 60)]);
      final now = DateTime.now();
      final ymd = '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      expect(ics.contains('DUE:${ymd}T070000'), isTrue,
          reason: '重复任务的 DUE 应为首个循环日 + repeatMinute');
      expect(ics.contains('TRIGGER:PT0S'), isTrue);
      expect(ics.contains('RRULE:FREQ=DAILY'), isTrue);
    });

    test('已结束重复（366 天内无循环日）不写提醒段，也不写 DUE', () {
      final ics = exportIcs([
        mk('1', repeat: RepeatType.daily, repeatMinute: 7 * 60, until: '2020-01-01'),
      ]);
      expect(ics.contains('BEGIN:VALARM'), isFalse);
      expect(ics.contains('DUE:'), isFalse);
    });

    test('无截止时间的一次性任务不写提醒段', () {
      final ics = exportIcs([mk('1')]);
      expect(ics.contains('BEGIN:VALARM'), isFalse);
    });
  });

  group('P2-1 iCal 提醒段（导入侧）', () {
    test('VALARM 的 TRIGGER 回填 reminderOffsetMin', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nUID:1@youtiao\r\nSUMMARY:开会\r\n'
          'DUE:20260920T090000\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\n'
          'TRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VTODO'));
      expect(r.tasks.single.reminderOffsetMin, 15);
      expect(r.reminderMigrated, 1);
      expect(r.reminderDropped, 0);
    });

    test('零时长 TRIGGER:PT0S 迁移为 0（准时提醒）', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:x\r\nDUE:20260920T090000\r\n'
          'TRIGGER:PT0S\r\nEND:VTODO'));
      expect(r.tasks.single.reminderOffsetMin, 0);
      expect(r.reminderMigrated, 1);
      expect(r.reminderDropped, 0);
    });

    test('天 / 小时混合时长（-P1DT2H）解析为 1560 分钟', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:x\r\nDUE:20260920T090000\r\n'
          'TRIGGER:-P1DT2H\r\nEND:VTODO'));
      expect(r.tasks.single.reminderOffsetMin, 1560);
    });

    test('vCalendar 1.0 AALARM 的绝对时刻按落点求差', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:体检\r\nDUE:20260920T090000\r\n'
          'AALARM:20260920T080000;PT5M;;\r\nEND:VTODO'));
      expect(r.tasks.single.reminderOffsetMin, 60);
      expect(r.reminderMigrated, 1);
    });

    test('「晚于落点」的提醒无对应语义 → 不计入 offset，如实报告未迁移', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:x\r\nDUE:20260920T090000\r\n'
          'TRIGGER:PT10M\r\nEND:VTODO'));
      expect(r.tasks.single.reminderOffsetMin, 0);
      expect(r.reminderMigrated, 0);
      expect(r.reminderDropped, 1);
      expect(r.report.contains('未迁移'), isTrue);
    });

    test('无提醒段的条目不计入迁移统计', () {
      final r = parseIcs(icsOf('BEGIN:VTODO\r\nSUMMARY:x\r\nDUE:20260920T090000\r\n'
          'END:VTODO'));
      expect(r.reminderMigrated, 0);
      expect(r.reminderDropped, 0);
    });

    test('导出 → 导入往返：提醒提前量守恒', () {
      final ics = exportIcs([mk('7', due: DateTime(2026, 9, 20, 9, 0), offset: 45)]);
      final back = parseIcs(ics);
      expect(back.tasks.single.reminderOffsetMin, 45);
      expect(back.reminderMigrated, 1);
    });
  });

  group('P3-2 预览口径（occursOnIgnoringSkip 公开入口）', () {
    test('忽略跳过，但遵守 repeatUntil', () {
      final t = mk('1', repeat: RepeatType.daily, repeatMinute: 450, until: '2026-09-30');
      final d = DateTime(2026, 9, 20);
      expect(t.occursOnIgnoringSkip(d), isTrue);
      final skipped = t.copyWith(skipDates: [Task.ymdKey(d)]);
      expect(skipped.occursOnIgnoringSkip(d), isTrue, reason: '跳过日仍需可见（撤销入口）');
      expect(skipped.repeatsOn(d), isFalse, reason: 'repeatsOn 仍应排除跳过日');
      expect(t.occursOnIgnoringSkip(DateTime(2026, 10, 1)), isFalse,
          reason: '超过 repeatUntil 不算循环日');
    });
  });

  group('P3-3 跳过与完成互斥', () {
    test('对已跳过的今天标记完成：原子撤销跳过，不双态并存', () async {
      final p = await buildWith([mk('1', repeat: RepeatType.daily, repeatMinute: 450)]);
      final today = DateTime.now();
      final key = Task.ymdKey(today);
      p.skipOccurrence('1');
      expect(p.byId('1')!.skipDates.contains(key), isTrue);

      p.markOccurrenceDone('1', today);
      final t = p.byId('1')!;
      expect(t.isDoneOn(today), isTrue);
      expect(t.skipDates.contains(key), isFalse,
          reason: '完成应原子撤销跳过，否则撤销跳过后提醒仍不回弹');
    });

    test('未跳过的日子标记完成不受影响', () async {
      final p = await buildWith([mk('1', repeat: RepeatType.daily, repeatMinute: 450)]);
      final today = DateTime.now();
      p.markOccurrenceDone('1', today);
      final t = p.byId('1')!;
      expect(t.isDoneOn(today), isTrue);
      expect(t.skipDates, isEmpty);
    });
  });

  group('U3 已结束重复角标', () {
    test('endRepeat 后 repeatEnded 为真，且不再产生循环日', () async {
      final p = await buildWith([mk('1', repeat: RepeatType.daily, repeatMinute: 450)]);
      p.endRepeat('1');
      final t = p.byId('1')!;
      expect(t.isRepeating, isTrue, reason: 'endRepeat 保留规则字段，只用 until 表达退场');
      expect(t.repeatEnded, isTrue);
      expect(t.repeatsOn(DateTime.now()), isFalse);
      expect(t.repeatsOn(DateTime.now().add(const Duration(days: 1))), isFalse);
    });

    test('正常重复 / 一次性任务的 repeatEnded 为假', () {
      expect(mk('1', repeat: RepeatType.daily, repeatMinute: 450).repeatEnded, isFalse);
      expect(mk('2').repeatEnded, isFalse);
      expect(
        mk('3', repeat: RepeatType.daily, repeatMinute: 450, until: '2099-01-01')
            .repeatEnded,
        isFalse,
      );
    });
  });

  group('P3-4 看板视图偏好', () {
    test('模式名解析：合法值还原，非法 / 缺失回退「状态」', () {
      expect(kanbanModeFromName('tag'), KanbanGroupMode.tag);
      expect(kanbanModeFromName('category'), KanbanGroupMode.category);
      expect(kanbanModeFromName('status'), KanbanGroupMode.status);
      expect(kanbanModeFromName('bogus'), KanbanGroupMode.status);
      expect(kanbanModeFromName(null), KanbanGroupMode.status);
    });
  });

  group('U4 泳道宽度自适应', () {
    test('窄屏（<600）恒为 220，保留横向滚动手感', () {
      expect(kanbanLaneWidthFor(360, 3), 220);
      expect(kanbanLaneWidthFor(599, 2), 220);
    });

    test('宽屏按可用宽铺满，单列夹在 200~280', () {
      expect(kanbanLaneWidthFor(800, 3), closeTo(261.33, 0.05));
      expect(kanbanLaneWidthFor(700, 2), 280);
      expect(kanbanLaneWidthFor(800, 8), 200, reason: '列数过多时夹到下限并横向滚动');
    });

    test('异常输入不抛（列数为 0 / 宽度非法）', () {
      expect(kanbanLaneWidthFor(0, 0), 200);
      expect(kanbanLaneWidthFor(800, 0), 200);
      expect(kanbanLaneWidthFor(double.nan, 3), 220);
      expect(kanbanLaneWidthFor(800, -1), 200);
    });
  });
}
