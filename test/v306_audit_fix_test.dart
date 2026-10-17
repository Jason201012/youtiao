import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/habit_migration.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/task_toggle_undo.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';

import 'test_helpers.dart';

/// v3.0.6 审计修复轮（《有条功能与操作审计报告（v3.0.6）》6 项）回归测试。
/// 每条修复至少一个「能区分修与未修」的用例；不落用例的项见文件尾说明。
///
/// 覆盖清单：
/// - **P3-1** `restoreTaskSnapshotPersisted` 落盘失败后 identical 分支**真正重试
///   落盘**（旧实现直接 return true → DB 异常路径下重试得到假成功）；
///   `showTaskUndoNotSaved` 如实回执（service 层；main._doTaskUndo 的归还快照
///   接线库外不可达，同历轮口径）；
/// - **P3-2** `deleteHabit` 撤提醒挪到落盘成功后——失败路径**零 cancel**
///   （旧实现先撤后落盘，9 号确认条被撤且不重挂），成功路径才撤（含 9 号槽）；
/// - **U2-1** `markOccurrenceDone` / `unmarkOccurrenceDone` 透传落盘结果；
///   `toggleDoneWithUndo` DB 异常时先弹「写入失败」、撤销横幅仍入队（widget）；
///   撤销回调走 `restoreTaskSnapshotPersisted`（成功后不误报「撤销已失效」）；
/// - **U3-2** `showHabitUndoNoRecordConfirm` 无记录可撤的覆盖式回执（service 层；
///   main._doHabitUndo 的 current<=0 接线库外不可达）；
/// - **惯例** 习惯侧 5 个写入口（addHabit / addHabitFromDraft / setReminder /
///   restoreHabit / restoreFromJson）透传落盘结果，失败回滚内存；
/// - **U3-1** habit_screen 死分支（invalid_null_aware_operator /
///   unnecessary_null_comparison）——纯静态警告，由 `flutter analyze` 零 warning
///   门禁兜住，无运行时行为可测（同历轮对纯 lint 项的处置）。
///
/// 不落用例：
/// - **main._doTaskUndo / _doHabitUndo / _doComplete 的接线**（归还快照、
///   current<=0 回执）——main.dart 顶层私有回调库外不可达（v3.0.2 / v3.0.4 /
///   v3.0.5 轮同判）；其依赖的 provider / service 层信号已在本文件钉死；
/// - **U2-1 的 App 内 UI 接线**（home / kanban / occurrence_sheet / habit_screen
///   的 SnackBar 消费）——provider 层返回值 + task_toggle_undo 的唯一实现已钉，
///   其余入口按 bool 分支属直接消费；
/// - **P3-2 的 9 号确认条「消失」场景复现**——需通知栏真实在途 + DB 异常双条件，
///   代码推演 + 「失败路径零 cancel」的断言已覆盖其不变式。
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
    // 🔴 testUseMemory 是进程级静态标志：本文件多个用例中途置 false 注入 DB
    // 异常，一旦用例在「置回 true」之前失败（或 widget 用例忘了置回），后续
    // 用例全部在假失败路径上跑（v3.0.6 首跑实证：泄漏使 setReminder 的首调
    // 落盘失败）。setUp 统一置真作为兜底，各用例内部仍须自负还原。
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    NotificationService.instance.enabled = true;
  });

  // v303 / v304 / v305 同款双形态防御提取（新版插件 cancel 的 arguments 是 Map）。
  int? cancelIdOf(MethodCall c) {
    final a = c.arguments;
    if (a is int) return a;
    if (a is Map) return a['id'] as int?;
    return null;
  }

  int? argsIdOf(MethodCall c) =>
      c.arguments is Map ? (c.arguments as Map)['id'] as int? : null;

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
    bool notificationsEnabled = false,
    bool rescheduleReminders = false,
  }) async {
    final p = TaskProvider();
    final json = jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': (trash ?? const <Task>[]).map((t) => t.toJson()).toList(),
      'notifications_enabled': notificationsEnabled,
      'sound_enabled': false,
    });
    await p.restoreFromJson(json, rescheduleReminders: rescheduleReminders);
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

  /// daily 重复任务工厂（occurrence 用例用）。
  Task repeating({String id = 'r', int? repeatMinute}) => Task(
        id: id,
        title: '每日任务',
        priority: Priority.medium,
        category: Category.work,
        repeat: RepeatType.daily,
        repeatMinute: repeatMinute,
      );

  /// 习惯 Provider 脚手架：setUp 已重置内存库 + prefs，直接 load + add。
  Future<(HabitProvider, Habit)> habitWithTarget({int target = 8}) async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '喝水',
      emoji: '💧',
      colorValue: 1,
      weekdays: const [],
      dailyTarget: target,
    );
    return (hp, hp.habits.single);
  }

  // ── P3-1：restoreTaskSnapshotPersisted 失败后重试真正落盘 ─────────
  test('P3-1：identical 分支重试落盘（失败后重试不得假成功）', () async {
    final p = await buildWith([mk(id: '7101')]);
    final snap = p.byId('7101')!; // 完成前的对象 = 通知 action 留存的快照
    expect(await p.setStatus('7101', TaskStatus.done), isTrue,
        reason: '前提：先完成（_tasks[0] 换成 done 副本，与 snap 非 identical）');

    // 第一次撤销：DB 异常 → false，内存撤销已生效（任务回待办）。
    LocalDatabase.testUseMemory = false;
    bool threw = false;
    bool firstOk = true;
    try {
      firstOk = await p.restoreTaskSnapshotPersisted(snap);
    } catch (_) {
      threw = true;
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(threw, isFalse, reason: '异常必须转为结果值而非 reject');
    expect(firstOk, isFalse, reason: '落盘失败透传 false');
    expect(p.byId('7101')!.status, TaskStatus.todo,
        reason: '前提：快照已安装到内存（identical 将在第二次命中）');

    // 第二次（DB 恢复）：identical 命中但必须真正落盘——旧实现直接 return true，
    // DB 里仍是完成态，main._doTaskUndo 会弹「已撤销完成」的假确认
    // （用户重启后发现任务又是完成态，认知错乱——报告 P3-1 三重后果②的根因）。
    expect(await p.restoreTaskSnapshotPersisted(snap), isTrue);
    final stored = await LocalDatabase.instance.loadTasks();
    expect(stored.single.status, TaskStatus.todo,
        reason: 'DB 实证：重试后真实落盘（identical 分支不再假设「装了即落了」）');
  });

  test('P3-1：showTaskUndoNotSaved 落任务段通知位 + 带重试 action（可再点一次撤销）',
      () async {
    await NotificationService.instance
        .showTaskUndoNotSaved('task-n1', '买牛奶');
    await drainMicrotasks();
    final shows = notifCalls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(1));
    final args = Map<String, dynamic>.from(shows.single.arguments as Map);
    expect(args['title'], '撤销未保存',
        reason: '文案与「已撤销完成」「撤销已失效」三分支各表其事');
    expect(args['body'], contains('保存失败'),
        reason: '如实说明「内存已撤销、保存失败」，不谎报也不误报失效');
    expect(args['payload'], '${NotificationService.payloadTaskPrefix}task-n1',
        reason: 'task: 前缀 payload——action 点击可解析回任务 id');
    final ps = Map<String, dynamic>.from(args['platformSpecifics'] as Map);
    final actions = (ps['actions'] as List).cast<Map>();
    expect(actions, hasLength(1),
        reason: '快照已归还（main._doTaskUndo），重试即再次撤销');
    expect(actions.single['id'], NotificationService.taskUndoActionId);
    expect(actions.single['title'], '重试');
  });

  // ── P3-2：deleteHabit 撤提醒挪到落盘成功后 ───────────────────────
  test('P3-2：deleteHabit 落盘失败零 cancel（确认条不消失）；成功路径才撤', () async {
    final (hp, habit) = await habitWithTarget();
    await hp.setReminder(habit, 9 * 60); // 挂每日提醒（0..7 槽在途）
    await hp.setCheckInValue(habit, DateTime.now(), 2);
    hp.markConfirmShown(habit.id); // 模拟通知 action 已弹 9 号确认条
    notifCalls.clear();

    // 失败路径：先撤后落盘的旧实现会 cancel 掉 0..7 槽 + 8 号 snooze + 9 号
    // 确认条，回滚却只按 reminderMinute 重挂每日提醒——确认条永久消失。
    LocalDatabase.testUseMemory = false;
    final DeletedHabit? snap;
    try {
      snap = await hp.deleteHabit(habit.id);
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(snap, isNull, reason: '删除未生效（v3.0.5 P3-2 基线保持）');
    expect(hp.byId(habit.id), isNotNull, reason: '内存回滚：习惯仍在');
    expect(hp.todayValue(habit), 2, reason: '打卡记录一并回滚');
    expect(
      notifCalls.where((c) => c.method == 'cancel'),
      isEmpty,
      reason: 'P3-2：失败路径根本不动通知——彻底消除「先撤后落盘」'
          '（任务侧 P2-2，v3.0.5 审计同族教训）',
    );

    // 成功路径：撤提醒（含 9 号槽确认条）——删除生效才撤。
    notifCalls.clear();
    final snap2 = await hp.deleteHabit(habit.id);
    expect(snap2, isNotNull, reason: '删除生效，返回快照供撤销');
    await drainMicrotasks();
    final cancels =
        notifCalls.where((c) => c.method == 'cancel').map(cancelIdOf).toSet();
    expect(cancels, contains(NotificationService.habitConfirmNotifyIdOf(habit.id)),
        reason: '成功路径撤 9 号槽确认条（习惯已删，确认条无意义）');
    expect(cancels.length, greaterThan(1),
        reason: '每日提醒落点（0..7 槽）一并撤');
  });

  // ── U2-1：occurrence 入口透传落盘结果 ────────────────────────────
  test('U2-1：markOccurrenceDone / unmarkOccurrenceDone 透传落盘结果', () async {
    final p = await buildWith([repeating(id: '7201')]);
    final day = today();
    expect(await p.markOccurrenceDone('7201', day), isTrue, reason: '成功路径 true');
    expect(p.byId('7201')!.isDoneOn(day), isTrue);
    expect(await p.unmarkOccurrenceDone('7201', day), isTrue);
    expect(p.byId('7201')!.isDoneOn(day), isFalse);
    expect(await p.unmarkOccurrenceDone('7201', day), isTrue,
        reason: '幂等早退 = true（无记录可取消不是失败）');
    expect(await p.markOccurrenceDone('ghost', day), isFalse,
        reason: '任务不存在 = false');

    LocalDatabase.testUseMemory = false;
    bool threw = false;
    bool ok = true;
    try {
      ok = await p.markOccurrenceDone('7201', day);
    } catch (_) {
      threw = true;
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(threw, isFalse);
    expect(ok, isFalse,
        reason: 'DB 异常透传 false——occurrence_sheet._markDone 据此弹'
            '「写入失败」（旧实现 void fire-and-forget，UI 已显示完成、重启回退）');
    expect(p.byId('7201')!.isDoneOn(day), isTrue,
        reason: '内存写入已生效（任务侧不内存回滚，v3.0.5 报告核查备注 A 口径）');
  });

  // ── U2-1：toggleDoneWithUndo 的 App 内反馈（widget） ──────────────
  group('U2-1 toggleDoneWithUndo（widget）', () {
    Widget host(void Function(BuildContext context) onTap) {
      return MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => onTap(ctx),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('DB 异常 → 「写入失败」先入队、撤销横幅仍随后入队', (tester) async {
      // ⚠️ buildWith 必须走 tester.runAsync：testWidgets 测试体跑在 FakeAsync
      // 时钟下，而 restoreFromJson 尾部会做真实 I/O（附件 blob 还原 / 孤儿回收
      // 经 path_provider），直接 await 永远等不到完成——整条用例挂死 10 分钟
      // 被超时终止（v289 轮同款教训，本项目 widget 用例播种的标准姿势）。
      final p = (await tester.runAsync(
              () => buildWith([mk(id: '7301', title: '买牛奶')])))!;
      LocalDatabase.testUseMemory = false; // 注入 DB 异常
      addTearDown(() => LocalDatabase.testUseMemory = true);
      await tester.pumpWidget(host(
          (ctx) => toggleDoneWithUndo(ctx, p, p.byId('7301')!)));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text('写入失败：数据未保存，请重试'), findsOneWidget,
          reason: '落盘失败如实提示——旧实现 fire-and-forget 后无条件弹'
              '「已完成（10 秒内可撤销）」，重启回退为未完成');
      // 撤销横幅仍在队列（任务侧 provider 不内存回滚，UI 的完成态需要撤销入口）。
      final ctx = tester.element(find.text('go'));
      expect(debugActiveUndoSnackCount(ScaffoldMessenger.of(ctx)), 1,
          reason: '横幅未被跳过——「写入失败」提示与撤销入口并存');
    });

    testWidgets('撤销回调走 restoreTaskSnapshotPersisted：成功后不误报失效',
        (tester) async {
      // 同上一用例：buildWith 走 runAsync（FakeAsync + 真实 I/O 死锁教训）。
      final p = (await tester.runAsync(
              () => buildWith([mk(id: '7302', title: '跑步')])))!;
      await tester.pumpWidget(host(
          (ctx) => toggleDoneWithUndo(ctx, p, p.byId('7302')!)));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(p.byId('7302')!.done, isTrue, reason: '内存完成态已生效');
      expect(find.textContaining('已完成「跑步」'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(p.byId('7302')!.done, isFalse, reason: '快照整体回滚（P3-10 契约）');
      expect(find.text('撤销已失效：该操作已不可恢复'), findsNothing,
          reason: '落盘成功不得误报失效——旧实现 restoreTaskSnapshot 的'
              '「存在」语义在落盘失败时同样返回 false（P3-1 同款错位）');
    });
  });

  // ── U3-2：无记录可撤的覆盖式回执（service 层） ────────────────────
  test('U3-2：showHabitUndoNoRecordConfirm 落 9 号槽（无记录可撤不再静默）',
      () async {
    await NotificationService.instance
        .showHabitUndoNoRecordConfirm('habit-n1');
    await drainMicrotasks();
    final shows = notifCalls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(1));
    expect(argsIdOf(shows.single),
        NotificationService.habitConfirmNotifyIdOf('habit-n1'),
        reason: '落 9 号槽覆盖式回执（与 showHabitEndedConfirm 同槽位）');
    final args = Map<String, dynamic>.from(shows.single.arguments as Map);
    expect(args['title'], '今天没有可撤销的记录');
    final ps = Map<String, dynamic>.from(args['platformSpecifics'] as Map);
    expect(ps['actions'], isNull,
        reason: '不挂撤销 action（无记录可撤，挂了也是死按钮）');
  });

  // ── 惯例：习惯侧 5 个写入口透传落盘结果 ───────────────────────────
  test('惯例：addHabit 落盘失败回滚内存并返回 false', () async {
    final hp = HabitProvider();
    await hp.load();
    LocalDatabase.testUseMemory = false;
    final bool ok;
    try {
      ok = await hp.addHabit(
        title: '新习惯',
        emoji: '🆕',
        colorValue: 1,
        weekdays: const [],
      );
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(ok, isFalse,
        reason: '旧实现 Future<void> 忽略 _persistHabits 结果：新建的习惯'
            ' 仅存内存，重启即丢，UI 却显示成功');
    expect(hp.habits, isEmpty,
        reason: '内存回滚——UI 层据此停留编辑层，重试不会造出重复习惯');
  });

  test('惯例：addHabitFromDraft 落盘失败回滚并返回 null', () async {
    final hp = HabitProvider();
    await hp.load();
    LocalDatabase.testUseMemory = false;
    final Habit? created;
    try {
      created = await hp.addHabitFromDraft(
        const HabitDraft(
          title: '背单词',
          weekdays: [1, 3],
          reminderMinute: 21 * 60,
          weeklyGoal: 2,
        ),
        emoji: '📚',
        colorValue: 0xFF112233,
      );
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(created, isNull,
        reason: '转换未生效——任务详情页据此不弹「已转为习惯」、不询问'
            '删除原任务（旧实现照走完整成功流程，把用户往数据丢失上引）');
    expect(hp.habits, isEmpty, reason: '内存回滚');
  });

  test('惯例：setReminder 落盘失败回滚内存、不动通知，返回 false', () async {
    final (hp, habit) = await habitWithTarget();
    await hp.setReminder(habit, 9 * 60);
    expect(hp.byId(habit.id)!.reminderMinute, 9 * 60);
    notifCalls.clear();

    LocalDatabase.testUseMemory = false;
    final bool ok;
    try {
      ok = await hp.setReminder(habit, 21 * 60);
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(ok, isFalse);
    expect(hp.byId(habit.id)!.reminderMinute, 9 * 60,
        reason: '内存回滚到**列表当前对象**（9*60 是第一次已落盘的改动）——'
            '旧实现按调用方实参回滚，过期实参会把它一并抹成 null'
            '（setReminder 的 updateHabit 同款 old = _habits[idx] 口径）');
    expect(notifCalls.where((c) => c.method == 'cancel'), isEmpty,
        reason: '失败路径不动通知——旧提醒与恢复后的习惯状态天然一致'
            '（旧实现改时间仅存内存、闹钟已按新时刻重挂，三处口径分裂）');
  });

  test('惯例：restoreHabit 落盘失败回滚（习惯与本次放回的打卡一并撤下）', () async {
    final (hp, habit) = await habitWithTarget();
    await hp.setCheckInValue(habit, DateTime.now(), 3);
    final snap = (await hp.deleteHabit(habit.id))!;
    expect(hp.byId(habit.id), isNull, reason: '前提：已删除');

    LocalDatabase.testUseMemory = false;
    final Habit? restored;
    try {
      restored = await hp.restoreHabit(snap);
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(restored, isNull, reason: '撤销未生效');
    expect(hp.byId(habit.id), isNull, reason: '内存回滚：习惯仍未恢复');
    expect(hp.checkIns.where((c) => c.habitId == habit.id), isEmpty,
        reason: '本次放回的打卡记录一并撤下（旧实现忽略 persist 结果，'
            '撤销仅存内存，重启后习惯「没恢复」而用户已看到撤销成功）');
  });

  test('惯例：restoreFromJson 透传落盘结果（backup_sheet failures 的输入）',
      () async {
    final (hp, habit) = await habitWithTarget();
    final payload = <String, dynamic>{
      'habits': [habit.toJson()],
      'check_ins': <dynamic>[],
    };
    LocalDatabase.testUseMemory = false;
    final bool okFail;
    try {
      okFail = await hp.restoreFromJson(payload);
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(okFail, isFalse,
        reason: '旧实现 Future<void> 忽略：本步写库失败时 UI 仍报'
            '「已恢复」，重启后恢复的习惯/打卡静默丢失');
    // 成功路径 true（内存态此时已是恢复集，再写一次同集落盘）。
    expect(await hp.restoreFromJson(payload), isTrue);
  });
}
