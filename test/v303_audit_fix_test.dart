import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/main.dart' show flushSnoozeQueues;
import 'package:todolist/models/task.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';

import 'test_helpers.dart';

/// v3.0.3 审计修复轮（《有条功能与操作审计报告（v3.0.3）》）回归测试。
/// 每条修复至少一个可区分用例；不落用例的项见文件尾说明。
///
/// 覆盖清单：
/// - **P2-1** 「稍后提醒」双队列消费收口（main.flushSnoozeQueues）：任务/习惯
///   队列各自独立逐条清空，杜绝旧「成对取头 × task 优先分支」对习惯 id 的
///   静默丢弃——交叉矩阵钉死消费契约（每条恰一次、单侧非空、任务先清）；
/// - **P2-2a** `snoozeTaskReminder` 完成态守卫：done / repeatEnded 早退不落点；
/// - **P2-2b** 重复任务完成族「先撤后挂」收口（TaskProvider.
///   _rescheduleRepeatOnCompletion，setStatus 入口代表）：8 个重复槽位 +
///   snooze 段 + 一次性段全部先撤，再按新状态重挂；repeatUntil 已过变体只撤不挂；
/// - **P3-1** `UserTemplate.fromJson` 元数据（id/name/description/icon）
///   安全转型：非字符串值回退默认，不再抛 TypeError 吞掉整份模板；
/// - **P3-3** 回收站到期判定 date-only 统一口径：deletedAt 日期 = 今天−N 当天
///   删除（原 Dart 精确时刻口径会晚于该口径、Kotlin date-only 严格小于会早于它，
///   三处漂移收拢为一）；边界 remaining == 1 ⇔ 明天 00:00 原生午夜重置删除；
/// - **U3-1** 9 号槽确认条内容新鲜度——**已被 v3.0.4 U2-1 推翻并收口**：
///   「今日任何非零写入都覆盖式 show」让 App 内打卡也弹常驻通知（无中生有），
///   v3.0.4 收口为「App 内打卡不生成 / 刷新确认条（show 唯一点在通知 action
///   回调），归零仍清失真条（P3-3 v3.0.2 保留）」；本文件的 U3-1 用例已按
///   v3.0.4 口径改写断言。
///
/// 不落用例：**P3-2**（Kotlin `dayDiff` UTC 化 / `cleanupTrashSqlite` 口径，
/// 无 Dart 测试面，真机复核建议见报告）；**P3-4**（main._doHabitUndo /
/// _doHabitCheckIn 的按写入结果回报接线——v3.0.4 P2-1 起 adjustCheckInValue /
/// checkInOnDay 已返回 bool，main.dart 顶层私有回调库外不可达，与 v3.0.2 轮
/// 同判）；**U3-2**
/// （cancelNotification 注释固化口径——插件 17.2.4 默认即 true，无行为面）；
/// **P3-3 Kotlin 侧**（`del <= cutoffStr` / `retentionDays <= 0`，同 P3-2 无测试面）。
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
    // 🔴 内存库是同进程共享单例：每个用例前必须重置 DB + prefs 再 load()，
    // 否则先跑的用例会往库里留数据（v2.9.7 轮实测教训）。
    LocalDatabase.resetMemoryForTest();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    // 与生产默认一致（enabled 默认 true）；restoreFromJson 会按备份的
    // notifications_enabled 改写实例字段，这里防前序用例把 false 泄漏进
    // 直接调 NotificationService 的用例（P2-2a / U3-1）。
    NotificationService.instance.enabled = true;
  });

  // flutter_local_notifications 新版 cancel 的 MethodCall arguments 是 Map
  // （{'id': ...}），裸比较 `arguments == <int>` 恒不命中——与 v302 既有断言
  // 同款的双形态防御提取。
  int? cancelIdOf(MethodCall c) {
    final a = c.arguments;
    if (a is int) return a;
    if (a is Map) return a['id'] as int?;
    return null;
  }

  // zonedSchedule / show 的 arguments 恒为 Map，id 提取（v285/v287 同款）。
  int? argsIdOf(MethodCall c) =>
      c.arguments is Map ? (c.arguments as Map)['id'] as int? : null;

  // 清空 microtask 队列：scheduleRepeatReminder / cancelRepeatReminder 是
  // fire-and-forget async（内部 for-await 与 await _scheduleMode），同步返回后
  // 调用链仍在 microtask 里逐条发往通道；若干轮 delay(Duration.zero) 后断言。
  Future<void> drainMicrotasks() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  // ── P2-1：双队列消费收口（main.flushSnoozeQueues） ────────────────
  test('P2-1：任务与习惯各 1 条——两条消费、任务先于习惯、每次单侧非空', () {
    final calls = <(String?, String?)>[];
    flushSnoozeQueues(
      (taskId, habitId) => calls.add((taskId, habitId)),
      taskQueue: ['t1'],
      habitQueue: ['h1'],
    );
    // 旧「成对取头」实现：第 1 轮 (t1, h1) 一起交给 _doSnooze，其 task 优先
    // 分支只消费 t1、h1 落进 else 被静默丢弃——期望序列只剩 1 条且习惯丢失。
    expect(calls, [('t1', null), (null, 'h1')]);
  });

  test('P2-1：任务 3 + 习惯 2 全序——任务队列先清空，习惯队列原序跟上', () {
    final calls = <(String?, String?)>[];
    flushSnoozeQueues(
      (taskId, habitId) => calls.add((taskId, habitId)),
      taskQueue: ['t1', 't2', 't3'],
      habitQueue: ['h1', 'h2'],
    );
    expect(calls, [
      ('t1', null),
      ('t2', null),
      ('t3', null),
      (null, 'h1'),
      (null, 'h2'),
    ]);
    // 消费契约钉死：恰好一次（5 条 = 3+2）且每条参数单侧非空。
    expect(calls.length, 5);
    for (final c in calls) {
      expect((c.$1 == null) != (c.$2 == null), isTrue,
          reason: '每次消费必须恰一侧非空（防再走成对取头）：$c');
    }
  });

  test('P2-1：单侧队列——另一侧为空时不产生任何多余消费', () {
    final calls = <(String?, String?)>[];
    flushSnoozeQueues(
      (taskId, habitId) => calls.add((taskId, habitId)),
      taskQueue: ['t9'],
      habitQueue: const [],
    );
    expect(calls, [('t9', null)]);

    calls.clear();
    flushSnoozeQueues(
      (taskId, habitId) => calls.add((taskId, habitId)),
      taskQueue: const [],
      habitQueue: ['h9'],
    );
    expect(calls, [(null, 'h9')]);

    calls.clear();
    flushSnoozeQueues(
      (taskId, habitId) => calls.add((taskId, habitId)),
      taskQueue: const [],
      habitQueue: const [],
    );
    expect(calls, isEmpty);
  });

  // ── P2-2a：snoozeTaskReminder 完成态守卫（服务层入口） ─────────────
  test('P2-2：已完成 / 重复已结束的任务 snooze 早退——不排任何新落点', () async {
    final done = _repeating(id: '4001', repeatMinute: 480)
        .copyWith(status: TaskStatus.done);
    final ok1 = await NotificationService.instance.snoozeTaskReminder(done);
    expect(ok1, isFalse, reason: '已完成任务不再排「稍后提醒」');

    final ended = _repeating(id: '4002', repeatMinute: 480).copyWith(
        repeatUntil:
            Task.ymdKey(today().subtract(const Duration(days: 1))));
    final ok2 = await NotificationService.instance.snoozeTaskReminder(ended);
    expect(ok2, isFalse, reason: '重复已结束的任务不再排「稍后提醒」');

    expect(
      notifCalls.where((c) => c.method == 'zonedSchedule'),
      isEmpty,
      reason: '早退不得产生任何新落点（防在途旧展示被点后复活）',
    );
  });

  test('P2-2：活跃重复任务 snooze 照常落点（snooze 独立段 id）', () async {
    final ok = await NotificationService.instance
        .snoozeTaskReminder(_repeating(id: '4003', repeatMinute: 480));
    expect(ok, isTrue);
    final zs = notifCalls.where((c) => c.method == 'zonedSchedule').toList();
    expect(zs, isNotEmpty);
    expect(
      zs.any((c) => argsIdOf(c) == 1900000000 + (4003 % 10000000)),
      isTrue,
      reason: 'snooze 必须落独立段位（1900000000 + id % 10000000），不得覆盖截止闹钟',
    );
  });

  // ── P2-2b：重复任务完成族「先撤后挂」收口（setStatus 代表入口） ────
  test('P2-2：重复任务完成时撤展示槽位 + snooze + 一次性段，再重挂重复链',
      () async {
    final p = await _buildWith(
      [_repeating(id: '3001', repeatMinute: 480)],
      notificationsEnabled: true,
      // restore 不预调度：保证 setStatus 的重挂必然发生（否则落点签名未变时
      // scheduleRepeatReminder 会跳过 zonedSchedule，淹没本用例断言）。
      rescheduleReminders: false,
    );
    notifCalls.clear();

    p.setStatus('3001', TaskStatus.done);
    await drainMicrotasks();

    final cancelIds = notifCalls
        .where((c) => c.method == 'cancel')
        .map(cancelIdOf)
        .whereType<int>()
        .toSet();
    // ① 8 个重复展示槽位先撤（旧实现只取消「尾部多余槽位」，0 号槽恰在
    //    新落点范围内被保留 → 通知栏残留「提醒 + 已完成 ✓」矛盾通知）。
    for (var d = 0; d < 8; d++) {
      expect(
        cancelIds.contains(NotificationService.repeatNotifyIdOf('3001', d)),
        isTrue,
        reason: '重复展示槽 $d 必须在完成时被撤',
      );
    }
    // ② snooze 段先撤（旧实现完全不管辖：snooze 挂起后完成任务，10 分钟后
    //    照常对已完成任务弹提醒）。
    expect(
      cancelIds.contains(1900000000 + (3001 % 10000000)),
      isTrue,
      reason: 'snooze 段必须在完成时被撤',
    );
    // ③ 一次性段照旧（cancel(id) 的既有行为，防回归）。
    expect(cancelIds.contains(3001), isTrue);
    // ④ 再按新状态重挂重复链（明天起 8 个未来落点）。
    final zs = notifCalls.where((c) => c.method == 'zonedSchedule').toList();
    expect(zs, isNotEmpty, reason: '完成重复任务后重复链必须重挂（未结束场景）');
    expect(
      zs.every((c) {
        final id = argsIdOf(c);
        return id != null && id >= 1600000000 && id < 1840000000;
      }),
      isTrue,
      reason: '重挂必须全部落在重复段位（1600000000 + …）',
    );
  });

  test('P2-2：repeatUntil 已过的重复任务完成时只撤不挂', () async {
    final p = await _buildWith(
      [
        _repeating(id: '3002', repeatMinute: 480).copyWith(
            repeatUntil:
                Task.ymdKey(today().subtract(const Duration(days: 1)))),
      ],
      notificationsEnabled: true,
      rescheduleReminders: false,
    );
    notifCalls.clear();

    p.setStatus('3002', TaskStatus.done);
    await drainMicrotasks();

    final cancelIds = notifCalls
        .where((c) => c.method == 'cancel')
        .map(cancelIdOf)
        .whereType<int>()
        .toSet();
    for (var d = 0; d < 8; d++) {
      expect(
        cancelIds.contains(NotificationService.repeatNotifyIdOf('3002', d)),
        isTrue,
        reason: '重复已结束 → 槽位 $d 照撤（旧实现什么都不做，旧闹钟照旧响）',
      );
    }
    expect(
      notifCalls.where((c) => c.method == 'zonedSchedule'),
      isEmpty,
      reason: '重复已结束 → 不得挂任何新落点',
    );
  });

  // ── P3-1：UserTemplate.fromJson 元数据安全转型 ────────────────────
  test('P3-1：UserTemplate 元数据（id/name/description/icon）非字符串不再抛错',
      () {
    // 旧实现四处裸 `as String?`：任一字段非字符串抛 TypeError →
    // loadAllWithBroken 把整份模板计为损坏（可见但不可用）。
    final bad = UserTemplate.fromJson(const {
      'id': 99,
      'name': 123,
      'description': true,
      'icon': 42,
      'items': [
        {'title': '好项', 'dueInDays': 1},
      ],
    });
    expect(isSafeTemplateId(bad.id), isTrue,
        reason: 'id 非字符串 → 走 sanitizeTemplateId 重新分配，仍是安全文件名');
    expect(bad.name, '未命名模板');
    expect(bad.description, '');
    expect(bad.iconName, 'checklist');
    expect(bad.items.length, 1, reason: 'items 与元数据互不影响，照常加载');

    // 合法值原样通过（不误伤正常模板）。
    final ok = UserTemplate.fromJson(const {
      'id': 'tpl_ok.1-x',
      'name': '正常模板',
      'description': '描述',
      'icon': 'star',
    });
    expect(ok.id, 'tpl_ok.1-x');
    expect(ok.name, '正常模板');
    expect(ok.description, '描述');
    expect(ok.iconName, 'star');
  });

  // ── P3-3：回收站到期判定 date-only 统一口径 ───────────────────────
  test('P3-3：deletedAt 日期 = 今天−N 当天删除；今天−(N−1) 保留且剩 1 天',
      () async {
    final boundary = today().subtract(const Duration(days: 30));
    final keep = today().subtract(const Duration(days: 29));
    final p = await _buildWith(const [], trash: [
      _mk(
          id: 't30',
          deletedAt:
              DateTime(boundary.year, boundary.month, boundary.day, 23, 59)),
      _mk(
          id: 't29',
          deletedAt:
              DateTime(keep.year, keep.month, keep.day, 23, 59)),
    ]);
    expect(p.trash.length, 2, reason: 'restore 不触发清理（清理只挂在 load/setTrash）');

    // 默认保留 30 与当前值相同会早退 → 先改 90 再改回 30 强制触发清理。
    await p.setTrashRetentionDays(90);
    expect(p.trash.length, 2, reason: '保留 90 天时两条均未到期');

    await p.setTrashRetentionDays(30);
    expect(p.trash.any((t) => t.id == 't30'), isFalse,
        reason: 'date-only 统一口径：deletedAt 日期 = 今天−30 → 今天删除'
            '（旧 Dart 精确时刻口径要到「删除时刻 + 30 天」才删，双端漂移）');
    expect(p.trash.any((t) => t.id == 't29'), isTrue, reason: '还差一天到期');
    final remain = p.trash.singleWhere((t) => t.id == 't29');
    expect(p.trashRemainingDays(remain), 1,
        reason: 'remaining == 1 ⇔ 明天 00:00 被原生午夜重置删除（与预告一致）');
  });

  // ── U3-1 → U2-1（v3.0.4 审计）：确认条触发面收口 ────────────────────
  // v3.0.3 U3-1 把「今日任何非零写入都覆盖式 show」落在 provider，触发面从
  // 通知 action 扩张到全部 App 内打卡（零打扰 → 每习惯一条常驻通知，且属
  // 「无中生有」）。v3.0.4 U2-1 判其为缺陷并收口：App 内写入不再生成/刷新
  // 确认条（show 唯一点在通知 action 回调 main._doHabitCheckIn / _doHabitUndo，
  // 按 P2-1 写入结果回报）；本用例按新口径改断言——归零仍清失真条（P3-3
  // v3.0.2 保留）、补昨天不动。
  test('U2-1（v3.0.4）：App 内打卡不再生成/刷新确认条；归零仍清失真条；补昨天不动',
      () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '喝水',
      emoji: '💧',
      colorValue: 1,
      weekdays: const [],
      dailyTarget: 8,
    );
    final habit = hp.habits.single;

    // 今日值 1 → 5：不得再 show（旧 v3.0.3 行为覆盖式刷新确认条——被 U2-1
    // 判为「无中生有」的常驻通知污染，收口到通知 action 回调）。
    await hp.setCheckInValue(habit, DateTime.now(), 1);
    notifCalls.clear();
    await hp.setCheckInValue(habit, DateTime.now(), 5);
    expect(notifCalls.where((c) => c.method == 'show'), isEmpty,
        reason: 'App 内打卡不生成/刷新确认条（确认条唯一 show 点在通知 action 回调）');

    // 补昨天的写入不动任何 9 号槽通知。
    notifCalls.clear();
    await hp.setCheckInValue(
        habit, today().subtract(const Duration(days: 1)), 6);
    expect(notifCalls.where((c) => c.method == 'show'), isEmpty);
    expect(
      notifCalls.where((c) =>
          c.method == 'cancel' &&
          cancelIdOf(c) ==
              NotificationService.habitConfirmNotifyIdOf(habit.id)),
      isEmpty,
      reason: '补昨天与展示中的今日确认条无关，cancel 也不得触发',
    );

    // 今日归零仍走 cancel 分支（P3-3 v3.0.2 口径保留），且不得 show。
    await hp.setCheckInValue(habit, DateTime.now(), 0);
    expect(
      notifCalls.any((c) =>
          c.method == 'cancel' &&
          cancelIdOf(c) ==
              NotificationService.habitConfirmNotifyIdOf(habit.id)),
      isTrue,
      reason: '归零后确认条已失真，必须取消',
    );
    expect(notifCalls.where((c) => c.method == 'show'), isEmpty,
        reason: '归零走 cancel，不得再弹确认条');
  });
}

// ── 脚手架 ────────────────────────────────────────────────────────

/// 用受控列表构造 TaskProvider（restoreFromJson 绕过 load()，不起午夜守护定时器）。
/// [notificationsEnabled] 写进备份由 restoreFromJson 改写 NotificationService
/// 实例开关；[rescheduleReminders] 默认关——restore 全量重排会先占
/// _armedSignatures 落点签名，淹没「完成族重挂」类断言（需要时显式开）。
Future<TaskProvider> _buildWith(
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
  // 清掉 restore 链逸出的 fire-and-forget microtask，隔离后续断言。
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return p;
}

/// 构造 daily 重复任务（daily 纯规则恒命中，跨日期稳定）。
/// [repeatMinute] 为提醒时刻（当日分钟数）：shouldScheduleRepeatReminder /
/// scheduleRepeatReminder 均以其非空为门槛。
Task _repeating({String id = 'r', int? repeatMinute}) => Task(
      id: id,
      title: '每日任务',
      priority: Priority.medium,
      category: Category.work,
      repeat: RepeatType.daily,
      repeatMinute: repeatMinute,
    );

/// 最小一次性任务工厂。
Task _mk({
  String id = '',
  String title = '任务',
  DateTime? due,
  TaskStatus status = TaskStatus.todo,
  DateTime? completedAt,
  Category category = Category.work,
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
      repeat: repeat,
      deletedAt: deletedAt,
    );
