import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/calendar_exporter.dart';

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

  /// 由任务行「专注」按钮设置的「待选任务」：跳到专注页后预选到 [_TaskPicker]。
  /// 不持久化，仅在本次跨页面跳转期间临时携带。
  String? pendingTaskId;
  String? pendingTaskTitle;

  /// 供任务行点击后请求「跳转到专注 Tab」的回调（由 [MainScaffold] 注册）。
  /// 设为静态以便任意持有 [FocusProvider] 的地方（如任务行）便捷调用。
  static VoidCallback? jumpToFocusTab;

  /// 任务行点「专注」时调用：暂存待选任务，并请求跳转到专注页。
  void requestTask(String id, String title) {
    pendingTaskId = id;
    pendingTaskTitle = title;
    jumpToFocusTab?.call();
  }

  /// 专注会话记录后的回调：(taskId, durationSec)。由 main 接线到
  /// TaskProvider.addFocusSec，把专注时长回填到关联任务的累计专注字段。
  /// 仅在会话带 taskId 时触发。
  void Function(String taskId, int durationSec)? onFocusRecorded;

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

  /// 所有会话（按结束时间倒序，最新在前）。
  List<FocusSession> get sessions =>
      _sessions.toList()..sort((a, b) => b.endedAt.compareTo(a.endedAt));

  Future<void> load() async {
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
    // 内存后端（测试）无需打开真实 SQLite；仅在生产（非内存）模式确保建表。
    // 与 HabitProvider.load() 保持一致，避免宿主环境下 databaseFactory 未初始化。
    if (!LocalDatabase.testUseMemory) {
      await db.db;
    }
    if (await db.focusEmpty && prefs.getString(_kFocus) != null) {
      await db.migrateFocusFromPrefs(prefs);
    }
    _sessions
      ..clear()
      ..addAll(await db.loadFocus());
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

  Future<void> _persist() async {
    await LocalDatabase.instance.replaceFocus(_sessions);
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
  Future<void> stopTimer() async {
    if (!hasActive) return;
    final elapsed = activeTotalSec - remainingSec;
    _tickTimer?.cancel();
    if (elapsed > 0) {
      final now = DateTime.now();
      final s = FocusSession(
        id: now.millisecondsSinceEpoch.toString(),
        taskId: activeTaskId,
        taskTitle: activeTaskTitle,
        plannedSec: activeTotalSec,
        durationSec: elapsed,
        completed: false,
        phase: activePhase,
        startedAt: now.subtract(Duration(seconds: elapsed)),
        endedAt: now,
      );
      addSession(s);
      _maybeExportToCalendar(s);
    }
    _resetActive();
    await _cancelCompletion();
    await NotificationService.instance.cancelFocusProgress();
    await _persistActive();
    notifyListeners();
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
    final phase = activePhase;
    final total = activeTotalSec;
    final start = activeSegmentStartEpochMs != null
        ? DateTime.fromMillisecondsSinceEpoch(activeSegmentStartEpochMs!)
        : DateTime.now().subtract(Duration(seconds: total));
    final ended = start.add(Duration(seconds: total));
    final s = FocusSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      taskId: activeTaskId,
      taskTitle: activeTaskTitle,
      plannedSec: total,
      durationSec: total,
      completed: true,
      phase: phase,
      startedAt: start,
      endedAt: ended,
    );
    addSession(s);
    _maybeExportToCalendar(s);

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

  void addSession(FocusSession s) {
    _sessions.add(s);
    if (s.taskId != null) {
      onFocusRecorded?.call(s.taskId!, s.durationSec);
    }
    _persist();
    notifyListeners();
  }

  /// 删除单条专注记录（按 id）。
  void removeSession(String id) {
    _sessions.removeWhere((s) => s.id == id);
    _persist();
    notifyListeners();
  }

  /// 删除今天（date-only）的全部专注记录。
  void clearToday() {
    final t = DateTime.now();
    final today = DateTime(t.year, t.month, t.day);
    _sessions.removeWhere((s) =>
        DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == today);
    _persist();
    notifyListeners();
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

  /// 今日**专注阶段**总秒数（不含休息，推荐用于「今日专注」展示）。
  int get todayFocusSec => focusSecOn(DateTime.now());

  /// 累计专注总秒数。
  int get totalSec => _sessions.fold(0, (sum, s) => sum + s.durationSec);

  /// 今日完成的番茄数（跑满预设时长的**专注**阶段；休息不计入）。
  int get todayCompleted =>
      _sessions.where((s) {
        final d = DateTime.now();
        final today = DateTime(d.year, d.month, d.day);
        return s.completed &&
            s.phase == FocusPhase.focus &&
            DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == today;
      }).length;

  void clear() {
    _sessions.clear();
    _persist();
    notifyListeners();
  }

  /// 按关联任务聚合的专注统计（仅含带 taskId 的会话）。
  /// 返回按累计时长降序的列表，供「专注与任务关联统计」展示。
  List<TaskFocusStat> get taskStats {
    final map = <String, TaskFocusStat>{};
    for (final s in _sessions) {
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

  /// 导出专注会话为 CSV（日期,开始,结束,计划时长(分),实际时长(分),是否完成,关联任务）。
  String exportCsv() {
    final buf = StringBuffer();
    buf.writeln('日期,开始时间,结束时间,计划时长(分),实际时长(分),是否完成,关联任务');
    for (final s in _sessions) {
      final started = _fmt(s.startedAt);
      final ended = _fmt(s.endedAt);
      final plannedMin = (s.plannedSec / 60).toStringAsFixed(0);
      final durMin = (s.durationSec / 60).toStringAsFixed(1);
      final done = s.completed ? '是' : '否';
      final task = s.taskTitle == null ? '' : '"${_esc(s.taskTitle!)}"';
      buf.writeln(
          '"$started","$ended","$plannedMin","$durMin","$done",$task');
    }
    return buf.toString();
  }

  /// 导出专注会话为 Markdown，按日期分组（旧→新），每组列明细与当日累计。
  String exportMarkdown() {
    final buf = StringBuffer();
    buf.writeln('# 有条 专注记录导出');
    buf.writeln('');
    buf.writeln('> 导出时间：${_fmt(DateTime.now())}');
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
  static String _esc(String s) => s.replaceAll('"', '""');
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
