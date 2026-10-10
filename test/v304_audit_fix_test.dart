import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';

import 'test_helpers.dart';

/// v3.0.4 审计修复轮（《有条功能与操作审计报告（v3.0.4）》11 项）回归测试。
/// 每条修复至少一个「能区分修与未修」的用例；不落用例的项见文件尾说明。
///
/// 覆盖清单：
/// - **P2-1** 持久层透传写入结果：`_persistCheckIns` 不再吞异常，
///   `setCheckInValue` / `checkInOnDay` 返回 bool——DB 异常时通知 action 回调
///   能据此不谎报「已打卡 ✓」（旧实现 `.catchError` 分支属不可达死代码）；
/// - **P2-2** 完成族撤挂按「是否影响今日」门控：未来日 markOccurrenceDone /
///   skipOccurrence 不再撤今日的 8 槽 + snooze + 一次性段（snooze 撤得掉、
///   不重建，旧实现属静默丢失）；今日路径照撤（回归护栏）；
/// - **P3-1** `_applyTaskUpdate` 对导入覆盖翻转的完成态对账提醒（完成族第 6
///   个写入者）：todo→done 撤一次性截止提醒、done→todo 恢复；
/// - **P3-2** 回收站到期口径改日历减法（清理侧构造器进位 / 预告侧 UTC 日历差），
///   跨月 / 跨年边界 remaining 语义不变式；
/// - **P3-3** `checkDailyReset` 跨天分支补回收站清理（进程存活跨午夜后
///   `_persist` 不再把原生已删行复活回 DB）；
/// - **U2-2** 确认条 payload 携带展示日（编解码往返 + 旧格式兼容）+
///   `cancelAllConfirmNotifications` 跨天批量清理 9 号槽；
/// - **U3-1** `showSnoozeUnavailableConfirm`：「稍后提醒」不可执行分支的覆盖式
///   如实回执（任务段 / 习惯段各自落位，不冲突）；
/// - **U3-3** `restoreTaskSnapshot` 撤提醒收口单点（重复任务撤一轮 = 10 次
///   cancel，旧实现入口 + 重排函数双重撤 = 20 次）。
///
/// 不落用例：
/// - **P2-2 / U3-1 的 main._doSnooze / P2-1 的 main 按结果回报接线**——main.dart
///   顶层私有回调库外不可达（v3.0.2 / v3.0.3 轮同判）；其依赖的 provider /
///   service 层结果信号（bool 返回值、snoozeTaskReminder 返回 false）已在本文件
///   与 v303 P2-2a 用例钉死；
/// - **U2-1**（App 内打卡不生成确认条）——provider 层行为，v303 U3-1 用例已按
///   v3.0.4 口径改写断言，不重复；
/// - **P3-4**（update 兜底 releaseUrl 切 releases-4）——schema 层行为，
///   update_checker_schema_test 两处断言已同步改写，不重复；
/// - **P3-2 的 DST 偏差本身**——测试宿主时区无夏令时，无法本地构造 ±1h 场景
///   （真机复核建议见报告）；此处钉「日历减法在跨月 / 跨年进位下的语义不变式」。
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
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    NotificationService.instance.enabled = true;
  });

  // v303 同款双形态防御提取（新版插件 cancel 的 arguments 是 Map）。
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
  /// [rescheduleReminders] 默认关——restore 全量重排会先占落点签名，淹没
  /// 「撤挂」类断言（需要「已挂出调度」时显式开）。
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

  /// 构造 daily 重复任务（纯规则恒命中，跨日期稳定）。
  Task repeating({String id = 'r', int? repeatMinute}) => Task(
        id: id,
        title: '每日任务',
        priority: Priority.medium,
        category: Category.work,
        repeat: RepeatType.daily,
        repeatMinute: repeatMinute,
      );

  /// 最小一次性任务工厂。
  Task mk({
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

  // ── P2-1：持久层透传写入结果 ──────────────────────────────────────
  test('P2-1：DB 异常经 setCheckInValue / checkInOnDay 透传为 false；成功路径 true',
      () async {
    final (hp, habit) = await habitWithTarget();
    // 成功路径：落盘成功 → true（通知 action 据此回报「已打卡 ✓ / 已记 x/y」）。
    expect(await hp.setCheckInValue(habit, DateTime.now(), 1), isTrue);

    // 失败路径：关闭内存后端 → replaceCheckIns 走 sqflite 平台通道（测试宿主
    // 无实现）→ 抛「databaseFactory not initialized」→ 旧实现在此被
    // _persistCheckIns 的 try/catch 吞掉、Future 正常完成，外层
    // .then(成功回报) 照走（谎报）；修复后必须透传 false。
    LocalDatabase.testUseMemory = false;
    bool quantifiedOk = true;
    bool boolOk = true;
    bool threw = false;
    try {
      quantifiedOk = await hp.setCheckInValue(habit, DateTime.now(), 2);
      boolOk = await hp.checkInOnDay(habit, DateTime.now(), value: 3);
    } catch (_) {
      threw = true; // Future 不得 reject（P2-1 修复后异常在 provider 层转为结果值）
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(threw, isFalse, reason: '异常必须转为结果值而非 reject（.catchError 不是主路径）');
    expect(quantifiedOk, isFalse,
        reason: 'DB 异常必须透传 false——main._doHabitCheckIn 据此不回报「已记 x/y」'
            '（旧实现吞掉后恒 true，通知栏在 DB 异常时谎报）');
    expect(boolOk, isFalse,
        reason: 'checkInOnDay 同口径透传（布尔打卡通知 action 的回报依据）');
  });

  test('P2-1：幂等早退返回 true（无写入 ≠ 失败，通知按钮的重复点击仍回确认）',
      () async {
    final (hp, habit) = await habitWithTarget();
    expect(await hp.setCheckInValue(habit, DateTime.now(), 1), isTrue);
    // 值未变 → 无操作：语义上目标态已达成，不得被误判为失败而吞掉确认回报。
    expect(await hp.setCheckInValue(habit, DateTime.now(), 1), isTrue);
    // checkInOnDay 幂等（已有记录且未显式给 value）。
    expect(await hp.checkInOnDay(habit, DateTime.now()), isTrue);
  });

  // ── P2-2：完成族撤挂按「是否影响今日」门控 ────────────────────────
  test('P2-2：未来日 markOccurrenceDone 不撤今日调度（8 槽 / snooze / 一次性段），'
      '且落点仍真实重算', () async {
    final p = await buildWith(
      [repeating(id: '6001', repeatMinute: 480)],
      notificationsEnabled: true,
      rescheduleReminders: true, // restore 挂出 8 槽，模拟「今日提醒在途」
    );
    await drainMicrotasks();
    // 额外挂一条 snooze（独立 8 号槽），验证「今日挂起的稍后提醒不被未来日波及」。
    final ok = await NotificationService.instance
        .snoozeTaskReminder(p.byId('6001')!);
    expect(ok, isTrue);
    notifCalls.clear();

    // 在 3 天后的预览里标记完成（旧实现：无条件撤 8 槽 + snooze + 一次性段，
    // 且重挂只走重复链 → snooze 静默蒸发）。
    p.markOccurrenceDone('6001', today().add(const Duration(days: 3)));
    await drainMicrotasks();

    expect(
      notifCalls.where((c) => c.method == 'cancel'),
      isEmpty,
      reason: '未来日完成不得撤任何今日调度（旧实现无条件 _cancelRemindersFor）',
    );
    expect(
      notifCalls.where((c) => c.method == 'zonedSchedule'),
      isNotEmpty,
      reason: '落点仍须真实重算（_repeatContentSig 含 doneDates，未来落点跳过已完成日）'
          '——「不撤」不得退化成「不重排」',
    );
  });

  test('P2-2 回归：今日 markOccurrenceDone 仍先撤后挂（门控不得误伤今日路径）',
      () async {
    final p = await buildWith(
      [repeating(id: '6002', repeatMinute: 480)],
      notificationsEnabled: true,
      rescheduleReminders: false,
    );
    notifCalls.clear();
    p.markOccurrenceDone('6002', today());
    await drainMicrotasks();

    final cancelIds = notifCalls
        .where((c) => c.method == 'cancel')
        .map(cancelIdOf)
        .whereType<int>()
        .toSet();
    for (var d = 0; d < 8; d++) {
      expect(
        cancelIds.contains(NotificationService.repeatNotifyIdOf('6002', d)),
        isTrue,
        reason: '今日完成必须撤重复展示槽 $d（v3.0.3 P2-2 的既有修复，防门控回归）',
      );
    }
    expect(cancelIds.contains(6002), isTrue,
        reason: '一次性段照撤（cancel(id) 既有行为）');
  });

  test('P2-2 同型：未来日 skipOccurrence / unskipOccurrence 不撤今日调度',
      () async {
    final p = await buildWith(
      [repeating(id: '6003', repeatMinute: 480)],
      notificationsEnabled: true,
      rescheduleReminders: true,
    );
    await drainMicrotasks();
    notifCalls.clear();

    p.skipOccurrence('6003', day: today().add(const Duration(days: 3)));
    await drainMicrotasks();
    expect(notifCalls.where((c) => c.method == 'cancel'), isEmpty,
        reason: '未来日跳过与 markOccurrenceDone 同型：不得撤今日调度');
    expect(notifCalls.where((c) => c.method == 'zonedSchedule'), isNotEmpty,
        reason: '首个落点须顺延（skipDates 进入内容签名）');

    notifCalls.clear();
    p.unskipOccurrence('6003', day: today().add(const Duration(days: 3)));
    await drainMicrotasks();
    expect(notifCalls.where((c) => c.method == 'cancel'), isEmpty,
        reason: '撤销未来日跳过同口径：不撤今日调度');
    expect(notifCalls.where((c) => c.method == 'zonedSchedule'), isNotEmpty);
  });

  // ── P3-1：导入覆盖翻转完成态对账提醒 ──────────────────────────────
  test('P3-1：导入覆盖 todo→done 撤一次性截止提醒（旧实现到点对已完成任务弹提醒）',
      () async {
    final due = today().add(const Duration(days: 3));
    final p = await buildWith(
      [mk(id: '7001', due: due, title: '买菜')],
      notificationsEnabled: true,
      rescheduleReminders: false,
    );
    // 预挂一次性截止提醒（模拟既有调度）。
    await NotificationService.instance.scheduleForTask(p.byId('7001')!);
    await drainMicrotasks();
    notifCalls.clear();

    // 导入覆盖：同 id + 同指纹（标题/截止一致），源显式 status=done。
    final r = p.importDedup(
      [mk(id: '7001', due: due, title: '买菜').copyWith(status: TaskStatus.done)],
      ['7001@youtiao'],
      overwrite: true,
      statuses: const [TaskStatus.done],
    );
    expect(r.overwritten, 1);
    await drainMicrotasks();

    final cancelIds = notifCalls
        .where((c) => c.method == 'cancel')
        .map(cancelIdOf)
        .whereType<int>()
        .toSet();
    expect(cancelIds.contains(7001), isTrue,
        reason: '完成态翻转必须对账提醒：todo→done 的一次性截止提醒不撤，'
            '到点会对已完成任务弹提醒且永不自愈（旧 remindersChanged 不含 status）');
  });

  test('P3-1：导入覆盖 done→todo 恢复一次性截止提醒（旧实现需重启 App 才恢复）',
      () async {
    final due = today().add(const Duration(days: 3));
    final p = await buildWith(
      [
        mk(id: '7002', due: due, title: '缴费',
            status: TaskStatus.done, completedAt: DateTime.now()),
      ],
      notificationsEnabled: true,
      rescheduleReminders: false,
    );
    notifCalls.clear();

    final r = p.importDedup(
      [mk(id: '7002', due: due, title: '缴费')],
      ['7002@youtiao'],
      overwrite: true,
      statuses: const [TaskStatus.todo],
    );
    expect(r.overwritten, 1);
    await drainMicrotasks();

    final zs = notifCalls.where((c) => c.method == 'zonedSchedule').toList();
    expect(
      zs.any((c) => argsIdOf(c) == 7002),
      isTrue,
      reason: 'done→todo 必须重挂截止提醒（旧实现 remindersChanged=false，'
          '需重启 App 才恢复）',
    );
  });

  // ── P3-2：回收站到期口径日历减法 ──────────────────────────────────
  test('P3-2：清理侧 cutoff 与预告侧 remaining 共用日历减法——今天到期 ⇔ 被清；'
      '构造器进位覆盖跨月 / 跨年边界', () async {
    final now = DateTime.now();
    for (final n in const [1, 7, 30, 90]) {
      // DateTime(y, m, d − N) 构造器日历减法（与修复后清理侧 cutoff 同一语义），
      // d−N 跨月 / 跨年由构造器进位——覆盖「subtract(Duration) 在 DST 切换日
      // 偏移 1h」修复所保护的边界形态（测试宿主无 DST，钉语义不变式）。
      // 变体 1：deletedAt 日期 = 今天−N、保留期 = N → 今天 00:00 到期：
      // 预告侧（UTC 日历差）与清理侧（构造器 cutoff）同判删除。
      // 保留期经 setTrashRetentionDays 显式设为 N（默认恒 30，与循环变量无关）；
      // 先改 90 再改 N 强制触发清理（v303 同款，防 n=30 时同值早退）。
      final p = await buildWith(const [], trash: [
        mk(id: 'd$n', deletedAt: DateTime(now.year, now.month, now.day - n, 12)),
      ]);
      expect(p.trash, hasLength(1), reason: 'N=$n：restore 不触发清理');
      await p.setTrashRetentionDays(n == 90 ? 30 : 90);
      await p.setTrashRetentionDays(n); // 触发清理
      expect(p.trash, isEmpty,
          reason: 'N=$n：deletedAt 日期 = 今天−N → 今天 00:00 到期，'
              '清理侧必须删除（trashRemainingDays 同判为 0）');

      // 变体 2：deletedAt = 今天−(N−1) → 未到期保留，remaining == 1
      //（明天 00:00 删除，v3.0.3 口径回归）。
      final p2 = await buildWith(const [], trash: [
        mk(id: 'k$n', deletedAt: DateTime(now.year, now.month, now.day - (n - 1), 12)),
      ]);
      await p2.setTrashRetentionDays(n == 90 ? 30 : 90);
      await p2.setTrashRetentionDays(n); // 触发一次清理（未到期 → 保留）
      expect(p2.trash, hasLength(1), reason: 'N=$n：差一天到期，不得被清理');
      expect(p2.trashRemainingDays(p2.trash.single), 1,
          reason: 'N=$n：remaining == 1 ⇔ 明天 00:00 被原生午夜重置删除'
              '（预告侧 UTC 日历差，与清理侧同一减法语义）');
    }
  });

  // ── P3-3：跨天分支补回收站清理 ────────────────────────────────────
  test('P3-3：checkDailyReset 跨天分支清理过期回收站（进程存活跨午夜不再复活）',
      () async {
    final p = await buildWith(const [], trash: [
      mk(
          id: 't90',
          deletedAt: today().subtract(const Duration(days: 30))),
    ]);
    expect(p.trash, hasLength(1),
        reason: 'restore 不触发清理（清理只挂 load / setTrashRetentionDays / 本修复的跨天分支）');

    // restore 后 _lastResetDay 基线未知（null）→ checkDailyReset 按「已跨天」
    // 处理（宁可多排不可漏排）→ 必须清理。旧实现什么都不做：内存 _trash 不重载，
    // 此后任意编辑触发 _persist 的按 id 差量 upsert 会把原生已删行复活回 DB。
    p.checkDailyReset();
    expect(p.trash, isEmpty,
        reason: '跨天分支必须与原生午夜清理同口径（旧实现窗口可持续数天，且'
            'trashRemainingDays 返回负数与「理论上已先于展示被清理」注释矛盾）');
  });

  // ── U2-2：确认条 payload 展示日 + 跨天批量清理 ────────────────────
  test('U2-2：payload 日期编解码往返 + 旧格式（无日期）兼容 + dateKey 格式',
      () {
    // static 方法调用非常量表达式，不得 const（const_eval_method_invocation）。
    final entity =
        NotificationService.habitEntityWithDate('42', '2026-10-10');
    expect(entity, '42|2026-10-10');
    expect(
        NotificationService.parseHabitId('habit:$entity'), '42',
        reason: 'parseHabitId 剥离日期后缀（snooze / 打卡 action 复用同一解析）');
    final parsed = NotificationService.parseHabitEntity('habit:$entity');
    expect(parsed, '42|2026-10-10');
    expect(NotificationService.habitEntityId(parsed!), '42');
    expect(NotificationService.habitEntityDate(parsed), '2026-10-10');

    // 旧版 payload（无日期后缀）：id 照常解析、日期为 null（处理端宽容按今日）。
    expect(NotificationService.parseHabitId('habit:42'), '42');
    final legacy = NotificationService.parseHabitEntity('habit:42');
    expect(NotificationService.habitEntityId(legacy!), '42');
    expect(NotificationService.habitEntityDate(legacy), isNull);

    // dateKey 与 CheckIn.dateKey 同格式（yyyy-MM-dd，补零）。
    expect(
        NotificationService.habitConfirmDateKey(DateTime(2026, 3, 7)),
        '2026-03-07');
  });

  test('U2-2：cancelAllConfirmNotifications 批量清全部习惯的 9 号槽（跨天残留）',
      () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
        title: '喝水', emoji: '💧', colorValue: 1, weekdays: const []);
    await hp.addHabit(
        title: '跑步', emoji: '🏃', colorValue: 2, weekdays: const []);
    final ids = hp.habits.map((h) => h.id).toList();

    hp.cancelAllConfirmNotifications();
    await drainMicrotasks();

    final cancelIds = notifCalls
        .where((c) => c.method == 'cancel')
        .map(cancelIdOf)
        .whereType<int>()
        .toSet();
    for (final id in ids) {
      expect(
        cancelIds
            .contains(NotificationService.habitConfirmNotifyIdOf(id)),
        isTrue,
        reason: '跨天必须清掉 9 号槽确认条（内容过期 + 「撤销」会错日写入）',
      );
    }
  });

  // ── U3-1：「稍后提醒」不可执行的覆盖式回执 ─────────────────────────
  test('U3-1：showSnoozeUnavailableConfirm——任务段 / 习惯段各自落位，不静默',
      () async {
    // 任务侧：实体已删 / repeatEnded / 服务层守卫早退（snoozeTaskReminder 返回
    // false）时由 main._doSnooze 回执——本用例钉服务层行为。
    await NotificationService.instance
        .showSnoozeUnavailableConfirm('9001', title: '买菜');
    var shows = notifCalls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(1), reason: '旧实现静默 return，点「稍后提醒」毫无反应');
    expect(argsIdOf(shows.single), 9001,
        reason: '任务侧挂一次性段（_notifyIdOf），在原提醒位覆盖');
    final args1 = Map<String, dynamic>.from(shows.single.arguments as Map);
    expect(args1['title'], '提醒已结束');
    expect(args1['body'] as String, contains('买菜'));

    // 习惯侧：挂 9 号槽（habitConfirmNotifyIdOf），不与任务段冲突。
    await NotificationService.instance
        .showSnoozeUnavailableConfirm('habit-x', isHabit: true);
    shows = notifCalls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(2));
    expect(argsIdOf(shows.last),
        NotificationService.habitConfirmNotifyIdOf('habit-x'),
        reason: '习惯侧必须挂习惯段 9 号槽（任务段 id 与习惯 id 同为数字，混段必撞）');
    final args2 = Map<String, dynamic>.from(shows.last.arguments as Map);
    expect(args2['title'], '提醒已结束');
  });

  // ── U3-3：restoreTaskSnapshot 撤提醒收口单点 ──────────────────────
  test('U3-3：重复任务 restoreTaskSnapshot 只撤一轮（10 次 cancel，旧实现 20 次）',
      () async {
    final t = repeating(id: '8001', repeatMinute: 480);
    final p = await buildWith([t], notificationsEnabled: true);
    notifCalls.clear();

    p.restoreTaskSnapshot(t.copyWith(title: '改标题'));
    await drainMicrotasks();

    final cancels =
        notifCalls.where((c) => c.method == 'cancel').toList();
    // 新口径：入口 _cancelRemindersFor 撤一次。撤一轮的 MethodCall 构成
    //（v303 P2-2b 断言佐证）：cancel(id) 内部撤两段（一次性段 id + snooze 段
    // 1900000000 + id%1e7）+ cancelRepeatReminder 逐槽 8 次 = 10 次；
    // 旧口径：入口 + _rescheduleRepeatOnCompletion 各撤一轮 = 20 次。
    expect(cancels.length, 10,
        reason: '撤提醒的唯一责任点收口到入口一次（幂等冗余的插件 IPC 往返消除）');
    expect(cancels.where((c) => cancelIdOf(c) == 8001).length, 1,
        reason: '一次性段恰好撤一次');
    expect(
      cancels
          .where((c) => cancelIdOf(c) == 1900000000 + (8001 % 10000000))
          .length,
      1,
      reason: 'snooze 段恰好撤一次（cancel(id) 顺带撤 snooze 段的既有行为）',
    );
    expect(
      cancels.where((c) {
        final id = cancelIdOf(c);
        return id != null && id >= 1600000000 && id < 1840000000;
      }).length,
      8,
      reason: '重复展示槽 0..7 恰好撤一轮',
    );
    // 撤完仍按快照重挂（P2-4 v2.9.6 的「先撤再重排」语义保持）。
    expect(notifCalls.where((c) => c.method == 'zonedSchedule'), isNotEmpty,
        reason: '入口撤掉后必须由重排链按快照重挂（防幽灵提醒的既有修复不得回归）');
  });
}
