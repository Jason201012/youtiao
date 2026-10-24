import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// P1-1 / P2-1 回归：跨天重排与列表内容解耦、顺延撤销的双向还原。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
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
}) =>
    Task(
      id: id,
      title: title ?? 'T$id',
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
      repeat: repeat,
      repeatWeekdays: weekdays,
      repeatMinute: repeat == RepeatType.none ? null : 450,
    );

void main() {
  setUp(_installMocks);

  group('P1-1 跨天重排与列表内容解耦', () {
    test('仅有一次性任务时，跨天检查仍触发 onDayChanged（旧实现恒不触发）', () async {
      // 关键点：列表里**没有任何重复任务**，_resetDailyIfNeeded() 必然返回 false。
      // 旧实现把 onDayChanged 包在 if (changed) 里 → 简报 / 挽留次日静默断更。
      final p = await buildWith([mk('1', due: DateTime(2026, 9, 11, 9, 0))]);
      var fired = 0;
      TaskProvider.onDayChanged = () => fired++;
      addTearDown(() => TaskProvider.onDayChanged = null);

      await p.checkDailyReset();
      expect(fired, 1, reason: '日边界判定必须与列表内容无关');
    });

    test('同一天内重复检查不重复触发重排（避免每 15 分钟空排一次简报）', () async {
      final p = await buildWith([mk('1', due: DateTime(2026, 9, 11, 9, 0))]);
      var fired = 0;
      TaskProvider.onDayChanged = () => fired++;
      addTearDown(() => TaskProvider.onDayChanged = null);

      await p.checkDailyReset(); // 确立当天基线
      await p.checkDailyReset();
      await p.checkDailyReset();
      expect(fired, 1);
    });
  });

  group('P2-1 顺延（移到下一天）撤销', () {
    final origDay = DateTime(2026, 9, 11);

    test('skipOccurrence / unskipOccurrence 严格互逆且幂等', () async {
      final p = await buildWith([mk('1', repeat: RepeatType.daily)]);

      p.skipOccurrence('1', day: origDay);
      expect(p.byId('1')!.skipDates, contains('2026-09-11'));

      p.unskipOccurrence('1', day: origDay);
      expect(p.byId('1')!.skipDates, isNot(contains('2026-09-11')));

      // 幂等：对未跳过的日期再次撤销不应报错、不应引入脏数据。
      p.unskipOccurrence('1', day: origDay);
      expect(p.byId('1')!.skipDates, isEmpty);
    });

    test('rescheduleOnceOccurrence 返回副本 id，撤销可精确双还原', () async {
      // F-2（v2.8.5 审计）：源任务改为「每周五」——2026-09-11 是周五，改期目标日
      // 9/12（周六）不是循环日，仍会建副本（daily 改期到明天会被防撞判定合并，
      // 见 v285_audit_fix_test 的 F-2 组）。
      final p = await buildWith([
        mk('1',
            title: '同名任务',
            repeat: RepeatType.weekly,
            weekdays: const [DateTime.friday],
            due: DateTime(2026, 9, 11, 9, 0)),
        // 同名 + 同一天的另一条任务：旧实现按「标题 + 日期」反查副本会误删它。
        mk('2', title: '同名任务', due: DateTime(2026, 9, 12, 9, 0)),
      ]);
      final newDay = origDay.add(const Duration(days: 1)); // 周六，非循环日

      // P2-2（v3.0.7 审计）：rescheduleOnceOccurrence 随 addTask 异步化。
      // P3-2（v3.0.8 审计）：返回值改具名记录，消费点取 .copy。
      final r = await p.rescheduleOnceOccurrence('1', newDay, origDay: origDay);
      final copy = r.copy;
      expect(copy, isNotNull);
      expect(copy!.id, isNot('1'));
      expect(p.byId('1')!.skipDates, contains('2026-09-11'));
      expect(p.byId(copy.id), isNotNull);
      expect(p.byId('2'), isNotNull, reason: '无关的同名任务必须原封不动');

      // 撤销：按副本 id 移除 + 归还 skipDates（原实现在此步说谎）。
      await p.discardTask(copy.id);
      await p.unskipOccurrence('1', day: origDay);

      expect(p.byId(copy.id), isNull, reason: '副本应被精确删除');
      expect(p.byId('2'), isNotNull, reason: '同名任务不得被误删');
      expect(p.byId('1')!.skipDates, isEmpty, reason: '原日必须从 skipDates 归还');
    });

    // P3-2（v3.0.8 审计）：null 四义拆开后，「源任务不存在」是显式的 missing
    // 分支——旧测试只断言 isNull，五义里任何一义都满足，钉不住具体语义。
    test('源任务不存在时 rescheduleOnceOccurrence 报 missing（copy 为 null）',
        () async {
      final p = await buildWith([mk('1', repeat: RepeatType.daily)]);
      final r = await p.rescheduleOnceOccurrence(
          'nope', origDay.add(const Duration(days: 1)));
      expect(r.missing, isTrue, reason: '源任务不存在 = missing');
      expect(r.copy, isNull);
      expect(r.coveredByLoop, isFalse);
      expect(r.copyFailed, isFalse);
      expect(r.noop, isFalse);
    });

    test('discardTask 幂等，且只作用于活动列表（不进回收站）', () async {
      final p = await buildWith([mk('1'), mk('2')]);
      p.discardTask('2');
      expect(p.byId('2'), isNull);
      expect(p.tasks.length, 1);
      // 幂等：再次移除同一 id 不抛错、不影响其它任务。
      p.discardTask('2');
      expect(p.byId('1'), isNotNull);
      expect(p.tasks.length, 1);
    });
  });
}
