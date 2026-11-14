import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/main.dart' show AppLockGate;
import 'package:todolist/models/achievement.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/period_review.dart';
import 'package:todolist/models/review.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart' show lightTheme;

import 'test_helpers.dart';

/// v3.1.1 审计修复轮（《有条功能与操作审计报告（v3.1.0）》P1-1 / P2-1..4 /
/// P3-1..8）回归测试。每条修复至少一个「能区分修与未修」的用例。
///
/// 覆盖清单：
/// - **P1-1** 习惯 / 专注补安全模式写盘守卫：加载失败置位后写入一律拒绝
///   （不再「一次写入清空整表」），load() 的 DB 打开失败同样置位；
/// - **P2-1** 完成统计统一 occurrence 级：周报 / 月报 / 成就按
///   [Task.completionEventDays] 计数（重复任务的历史不再被午夜重置抹掉）；
/// - **P2-2** 备份白名单改真实键名（brief_*/habit_nudge_*），幽灵键与
///   auto_backup_encrypt 不再进备份；
/// - **P2-3** 应用锁恢复路径补硬件门槛（无生物识别强制写回 false）+
///   解锁页「无法验证？关闭应用锁」出口（二次确认）；
/// - **P2-4** 休息段不算专注：taskStats / hourDistribution / totalSec /
///   focusTop 过滤 phase==focus，任务累计回调同样按阶段过滤；
/// - **P3-1** 周报习惯口径对齐月报：全量含归档 + createdAt/archivedAt 夹取；
/// - **P3-2** 专注记录族落盘回执：removeSession/clearToday 失败回滚内存
///   并如实上报，addSession/clear 透传 bool；
/// - **P3-3** restoreFromTrash 先落盘、成功后才挂提醒（失败分支不碰通知）；
/// - **P3-5** 标签 rename/merge/delete 的归档集合写盘失败回滚（N9 横向推广）；
/// - **P3-6②** mergeTags 支持撤销（复用 batchUpdateAs 快照 + 归档迁移还原）；
/// - **P3-7** 简报 / 挽留跨天改构造器日历进位（月末/年末语义守门）；
/// - **P3-8①** 归档习惯 setCheckInValue 拒绝写入返回 false（不再谎报成功）。
///
/// 不落用例（如实）：
/// - **P1-1 的 main 横幅合并**（三个 dbLoadFailed 的 `||` 组合）与
///   **P3-4 的启动 / 回前台接线**（unawaited 调用）——纯 main.dart 接线，
///   库外不可达；P3-4 的 getter 语义已由 `areNotificationsEnabled=false`
///   注入用例钉死；
/// - **P3-4 设置页常驻提示 / P3-6① 体检弹层 action 渲染 / P3-6② 合并确认
///   对话框**——纯 UI 渲染分支，以 widget 结构与 provider 契约推演交付；
/// - **P3-7 的 DST 日**：本机时区（Asia/Shanghai）无 DST、tz 数据库在宿主
///   测试环境未初始化，无法本地模拟切换日漂移；用例只守门「跨月 / 跨年
///   仍是明天同一墙钟时刻」，与 N16 同为如实记载的模拟局限；
/// - **P3-8② `_resetDailyIfNeeded` 透传**：私有方法 + 无 UI 上下文，签名
///   改 Future<bool> 与日志由代码推演（跨天重置成功路径已被既有用例覆盖）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  // 记录型通知插件 mock：除返回 null 外，把全部方法调用留档（P3-3 用）。
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
    // 🔴 内存库是同进程共享单例：每个用例前必须重置 DB + prefs。
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    NotificationService.instance.enabled = true;
  });

  // ── 脚手架 ────────────────────────────────────────────────────────

  /// 用受控列表构造 TaskProvider（restoreFromJson 绕过 load()，不起午夜守护）。
  Future<TaskProvider> buildWith(
    List<Task> tasks, {
    List<Task>? trash,
  }) async {
    final p = TaskProvider();
    final json = jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': (trash ?? const <Task>[]).map((t) => t.toJson()).toList(),
      'notifications_enabled': false,
      'sound_enabled': false,
    });
    await p.restoreFromJson(json);
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

  /// 「最近 N 天每天完成一次」的重复任务（occurrence 历史在 doneDates）。
  ///
  /// P3-10（v3.1.2 审计）：仅用于**无时间窗**的消费方（成就——按全部事件计数）。
  /// 周报 / 月报等窗口型统计请用 [weeklyDone] / [monthlyDone]——本方法用
  /// `now-1 / now-2` 造历史，每月 1–2 日会落到上个月（月报必挂）、周一运行会
  /// 跨周（周报必挂），「全量绿」只在特定日期成立。
  Task dailyDone(int days, {String id = 'r1'}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final doneDates = <String>[];
    for (var i = 1; i <= days; i++) {
      final d = today.subtract(Duration(days: i));
      doneDates.add(
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
    }
    return Task(
      id: id,
      title: '每天喝水',
      priority: Priority.medium,
      category: Category.work,
      status: TaskStatus.done,
      completedAt: now,
      repeat: RepeatType.daily,
      doneDates: doneDates,
    );
  }

  /// P3-10（v3.1.2 审计）：周报专用夹具——三个完成事件全部锚定在**本周
  /// 一/二/三**（doneDates），completedAt 与周一重合（事件集合按日去重）。
  /// 无论周几运行，事件都落在当前周内，completedCount 恒 = 3（旧单槽口径
  /// 恒 = 1，断言仍具区分力）。
  Task weeklyDone({String id = 'r1'}) {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    String ymd(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return Task(
      id: id,
      title: '每天喝水',
      priority: Priority.medium,
      category: Category.work,
      status: TaskStatus.done,
      completedAt: monday,
      repeat: RepeatType.daily,
      doneDates: [
        ymd(monday),
        ymd(monday.add(const Duration(days: 1))),
        ymd(monday.add(const Duration(days: 2))),
      ],
    );
  }

  /// P3-10（v3.1.2 审计）：月报专用夹具——anchor 固定在当月 15 日（月报支持
  /// [PeriodReview.fromProviders] 的 anchor 入参），doneDates = 13/14 日、
  /// completedAt = 15 日。所有月份（含 2 月）都有这三天，completedCount 恒 = 3，
  /// 与运行日期无关。
  Task monthlyDone({String id = 'r1'}) {
    final now = DateTime.now();
    String ymd(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return Task(
      id: id,
      title: '每天喝水',
      priority: Priority.medium,
      category: Category.work,
      status: TaskStatus.done,
      completedAt: DateTime(now.year, now.month, 15),
      repeat: RepeatType.daily,
      doneDates: [
        ymd(DateTime(now.year, now.month, 13)),
        ymd(DateTime(now.year, now.month, 14)),
      ],
    );
  }

  FocusSession focusSession({
    String id = 's1',
    String? taskId,
    FocusPhase phase = FocusPhase.focus,
    int sec = 600,
    DateTime? endedAt,
  }) {
    final end = endedAt ?? DateTime.now();
    return FocusSession(
      id: id,
      taskId: taskId,
      taskTitle: taskId,
      plannedSec: sec,
      durationSec: sec,
      completed: phase == FocusPhase.focus,
      phase: phase,
      startedAt: end.subtract(Duration(seconds: sec)),
      endedAt: end,
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // P1-1：习惯 / 专注安全模式写盘守卫
  // ══════════════════════════════════════════════════════════════════

  group('P1-1 习惯侧安全模式写盘守卫（v3.1.0 审计）', () {
    test('load() 的 DB 打开失败 → 置位 dbLoadFailed', () async {
      LocalDatabase.testUseMemory = false;
      final hp = HabitProvider();
      await hp.load();
      LocalDatabase.testUseMemory = true;
      expect(hp.dbLoadFailed, isTrue,
          reason: 'P1-1：加载失败必须置位（旧实现置位了，但写入不读它）');
    });

    test('置位后写入全部被拒且内存回滚，库中历史不被清空', () async {
      // 先往内存库写一条历史习惯。
      final hp0 = HabitProvider();
      await hp0.load();
      expect(
          await hp0.addHabit(
              title: '喝水', emoji: '💧', colorValue: 1, weekdays: const []),
          isTrue);

      final hp = HabitProvider();
      await hp.load();
      hp.markDbLoadFailedForTest(); // 模拟「内存不全、DB 可写」的安全模式

      // 旧实现：replaceHabits([新习惯]) 成功 → 库中其余全部习惯被删，UI 报成功。
      expect(
          await hp.addHabit(
              title: '新习惯', emoji: 'x', colorValue: 2, weekdays: const []),
          isFalse,
          reason: 'P1-1：安全模式下写入被拒');
      // load 成功读到历史「喝水」；失败的「新习惯」必须被回滚，不得留下。
      expect(hp.habits.map((h) => h.title), ['喝水'],
          reason: '失败回滚内存（UI 即事实）');

      // 历史数据完好（旧实现此时库中只剩「新习惯」或空）。
      final hp2 = HabitProvider();
      await hp2.load();
      expect(hp2.habits.single.title, '喝水',
          reason: 'P1-1：守卫拒绝落盘，坏库不被内存态覆盖');

      // 打卡路径同样被拒（旧实现会把整张 check_ins 清成这一条）。
      final h = hp2.habits.single;
      expect(await hp2.setCheckInValue(h, DateTime.now(), 1), isTrue,
          reason: '脱离安全模式后写入恢复正常');
      hp.markDbLoadFailedForTest();
      expect(await hp.setCheckInValue(h, DateTime.now(), 1), isFalse);
    });
  });

  group('P1-1 专注侧安全模式写盘守卫（v3.1.0 审计）', () {
    test('load() 的 DB 打开失败 → 置位 dbLoadFailed（旧实现异常被 _safeLoad 吞掉）',
        () async {
      LocalDatabase.testUseMemory = false;
      final fp = FocusProvider();
      await fp.load();
      LocalDatabase.testUseMemory = true;
      expect(fp.dbLoadFailed, isTrue);
    });

    test('置位后 addSession/clear 拒绝落盘返回 false', () async {
      final fp = FocusProvider();
      fp.markDbLoadFailedForTest();
      expect(
          await fp.addSession(
              focusSession(id: 's1', taskId: '1')), isFalse,
          reason: 'P1-1：replaceFocus 是整表替换，安全模式下必须拒绝');
      expect(await fp.clear(), isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-1：完成统计统一 occurrence 级
  // ══════════════════════════════════════════════════════════════════

  group('P2-1 completionEventDays 真源（v3.1.0 审计）', () {
    test('一次性任务 = completedAt；重复任务 = doneDates ∪ done 的 completedAt',
        () {
      final now = DateTime.now();
      final oneShot = mk(id: '1', status: TaskStatus.done)
          .copyWith(completedAt: DateTime(2026, 10, 30, 21, 30));
      expect(oneShot.completionEventDays, {DateTime(2026, 10, 30)});

      final repeat = dailyDone(2);
      final today = DateTime(now.year, now.month, now.day);
      expect(repeat.completionEventDays.length, 3,
          reason: 'doneDates 两天 + 今天 completedAt（旧单槽口径只算 1 天）');
      expect(repeat.completionEventDays.contains(today), isTrue);
    });

    test('脏 doneDates 串跳过；未完成任务只有 doneDates 历史也计入', () {
      final t = mk(id: '2').copyWith(
          doneDates: const ['2026-10-01', 'bad', '2026-13-40', '2026-10-02']);
      expect(t.completionEventDays,
          {DateTime(2026, 10, 1), DateTime(2026, 10, 2)},
          reason: '非法串不污染统计（与 _parseYmdSafe 同口径）');
    });
  });

  group('P2-1 周报 / 月报 / 成就 occurrence 化（v3.1.0 审计）', () {
    test('周报：重复任务本周 3 次完成 → completedCount=3（旧实现 1）', () async {
      // P3-10（v3.1.2 审计）：夹具锚定本周一/二/三，任何日期运行都稳定。
      final p = await buildWith([weeklyDone()]);
      final r = WeeklyReview.fromProviders(p, FocusProvider(), HabitProvider());
      expect(r.completedCount, 3,
          reason: 'occurrence 级：3 次完成各计 1 次，与周目标口径一致');
    });

    test('月报：同任务 completedCount=3、buckets 命中', () async {
      // P3-10（v3.1.2 审计）：anchor 固定当月 15 日 + 事件锚定 13/14/15 日，
      // 每月 1–2 日运行不再把事件落到上个月（旧夹具用 now-1/now-2）。
      final p = await buildWith([monthlyDone()]);
      final now = DateTime.now();
      final r = PeriodReview.fromProviders(p, FocusProvider(), HabitProvider(),
          period: ReviewPeriod.month,
          anchor: DateTime(now.year, now.month, 15));
      expect(r.completedCount, 3);
      expect(r.buckets.any((v) => v > 0), isTrue);
    });

    test('成就：completedTasks 不随午夜重置回落（历史完成事件数）', () async {
      final p = await buildWith([dailyDone(2)]);
      final ctx = AchievementContext.fromProviders(
          p, FocusProvider(), HabitProvider());
      expect(ctx.completedTasks, 3,
          reason: '旧实现 task.completed=1（当前 done 数），随重置倒退');
      expect(ctx.maxTasksInDay, 1, reason: '单日峰值按事件日聚合');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-4：番茄休息段不算专注
  // ══════════════════════════════════════════════════════════════════

  group('P2-4 休息段与专注统计隔离（v3.1.0 审计）', () {
    test('taskStats / hourDistribution / totalSec 只算专注阶段', () async {
      final fp = FocusProvider();
      final now = DateTime.now();
      await fp.addSession(focusSession(
          id: 'f1', taskId: '1', phase: FocusPhase.focus, sec: 600));
      await fp.addSession(focusSession(
          id: 'b1', taskId: '1', phase: FocusPhase.shortBreak, sec: 300,
          endedAt: now));
      expect(fp.taskStats.single.totalSec, 600,
          reason: '旧实现 900：休息段带 taskId 被算进任务「已专注」');
      expect(fp.totalSec, 600,
          reason: '成就「累计专注分钟」不再被休息灌水');
      final dist = fp.hourDistribution();
      expect(dist.fold<int>(0, (a, b) => a + b), 600);
    });

    test('周报 focusTop 过滤休息段（与同卡「专注(分)」对账一致）', () async {
      final p = await buildWith([mk(id: '1', title: '甲')]);
      final fp = FocusProvider();
      await fp.addSession(focusSession(id: 'f1', taskId: '1', sec: 600));
      await fp.addSession(focusSession(
          id: 'b1', taskId: '1', phase: FocusPhase.shortBreak, sec: 300));
      final r = WeeklyReview.fromProviders(p, fp, HabitProvider());
      expect(r.focusSec, 600);
      expect(r.focusTop.single.totalSec, 600,
          reason: '旧实现 900：休息段与专注段一起进 focusTop');
    });

    test('任务累计回调只认专注阶段（休息段不再回填任务）', () async {
      final p = await buildWith([mk(id: '1')]);
      final fp = FocusProvider();
      fp.onFocusRecorded = (taskId, sec) => p.addFocusSec(taskId, sec);
      // 历史脏数据形态：休息段带 taskId 落库（P2-4 修复前的产物）。
      await fp.addSession(focusSession(
          id: 'b1', taskId: '1', phase: FocusPhase.shortBreak, sec: 300));
      expect(p.byId('1')!.focusSecTotal, 0,
          reason: 'addSession 仅在 phase==focus 时回填任务累计');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-2：备份白名单改真实键名
  // ══════════════════════════════════════════════════════════════════

  group('P2-2 备份白名单键名修正（v3.1.0 审计）', () {
    test('collectAppPrefs 收真实键、弃幽灵键与 auto_backup_encrypt', () async {
      // SharedPreferences 实例在进程内缓存，setUp 替换 platform store 不影响
      // 已缓存数据——用例内显式清空，杜绝前序用例写入串味。
      await (await SharedPreferences.getInstance()).clear();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('brief_evening_on', true);
      await prefs.setInt('brief_evening_h', 22);
      await prefs.setInt('brief_evening_m', 30);
      await prefs.setBool('habit_nudge_on', false);
      await prefs.setInt('habit_nudge_min', 1380);
      // 旧白名单里的幽灵键（从未被写入）与刻意排除的加密开关：
      await prefs.setBool('briefing_evening_enabled', true);
      await prefs.setBool('auto_backup_encrypt', true);

      final out = await collectAppPrefs();
      expect(out['brief_evening_on'], isTrue,
          reason: 'P2-2：真实键进备份（旧白名单是 briefing_evening_* 幽灵键，'
              '导出必空、恢复必写不中）');
      expect(out['brief_evening_h'], 22);
      expect(out['habit_nudge_min'], 1380);
      expect(out.containsKey('briefing_evening_enabled'), isFalse,
          reason: '幽灵键不再进白名单');
      expect(out.containsKey('auto_backup_encrypt'), isFalse,
          reason: '口令在 secure storage，开关迁移会造成每日备份持续失败');
    });

    test('恢复往返：applyAppPrefs 写回真实键、幽灵键被拒', () async {
      await (await SharedPreferences.getInstance()).clear();
      await applyAppPrefs({
        'brief_morning_h': 8,
        'brief_morning_m': 10,
        'habit_nudge_min': 1320,
        'briefing_morning_hour': 5, // 旧幽灵键：白名单已弃，必须被丢弃
        'auto_backup_encrypt': true, // 排除键：恢复侧同样写不进
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('brief_morning_h'), 8,
          reason: 'P2-2：真实键恢复生效（旧白名单写不中它）');
      expect(prefs.getInt('habit_nudge_min'), 1320);
      expect(prefs.containsKey('briefing_morning_hour'), isFalse,
          reason: '幽灵键不再被写回');
      expect(prefs.containsKey('auto_backup_encrypt'), isFalse);
      // 这些键正是 TaskProvider.load() 读入 briefingMorning*/habitNudge* 的
      // 持久层入口（键名常量逐一核对，恢复后由 load/重启使内存态生效）。
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-3：应用锁恢复路径硬件门槛 + 解锁页出口
  // ══════════════════════════════════════════════════════════════════

  group('P2-3 应用锁不可解锁路径消除（v3.1.0 审计）', () {
    test('恢复写入 enabled=true 但无生物识别 → 强制写回 false', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_lock_enabled', true);
      final lock = AppLockProvider();
      // 测试环境 local_auth 平台通道未实现 → probeBiometric 降级为不可用。
      await lock.refreshEnabled();
      expect(lock.biometricAvailable, isFalse);
      expect(lock.appLockEnabled, isFalse,
          reason: 'P2-3：旧实现原样采纳 true，下次回前台即锁死在解锁页');
      expect(prefs.getBool('app_lock_enabled'), isFalse,
          reason: '持久层一并改回（不只是内存）');
    });

    // P2-1（v3.1.6 审计）口径修正：旧用例把「authenticate 返回 false（用户取消）」
    // 当成「本机无凭据」，断言取消后仍能二次确认关闭——这正是报告点名的
    // 绕过面。真实死路必须由**不可用类异常 + 重新探测确认无凭据**表达，
    // 因此 mock 改为抛 NotAvailable（取消路径由 v312 / v316 用例覆盖）。
    testWidgets('死路（真实无凭据异常）→ 二次确认后关闭；取消验证不再走此路径',
        (tester) async {
      // P1-1（v3.1.2 审计）：出口收窄 + 关闭前强制 authenticate。
      const authCh = MethodChannel('plugins.flutter.io/local_auth');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(authCh, (call) async {
        switch (call.method) {
          case 'canCheckBiometrics':
          case 'isDeviceSupported':
            return false; // 死路：设备无任何可用凭据
          case 'authenticate':
            throw PlatformException(
                code: 'NotAvailable',
                message: 'No authentication available');
          default:
            return null;
        }
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await prefs.setBool('app_lock_enabled', true);
      final lock = AppLockProvider();
      // P1-1：关闭前强制 authenticate 走的是「已启用」分支——必须先 load()
      //（旧用例不 load 也成立：旧流程只走确认框；新流程 authenticate 对
      // 未启用态直接放行，测不到「验证失败才进确认框」）。
      await lock.load();

      await tester.pumpWidget(MultiProvider(
        providers: [ChangeNotifierProvider.value(value: lock)],
        // appColors 依赖主题里的 AppColorsExt 扩展，须用应用主题（MaterialApp
        // 默认主题无该扩展 → appColors 的 `!` 抛错）。
        child: MaterialApp(theme: lightTheme, home: const AppLockGate()),
      ));
      expect(find.text('无法验证？关闭应用锁'), findsOneWidget,
          reason: '死路（!biometricAvailable）必须提供出口（P2-3 v3.1.0）');
      // P1-1：点出口先强制一次 authenticate（桩抛 NotAvailable）→
      // 重新探测仍判无凭据 → 才进入二次确认框。
      await tester.tap(find.text('无法验证？关闭应用锁'));
      await tester.pumpAndSettle();
      expect(find.text('取消'), findsOneWidget,
          reason: '只有「确认无凭据」才进入二次确认（P2-1 v3.1.6）');
      await tester.tap(find.widgetWithText(FilledButton, '关闭应用锁'));
      await tester.pumpAndSettle();

      expect(lock.appLockEnabled, isFalse);
      expect(
          (await SharedPreferences.getInstance()).getBool('app_lock_enabled'),
          isFalse,
          reason: '关闭出口必须真实落盘（下次回前台不再上锁）');
    });

    testWidgets('P1-1：出口强制验证通过 → 解锁且不关闭应用锁', (tester) async {
      const authCh = MethodChannel('plugins.flutter.io/local_auth');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(authCh, (call) async {
        switch (call.method) {
          case 'canCheckBiometrics':
          case 'isDeviceSupported':
            return false; // 死路形态（出口可见）
          case 'authenticate':
            return true; // 锁屏密码降级验证成功
          default:
            return null;
        }
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await prefs.setBool('app_lock_enabled', true);
      final lock = AppLockProvider();
      await lock.load(); // P1-1：authenticate 需「已启用」分支（同上一条）

      await tester.pumpWidget(MultiProvider(
        providers: [ChangeNotifierProvider.value(value: lock)],
        child: MaterialApp(theme: lightTheme, home: const AppLockGate()),
      ));
      await tester.tap(find.text('无法验证？关闭应用锁'));
      await tester.pumpAndSettle();

      expect(lock.locked, isFalse, reason: '验证通过即正常解锁');
      expect(lock.appLockEnabled, isTrue,
          reason: 'P1-1：验证通过**不得**关闭应用锁（旧实现两键即绕过）');
      expect(
          (await SharedPreferences.getInstance()).getBool('app_lock_enabled'),
          isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-1：周报习惯口径对齐月报
  // ══════════════════════════════════════════════════════════════════

  group('P3-1 周报习惯全量 + 区间夹取（v3.1.0 审计）', () {
    /// 直接以 restoreFromJson 注入 Habit 列表（绕过 addHabit 的 createdAt=now）。
    Future<HabitProvider> habitWith(List<Habit> habits) async {
      final hp = HabitProvider();
      await hp.restoreFromJson({
        'habits': habits.map((h) => h.toJson()).toList(),
      });
      return hp;
    }

    test('本周归档的习惯仍在周报里（旧实现整段消失、历史被改写）', () async {
      final now = DateTime.now();
      final hp = await habitWith([
        Habit(
          id: 'h1',
          title: '已归档习惯',
          emoji: '🏃',
          colorValue: 1,
          weekdays: const [],
          createdAt: now.subtract(const Duration(days: 30)),
          archived: true,
          archivedAt: now.subtract(const Duration(days: 1)),
        ),
      ]);
      final r = WeeklyReview.fromProviders(TaskProvider(), FocusProvider(), hp);
      expect(r.habits, isNotEmpty,
          reason: 'P3-1：遍历源从 activeHabits 改为全量含归档（月报同口径）');
    });

    test('应打卡按 createdAt 夹取：今天新建的每天习惯 expected 至少含今天',
        () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final monday = today.subtract(Duration(days: today.weekday - 1));
      final hp = await habitWith([
        Habit(
          id: 'h2',
          title: '今天新建',
          emoji: '💧',
          colorValue: 1,
          weekdays: const [],
          createdAt: today,
        ),
      ]);
      final r = WeeklyReview.fromProviders(TaskProvider(), FocusProvider(), hp);
      // 旧实现整周 7 天一刀切：周三新建的习惯达成率上限被压到 3/7。
      // 夹取后区间 = [创建日(今天), 本周日] → 应打卡 = 今天到周日的天数。
      final sunday = monday.add(const Duration(days: 6));
      expect(r.habitExpected, sunday.difference(today).inDays + 1,
          reason: '夹取到创建日（与月报 _laterOf/_earlierOf 同口径），'
              '而非整周 7 天');
      expect(r.habitExpected, lessThanOrEqualTo(7));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-2：专注记录族落盘回执
  // ══════════════════════════════════════════════════════════════════

  group('P3-2 专注落盘失败回滚与如实上报（v3.1.0 审计）', () {
    test('removeSession 落盘失败 → null + 内存回滚（记录不再「重启复活」）',
        () async {
      final fp = FocusProvider();
      final s = focusSession(id: 's1', taskId: null);
      await fp.addSession(s);
      LocalDatabase.testUseMemory = false;
      late final FocusSession? removed;
      try {
        removed = await fp.removeSession('s1');
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(removed, isNull, reason: 'P3-2：旧实现丢弃 _persist 结果，'
          '删除可能只生效在内存、重启复活而横幅已承诺可撤销');
      expect(fp.sessions.any((e) => e.id == 's1'), isTrue,
          reason: '落盘失败插回原位（UI 显示的即已落盘的）');
    });

    test('clearToday 落盘失败 → 空列表 + 内存回滚', () async {
      final fp = FocusProvider();
      await fp.addSession(focusSession(id: 's1'));
      LocalDatabase.testUseMemory = false;
      late final List<FocusSession> removed;
      try {
        removed = await fp.clearToday();
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(removed, isEmpty,
          reason: '空列表 = 清空未生效（旧实现照弹「已清空 N 条」假横幅）');
      expect(fp.sessions.length, 1, reason: '回滚内存');
    });

    test('安全模式下 addSession 恒 false（P1-1 守卫透传）', () async {
      final fp = FocusProvider();
      fp.markDbLoadFailedForTest();
      expect(await fp.addSession(focusSession(id: 's1')), isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-3：restoreFromTrash 先落盘、后挂提醒
  // ══════════════════════════════════════════════════════════════════

  group('P3-3 回收站恢复顺序（v3.1.0 审计）', () {
    test('落盘失败 → 返回 false 且不挂任何提醒（旧实现闹钟已挂出）', () async {
      final due = DateTime.now().add(const Duration(days: 3));
      final t = mk(id: '9101', due: due);
      final p = await buildWith([], trash: [t]);
      expect(p.trash.length, 1);
      notifCalls.clear(); // 只看 restoreFromTrash 自身的通知动作

      LocalDatabase.testUseMemory = false;
      late final bool ok;
      try {
        ok = await p.restoreFromTrash('9101');
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(ok, isFalse);
      // 旧顺序「插回 → _scheduleRemindersFor → 落盘」：写库失败时一次性截止
      // 提醒已挂进系统，重启后任务回回收站、提醒仍对「已删除」任务弹出。
      expect(
          notifCalls.where((c) => c.method == 'zonedSchedule'), isEmpty,
          reason: 'P3-3：先落盘、成功后才挂提醒，失败分支不碰通知');
      expect(p.tasks.any((e) => e.id == '9101'), isTrue,
          reason: '内存保留恢复态与 UI 一致（不内存回滚口径），重启自回回收站');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-5：标签三入口归档集合回滚（N9 横向推广）
  // ══════════════════════════════════════════════════════════════════

  group('P3-5 标签 rename/merge/delete 归档集合回滚（v3.1.0 审计）', () {
    test('renameTag：prefs 写失败 → false + 归档态回滚', () async {
      final p = await buildWith([
        mk(id: '1').copyWith(tags: ['旧名']),
      ]);
      expect(await p.archiveTag('旧名'), isTrue);

      final healthy = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance =
          _FailingStringListPrefsStore(healthy);
      late final bool ok;
      try {
        ok = await p.renameTag('旧名', '新名');
      } finally {
        SharedPreferencesStorePlatform.instance = healthy;
      }
      expect(ok, isFalse);
      expect(p.archivedTags, contains('旧名'),
          reason: 'P3-5：N9 只修了 archiveTag/unarchiveTag，rename 的归档集合'
              '迁移此前丢弃落盘结果、失败不回滚');
      expect(p.archivedTags, isNot(contains('新名')));
    });

    test('deleteTag：prefs 写失败 → false + 归档态回滚', () async {
      final p = await buildWith([
        mk(id: '1').copyWith(tags: ['标签甲']),
      ]);
      // 归档两个标签：删除「标签甲」后集合仍非空 → 走 setStringList 写路径
      //（删最后一个归档标签走 prefs.remove，注入不命中，v310 N9 同判）。
      expect(await p.archiveTag('标签甲'), isTrue);
      expect(await p.archiveTag('标签乙'), isTrue);

      final healthy = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance =
          _FailingStringListPrefsStore(healthy);
      late final bool ok;
      try {
        ok = await p.deleteTag('标签甲');
      } finally {
        SharedPreferencesStorePlatform.instance = healthy;
      }
      expect(ok, isFalse);
      expect(p.archivedTags, contains('标签甲'),
          reason: 'P3-5：删除标签的归档集合消费此前被丢弃、失败不回滚');
      expect(p.archivedTags, contains('标签乙'));
    });

    test('mergeTags：prefs 写失败 → false + 归档态回滚', () async {
      final p = await buildWith([
        mk(id: '1').copyWith(tags: ['源']),
      ]);
      expect(await p.archiveTag('源'), isTrue);

      final healthy = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance =
          _FailingStringListPrefsStore(healthy);
      late final (int, int, bool) r;
      try {
        r = await p.mergeTags('源', '目标');
      } finally {
        SharedPreferencesStorePlatform.instance = healthy;
      }
      expect(r.$3, isFalse);
      expect(p.archivedTags, contains('源'),
          reason: '归档迁移失败回滚：source 仍在归档集合');
      expect(p.archivedTags, isNot(contains('目标')));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-6②：mergeTags 撤销（provider 侧契约）
  // ══════════════════════════════════════════════════════════════════

  group('P3-6 合并标签的确认与撤销（v3.1.0 审计）', () {
    test('mergeTags 返回 (changed, batchId, saved)；undoMergeTags 还原任务与归档',
        () async {
      final p = await buildWith([
        mk(id: '1', title: '甲').copyWith(tags: ['源']),
        mk(id: '2', title: '乙').copyWith(tags: ['源', '保留']),
      ]);
      expect(await p.archiveTag('源'), isTrue);

      final (changed, batchId, ok) = await p.mergeTags('源', '目标');
      expect(ok, isTrue);
      expect(changed, 2);
      expect(batchId, isNot(0), reason: '供 UI 挂定向撤销横幅');
      expect(p.byId('1')!.tags, ['目标']);
      expect(p.byId('2')!.tags, ['目标', '保留']);
      expect(p.archivedTags, contains('目标'),
          reason: '归档态迁移到 target');
      expect(p.archivedTags, isNot(contains('源')));

      final u = await p.undoMergeTags(batchId);
      expect(u.applied, isTrue);
      expect(u.saved, isTrue);
      expect(p.byId('1')!.tags, ['源'], reason: '任务 tags 还原（batchUpdateAs 快照）');
      expect(p.byId('2')!.tags, ['源', '保留']);
      expect(p.archivedTags, contains('源'), reason: '归档态还给 source');
      expect(p.archivedTags, isNot(contains('目标')));

      // 撤销后重复撤销：失效。
      final again = await p.undoMergeTags(batchId);
      expect(again.applied, isFalse);
    });

    test('mergeTags 无命中任务：仅归档迁移也可撤销', () async {
      final p = await buildWith([]);
      expect(await p.archiveTag('孤标签'), isTrue);
      final (changed, batchId, ok) = await p.mergeTags('孤标签', '新家');
      expect(ok, isTrue);
      expect(changed, 0);
      expect(p.archivedTags, contains('新家'));
      final u = await p.undoMergeTags(batchId);
      expect(u.applied, isTrue);
      expect(p.archivedTags, contains('孤标签'));
      expect(p.archivedTags, isNot(contains('新家')));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-7：简报 / 挽留跨天用构造器日历进位
  // ══════════════════════════════════════════════════════════════════

  group('P3-7 跨天时刻的日历进位（v3.1.0 审计）', () {
    test('nextHabitNudgeTime：月末已过时刻 → 次月同墙钟时刻', () {
      // from=3/31 23:05，nudge=23:00 → 明天 = 4/1 23:00（构造器进位）。
      final r = NotificationService.nextHabitNudgeTime(
        23 * 60,
        from: DateTime(2026, 3, 31, 23, 5),
      );
      expect(r, DateTime(2026, 4, 1, 23, 0),
          reason: 'P3-7：跨天改用构造器日历进位，不再是 +24 小时'
              '（DST 切换日墙钟漂移无法在本机时区模拟，见文件头说明）');
    });

    test('nextHabitNudgeTime：年末已过时刻 → 次年 1 月同墙钟时刻', () {
      final r = NotificationService.nextHabitNudgeTime(
        23 * 60,
        from: DateTime(2026, 12, 31, 23, 30),
      );
      expect(r, DateTime(2027, 1, 1, 23, 0));
    });

    test('当日未过 → 今天该时刻（不跨天路径零回归）', () {
      final r = NotificationService.nextHabitNudgeTime(
        23 * 60,
        from: DateTime(2026, 3, 31, 12, 0),
      );
      expect(r, DateTime(2026, 3, 31, 23, 0));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-8①：归档习惯写入拒绝不再谎报成功
  // ══════════════════════════════════════════════════════════════════

  group('P3-8 归档习惯 setCheckInValue 返回 false（v3.1.0 审计）', () {
    test('归档习惯写入 → false（旧实现返回 true，把「未写入」当成功）', () async {
      final hp = HabitProvider();
      await hp.load();
      expect(
          await hp.addHabit(
              title: '跑步', emoji: '🏃', colorValue: 1, weekdays: const []),
          isTrue);
      final h = hp.habits.single;
      expect(await hp.updateHabit(h, archived: true), isTrue);

      expect(await hp.setCheckInValue(h, DateTime.now(), 1), isFalse,
          reason: 'P3-8：归档 = 退场，写入被拒必须如实返回 false'
              '（全仓「bool = 落盘成功」契约）');
      expect(hp.checkInValueOn(h, DateTime.now()), 0);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-4：通知权限被拒状态可被查询（接线消费）
  // ══════════════════════════════════════════════════════════════════

  group('P3-4 notificationPermissionDenied 可刷新（v3.1.0 审计）', () {
    test('系统返回未授权 → denied=true（设置页常驻提示的数据源）', () async {
      // 默认 mock（notifCalls）对未知方法返回 null → checkPermission 为 null；
      // 这里显式注入 areNotificationsEnabled=false。
      const ch = MethodChannel('dexterous.com/flutter/local_notifications');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
        if (call.method == 'areNotificationsEnabled') return false;
        return null;
      });
      final p = await buildWith([]);
      expect(p.notificationPermissionDenied, isNull,
          reason: 'P3-4：旧实现 getter 全仓无人读取、refresh 从未被调用');
      await p.refreshNotificationPermission();
      expect(p.notificationPermissionDenied, isTrue);
      // 恢复默认 mock，避免影响后续用例。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
        notifCalls.add(call);
        return null;
      });
    });
  });
}

/// P3-5 测试注入：StringList 写抛错（模拟 SharedPreferences 落盘失败），
/// 其余读写委托给健康 store（v310 同款）。
class _FailingStringListPrefsStore extends SharedPreferencesStorePlatform {
  final SharedPreferencesStorePlatform _delegate;
  _FailingStringListPrefsStore(this._delegate);
  @override
  Future<bool> remove(String key) => _delegate.remove(key);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (valueType == 'StringList') {
      throw Exception('P3-5 测试注入：prefs 写失败');
    }
    return _delegate.setValue(valueType, key, value);
  }
  @override
  Future<bool> clear() => _delegate.clear();
  @override
  Future<Map<String, Object>> getAll() => _delegate.getAll();
}
