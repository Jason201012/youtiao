import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/app_log.dart'; // L9（v3.0.8 审计）：迁移失败日志
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/calendar_exporter.dart';
// M6（v3.0.8 审计）：CSV 公式注入防护收口到 csv_safe 单一真源。
import 'package:todolist/services/csv_safe.dart';

/// 专注会话的持久化与统计。独立于 TaskProvider，避免相互耦合；
/// 仅依赖 shared_preferences，key 为 [ _kFocus ]。
///
/// 番茄钟运行态（[activeTotalSec] 等）也由本 Provider 持有并持久化，原因是：
/// 计时器若挂在页面 State 上，切 Tab（页面 dispose）或杀后台（进程死亡）都会让
/// [Timer] 失效、已逝时间丢失。下沉到 Provider 后，Provider 在 main 顶层常驻，
/// 计时与记录都不受页面生命周期影响；剩余时间改用「墙钟时刻」推算，杀后台后重新
/// 打开 App 能从持久化的起点恢复，并继续累计；完成时刻另挂一条 setAlarmClock 系统
/// 通知，即便 App 被杀也能准点提醒。
class FocusProvider extends ChangeNotifier {
  /// 进程内单例引用（由 main 在构造后写入），供 TaskProvider 自动备份等场景安全取用。
  /// 取前请判空（[instanceOrNull]）；测试/未初始化时为 null。
  static FocusProvider? _instance;
  static FocusProvider? get instanceOrNull => _instance;
  static const String _kFocus = 'focus_sessions';
  static const String _kCustom = 'focus_custom_sec';
  static const String _kActive = 'focus_active_timer';
  static const String _kSysCal = 'focus_sys_calendar';

  // —— 番茄循环配置（持久化）——
  static const String _kPomoEnabled = 'focus_pomo_enabled';
  static const String _kPomoFocus = 'focus_pomo_focus_sec';
  static const String _kPomoShort = 'focus_pomo_short_sec';
  static const String _kPomoLong = 'focus_pomo_long_sec';
  static const String _kPomoRounds = 'focus_pomo_rounds';

  final List<FocusSession> _sessions = [];

  /// P1-1（v3.1.0 审计）：专注侧安全模式标志——与 TaskProvider / HabitProvider
  /// 的 dbLoadFailed 同口径。此前 [load] 没有 try/catch：`_sessions` 先 clear、
  /// `await db.loadFocus()` 后抛错，异常被 main._safeLoad 吞掉——内存为空且
  /// 无任何提示，随后任意一次 [addSession] 的整表替换写入（replaceFocus）会把
  /// 库中**全部历史专注记录**覆盖成只剩这一条，UI 报「保存成功」。置位后由
  /// [_persist] 拒绝落盘，main 顶部安全模式横幅统一提示。
  bool _dbLoadFailed = false;
  bool get dbLoadFailed => _dbLoadFailed;

  /// P1-1（v3.1.0 审计）：测试钩子——「加载失败置位」在宿主测试环境无法用
  /// 真实坏库复现（内存后端读写同构），由回归测试显式置位后验证
  /// [_persist] 的拒绝语义（与 task_provider 的 @visibleForTesting 门槛同型）。
  @visibleForTesting
  void markDbLoadFailedForTest() => _dbLoadFailed = true;

  /// 自定义专注时长（秒），默认 30 分钟。
  int _customSec = 30 * 60;
  int get customSec => _customSec;

  // —— 进行中的番茄钟运行态（持久化，杀后台 / 切 Tab 不丢）——
  /// 本次设定的总时长（秒）。
  int activeTotalSec = 0;
  /// 已完成段落累计秒（暂停前已计的秒数），与当前段落相加得已专注秒数。
  int activeAccumulatedSec = 0;
  /// 当前运行段落起点（墙钟毫秒）。暂停 / 未开始为 null。
  int? activeSegmentStartEpochMs;
  /// 是否正在运行（true 时按墙钟实时累计剩余）。
  bool activeRunning = false;
  /// 启动时的预设序号（用于 UI 高亮恢复）。
  int activeModeIndex = 0;
  /// 启动时的自定义秒数（custom 模式用）。
  int activeCustomSec = 0;

  /// 进行中番茄钟关联的任务（可选）；完成/停止时写入会话。
  String? activeTaskId;
  String? activeTaskTitle;

  // ===== P0-4：专注「中断感知」L1（纯生命周期判定，零权限、零联网）=====
  /// 判定为「一次打断」的最小离开时长。低于此值视为正常切屏（回个消息、接个电话），
  /// 不计入——避免把每次锁屏都算成打断而污染数据。
  static const int interruptThresholdSec = 60;

  /// 当前进行中段落已记录的打断次数（完成 / 停止时写入 [FocusSession.interruptCount]）。
  int activeInterruptCount = 0;

  /// 最近一次切出 App 的时刻（墙钟）；null 表示当前在前台。
  DateTime? _leftAt;

  /// 由任务行「专注」按钮设置的「待选任务」：跳到专注页后预选到 [_TaskPicker]。
  /// 不持久化，仅在本次跨页面跳转期间临时携带。
  String? pendingTaskId;
  String? pendingTaskTitle;

  /// 供任务行点击后请求「跳转到专注 Tab」的回调（由 [MainScaffold] 注册）。
  /// 设为静态以便任意持有 [FocusProvider] 的地方（如任务行）便捷调用。
  static VoidCallback? jumpToFocusTab;

  /// 任务行点「专注」时调用：暂存待选任务，并请求跳转到专注页。
  ///
  /// P2-8（v2.9.6 审计）：赋值后必须 `notifyListeners()`——Tab 保活后
  /// FocusScreen 首次访问便常驻，`initState` 的 pending 消费只在**首次**生效，
  /// 此后全靠本通知驱动页面消费（见 focus_screen 的 listener）。此前不 notify，
  /// 「任务行 → 专注钮预选」从第二次起静默失效。
  void requestTask(String id, String title) {
    pendingTaskId = id;
    pendingTaskTitle = title;
    jumpToFocusTab?.call();
    notifyListeners();
  }

  /// P3-2（v3.1.0 审计）：专注会话落盘失败时的 UI 透出回调——由 main 注入。
  /// 消费方是没有 BuildContext 的内部路径（番茄循环 tick 自动推进、杀后台
  /// 补录），它们无法直接弹 SnackBar；注入式回调 + 未注入静默跳过，与
  /// [HabitProvider.onHabitsChanged] 同一模式。
  static void Function()? onSessionPersistFailed;

  void _notifySessionPersistFailed() {
    final cb = onSessionPersistFailed;
    if (cb == null) return;
    try {
      cb();
    } catch (e) {
      AppLog.d('[FocusProvider] 落盘失败回调异常（已忽略）：$e');
    }
  }

  /// 专注会话记录后的回调：(taskId, durationSec)。由 main 接线到
  /// TaskProvider.addFocusSec，把专注时长回填到关联任务的累计专注字段。
  /// 仅在会话带 taskId 时触发。
  void Function(String taskId, int durationSec)? onFocusRecorded;

  /// P2-9（v2.9.6 审计）：专注会话**删除**后的回调：(taskId, durationSec)。
  /// 由 main 接线到 TaskProvider.removeFocusSec，与 [onFocusRecorded] 对称——
  /// 此前删除记录不扣减、撤销删除又经 [addSession] 回填一次，任务「已专注」
  /// 凭空多出一段（详情页偏差与排程建议的下游口径被污染）。
  /// 仅在会话带 taskId 时触发。
  void Function(String taskId, int durationSec)? onFocusRemoved;

  // —— 番茄循环：运行态阶段（持久化，杀后台 / 切 Tab 不丢）——
  /// 当前阶段：专注 / 短休 / 长休。非循环单次计时恒为 [FocusPhase.focus]。
  FocusPhase activePhase = FocusPhase.focus;
  /// 本轮回合内已完成的专注数（用于决定下次是短休还是长休）。
  int focusDoneInCycle = 0;
  /// 第几轮（长休后 +1，仅用于展示）。
  int cycleNo = 1;

  // —— 番茄循环：配置（持久化）——
  bool _pomodoroEnabled = false;
  bool get pomodoroEnabled => _pomodoroEnabled;
  int _pomoFocusSec = 25 * 60;
  int get pomoFocusSec => _pomoFocusSec;
  int _pomoShortSec = 5 * 60;
  int get pomoShortSec => _pomoShortSec;
  int _pomoLongSec = 15 * 60;
  int get pomoLongSec => _pomoLongSec;
  int _pomoRounds = 4;
  int get pomoRounds => _pomoRounds;

  /// 专注结束是否自动记入系统日历（设置项，默认关闭）。
  bool _sysCalendarEnabled = false;
  bool get sysCalendarEnabled => _sysCalendarEnabled;

  Timer? _tickTimer;

  /// 补录/推进阶段时的重入守卫：阶段跑满由每秒 tick 触发，但在 [ _recordAndAdvance ]
  /// 内部的多个 await 完成前，下一秒 tick 可能再次进入并重复补录同一阶段会话。
  /// 用此标志保证同一阶段只收尾一次。
  bool _completing = false;

  /// 会话 id 自增序号：与时间戳组合，避免同一毫秒内两次完成撞 id（撞 id 会导致
  /// 整表 JSON 按 id 覆盖时丢一条会话）。habit 侧 v2.4.6 已修过同类问题。
  static int _sessionSeq = 0;

  /// 生成全局唯一的专注会话 id（时间戳 + 3 位自增序号）。
  String _nextSessionId() {
    final seq = (_sessionSeq++ % 1000).toString().padLeft(3, '0');
    return '${DateTime.now().millisecondsSinceEpoch}$seq';
  }

  /// 所有会话（按结束时间倒序，最新在前）。
  List<FocusSession> get sessions =>
      _sessions.toList()..sort((a, b) => b.endedAt.compareTo(a.endedAt));

  Future<void> load() async {
    _instance = this; // 注册单例，供自动备份等场景安全取用
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_kCustom);
    if (saved != null && saved > 0) _customSec = saved;
    _sysCalendarEnabled = prefs.getBool(_kSysCal) ?? false;
    // —— 番茄循环配置（无则保持默认）——
    _pomodoroEnabled = prefs.getBool(_kPomoEnabled) ?? false;
    final pf = prefs.getInt(_kPomoFocus);
    if (pf != null && pf > 0) _pomoFocusSec = pf;
    final ps = prefs.getInt(_kPomoShort);
    if (ps != null && ps > 0) _pomoShortSec = ps;
    final pl = prefs.getInt(_kPomoLong);
    if (pl != null && pl > 0) _pomoLongSec = pl;
    final pr = prefs.getInt(_kPomoRounds);
    if (pr != null && pr > 0) _pomoRounds = pr;
    // —— 专注会话从旧版 SP JSON 迁移到 SQLite（仅首次：DB 为空且旧 key 存在）——
    final db = LocalDatabase.instance;
    // P1-1（v3.1.0 审计）：DB 打开 / 迁移 / 读取统一纳入 try/catch——旧实现
    // 无守卫，任何一处抛错都会一路冒到 main._safeLoad 被吞（内存空、无提示），
    // 随后任何一次成功写入（replaceFocus 整表替换）都会把库中全部历史专注
    // 记录覆盖成单条。失败时清空内存并置安全模式：由 [_persist] 拒绝后续
    // 写入、main 顶部安全模式横幅统一提示。
    try {
      // 内存后端（测试）无需打开真实 SQLite；仅在生产（非内存）模式确保建表。
      // 与 HabitProvider.load() 保持一致，避免宿主环境下 databaseFactory 未初始化。
      if (!LocalDatabase.testUseMemory) {
        await db.db;
      }
      // L9（v3.0.8 审计）：同 TaskProvider.load——损坏旧 JSON 抛错时保留 key、
      // 按空库继续（migrate 在 replaceFocus 之前中止，不覆盖写）。迁移自身的
      // 失败保留独立 catch：旧 key 保留、按空库继续，不因此置安全模式。
      if (await db.focusEmpty && prefs.getString(_kFocus) != null) {
        try {
          await db.migrateFocusFromPrefs(prefs);
        } catch (e, s) {
          AppLog.d('[FocusProvider] 旧版 SP 数据迁移失败（已保留旧 key）：$e\n$s');
        }
      }
      final loaded = await db.loadFocus();
      _sessions
        ..clear()
        ..addAll(loaded);
      _dbLoadFailed = false; // 加载成功即脱离安全模式
    } catch (e, s) {
      AppLog.d('[FocusProvider] 专注会话加载失败（专注记录暂不可用）：$e\n$s');
      _sessions.clear();
      _dbLoadFailed = true;
    }
    // 恢复进行中的番茄钟：杀后台 / 重启后据此恢复，避免时长丢失。
    final rawA = prefs.getString(_kActive);
    if (rawA != null) {
      try {
        final m = jsonDecode(rawA) as Map<String, dynamic>;
        activeTotalSec = m['totalSec'] as int? ?? 0;
        activeAccumulatedSec = m['accumulatedSec'] as int? ?? 0;
        activeSegmentStartEpochMs = m['segmentStartEpochMs'] as int?;
        activeRunning = m['running'] as bool? ?? false;
        activeModeIndex = m['modeIndex'] as int? ?? 0;
        activeCustomSec = m['customSec'] as int? ?? 0;
        activeTaskId = m['taskId'] as String?;
        activeTaskTitle = m['taskTitle'] as String?;
        // 恢复阶段运行态（无则默认专注 / 第 1 轮）。
        activePhase = FocusPhase.values.byName(
            (m['phase'] as String?) ?? 'focus');
        focusDoneInCycle = m['focusDoneInCycle'] as int? ?? 0;
        cycleNo = m['cycleNo'] as int? ?? 1;
        // P0-4：恢复打断计数（旧存档无此字段 → 0，向后兼容）。
        activeInterruptCount = m['interruptCount'] as int? ?? 0;
        if (activeTotalSec > 0 &&
            activeRunning &&
            activeSegmentStartEpochMs != null) {
          final elapsed = activeAccumulatedSec +
              (DateTime.now().millisecondsSinceEpoch -
                      activeSegmentStartEpochMs!) ~/
                  1000;
          if (elapsed >= activeTotalSec) {
            // 后台期间已跑满：静默补录（系统闹钟通知已在完成时刻弹出，不再重复）。
            await _completeSilently();
          } else {
            _startTick();
            await _scheduleCompletion();
          }
        }
      } catch (_) {
        // 损坏则丢弃运行态，不影响其它功能。
      }
    }
    // 清理可能残留的「进行中」常驻通知（上次异常退出/被杀后未取消）。
    if (!hasActive) {
      await NotificationService.instance.cancelFocusProgress();
    }
    notifyListeners();
  }

  /// 设置自定义专注时长（秒）并持久化。
  Future<void> setCustomSec(int sec) async {
    if (sec <= 0) return;
    _customSec = sec;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kCustom, sec);
    notifyListeners();
  }

  /// 番茄循环各阶段时长（秒）：专注 / 短休 / 长休。
  int phaseDuration(FocusPhase phase) {
    switch (phase) {
      case FocusPhase.focus:
        return _pomoFocusSec;
      case FocusPhase.shortBreak:
        return _pomoShortSec;
      case FocusPhase.longBreak:
        return _pomoLongSec;
    }
  }

  /// 预设 chip 高亮用的 modeIndex 映射：专注→0，短休→1，长休→2。
  int _modeIndexOfPhase(FocusPhase phase) =>
      phase == FocusPhase.focus ? 0 : (phase == FocusPhase.shortBreak ? 1 : 2);

  /// 开启 / 关闭番茄循环并持久化。关闭时不清空进行中的计时。
  Future<void> setPomodoroEnabled(bool v) async {
    _pomodoroEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPomoEnabled, v);
    notifyListeners();
  }

  /// 设置番茄循环时长配置（秒）并持久化。参数非法则忽略对应项。
  Future<void> setPomodoroConfig({
    int? focusSec,
    int? shortSec,
    int? longSec,
    int? rounds,
  }) async {
    if (focusSec != null && focusSec > 0) _pomoFocusSec = focusSec;
    if (shortSec != null && shortSec > 0) _pomoShortSec = shortSec;
    if (longSec != null && longSec > 0) _pomoLongSec = longSec;
    if (rounds != null && rounds > 0) _pomoRounds = rounds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPomoFocus, _pomoFocusSec);
    await prefs.setInt(_kPomoShort, _pomoShortSec);
    await prefs.setInt(_kPomoLong, _pomoLongSec);
    await prefs.setInt(_kPomoRounds, _pomoRounds);
    notifyListeners();
  }

  /// P3-2（v3.1.0 审计）：返回落盘是否成功——旧实现 `Future<void>` 丢弃结果，
  /// 写库失败时记录只活在内存、重启即丢且无提示。
  ///
  /// P1-1（v3.1.0 审计）：安全模式写盘守卫——与 TaskProvider._persist（S13）同
  /// 口径。加载失败后内存不全，replaceFocus 是整表替换，任一次成功写入都会把
  /// 库中全部历史专注记录覆盖成内存态（完成一次专注 = 抹掉全部历史）。
  Future<bool> _persist() async {
    if (_dbLoadFailed) return false;
    try {
      await LocalDatabase.instance.replaceFocus(_sessions);
      return true;
    } catch (e) {
      AppLog.d('[FocusProvider] 持久化专注会话失败：$e');
      return false;
    }
  }

  /// 持久化进行中的番茄钟运行态；无进行中则删除该 key。
  Future<void> _persistActive() async {
    final prefs = await SharedPreferences.getInstance();
    if (!hasActive) {
      await prefs.remove(_kActive);
      return;
    }
    await prefs.setString(
      _kActive,
      jsonEncode({
        'totalSec': activeTotalSec,
        'accumulatedSec': activeAccumulatedSec,
        'segmentStartEpochMs': activeSegmentStartEpochMs,
        'running': activeRunning,
        'modeIndex': activeModeIndex,
        'customSec': activeCustomSec,
        'taskId': activeTaskId,
        'taskTitle': activeTaskTitle,
        'phase': activePhase.name,
        'focusDoneInCycle': focusDoneInCycle,
        'cycleNo': cycleNo,
        'interruptCount': activeInterruptCount, // P0-4
      }),
    );
  }

  /// 进程即将被杀（AppLifecycleState.paused/detached）时调用，把所有内存态重新落盘，
  /// 最大化解 shared_preferences.apply() / SQLite 在进程死亡前的刷盘机会
  /// （ColorOS 等激进杀进程 ROM 上 apply() 异步写盘易在杀进程时丢失）。
  Future<void> persist() async {
    await _persist(); // 会话列表（SQLite）
    await _persistActive(); // 进行中计时态（SP）
  }

  // —— 进行中状态派生 ——

  /// 是否存在进行中的番茄钟。
  bool get hasActive => activeTotalSec > 0;

  /// 当前剩余秒数（基于墙钟实时推算，杀后台不丢）。
  int get remainingSec {
    if (activeTotalSec <= 0) return 0;
    var base = activeAccumulatedSec;
    if (activeRunning && activeSegmentStartEpochMs != null) {
      base += (DateTime.now().millisecondsSinceEpoch -
              activeSegmentStartEpochMs!) ~/
          1000;
    }
    final rem = activeTotalSec - base;
    return rem < 0 ? 0 : rem;
  }

  /// 进度 0..1。
  double get progress {
    if (activeTotalSec <= 0) return 0.0;
    final p = 1 - remainingSec / activeTotalSec;
    return p < 0 ? 0.0 : (p > 1 ? 1.0 : p);
  }

  // —— 控制 ——

  /// 开始一个新的番茄钟（覆盖任何既有的进行中状态）。
  /// 非循环单次计时：阶段恒为 [FocusPhase.focus]。
  Future<void> startTimer({
    required int totalSec,
    required int modeIndex,
    required int customSec,
    String? taskId,
    String? taskTitle,
  }) async {
    await _startCore(
      totalSec: totalSec,
      modeIndex: modeIndex,
      customSec: customSec,
      phase: FocusPhase.focus,
      taskId: taskId,
      taskTitle: taskTitle,
    );
  }

  /// 开始一个番茄循环：从专注阶段起算，重置回合数。
  Future<void> startPomodoroCycle({String? taskId, String? taskTitle}) async {
    await _beginPhase(
      FocusPhase.focus,
      taskId: taskId,
      taskTitle: taskTitle,
      resetCycle: true,
    );
  }

  /// 进入番茄循环的某个阶段（不重置回合计数，除非 [resetCycle]）。
  /// 自动接管计时起点、系统闹钟与进度通知。
  Future<void> _beginPhase(
    FocusPhase phase, {
    String? taskId,
    String? taskTitle,
    bool resetCycle = false,
  }) async {
    if (resetCycle) {
      focusDoneInCycle = 0;
      cycleNo = 1;
    }
    await _startCore(
      totalSec: phaseDuration(phase),
      modeIndex: _modeIndexOfPhase(phase),
      customSec: phaseDuration(phase),
      phase: phase,
      taskId: taskId,
      taskTitle: taskTitle,
    );
  }

  /// 计时启动的公共内核：设置运行态、挂系统闹钟、弹进度通知。
  /// [phase] 写回 [activePhase]，使阶段语义贯穿整个运行态。
  Future<void> _startCore({
    required int totalSec,
    required int modeIndex,
    required int customSec,
    required FocusPhase phase,
    String? taskId,
    String? taskTitle,
  }) async {
    final now = DateTime.now();
    _tickTimer?.cancel();
    activeTotalSec = totalSec;
    activeAccumulatedSec = 0;
    activeSegmentStartEpochMs = now.millisecondsSinceEpoch;
    activeRunning = true;
    activeModeIndex = modeIndex;
    activeCustomSec = customSec;
    activePhase = phase;
    activeTaskId = taskId;
    activeTaskTitle = taskTitle;
    // P0-4：新段落从零开始统计打断（覆盖 startTimer 与番茄循环的每次阶段切换）。
    activeInterruptCount = 0;
    _leftAt = null;
    _startTick();
    await _persistActive();
    await _scheduleCompletion();
    await NotificationService.instance.showFocusProgress(
      remainingSec: remainingSec,
      totalSec: activeTotalSec,
      taskTitle: activeTaskTitle,
      phase: activePhase,
    );
    notifyListeners();
  }

  /// 暂停：把当前段落已逝时间并入累计，并取消完成通知（恢复时再挂）。
  Future<void> pauseTimer() async {
    if (!activeRunning) return;
    final seg = activeSegmentStartEpochMs ?? DateTime.now().millisecondsSinceEpoch;
    activeAccumulatedSec +=
        (DateTime.now().millisecondsSinceEpoch - seg) ~/ 1000;
    if (activeAccumulatedSec > activeTotalSec) {
      activeAccumulatedSec = activeTotalSec;
    }
    activeSegmentStartEpochMs = null;
    activeRunning = false;
    _tickTimer?.cancel();
    await _cancelCompletion();
    await NotificationService.instance.cancelFocusProgress();
    await _persistActive();
    notifyListeners();
  }

  /// 从暂停恢复：以「现在」为新段落起点重新累计，并重挂完成通知。
  Future<void> resumeTimer() async {
    if (activeRunning || !hasActive) return;
    if (remainingSec <= 0) return;
    activeSegmentStartEpochMs = DateTime.now().millisecondsSinceEpoch;
    activeRunning = true;
    _startTick();
    await _scheduleCompletion();
    await _persistActive();
    notifyListeners();
  }

  /// 手动停止：按已逝时间补录一条（未完成），并清空进行中状态、取消完成通知。
  /// 手动停止视为放弃当前循环，回合计数一并清零。
  ///
  /// P3-2（v3.1.0 审计）：返回补录是否落盘成功（无补录 = true），供停止按钮
  /// 如实提示——旧实现丢弃 `_persist()` 结果，写库失败时记录重启即丢且零反馈。
  Future<bool> stopTimer() async {
    if (!hasActive) return true;
    final elapsed = activeTotalSec - remainingSec;
    _tickTimer?.cancel();
    var ok = true;
    if (elapsed > 0) {
      final now = DateTime.now();
      // P2-4（v3.1.0 审计）：休息段手动停止同样不把会话记到任务上（与
      // [_recordAndAdvance] 的落库口径一致）。
      final bool isFocusPhase = activePhase == FocusPhase.focus;
      final s = FocusSession(
        id: _nextSessionId(),
        taskId: isFocusPhase ? activeTaskId : null,
        taskTitle: isFocusPhase ? activeTaskTitle : null,
        plannedSec: activeTotalSec,
        durationSec: elapsed,
        completed: false,
        phase: activePhase,
        interruptCount: activeInterruptCount, // P0-4
        startedAt: now.subtract(Duration(seconds: elapsed)),
        endedAt: now,
      );
      ok = await addSession(s);
      if (!ok) _notifySessionPersistFailed();
      _maybeExportToCalendar(s);
    }
    final hadInterrupt = activeInterruptCount > 0;
    _resetActive();
    await _cancelCompletion();
    await NotificationService.instance.cancelFocusProgress();
    // P0-4：专注结束，清掉可能残留的「被切出」挽留通知。
    if (hadInterrupt) {
      await NotificationService.instance.cancelFocusInterruptNotice();
    }
    await _persistActive();
    notifyListeners();
    return ok;
  }

  void _resetActive() {
    activeTotalSec = 0;
    activeAccumulatedSec = 0;
    activeSegmentStartEpochMs = null;
    activeRunning = false;
    activeModeIndex = 0;
    activeCustomSec = 0;
    activePhase = FocusPhase.focus;
    focusDoneInCycle = 0;
    cycleNo = 1;
    // P0-4：段落结束即清零打断计数与切出时刻。
    activeInterruptCount = 0;
    _leftAt = null;
  }

  // ===== P0-4：专注「中断感知」L1 =====
  // 口径：专注**阶段**进行中切出 App，且离开超过 [interruptThresholdSec] 才计一次。
  // 休息阶段不统计（休息本来就该离开），暂停 / 无进行中计时也不统计。

  /// App 切到后台（[AppLifecycleState.paused]/[hidden]）时调用：记下切出时刻。
  /// 由 main.dart 的生命周期观察器接线。
  void noteAppPaused() {
    if (!activeRunning || activePhase != FocusPhase.focus) return;
    _leftAt = DateTime.now();
  }

  /// App 切回前台（[AppLifecycleState.resumed]）时调用：按离开时长判定是否构成
  /// 一次打断，是则累加计数并弹一条挽留通知。由 main.dart 的生命周期观察器接线。
  Future<void> noteAppResumed() async {
    final left = _leftAt;
    _leftAt = null;
    if (left == null) return;
    if (!activeRunning || activePhase != FocusPhase.focus) return;
    final awaySec = DateTime.now().difference(left).inSeconds;
    if (awaySec < interruptThresholdSec) return; // 短暂切屏，不算打断
    activeInterruptCount += 1;
    await _persistActive();
    notifyListeners();
    try {
      await NotificationService.instance
          .showFocusInterruptNotice(activeInterruptCount);
    } catch (_) {
      // 通知失败不影响计时本身。
    }
  }

  void _startTick() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    if (!activeRunning) return;
    if (remainingSec <= 0) {
      _completeNaturally();
    } else {
      // 每次心跳刷新锁屏/通知上的剩余时间（常驻进度通知）。
      NotificationService.instance.showFocusProgress(
        remainingSec: remainingSec,
        totalSec: activeTotalSec,
        taskTitle: activeTaskTitle,
        phase: activePhase,
      );
      notifyListeners();
    }
  }

  /// 应用内自然跑满：补录完成会话、取消系统闹钟、立即补弹通知（同 id 覆盖不重复）。
  ///
  /// 若开启番茄循环则自动进入下一阶段（专注↔休息），形成连续循环；
  /// 否则维持原行为：补录后清空进行中状态。
  Future<void> _completeNaturally() async {
    await _recordAndAdvance(silent: false);
  }

  /// 被杀后台期间跑满：补录完成会话并自动推进（系统闹钟已在完成时刻弹出，不再补弹）。
  Future<void> _completeSilently() async {
    await _recordAndAdvance(silent: true);
  }

  /// 跑满一个阶段后的统一收尾：补录完成会话，并按是否开启番茄循环决定走向。
  ///
  /// - 番茄循环开启：根据 [activePhase] 与回合计数算出下一阶段并自动进入；
  ///   专注完成提示"该休息"，休息结束提示"开始下一个番茄"。[silent] 为 true 时
  ///   不弹「完成」通知（系统闹钟已在完成时刻弹出）。
  /// - 番茄循环关闭：维持原行为，清空进行中状态（不自动开始下一段）。
  Future<void> _recordAndAdvance({required bool silent}) async {
    // 重入保护：避免在 await 链未结束前被下一秒 tick 再次进入，导致重复补录会话。
    if (_completing) return;
    _completing = true;
    try {
    final phase = activePhase;
    final total = activeTotalSec;
    final start = activeSegmentStartEpochMs != null
        ? DateTime.fromMillisecondsSinceEpoch(activeSegmentStartEpochMs!)
        : DateTime.now().subtract(Duration(seconds: total));
    // 🟡 修复 Bug4：补录场景下，endedAt 不允许落在未来。
    // 原写法 `ended = start + total` 在「本阶段曾暂停过」时会把 paused 之前的累计秒
    // 也加进去（start 已是最后一段起点，total 却含已累计的暂停前时间），导致 endedAt
    // 晚于当前时刻（落在未来）。按 endedAt 归日的统计（今日专注、日历视图）会算错天。
    //
    // M11（v3.0.8 审计）：endedAt 改取 `min(now, start + total)`——旧实现取 now
    // （重开时刻）修 Bug4 的同时引入反向错误：杀后台跨天后补录会把昨日跑满的阶段
    // 记到**今天**（昨日漏记、今日虚增，日历事件跨度从昨晚拉到今晨）。阶段真正
    // 跑满的时刻就是 `start + total`（无暂停时精确；暂停时它偏未来，由 min 夹到
    // now，Bug4 的防护不变）。
    final now = DateTime.now();
    final cap = start.add(Duration(seconds: total));
    final ended = cap.isAfter(now) ? now : cap;
    // P2-4（v3.1.0 审计）：休息阶段的会话不携带任务——旧实现把 activeTaskId
    // 原样带进休息段并触发任务累计回填，25/5 循环 4 轮后任务「已专注」显示
    // 130 分钟（100 专注 + 30 休息）。运行态保留 activeTaskId（休息结束回到
    // 专注阶段仍关联同一任务），只对**落库的会话**抹去任务关联。
    final bool isFocusPhase = phase == FocusPhase.focus;
    final s = FocusSession(
      id: _nextSessionId(),
      taskId: isFocusPhase ? activeTaskId : null,
      taskTitle: isFocusPhase ? activeTaskTitle : null,
      plannedSec: total,
      durationSec: total,
      completed: true,
      phase: phase,
      interruptCount: activeInterruptCount, // P0-4
      startedAt: start,
      endedAt: ended,
    );
    // P3-2（v3.1.0 审计）：await 落盘结果；失败经 [onSessionPersistFailed]
    // 透给 UI 提示（tick 触发的自动推进没有 BuildContext）。
    final ok = await addSession(s);
    if (!ok) _notifySessionPersistFailed();
    _maybeExportToCalendar(s);

    // P0-4：本阶段收尾，清掉挽留通知；进入下一阶段前先把计数归零。
    if (activeInterruptCount > 0) {
      await NotificationService.instance.cancelFocusInterruptNotice();
    }
    activeInterruptCount = 0;
    _leftAt = null;

    if (_pomodoroEnabled) {
      FocusPhase next;
      String? body;
      if (phase == FocusPhase.focus) {
        focusDoneInCycle += 1;
        next = nextPhaseFrom(FocusPhase.focus, focusDoneInCycle, _pomoRounds);
        body = next == FocusPhase.longBreak
            ? '专注完成 🍅 本轮已 $focusDoneInCycle/$_pomoRounds，去长休息一下吧'
            : '专注完成 🍅 该短休息一下啦';
      } else {
        if (phase == FocusPhase.longBreak) {
          focusDoneInCycle = 0;
          cycleNo += 1;
        }
        next = FocusPhase.focus;
        body = '休息结束 ☕ 开始下一个番茄';
      }
      if (!silent) {
        await NotificationService.instance.showFocusDoneNow(body: body);
      }
      // 自动进入下一阶段（接管计时、系统闹钟与进度通知）。
      // M11（v3.0.8 审计）：**杀后台期间跑满的补录不自动续跑**——旧实现补录后
      // 立即 _beginPhase(next)：设置运行态、弹常驻进度通知、挂系统闹钟，数日后
      // 打开 App 会凭空替用户「开新番茄」。补录只把已完成的阶段记账，运行态收敛
      // 到「待开始」（与用户主动停止同口径），想继续由用户自己点开始。
      // 应用内自然跑满（silent=false）保持自动循环行为不变。
      if (silent) {
        _resetActive();
        await _cancelCompletion();
        await NotificationService.instance.cancelFocusProgress();
        notifyListeners();
        return;
      }
      await _beginPhase(next, taskId: activeTaskId, taskTitle: activeTaskTitle);
      return;
    }

    // 非番茄循环：原行为。
    _resetActive();
    await _cancelCompletion();
    await NotificationService.instance.cancelFocusProgress();
    if (!silent) {
      await NotificationService.instance.showFocusDoneNow();
    }
    notifyListeners();
    } finally {
      _completing = false;
    }
  }

  /// 挂「专注完成」系统闹钟（setAlarmClock）：完成时刻弹出，杀后台也准点。
  Future<void> _scheduleCompletion() async {
    if (!hasActive || !activeRunning || activeSegmentStartEpochMs == null) {
      return;
    }
    final when = DateTime.fromMillisecondsSinceEpoch(activeSegmentStartEpochMs!)
        .add(Duration(seconds: activeTotalSec - activeAccumulatedSec));
    await NotificationService.instance.scheduleFocusDone(when);
  }

  Future<void> _cancelCompletion() async {
    await NotificationService.instance.cancelFocusDone();
  }

  /// P3-2（v3.1.0 审计）：返回落盘是否成功。新增写入**不回滚内存**（与任务侧
  /// addFocusSec「修改类写入口不内存回滚」口径一致——回滚会让用户刚跑完的
  /// 专注在 UI 上凭空消失），失败由调用方如实提示；安全模式下恒 false（P1-1）。
  ///
  /// P2-4（v3.1.0 审计）：任务累计回填（[onFocusRecorded]）仅限**专注阶段**会话
  /// ——休息段带 taskId 的历史数据不再把休息时长记到任务上。回调整体挪到
  /// **落盘成功之后**：落盘失败时任务累计与库内状态保持一致（都未生效）。
  Future<bool> addSession(FocusSession s) async {
    _sessions.add(s);
    final ok = await _persist();
    if (ok && s.taskId != null && s.phase == FocusPhase.focus) {
      onFocusRecorded?.call(s.taskId!, s.durationSec);
    }
    notifyListeners();
    return ok;
  }

  /// 删除单条专注记录（按 id）。
  ///
  /// P2-9（v2.9.6 审计）：删除与新增**对称**——带 taskId 的记录删除时经
  /// [onFocusRemoved] 扣减任务累计专注（此前只加不减，撤销删除再回填即双倍）。
  ///
  /// P3-2（v3.1.0 审计）：返回被删记录；**null = 删除未生效**（id 不存在，或
  /// 落盘失败已回滚内存）——旧实现 `_persist()` 丢弃结果：删除可能只生效在
  /// 内存、重启「复活」，而横幅已承诺可撤销。落盘失败时插回原位并返回 null，
  /// 调用方（focus_screen）据 null 如实提示。
  Future<FocusSession?> removeSession(String id) async {
    final i = _sessions.indexWhere((s) => s.id == id);
    if (i == -1) return null;
    final s = _sessions.removeAt(i);
    final ok = await _persist();
    if (!ok) {
      _sessions.insert(i, s);
      notifyListeners();
      return null;
    }
    if (s.taskId != null && s.phase == FocusPhase.focus) {
      // P2-4：休息段（历史数据带 taskId）删除时不扣任务累计（写入侧已不回填）。
      onFocusRemoved?.call(s.taskId!, s.durationSec);
    }
    notifyListeners();
    return s;
  }

  /// 删除今天（date-only）的全部专注记录。返回被删的记录列表（供撤销整体
  /// 恢复，P3-15——同屏单条删除有 10 秒撤销，批量清空反而无保护，力度倒挂）。
  ///
  /// P3-2（v3.1.0 审计）：**空列表 = 清空未生效**（今天本无记录，或落盘失败
  /// 已回滚内存——调用方 focus_screen 判空后不再弹「已清空 0 条」的假横幅，
  /// 落盘失败时给出如实提示）。
  ///
  /// P2-9 对称扣减：与 [removeSession] 同口径，带 taskId 的**专注阶段**记录
  /// 逐条经 [onFocusRemoved] 扣减；撤销恢复走 [addSession] 逐条回填，两侧相抵。
  Future<List<FocusSession>> clearToday() async {
    final t = DateTime.now();
    final today = DateTime(t.year, t.month, t.day);
    final removed = _sessions
        .where((s) =>
            DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == today)
        .toList();
    if (removed.isEmpty) return const <FocusSession>[];
    _sessions.removeWhere((s) =>
        DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == today);
    final ok = await _persist();
    if (!ok) {
      _sessions.addAll(removed);
      notifyListeners();
      return const <FocusSession>[];
    }
    for (final s in removed) {
      if (s.taskId != null && s.phase == FocusPhase.focus) {
        onFocusRemoved?.call(s.taskId!, s.durationSec);
      }
    }
    notifyListeners();
    return removed;
  }

  /// 某天（date-only）专注总秒数（含休息阶段，历史口径）。
  int totalSecOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return _sessions
        .where((s) =>
            DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == d)
        .fold(0, (sum, s) => sum + s.durationSec);
  }

  /// 某天（date-only）**专注阶段**总秒数（不含休息，番茄统计口径）。
  int focusSecOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return _sessions
        .where((s) =>
            s.phase == FocusPhase.focus &&
            DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == d)
        .fold(0, (sum, s) => sum + s.durationSec);
  }

  /// 近 7 日（含今天，由旧到新）每日**专注阶段**总秒数，供可视化使用。
  List<int> last7FocusSecs() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final list = <int>[];
    for (var i = 6; i >= 0; i--) {
      list.add(focusSecOn(today.subtract(Duration(days: i))));
    }
    return list;
  }

  /// 今日专注总秒数（含休息阶段，历史口径）。
  int get todayTotalSec => totalSecOn(DateTime.now());

  /// 专注时段分布（A2）：按「开始时刻的小时」把全部**专注阶段**会话聚合到
  /// 24 个桶，返回长度 24 的 int 列表（下标 0..23 对应 00:00..23:00 的累计专注秒数）。
  /// 用于「专注时段分布图」自绘直方图。零新存储，纯基于现有 [_sessions] 现算。
  /// P2-4（v3.1.0 审计）：旧实现含休息阶段——休息时段混进「专注时段分布」，
  /// 与页面其它「专注阶段」口径打架。
  List<int> hourDistribution() {
    final buckets = List.filled(24, 0);
    for (final s in _sessions) {
      if (s.phase != FocusPhase.focus) continue;
      final h = s.startedAt.hour.clamp(0, 23);
      buckets[h] += s.durationSec;
    }
    return buckets;
  }

  /// 今日**专注阶段**总秒数（不含休息，推荐用于「今日专注」展示）。
  int get todayFocusSec => focusSecOn(DateTime.now());

  /// 累计**专注阶段**总秒数（P2-4，v3.1.0 审计：不含休息——成就「累计专注
  /// 分钟」与专注页「累计」消费本值，把休息算进去会让核心度量系统性偏高，
  /// 且与 [focusSecOn] / [todayFocusSec] 的阶段口径打架）。
  int get totalSec => _sessions
      .where((s) => s.phase == FocusPhase.focus)
      .fold(0, (sum, s) => sum + s.durationSec);

  /// 今日完成的番茄数（跑满预设时长的**专注**阶段；休息不计入）。
  int get todayCompleted => completedOn(DateTime.now());

  /// 指定日完成的番茄数（date-only）。
  /// P2-1：晚简报按**投递日**聚合，不能取「本机当前日」，
  /// 否则 22:00 后重排到次日投递时会出现「任务 0 个 / 专注 X 分钟」的混合口径。
  int completedOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return _sessions.where((s) {
      return s.completed &&
          s.phase == FocusPhase.focus &&
          DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == d;
    }).length;
  }

  /// 指定日专注被打断的总次数（F2：仅统计**专注**阶段会话的 interruptCount）。
  int interruptCountOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return _sessions
        .where((s) =>
            s.phase == FocusPhase.focus &&
            DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == d)
        .fold(0, (sum, s) => sum + s.interruptCount);
  }

  /// 今日专注被打断次数（F2 展示闭环的今日入口）。
  int get todayInterruptCount => interruptCountOn(DateTime.now());

  /// P3-2（v3.1.0 审计）：返回落盘是否成功（此前丢弃结果）。失败时内存回滚
  /// ——清空族与删除族同口径，UI 显示的即已落盘的。
  Future<bool> clear() async {
    final snapshot = List<FocusSession>.of(_sessions);
    _sessions.clear();
    final ok = await _persist();
    if (!ok) {
      _sessions
        ..clear()
        ..addAll(snapshot);
    }
    notifyListeners();
    return ok;
  }

  /// 按关联任务聚合的专注统计（仅含带 taskId 的**专注阶段**会话）。
  /// 返回按累计时长降序的列表，供「专注与任务关联统计」展示。
  /// P2-4（v3.1.0 审计）：旧实现不过滤阶段——番茄循环的休息段（历史数据带
  /// taskId 落库）把休息时长算进任务「已专注」，与任务详情/报表口径矛盾。
  List<TaskFocusStat> get taskStats {
    final map = <String, TaskFocusStat>{};
    for (final s in _sessions) {
      if (s.phase != FocusPhase.focus) continue;
      if (s.taskId == null) continue;
      final existing = map[s.taskId!];
      if (existing == null) {
        map[s.taskId!] = TaskFocusStat(
          taskId: s.taskId!,
          title: s.taskTitle ?? '任务',
          totalSec: s.durationSec,
          count: 1,
        );
      } else {
        map[s.taskId!] = TaskFocusStat(
          taskId: existing.taskId,
          title: existing.title,
          totalSec: existing.totalSec + s.durationSec,
          count: existing.count + 1,
        );
      }
    }
    final list = map.values.toList()
      ..sort((a, b) => b.totalSec.compareTo(a.totalSec));
    return list;
  }

  /// 某天（date-only）结束的专注会话列表（供日历显示）。
  List<FocusSession> sessionsOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return _sessions.where((s) {
      final sd = DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day);
      return sd == d;
    }).toList();
  }

  /// 设置「专注结束自动记入系统日历」开关并持久化。
  Future<void> setSysCalendarEnabled(bool v) async {
    _sysCalendarEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSysCal, v);
    notifyListeners();
  }

  /// 若开启系统日历同步，则在专注结束时写入一条系统日历事件（失败静默）。
  void _maybeExportToCalendar(FocusSession s) {
    if (!_sysCalendarEnabled) return;
    exportFocusToSystemCalendar(s).catchError((_) {
      // 权限未授予 / 平台不支持等情况不应影响专注记录本身。
      return;
    });
  }

  // ===== 备份 / 导出 / 恢复（番茄钟每日专注并入「自动保存数据与导出」）=====

  /// 专注会话的 JSON 列表（用于在备份时与任务数据合并）。
  List<Map<String, dynamic>> get sessionsJson =>
      _sessions.map((s) => s.toJson()).toList();

  /// 从备份恢复专注会话列表（[list] 为 FocusSession 的 JSON 列表）。
  /// 仅在备份含 [focus_sessions] 字段时调用；缺失则保留现有数据不覆盖。
  Future<void> restoreSessions(List<dynamic> list) async {
    _sessions
      ..clear()
      ..addAll(
          list.map((e) => FocusSession.fromJson(e as Map<String, dynamic>)));
    await _persist();
    notifyListeners();
  }

  /// P3-11（v2.9.5 审计）：专注表列定义（CSV / Excel 共用的**单一真源**）。
  ///
  /// 此前表头在 `exportCsv` 与 `report_exporter._fillFocusSheet` 各写一份——
  /// v2.9.3 给 CSV 补列时 Excel 静默漏改的风险一直存在（任务表在 v2.9.1 就踩过
  /// 这类双份定义漂移）。现在两路都走这里，下一轮加列只改这一处。
  static const List<String> focusExportHeaders = [
    '日期',
    '开始时间',
    '结束时间',
    '计划时长(分)',
    '实际时长(分)',
    '是否完成',
    '关联任务',
  ];

  /// 专注表一行取值（与 [focusExportHeaders] 逐列对齐）。
  ///
  /// 数值列回传真值（计划时长 int / 实际时长 double，Excel 写原生数值单元格），
  /// CSV 侧对 double 统一 `toStringAsFixed(1)`（与旧格式逐字节一致）。
  List<Object> focusExportCells(FocusSession s) => [
        _fmtDate(s.startedAt),
        _fmt(s.startedAt),
        _fmt(s.endedAt),
        (s.plannedSec / 60).round(),
        s.durationSec / 60,
        s.completed ? '是' : '否',
        s.taskTitle ?? '',
      ];

  /// 导出专注会话为 CSV（列定义见 [focusExportHeaders]）。
  String exportCsv() {
    final buf = StringBuffer();
    buf.writeln(focusExportHeaders.join(','));
    for (final s in _sessions) {
      final cells = focusExportCells(s);
      String cell(Object v) =>
          v is double ? v.toStringAsFixed(1) : v.toString();
      // P3-11（v2.9.5 审计）顺带修复：表头本就含「日期」列（v2.9.3 补列时
      // 只加了表头），但数据行从基线起就漏写该字段 → 整行左移一列（开始时间
      // 落在「日期」列下）。现在从真源 cells 逐列对齐取值，7 列一一对应。
      buf.writeln('"${cells[0]}","${_fmt(s.startedAt)}","${_fmt(s.endedAt)}",'
          '"${cell(cells[3])}","${cell(cells[4])}","${cells[5]}",'
          '"${_esc(s.taskTitle ?? '')}"');
    }
    return buf.toString();
  }

  /// 导出专注会话为 Markdown，按日期分组（旧→新），每组列明细与当日累计。
  String exportMarkdown() {
    final buf = StringBuffer();
    buf.writeln('# 有条 专注记录导出');
    buf.writeln('');
    buf.writeln('> 导出时间：${_fmt(DateTime.now())}');
    // P3-10（v2.9.6 审计）：与任务 / 习惯 MD 同口径——标注「可读摘要」定位
    // （本表缺阶段列 / 关联任务 id 等真源列），完整字段请用 CSV / Excel。
    buf.writeln('> 说明：Markdown 为**可读摘要**；归档 / 迁移请用 CSV 或 Excel 导出。');
    buf.writeln('');
    if (_sessions.isEmpty) {
      buf.writeln('_暂无专注记录_');
      return buf.toString();
    }
    final byDay = <DateTime, List<FocusSession>>{};
    for (final s in _sessions) {
      final d = DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day);
      byDay.putIfAbsent(d, () => []).add(s);
    }
    final days = byDay.keys.toList()..sort();
    for (final d in days) {
      final list = byDay[d]!;
      final totalSec = list.fold(0, (a, s) => a + s.durationSec);
      buf.writeln('## ${_fmt(d)}（${list.length} 次 · ${formatFocusDuration(totalSec)}）');
      for (final s in list) {
        final flag = s.completed ? '🍅' : '·';
        final task = s.taskTitle == null ? '' : ' ｜ ${s.taskTitle}';
        final start = _fmt(s.startedAt).substring(11);
        final end = _fmt(s.endedAt).substring(11);
        buf.writeln(
            '- $flag $start → $end ${formatFocusDuration(s.durationSec)}$task');
      }
      buf.writeln('');
    }
    return buf.toString();
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// P3-11：date-only 形态（专注表「日期」列），供 [focusExportCells] 与 Excel 共用。
  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// M6（v3.0.8 审计）：直接委托 [csvCell]（csv_safe 单一真源）——旧实现是
  /// 弱化版（只查首字符）：`"  =HYPERLINK(...)"`、`"\uFEFF=cmd|..."` 这类
  /// 「前导空白 / BOM + 公式引导符」可绕过，恶意导入的标题带进专注记录后，导出
  /// CSV 在 Excel/WPS 打开即公式注入复活。任务表 /  habit 表早在用 csvCell，
  /// 专注表是最后一处漏网。
  static String _esc(String s) => csvCell(s);
}

/// 单个任务的专注聚合统计。
class TaskFocusStat {
  final String taskId;
  final String title;
  final int totalSec;
  final int count;
  const TaskFocusStat({
    required this.taskId,
    required this.title,
    required this.totalSec,
    required this.count,
  });
}
