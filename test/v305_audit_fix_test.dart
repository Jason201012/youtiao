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

/// v3.0.5 审计修复轮（《有条功能与操作审计报告（v3.0.5）》9 项）回归测试。
/// 每条修复至少一个「能区分修与未修」的用例；不落用例的项见文件尾说明。
///
/// 覆盖清单：
/// - **P2-1** 任务侧落盘结果透传：`_persist` 返回 bool，`setStatus` / `toggleDone`
///   / `restoreTaskSnapshotPersisted` 透传——DB 异常时通知「完成 / 撤销完成」
///   action 不再谎报（与习惯侧 v3.0.4 P2-1 同构缺口的收口）；
/// - **P3-1** 冷启动跨天残留清理：load() 恢复的习惯集合可被
///   `cancelAllConfirmNotifications` 覆盖（main 启动链路清一次 9 号槽；
///   main 私有链路库外不可达，v3.0.2 / v3.0.4 轮同判，此处钉 provider 侧前提）；
/// - **P3-2** 写失败回滚内存 + bool 消费：`setCheckInValue` 失败回滚到写前值、
///   `deleteHabit` 失败回滚返回 null、`updateHabit` 失败回滚返回 false；
/// - **P3-3** `_applyTaskUpdate` 的 remindersChanged 判定补入 doneDates——
///   导入覆盖改写完成历史（status 不变）时立即重排提醒（cancel 必须发生）；
/// - **U2-1** 确认条刷新折中：`markConfirmShown` 登记后 App 内写入覆盖刷新
///   9 号槽（内容新鲜度回归修复），无标记不「无中生有」（v3.0.4 口径保持）；
/// - **U3-1** `showHabitEndedConfirm`：已删 / 已归档习惯的「打卡 / 撤销」action
///   覆盖式回执落 9 号槽；
/// - **U3-2** 文案精度：过期确认回执回显 payload 展示日（不再写死「昨天」）；
///   snooze 调度异常分支「顺延失败」与已结束分支「不会再响」区分。
///
/// 不落用例：
/// - **P2-1 / P3-1 / U3-1 / U2-1 的 main 接线**（_doComplete / _doTaskUndo /
///   启动链路清理 / _doHabitCheckIn 已删回执 / markConfirmShown 登记）——
///   main.dart 顶层私有回调库外不可达（v3.0.2 / v3.0.3 / v3.0.4 轮同判）；
///   其依赖的 provider / service 层信号已在本文件钉死；
/// - **U2-2 / U3-3**（README 下载引导 / update_checker doc 注释）——纯文档面，
///   无行为可测；
/// - **U3-2 的 main._doSnooze 分支区分**（repeatEnded / archived 预拦截后
///   rescheduleFailed: true）——main 私有；service 层两形态文案已钉；
/// - **P3-2 的 App 内 SnackBar 接线**（habit_screen 各写入口）——widget 面依赖
///   DB 异常注入 + 帧驱动，provider 层返回值已钉死，UI 按 bool 分支属直接消费。
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

  // v303 / v304 同款双形态防御提取（新版插件 cancel 的 arguments 是 Map）。
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
  }) =>
      Task(
        id: id,
        title: title,
        priority: Priority.medium,
        category: Category.work,
        dueDate: due,
        status: status,
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

  // ── P2-1：任务侧落盘结果透传（习惯侧 v3.0.4 P2-1 的同构缺口收口） ──
  test('P2-1：DB 异常经 setStatus / toggleDone / restoreTaskSnapshotPersisted '
      '透传为 false；成功路径 true', () async {
    final todo = mk(id: '7001');
    final p = await buildWith([todo]);
    final todoSnap = p.byId('7001')!;
    // 成功路径：落盘成功 → true（main._doComplete 据此弹「已完成 ✓」）。
    expect(await p.setStatus('7001', TaskStatus.done), isTrue);

    // 失败路径：关闭内存后端 → replaceTasks 走 sqflite 平台通道（测试宿主无
    // 实现）→ 抛「databaseFactory not initialized」→ 旧实现在此被 _persist 的
    // try/catch 吞掉、Future 正常完成且通知 action 无条件弹「已完成 ✓」（谎报，
    // 重启后任务复活为未完成）；修复后必须透传 false。
    LocalDatabase.testUseMemory = false;
    bool setStatusOk = true;
    bool restoreOk = true;
    bool toggleOk = true;
    bool threw = false;
    TaskStatus afterSet = TaskStatus.todo;
    TaskStatus afterRestore = TaskStatus.todo;
    TaskStatus afterToggle = TaskStatus.todo;
    try {
      setStatusOk = await p.setStatus('7001', TaskStatus.todo);
      afterSet = p.byId('7001')!.status;
      restoreOk = await p.restoreTaskSnapshotPersisted(todoSnap);
      afterRestore = p.byId('7001')!.status;
      toggleOk = await p.toggleDone('7001');
      afterToggle = p.byId('7001')!.status;
    } catch (_) {
      threw = true; // Future 不得 reject（异常在 provider 层转为结果值）
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(threw, isFalse, reason: '异常必须转为结果值而非 reject');
    expect(setStatusOk, isFalse,
        reason: 'DB 异常必须透传 false——main._doComplete 据此不弹「已完成 ✓」');
    expect(afterSet, TaskStatus.todo,
        reason: '内存写入已生效（任务侧不做内存回滚，报告 P2-1 建议第 4 条：'
            'App 内路径口径与 habit 侧 P3-2 区分）');
    expect(restoreOk, isFalse,
        reason: 'restoreTaskSnapshotPersisted 落盘失败返回 false——'
            'main._doTaskUndo 据此不弹「已撤销完成」（旧 restoreTaskSnapshot 的 '
            'bool 只表达「任务是否存在」，落盘失败照样谎报成功）');
    expect(afterRestore, TaskStatus.todo,
        reason: '快照已应用到内存：通知面不回报，App 内显示真实状态');
    expect(toggleOk, isFalse, reason: 'toggleDone 同口径透传');
    expect(afterToggle, TaskStatus.done,
        reason: 'toggleDone 内存翻转已生效（落盘失败仅透传 false，不回滚内存）');
  });

  test('P2-1：任务不存在 = false、幂等早退 = true（返回值语义矩阵）', () async {
    final p = await buildWith([mk(id: '7002')]);
    expect(await p.setStatus('ghost', TaskStatus.done), isFalse,
        reason: '任务不存在：无写入可言成功（main._doComplete 已有 byId 预检，'
            '此为 provider 层兜底语义）');
    expect(await p.toggleDone('ghost'), isFalse);
    expect(await p.restoreTaskSnapshotPersisted(mk(id: 'ghost')), isFalse,
        reason: '快照失效（任务已删）= false → main._doTaskUndo 回「已失效」');
    expect(await p.setStatus('7002', TaskStatus.todo), isTrue,
        reason: '已是请求态：幂等早退 = true（与习惯侧 setCheckInValue 同口径，'
            '「目标态已达成」不是失败）');
    expect(await p.toggleDone('7002'), isTrue, reason: '正常翻转 + 落盘成功');
  });

  // ── P3-3：remindersChanged 判定补入 doneDates ─────────────────────
  test('P3-3：导入覆盖改写 doneDates（status 恰好不变）立即重排提醒（cancel 必须发生）',
      () async {
    final p = await buildWith(
      [repeating(id: '9101', repeatMinute: 480)],
      notificationsEnabled: true,
      rescheduleReminders: true, // restore 挂出 8 槽，模拟「提醒在途」
    );
    await drainMicrotasks();
    notifCalls.clear();

    // 同 id + 同指纹（标题/截止一致）→ 覆盖分支；来源携带不同的完成历史、
    // 不带状态列（statuses: [null] → status 保留原值，statusChanged 不命中）。
    // 旧实现：remindersChanged 不含 doneDates → 两个判定都不命中 → 不重排，
    // 重复提醒落点陈旧 ≤15 分钟（靠 _repeatContentSig 守护自愈）。
    final src = repeating(id: '9101', repeatMinute: 480).copyWith(
      doneDates: [Task.ymdKey(today().subtract(const Duration(days: 1)))],
    );
    final r = await p.importDedup([src], [null], overwrite: true, statuses: [null]);
    expect(r.overwritten, 1, reason: '同 id 同指纹 → 覆盖分支命中');
    expect(p.byId('9101')!.doneDates, isNotEmpty,
        reason: '前提：_mergeOverwriteFields 以来源 doneDates 覆盖（报告前提复算）');
    await drainMicrotasks();

    expect(
      notifCalls.where((c) => c.method == 'cancel'),
      isNotEmpty,
      reason: 'doneDates 必须命中 remindersChanged（落点序列已变 → 先撤后挂；'
          '旧实现零 cancel = 缺口本体）',
    );
  });

  // ── P3-2：写失败回滚内存 + bool 消费 ──────────────────────────────
  test('P3-2：setCheckInValue 落盘失败回滚内存（UI 显示的即已落盘的）', () async {
    final (hp, habit) = await habitWithTarget();
    expect(await hp.setCheckInValue(habit, DateTime.now(), 1), isTrue);

    LocalDatabase.testUseMemory = false;
    bool ok = true;
    bool threw = false;
    try {
      ok = await hp.setCheckInValue(habit, DateTime.now(), 5);
    } catch (_) {
      threw = true;
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(threw, isFalse);
    expect(ok, isFalse, reason: '落盘失败透传 false（P2-1，v3.0.4 基线保留）');
    expect(hp.todayValue(habit), 1,
        reason: '内存必须回滚到写前值——旧实现内存已改 + notifyListeners 已发，'
            'App 内乐观显示 5/8、重启静默回退（报告 P3-2 第 1 条）');
  });

  test('P3-2：deleteHabit 落盘失败回滚（返回 null，习惯与打卡记录均在）', () async {
    final (hp, habit) = await habitWithTarget();
    await hp.setCheckInValue(habit, DateTime.now(), 2);

    LocalDatabase.testUseMemory = false;
    final snap = await hp.deleteHabit(habit.id);
    LocalDatabase.testUseMemory = true;

    expect(snap, isNull,
        reason: '删除未生效——UI 据此不弹「已删除」撤销横幅（旧实现静默丢落盘结果，'
            'UI 显示已删、DB 里还在，重启「复活」）');
    expect(hp.byId(habit.id), isNotNull, reason: '内存回滚：习惯仍在');
    expect(hp.todayValue(habit), 2, reason: '打卡记录一并回滚');
  });

  test('P3-2：updateHabit 落盘失败回滚（返回 false，字段还原）', () async {
    final (hp, habit) = await habitWithTarget();

    LocalDatabase.testUseMemory = false;
    bool ok = true;
    bool threw = false;
    try {
      ok = await hp.updateHabit(habit, title: '改名');
    } catch (_) {
      threw = true;
    } finally {
      LocalDatabase.testUseMemory = true;
    }
    expect(threw, isFalse);
    expect(ok, isFalse, reason: '编辑层据本结果停留并如实提示（旧实现恒 void）');
    expect(hp.byId(habit.id)!.title, '喝水',
        reason: '内存回滚：改名未生效（旧实现改名静默丢失落盘、重启回退）');
  });

  // ── P3-1：冷启动跨天残留清理（provider 侧前提） ───────────────────
  test('P3-1：load() 恢复的习惯集合可被 cancelAllConfirmNotifications 覆盖', () async {
    final (hp, habit) = await habitWithTarget();
    await hp.setCheckInValue(habit, DateTime.now(), 1);

    // 模拟冷启动：新 provider 从同一内存库 load（进程内的确认条标记等全部丢失，
    // 通知栏残留仍在——Android 通知跨进程重启保留）。
    final hp2 = HabitProvider();
    await hp2.load();
    expect(hp2.habits.map((h) => h.id), contains(habit.id),
        reason: '冷启动恢复出确认条所属的习惯');
    notifCalls.clear();
    hp2.cancelAllConfirmNotifications();
    await drainMicrotasks();
    expect(
      notifCalls.any((c) =>
          c.method == 'cancel' &&
          cancelIdOf(c) ==
              NotificationService.habitConfirmNotifyIdOf(habit.id)),
      isTrue,
      reason: 'P3-1：启动链路清一次 9 号槽——load() 把跨天基线置为当天后 '
          'onDayChanged 不触发，冷启动残留只能靠这里清（main 接线库外不可达，'
          '此处钉 provider 侧可达性）',
    );
  });

  // ── U2-1：确认条覆盖刷新折中（内容新鲜度恢复） ─────────────────────
  test('U2-1：markConfirmShown 后 App 内写入覆盖刷新确认条；无标记不无中生有',
      () async {
    final (hp, habit) = await habitWithTarget();

    // 模拟通知 action 已弹确认条（main._markAndShowHabitConfirm 在 show 前
    // markConfirmShown——登记动作本身不可达，直接调 provider 等价入口）。
    hp.markConfirmShown(habit.id);
    notifCalls.clear();
    await hp.setCheckInValue(habit, DateTime.now(), 5);
    final shows = notifCalls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(1),
        reason: '折中方案恢复：确认条内容新鲜度——「通知打卡已记 1/8 → App 内改 '
            '5/8」不再停在 1/8（v3.0.3 U3-1 修复的失真回归）');
    expect(argsIdOf(shows.single),
        NotificationService.habitConfirmNotifyIdOf(habit.id),
        reason: '刷新落 9 号槽（覆盖式，不叠加新通知）');
    final args = Map<String, dynamic>.from(shows.single.arguments as Map);
    expect(args['title'], '已记 5/8',
        reason: '刷新内容 = 写入后的真实进度（失真窗口闭合）');

    // 归零：cancel + 标记清除（P3-3 v3.0.2 失真清理口径保留）。
    await hp.setCheckInValue(habit, DateTime.now(), 0);
    expect(
      notifCalls.any((c) =>
          c.method == 'cancel' &&
          cancelIdOf(c) ==
              NotificationService.habitConfirmNotifyIdOf(habit.id)),
      isTrue,
      reason: '归零清失真条',
    );

    // 标记已清：再次写入不得「无中生有」（v3.0.4 U2-1 的收口成果保持）。
    notifCalls.clear();
    await hp.setCheckInValue(habit, DateTime.now(), 3);
    expect(notifCalls.where((c) => c.method == 'show'), isEmpty,
        reason: '确认条不存在（标记未登记）→ App 内写入不生成任何确认条');
  });

  // ── U3-1：已删 / 已归档的覆盖式回执 ───────────────────────────────
  test('U3-1：showHabitEndedConfirm 落 9 号槽（已删 / 已归档不再「点了没用」）',
      () async {
    await NotificationService.instance.showHabitEndedConfirm('habit-e1');
    final shows = notifCalls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(1),
        reason: '旧实现静默 return——在途旧闹钟被点后通知随 action 消散、毫无反应');
    expect(argsIdOf(shows.single),
        NotificationService.habitConfirmNotifyIdOf('habit-e1'),
        reason: '与打卡确认同槽（覆盖式），残留旧确认条一并被覆盖');
    final args = Map<String, dynamic>.from(shows.single.arguments as Map);
    expect(args['title'], '习惯已结束');
  });

  // ── U3-2：回执文案精度 ────────────────────────────────────────────
  test('U3-2：过期确认回执回显 payload 展示日（不再写死「昨天」）；异常值退中性文案',
      () async {
    await NotificationService.instance
        .showHabitConfirmExpired('habit-x', dateKey: '2026-10-09');
    var shows = notifCalls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(1));
    var args = Map<String, dynamic>.from(shows.single.arguments as Map);
    expect(args['body'] as String, contains('10月9日'),
        reason: '冷启动残留场景该条可能已是数天前，按实际日期回显（U3-2 第 1 条）');
    expect(args['body'] as String, isNot(contains('昨天')));

    // dateKey 缺省（旧版 payload）/ 非 yyyy-MM-dd → 中性「之前」表述。
    await NotificationService.instance.showHabitConfirmExpired('habit-x');
    shows = notifCalls.where((c) => c.method == 'show').toList();
    args = Map<String, dynamic>.from(shows.last.arguments as Map);
    expect(args['body'] as String, contains('之前'));
  });

  test('U3-2：snooze 回执文案区分——异常分支「顺延失败」，已结束分支「不会再响」',
      () async {
    // rescheduleFailed: true = 调度异常分支（重复任务的既有 8 槽落点仍挂在
    // 外、下个周期照响）——「不会再响」在此失实。
    await NotificationService.instance.showSnoozeUnavailableConfirm(
      '9201',
      title: '任务A',
      rescheduleFailed: true,
    );
    var shows = notifCalls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(1));
    var args = Map<String, dynamic>.from(shows.single.arguments as Map);
    expect(args['body'] as String, contains('顺延失败'));
    expect(args['body'] as String, isNot(contains('不会再响')));

    // 缺省（实体已删 / 重复已结束的预拦截分支）——确实无未来落点，现文案成立。
    await NotificationService.instance
        .showSnoozeUnavailableConfirm('9202', title: '任务B');
    shows = notifCalls.where((c) => c.method == 'show').toList();
    args = Map<String, dynamic>.from(shows.last.arguments as Map);
    expect(args['body'] as String, contains('不会再响'));
  });
}
