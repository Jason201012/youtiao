import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';
import 'test_helpers.dart';

/// v2.9.6 审计修复轮回归测试（《有条功能与操作审计报告（v2.9.6）》）。
///
/// 覆盖清单（可纯 Dart 断言部分；widget 用例见文件尾部 testWidgets 组）：
/// - P2-2 撤销缓冲失效的**结果反馈**：undoDelete / undoBatchEdit 返回是否生效
///   （缓冲被消费 / 作废 → false），`showUndoSnackBar` 据此提示「撤销已失效」；
/// - P2-3 恢复备份（restoreFromJson）清空编辑 + 删除两套撤销缓冲——残留横幅
///   不再能「复活」恢复前任务或回写恢复前快照；
/// - P2-4 restoreTaskSnapshot 先 cancel 后重排——日历改期撤销后不再遗留
///   「幽灵提醒」（cancel 在撤销路径上被真实调用）；
/// - P2-5 习惯页概览「今日 x/y」分母真源 `habitsDueOn`（休息日过滤）；
/// - P2-6（在 v296 文件补历史日用例）本文件补 provider 判据的直接断言；
/// - P2-9 专注记录删除 / 撤销与任务累计专注**对称**（removeSession 扣减）；
/// - P3-1 dueCompareKey 横向推广：isOverdue / dueIsPureDateForm 判秒统一；
/// - P3-5 庆祝去重（同日二次达标不再触发庆祝）——provider 侧无法直接观测
///   UI 庆祝，由 habit_screen 顶层 `_celebratedKeys` 承担，纯逻辑不在此钉；
/// - P3-7 weeklyGoal 读侧保真已在 v296 文件改写断言（读侧不再夹取）；
/// - U3-15（报告 P3-15）清空今日专注记录返回被删列表（可撤销）。
///
/// widget 用例（撤销真源 P2-1/P2-2）：
/// - 撤销失败 → 「撤销已失效：该操作已不可恢复」；
/// - 活跃撤销条计数契约（超时 skip 判据的输入：入队 +1 / closed −1）。
///
/// 完整超时链路（Timer → 收起动画 → closed → 120ms 判定 → hint 入队）横跨
/// 多次帧调度停止点，FakeAsync 下无法稳定驱动——「文案绑定」改为对
/// [expiredHintFromContent] 的纯 Dart 断言，链路行为由 undo_snack_bar.dart
/// 的实现注释与真机体验保障（v2.9.6 轮 widget 层 timer 型用例不落回归的
/// 既有惯例）。
void main() {
  _installMocks();

  // ── P2-2 / P2-3：撤销缓冲的结果语义 ─────────────────────────
  group('P2-2/P2-3 撤销缓冲返回生效结果 + 恢复备份清缓冲', () {
    test('undoDelete：成功 true；重复撤销（缓冲已消费）false', () async {
      final p = await buildWith([_task('1', title: '甲'), _task('2', title: '乙')]);
      // P2-2（v3.0.7 审计）：deleteTaskAs / undoDelete 异步化并改返回具名记录
      // `(applied, saved)`——生效断言改为读 applied 字段（saved 语义见 v307 用例）。
      final r = await p.deleteTaskAs('1');
      expect(r.$2, isNotNull);
      expect((await p.undoDelete(r.$1)).applied, isTrue,
          reason: '缓冲在、任务可恢复 → 生效');
      expect((await p.undoDelete(r.$1)).applied, isFalse,
          reason: '同一 batchId 已被消费');
      expect(p.tasks.any((t) => t.id == '1'), isTrue,
          reason: '撤销成功后任务回到列表');
    });

    test('undoBatchEdit：生效 true；空缓冲 / 未知 batchId false', () async {
      final p = await buildWith([_task('1', title: '甲')]);
      final r = await p.postponeToAs(['1'], DateTime(2026, 10, 1));
      expect(r.$2, 1);
      expect((await p.undoBatchEdit(r.$1)).applied, isTrue);
      expect((await p.undoBatchEdit(r.$1)).applied, isFalse, reason: '已消费');
      expect((await p.undoBatchEdit(99999)).applied, isFalse,
          reason: '未知 batchId');
    });

    test('P2-3：restoreFromJson 清空两套撤销缓冲，残留横幅不再复活任务',
        () async {
      final p = await buildWith([_task('1', title: '甲')]);
      // ① 删除（删除缓冲登记 batchId）
      // P2-2（v3.0.7 审计）：deleteTaskAs / postponeToAs 异步化。
      final del = await p.deleteTaskAs('1');
      expect(p.tasks.any((t) => t.id == '1'), isFalse);
      // ② 编辑另一条（编辑缓冲登记另一个 batchId）
      final edit = await p.postponeToAs(['2'], DateTime(2026, 10, 2));
      // 恢复备份（覆盖 _tasks/_trash）
      final backup = jsonEncode({
        'version': 3,
        'app': '有条',
        'tasks': [_task('9', title: '备份里的任务').toJson()],
        'trash': <dynamic>[],
        'notifications_enabled': false,
        'sound_enabled': false,
      });
      await p.restoreFromJson(backup);
      // ③ 残留横幅的「撤销」：缓冲已清 → 返回 false 且**不得复活/回写**。
      expect((await p.undoDelete(del.$1)).applied, isFalse,
          reason: 'P2-3：删除缓冲已被恢复清空——此前会把恢复前已删任务复活');
      expect((await p.undoBatchEdit(edit.$1)).applied, isFalse,
          reason: 'P2-3：编辑缓冲已被恢复清空——此前会按 id 回写恢复前快照');
      expect(p.tasks.map((t) => t.id), ['9'],
          reason: '恢复结果不被残留撤销污染');
    });
  });

  // ── P2-4：幽灵提醒 ──────────────────────────────────────────
  group('P2-4 restoreTaskSnapshot 先 cancel 后重排（幽灵提醒）', () {
    test('撤销到逾期快照：撤销路径上发生 cancel（此前从不 cancel）', () async {
      const ch = MethodChannel('dexterous.com/flutter/local_notifications');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
        calls.add(call);
        return null;
      });

      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final overdue = _task('1',
          title: '逾期任务', dueDate: DateTime(yesterday.year, yesterday.month,
              yesterday.day, 10, 0));
      final p = await buildWith([overdue]);

      // 模拟日历拖拽：改期到明天（改期路径会 cancel + schedule 新闹钟）
      final now = DateTime.now();
      final updated = overdue.copyWith(
          dueDate: DateTime(now.year, now.month, now.day + 1, 10, 0));
      p.updateTask(updated);
      final cancelsBefore = calls.where((c) => c.method == 'cancel').length;

      // 10 秒内点「撤销」：整体快照回滚到逾期状态。
      // U3-4（v3.0.8 审计）：迁到 persisted 版（await 落盘结果）。
      final ok = await p.restoreTaskSnapshotPersisted(overdue);
      expect(ok, isTrue, reason: 'P2-2：restoreTaskSnapshotPersisted 返回是否落盘');
      final cancelsAfter = calls.where((c) => c.method == 'cancel').length;
      expect(cancelsAfter, greaterThan(cancelsBefore),
          reason: '改期挂上的「明天」闹钟必须在撤销时被 cancel——'
              '旧实现 reconcile 只 schedule 不 cancel，幽灵提醒留存');
      expect(p.byId('1')!.dueDate, overdue.dueDate,
          reason: '快照逐位还原');
    });

    test('撤销到不存在的任务：返回 false（不抛错）', () async {
      final p = await buildWith([_task('1')]);
      expect(await p.restoreTaskSnapshotPersisted(_task('ghost')), isFalse);
    });
  });

  // ── P2-5：习惯页概览分母 ────────────────────────────────────
  group('P2-5 habitsDueOn：概览「今日 x/y」分母按计划日过滤', () {
    test('周一三五 + 每天：周二分母 1、周一分母 2、分子分母同源', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '一三五',
          emoji: '🏃',
          colorValue: 1,
          weekdays: const [1, 3, 5]);
      await hp.addHabit(
          title: '每天', emoji: '💧', colorValue: 2, weekdays: const []);
      // 2026-09-21 周一 / 2026-09-22 周二（固定日期，与运行日无关）。
      final monday = DateTime(2026, 9, 21);
      final tuesday = DateTime(2026, 9, 22);
      expect(hp.habitsDueOn(monday).length, 2, reason: '两个习惯都该打卡');
      expect(hp.habitsDueOn(tuesday).length, 1, reason: '周二只有「每天」');
      expect(hp.habitsDueOn(tuesday).single.title, '每天');
    });
  });

  // ── P2-6：补卡判据（provider 直断言）────────────────────────
  group('P2-6 setCheckInValue 只对「写入今天且达标」撤 snooze', () {
    test('撤卡（值 0）不撤在途 snooze（8 号槽）；补历史日达标不触发 cancel', () async {
      const ch = MethodChannel('dexterous.com/flutter/local_notifications');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
        calls.add(call);
        return null;
      });
      final hp = await newHabitProvider();
      // weekdays 空 = 每天计划：判据断言与「今天星期几」无关。
      await hp.addHabit(
          title: '撤卡不撤snooze',
          emoji: '💧',
          colorValue: 1,
          weekdays: const [],
          dailyTarget: 2);
      final h = hp.habits.firstWhere((x) => x.title == '撤卡不撤snooze');
      // flutter_local_notifications 新版 cancel 的 arguments 是 Map（{'id':...}），
      // 裸比较恒不命中——与 v301 的 cancelIdOf 同款双形态防御提取。
      int? cancelIdOf(MethodCall c) {
        final a = c.arguments;
        if (a is int) return a;
        if (a is Map) return a['id'] as int?;
        return null;
      }
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));

      await hp.setCheckInValue(h, today, 2); // 今天达标 → 撤 snooze
      expect(calls.where((c) => c.method == 'cancel'), isNotEmpty);
      calls.clear();
      await hp.setCheckInValue(h, today, 0); // 撤卡（写今天但不达标）
      // P3-3（v3.0.2 审计）改口径：旧断言把「值 0 → cancel 调用全空」钉为正确
      // 行为；P3-3 落地后「今日值降 0」必须撤 9 号槽确认通知（「已打卡 ✓ / 撤销」
      // 确认条已失真）。P2-6 原口径「未达标不清」专指 **8 号槽在途 snooze**，
      // 判据收窄而非放松：断言改为按槽位 id 精确判定。
      expect(
        calls.where((c) =>
            c.method == 'cancel' &&
            cancelIdOf(c) ==
                NotificationService.habitSnoozeNotifyIdOf(h.id)),
        isEmpty,
        reason: 'P2-6/P2-7 原口径保留：未达标不撤在途 snooze（8 号槽）',
      );
      expect(
        calls.where((c) =>
            c.method == 'cancel' &&
            cancelIdOf(c) ==
                NotificationService.habitConfirmNotifyIdOf(h.id)),
        isNotEmpty,
        reason: 'P3-3（v3.0.2 审计）：今日值降 0 → 9 号槽「已打卡 ✓」确认条失真，必须撤',
      );
      // P3-3：今日降 0 已记一条 9 号槽 confirm-cancel，清空后再验证「补历史日」
      // 独立场景（末段断言的是补历史日本身不产生 cancel，不含上一段残留）。
      calls.clear();
      await hp.setCheckInValue(h, yesterday, 2); // 补历史日达标
      expect(calls.where((c) => c.method == 'cancel'), isEmpty,
          reason: 'P2-6：历史日达标与今天在途 snooze 无关');
    });
  });

  // ── P2-9：专注删除与任务累计专注对称 ────────────────────────
  group('P2-9 专注记录删除对称扣减任务累计专注', () {
    test('addSession 回填 → removeSession 扣减 → 撤销 addSession 回填（净变化 0）',
        () async {
      final p = await buildWith([_task('1', title: '甲')]);
      final focus = FocusProvider();
      focus.onFocusRecorded = (taskId, sec) => p.addFocusSec(taskId, sec);
      focus.onFocusRemoved = (taskId, sec) => p.removeFocusSec(taskId, sec);

      final now = DateTime.now();
      final s = FocusSession(
        id: 's1',
        taskId: '1',
        taskTitle: '甲',
        plannedSec: 600,
        durationSec: 600,
        completed: true,
        startedAt: now.subtract(const Duration(minutes: 10)),
        endedAt: now,
      );
      // P3-2（v3.1.0 审计）：addSession / removeSession / clearToday 均改为
      // await 落盘结果——旧契约是同步 void/Future 即完成，任务回填在内存修改
      // 后立即发生；现在回调挪到落盘成功后触发（落盘失败不扣不回填）。
      await focus.addSession(s);
      expect(p.byId('1')!.focusSecTotal, 600);

      final removed = await focus.removeSession('s1');
      expect(removed, isNotNull, reason: 'removeSession 返回被删记录（可撤销）');
      expect(p.byId('1')!.focusSecTotal, 0,
          reason: 'P2-9：删除即扣减——旧实现不扣，撤销后凭空多一段');

      await focus.addSession(removed!); // 撤销删除
      expect(p.byId('1')!.focusSecTotal, 600,
          reason: '撤销回填与删除扣减相抵，两侧口径对称');
    });

    test('removeFocusSec 结果夹 0（防御重复扣减）；removeSession 幂等', () async {
      final p = await buildWith([_task('1', title: '甲')]);
      p.addFocusSec('1', 100);
      p.removeFocusSec('1', 999999);
      expect(p.byId('1')!.focusSecTotal, 0, reason: '不为负');
      final focus = FocusProvider();
      expect(await focus.removeSession('不存在'), isNull, reason: '幂等');
    });

    test('P3-15：clearToday 返回被删列表，撤销逐条恢复', () async {
      final p = await buildWith([_task('1', title: '甲')]);
      final focus = FocusProvider();
      focus.onFocusRecorded = (taskId, sec) => p.addFocusSec(taskId, sec);
      focus.onFocusRemoved = (taskId, sec) => p.removeFocusSec(taskId, sec);
      final now = DateTime.now();
      final s = FocusSession(
        id: 's1',
        taskId: '1',
        taskTitle: '甲',
        plannedSec: 300,
        durationSec: 300,
        completed: true,
        startedAt: now.subtract(const Duration(minutes: 5)),
        endedAt: now,
      );
      await focus.addSession(s);
      final removed = await focus.clearToday(); // P3-2：await 落盘结果
      expect(removed.length, 1);
      expect(focus.sessions.where((x) => x.id == 's1'), isEmpty);
      expect(p.byId('1')!.focusSecTotal, 0, reason: '清空同步扣减');
      for (final x in removed) {
        // P3-2：addSession 改 async（回填挪到落盘成功后触发），撤销须 await。
        await focus.addSession(x); // 撤销
      }
      expect(focus.sessions.length, 1);
      expect(p.byId('1')!.focusSecTotal, 300, reason: '撤销回填，两侧相抵');
    });
  });

  // ── P3-1 / P3-13：dueCompareKey 横向推广 ───────────────────
  group('P3-1/P3-13 dueCompareKey 横向推广与判秒统一', () {
    test('P3-13：00:00:01 也归纯日期形态（两侧判秒对称）', () {
      expect(
          dueCompareKey(DateTime(2026, 3, 10, 0, 0, 1)), DateTime(2026, 3, 10),
          reason: '序列化链路的 00:00:01 是纯日期形态变体');
      expect(dueIsPureDateForm(DateTime(2026, 3, 10, 0, 0, 1)), isTrue);
      expect(dueIsPureDateForm(DateTime(2026, 3, 10, 23, 59, 59)), isTrue);
    });

    test('Task.isOverdue 行为不变（经比较键收口）：今天到点未做不算逾期', () {
      final now = DateTime(2026, 3, 10, 11, 0);
      expect(Task.isOverdue(
          _task('1', dueDate: DateTime(2026, 3, 10, 10, 20)), now), isFalse,
          reason: '带时刻截止今天已过时刻——「逾期」仍按天比（今天不算）');
      expect(Task.isOverdue(
          _task('2', dueDate: DateTime(2026, 3, 9, 10, 20)), now), isTrue);
      expect(Task.isOverdue(
          _task('3', dueDate: DateTime(2026, 3, 11)), now), isFalse);
      // 重复任务不计逾期（口径不变）
      expect(
          Task.isOverdue(
              _task('4',
                  dueDate: DateTime(2026, 3, 1),
                  repeat: RepeatType.daily,
                  repeatMinute: 8 * 60),
              now),
          isFalse);
    });
  });

  // ── 撤销真源 UI（P2-1 / P2-2 的 widget 层）──────────────────
  group('P2-1/P2-2 showUndoSnackBar（widget）', () {
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

    testWidgets('P2-2：撤销失效 → 提示「撤销已失效：该操作已不可恢复」',
        (tester) async {
      await tester.pumpWidget(host((ctx) {
        showUndoSnackBar(
          ctx,
          content: undoContent('已删除「牛奶」'),
          onUndo: () async => false, // 缓冲已失效
        );
      }));
      await tester.tap(find.text('go'));
      await tester.pump(); // SnackBar 入场
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text('撤销已失效：该操作已不可恢复'), findsOneWidget);
      expect(find.textContaining('已删除「牛奶」'), findsNothing,
          reason: '点过撤销后不再补「窗口已结束」提示');
    });

    testWidgets('P2-1：活跃撤销条计数契约（超时 skip 判据的输入）', (tester) async {
      // P2-1 的「后继条在展示则跳过本条提示」由 [debugActiveUndoSnackCount]
      // 的计数驱动：入队 +1、closed −1。完整超时链路（Timer → 收起动画 →
      // closed → 120ms 判定 → hint 入队）横跨多次帧调度停止点，FakeAsync 下
      // 无法稳定驱动（v296 轮教训：widget 层 timer 型用例不落回归），故只钉
      // 计数契约本身——skip 判定就是 `count > 0` 一行。
      ScaffoldMessengerState? messengerRef;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              messengerRef ??= ScaffoldMessenger.of(ctx);
              return Center(
                child: TextButton(
                  onPressed: () {
                    showUndoSnackBar(
                      ctx,
                      content: undoContent('已删除「A」'),
                      onUndo: () async => true,
                    );
                    showUndoSnackBar(
                      ctx,
                      content: undoContent('已删除「B」'),
                      onUndo: () async => true,
                    );
                  },
                  child: const Text('go'),
                ),
              );
            },
          ),
        ),
      ));
      final messenger = messengerRef!;
      await tester.tap(find.text('go'));
      await tester.pump(); // A 入场中，B 已入队
      expect(debugActiveUndoSnackCount(messenger), 2,
          reason: '两条撤销横幅均已入队（A 展示中 + B 排队中）');

      // 同步发起隐藏（无 Timer 依赖）：A 收起后 closed 触发 → 计数 −1。
      messenger.hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(debugActiveUndoSnackCount(messenger), 1,
          reason: 'A 已收起（closed −1），B 仍活跃——此刻 A 若超时必须被跳过');

      messenger.hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(debugActiveUndoSnackCount(messenger), 0,
          reason: '全部收起（count=0）——此刻最后一条若超时，其提示即代表'
              '「全部窗口已结束」');
    });

    test('P2-1：「已结束」提示与操作描述绑定（undoContent 固定后缀剥取）', () {
      // undoContent 拼装的文案 → 剥出操作描述。
      expect(expiredHintFromContent(undoContent('已删除「买牛奶」')),
          '已删除「买牛奶」：撤销窗口已结束');
      expect(expiredHintFromContent(undoContent('已顺延 3 条任务到 9 月 26 日')),
          '已顺延 3 条任务到 9 月 26 日：撤销窗口已结束');
      // 不带固定后缀的自拼文案 → 退回通用文案（不误剥）。
      expect(expiredHintFromContent('已跳过今天这一次'),
          '撤销窗口已结束');
    });
  });
}

void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控列表构造 TaskProvider（绕过 load()，避免启动午夜守护定时器）。
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

Future<HabitProvider> newHabitProvider() async {
  final hp = HabitProvider();
  await hp.load();
  return hp;
}

/// P2-9 / P2-4 的 provider 断言用任务工厂。
Task _task(
  String id, {
  String title = '任务',
  DateTime? dueDate,
  RepeatType repeat = RepeatType.none,
  int? repeatMinute,
}) {
  final d = dueDate ?? DateTime(2026, 9, 1, 9, 0);
  return Task(
    id: id,
    title: title,
    priority: Priority.medium,
    category: Category.life,
    dueDate: d,
    repeat: repeat,
    repeatMinute: repeatMinute,
  );
}
