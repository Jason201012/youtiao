import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/services/notification_service.dart';

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

  Timer? _tickTimer;

  /// 所有会话（按结束时间倒序，最新在前）。
  List<FocusSession> get sessions =>
      _sessions.toList()..sort((a, b) => b.endedAt.compareTo(a.endedAt));

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFocus);
    final saved = prefs.getInt(_kCustom);
    if (saved != null && saved > 0) _customSec = saved;
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _sessions
        ..clear()
        ..addAll(list.map((e) => FocusSession.fromJson(e as Map<String, dynamic>)));
    } catch (_) {
      // 解析失败：丢弃损坏数据，不阻塞启动。
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

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kFocus,
      jsonEncode(_sessions.map((s) => s.toJson()).toList()),
    );
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
      }),
    );
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
  Future<void> startTimer({
    required int totalSec,
    required int modeIndex,
    required int customSec,
  }) async {
    final now = DateTime.now();
    _tickTimer?.cancel();
    activeTotalSec = totalSec;
    activeAccumulatedSec = 0;
    activeSegmentStartEpochMs = now.millisecondsSinceEpoch;
    activeRunning = true;
    activeModeIndex = modeIndex;
    activeCustomSec = customSec;
    _startTick();
    await _persistActive();
    await _scheduleCompletion();
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
  Future<void> stopTimer() async {
    if (!hasActive) return;
    final elapsed = activeTotalSec - remainingSec;
    _tickTimer?.cancel();
    if (elapsed > 0) {
      final now = DateTime.now();
      addSession(FocusSession(
        id: now.millisecondsSinceEpoch.toString(),
        plannedSec: activeTotalSec,
        durationSec: elapsed,
        completed: false,
        startedAt: now.subtract(Duration(seconds: elapsed)),
        endedAt: now,
      ));
    }
    _resetActive();
    await _cancelCompletion();
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
      notifyListeners();
    }
  }

  /// 应用内自然跑满：补录完成会话、取消系统闹钟、立即补弹通知（同 id 覆盖不重复）。
  Future<void> _completeNaturally() async {
    final total = activeTotalSec;
    final start = activeSegmentStartEpochMs != null
        ? DateTime.fromMillisecondsSinceEpoch(activeSegmentStartEpochMs!)
        : DateTime.now().subtract(Duration(seconds: total));
    final ended = start.add(Duration(seconds: total));
    _resetActive();
    await _cancelCompletion();
    addSession(FocusSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      plannedSec: total,
      durationSec: total,
      completed: true,
      startedAt: start,
      endedAt: ended,
    ));
    await NotificationService.instance.showFocusDoneNow();
    notifyListeners();
  }

  /// 被杀后台期间跑满：补录完成会话（系统闹钟已在完成时刻弹出，这里只取消防重复）。
  Future<void> _completeSilently() async {
    final total = activeTotalSec;
    final start = activeSegmentStartEpochMs != null
        ? DateTime.fromMillisecondsSinceEpoch(activeSegmentStartEpochMs!)
        : DateTime.now().subtract(Duration(seconds: total));
    final ended = start.add(Duration(seconds: total));
    _resetActive();
    addSession(FocusSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      plannedSec: total,
      durationSec: total,
      completed: true,
      startedAt: start,
      endedAt: ended,
    ));
    await _cancelCompletion();
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

  /// 某天（date-only）专注总秒数。
  int totalSecOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return _sessions
        .where((s) =>
            DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == d)
        .fold(0, (sum, s) => sum + s.durationSec);
  }

  /// 今日专注总秒数。
  int get todayTotalSec => totalSecOn(DateTime.now());

  /// 累计专注总秒数。
  int get totalSec => _sessions.fold(0, (sum, s) => sum + s.durationSec);

  /// 今日完成的番茄数（跑满预设时长）。
  int get todayCompleted =>
      _sessions.where((s) {
        final d = DateTime.now();
        final today = DateTime(d.year, d.month, d.day);
        return s.completed &&
            DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == today;
      }).length;

  void clear() {
    _sessions.clear();
    _persist();
    notifyListeners();
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
