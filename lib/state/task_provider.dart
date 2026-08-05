import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/background_service.dart';

/// 首页列表筛选（看板统计卡点击后跳转首页并套用）。
enum TaskFilter { all, todo, done, overdue }

/// 内存状态 + shared_preferences 持久化（任务列表与开关设置落盘，重启不丢）
class TaskProvider extends ChangeNotifier {
  static const String _kTasks = 'tasks';
  static const String _kTrash = 'trash';
  static const String _kTheme = 'theme_mode';
  static const String _kFollowSystem = 'follow_system';
  static const String _kNotify = 'notifications_enabled';
  static const String _kSound = 'sound_enabled';
  static const String _kGuard = 'background_guard';

  ThemeMode _themeMode = ThemeMode.light;
  ThemeMode get themeMode => _themeMode;

  bool _followSystem = true;
  bool get followSystem => _followSystem;

  /// 实际生效的主题模式：跟随系统时用系统亮度，否则用手动 light/dark。
  ThemeMode get effectiveThemeMode =>
      _followSystem ? ThemeMode.system : _themeMode;

  void setFollowSystem(bool v) {
    _followSystem = v;
    notifyListeners();
    _persist();
  }

  /// 手动选择浅色/深色：自动退出「跟随系统」。
  void setThemeMode(bool dark) {
    _followSystem = false;
    _themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    _persist();
  }

  // ===== 通知总开关 =====
  bool _notificationsEnabled = true;
  bool get notificationsEnabled => _notificationsEnabled;
  void setNotificationsEnabled(bool v) {
    _notificationsEnabled = v;
    NotificationService.instance.enabled = v;
    if (v) {
      // 打开开关时重新请求通知权限（若之前被拒可再次弹窗）
      NotificationService.instance.requestPermission();
      // 重新调度所有「未完成且未过期」的截止提醒 + 每日提醒，应用新状态
      _rescheduleAllActive();
    } else {
      NotificationService.instance.cancelAll();
    }
    notifyListeners();
    _persist();
  }

  /// 请求通知权限并返回是否授予（设置页「发送测试通知」前调用，
  /// 未授予时引导用户去系统设置开启）。Android 13+ 才需要。
  Future<bool?> requestNotificationPermission() =>
      NotificationService.instance.requestPermission();

  // ===== 声音开关（控制提醒是否响铃）=====
  bool _soundEnabled = true;
  bool get soundEnabled => _soundEnabled;

  // ===== 后台提醒守护（前台服务保活）=====
  bool _backgroundGuard = true;
  bool get backgroundGuardEnabled => _backgroundGuard;
  void setSoundEnabled(bool v) {
    _soundEnabled = v;
    // 重新调度所有提醒（截止 + 每日），应用新的声音设置
    if (_notificationsEnabled) {
      _rescheduleAllActive();
    }
    notifyListeners();
    _persist();
  }

  /// 后台提醒守护开关：开启则拉起前台服务（进程常驻），关闭则停止。
  /// ColorOS 等国产 ROM 划掉后台后会速冻第三方 App，前台服务是唯一可靠的保活手段。
  Future<void> setBackgroundGuard(bool v) async {
    if (_backgroundGuard == v) return;
    _backgroundGuard = v;
    if (v) {
      await BackgroundService.instance.start();
    } else {
      await BackgroundService.instance.stop();
    }
    notifyListeners();
    _persist();
  }

  // ===== 持久化（shared_preferences）=====
  /// 启动时调用：从本地读取任务列表与开关设置；首次启动则保留 7 条 mock 并落盘。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kTasks);
    if (raw == null) {
      await _persist(); // 首次启动：写入初始 mock
    } else {
      try {
        final list = jsonDecode(raw) as List;
        _tasks
          ..clear()
          ..addAll(list.map((e) => Task.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        await _persist(); // 解析失败则回退到内存初始值
      }
    }
    final rawTrash = prefs.getString(_kTrash);
    if (rawTrash != null) {
      try {
        final list = jsonDecode(rawTrash) as List;
        _trash
          ..clear()
          ..addAll(list.map((e) => Task.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        // 回收站解析失败则忽略，不影响正常任务
      }
    }
    final themeIdx = prefs.getInt(_kTheme);
    if (themeIdx != null &&
        themeIdx >= 0 &&
        themeIdx < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[themeIdx];
    }
    _followSystem = prefs.getBool(_kFollowSystem) ?? true;
    _notificationsEnabled = prefs.getBool(_kNotify) ?? true;
    _soundEnabled = prefs.getBool(_kSound) ?? true;
    _backgroundGuard = prefs.getBool(_kGuard) ?? true;
    NotificationService.instance.enabled = _notificationsEnabled;
    // 每日任务：若今天之前已完成且未到截止日期，则重置为未完成，实现「每天循环」提醒。
    // （原生 MidnightResetReceiver 会在每天 00:00 后台自动做同样的事，这里作为
    //  App 启动时的兜底，并在 App 前台时由 _startMidnightWatch 周期性刷新。）
    _resetDailyIfNeeded();
    // 挂上「当天 00:00 自动重置」的午夜闹钟（不依赖 App 是否打开）。
    NotificationService.instance.armMidnightReset();
    // 启动时为已有「未完成且未过期」的任务 + 每日提醒重新调度（老任务/初始 mock 也能响）
    if (_notificationsEnabled) _rescheduleAllActive();
    _recomputeIdSeq();
    _startMidnightWatch();
    notifyListeners();
  }

  /// 把「已完成、未过截止日、且今天是其循环日、且上次完成早于今天」的重复任务重置为未完成。
  /// 返回是否发生了变更（仅在变更时落盘 + 通知 UI）。与原生 MidnightResetReceiver 逻辑一致。
  bool _resetDailyIfNeeded() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var dailyDirty = false;
    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.isRepeating &&
          t.status == TaskStatus.done &&
          (t.dueDate == null || !_dateHasPassed(t.dueDate!)) &&
          t.repeatsOn(today)) {
        final c = t.completedAt;
        if (c == null || DateTime(c.year, c.month, c.day).isBefore(today)) {
          _tasks[i] = t.copyWith(status: TaskStatus.todo, completedAt: null);
          dailyDirty = true;
        }
      }
    }
    if (dailyDirty) _persist();
    return dailyDirty;
  }

  /// 供生命周期/周期守护调用的对外入口：跨天则重置每日任务并刷新 UI。
  void checkDailyReset() {
    if (_resetDailyIfNeeded()) notifyListeners();
  }

  /// App 在前台/后台存活期间的轻量守护：周期性（15 分钟）+ 回到前台时检查「日期是否已跨天」，
  /// 若跨天则重置每日任务。原生午夜闹钟负责「App 已关闭」的情况，本守护负责「App 正开着」的边界。
  void _startMidnightWatch() {
    // 周期性检查（App 进程存活时有效）
    Future.doWhile(() async {
      await Future.delayed(const Duration(minutes: 15));
      checkDailyReset();
      return true; // 持续循环直到进程退出
    });
    // 回到前台时补一次（覆盖后台被系统节流、多年未触发的边界）
    WidgetsBinding.instance.addObserver(_LifecycleObserver(this));
  }

  /// 把当前任务列表与开关设置写入本地。
  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kTasks, jsonEncode(_tasks.map((t) => t.toJson()).toList()));
    await prefs.setString(
        _kTrash, jsonEncode(_trash.map((t) => t.toJson()).toList()));
    await prefs.setInt(_kTheme, _themeMode.index);
    await prefs.setBool(_kFollowSystem, _followSystem);
    await prefs.setBool(_kNotify, _notificationsEnabled);
    await prefs.setBool(_kSound, _soundEnabled);
    await prefs.setBool(_kGuard, _backgroundGuard);
  }

  /// 载入后重算自增 id 起点，避免新任务 id 与已有（含回收站）冲突。
  void _recomputeIdSeq() {
    int max = 7;
    for (final t in [..._tasks, ..._trash]) {
      final n = int.tryParse(t.id);
      if (n != null && n > max) max = n;
    }
    _idSeq = max + 1;
  }

  // ===== 首页筛选状态（已移除搜索 / 筛选功能）=====

 void toggleTheme() {
    // 手动切换即退出跟随系统
    setThemeMode(_themeMode != ThemeMode.dark);
  }

  // ===== Mock 数据（7 条，分类进度：工作 75% / 生活 100% / 学习 50%）=====
  final List<Task> _tasks = [
    Task(
      id: '1',
      title: '整理周会纪要',
      priority: Priority.high,
      category: Category.work,
      dueDate: DateTime.now().add(const Duration(hours: 6)),
    ),
    Task(
      id: '2',
      title: '回复客户邮件',
      priority: Priority.medium,
      category: Category.work,
      dueDate: DateTime.now().add(const Duration(days: 1)),
    ),
    Task(
      id: '3',
      title: '买周末食材',
      priority: Priority.low,
      category: Category.life,
      dueDate: DateTime.now().add(const Duration(days: 2)),
    ),
    Task(
      id: '4',
      title: '阅读《设计心理学》',
      priority: Priority.medium,
      category: Category.study,
      dueDate: DateTime.now().add(const Duration(days: 3)),
    ),
    Task(
      id: '5',
      title: '提交季度报表',
      priority: Priority.high,
      category: Category.work,
      dueDate: DateTime.now().add(const Duration(days: -1)),
      status: TaskStatus.done,
      completedAt: DateTime.now().add(const Duration(days: -2)),
    ),
    Task(
      id: '6',
      title: '给绿植浇水',
      priority: Priority.low,
      category: Category.life,
      status: TaskStatus.done,
      completedAt: DateTime.now().add(const Duration(days: -4)),
    ),
    Task(
      id: '7',
      title: '完成算法作业',
      priority: Priority.high,
      category: Category.study,
      status: TaskStatus.done,
      completedAt: DateTime.now().add(const Duration(days: -6)),
    ),
  ];

  List<Task> get tasks => List.unmodifiable(_tasks);

  /// 回收站（已删除但可恢复的任务，按删除时间倒序）
  final List<Task> _trash = [];
  List<Task> get trash => List.unmodifiable(_trash);
  int get trashCount => _trash.length;

  /// 今日待办（未完成）
  List<Task> get todayTasks => _tasks.where((t) => !t.done).toList();

  /// 已完成
  List<Task> get doneTasks => _tasks.where((t) => t.done).toList();

  // ===== 聚合统计 =====
  int get total => _tasks.length;
  int get completed => _tasks.where((t) => t.done).length;
  int get overdue =>
      _tasks.where((t) => !t.done && t.dueDate != null && t.dueDate!.isBefore(DateTime.now())).length;
  double get completionRate => total == 0 ? 0 : completed / total;

  /// 各分类完成比例
  Map<Category, double> categoryProgress() {
    final Map<Category, int> total = {};
    final Map<Category, int> done = {};
    for (final c in Category.values) {
      total[c] = 0;
      done[c] = 0;
    }
    for (final t in _tasks) {
      total[t.category] = total[t.category]! + 1;
      if (t.done) done[t.category] = done[t.category]! + 1;
    }
    return {
      for (final c in Category.values)
        c: total[c]! == 0 ? 0 : done[c]! / total[c]!,
    };
  }

  /// 近 7 日（含今天）的完整日期列表，旧→新。
  List<DateTime> get weekTrendDates {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return List.generate(7, (i) => today.subtract(Duration(days: 6 - i)));
  }

  /// 近 7 日每日完成数（旧→新），按 completedAt 统计。
  List<int> get weekTrend {
    final days = weekTrendDates;
    final counts = List.filled(7, 0);
    for (final t in _tasks) {
      if (!t.done || t.completedAt == null) continue;
      final d = DateTime(t.completedAt!.year, t.completedAt!.month, t.completedAt!.day);
      final idx = days.indexWhere((day) => day.isAtSameMomentAs(d));
      if (idx != -1) counts[idx]++;
    }
    return counts;
  }

  /// 上一周（往前 8-14 天）每日完成数（旧→新），用于环比。
  List<int> get lastWeekTrend {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = List.generate(7, (i) => today.subtract(Duration(days: 13 - i)));
    final counts = List.filled(7, 0);
    for (final t in _tasks) {
      if (!t.done || t.completedAt == null) continue;
      final d = DateTime(t.completedAt!.year, t.completedAt!.month, t.completedAt!.day);
      final idx = days.indexWhere((day) => day.isAtSameMomentAs(d));
      if (idx != -1) counts[idx]++;
    }
    return counts;
  }

  /// 有完成记录（completedAt 当天 ≥1 个已完成任务）的所有日期（date-only）。
  Set<DateTime> get completionDays {
    final s = <DateTime>{};
    for (final t in _tasks) {
      if (t.done && t.completedAt != null) {
        s.add(DateTime(t.completedAt!.year, t.completedAt!.month, t.completedAt!.day));
      }
    }
    return s;
  }

  static DateTime _dateOnly(DateTime d) =>
      DateTime(d.year, d.month, d.day);

  /// 当前连续打卡天数：从最近一个完成日往回数连续天数；若最近完成日距今 >1 天则视为中断，记为 0。
  int get currentStreak {
    final days = completionDays;
    if (days.isEmpty) return 0;
    final today = _dateOnly(DateTime.now());
    DateTime last = days.first;
    for (final d in days) {
      if (d.isAfter(last)) last = d;
    }
    final gap = today.difference(last).inDays;
    if (gap > 1) return 0; // 中间空了一整天 → 中断
    int streak = 0;
    var cursor = last;
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// 历史最长连续打卡天数。
  int get longestStreak {
    final days = completionDays.toList()..sort();
    if (days.isEmpty) return 0;
    int best = 1;
    int run = 1;
    for (int i = 1; i < days.length; i++) {
      if (days[i].difference(days[i - 1]).inDays == 1) {
        run++;
        if (run > best) best = run;
      } else {
        run = 1;
      }
    }
    return best;
  }

  /// 指定月份内「每天完成数」映射（date-only → 完成数），用于日历热力图。
  Map<DateTime, int> completionsInMonth(DateTime monthAnchor) {
    final map = <DateTime, int>{};
    for (final t in _tasks) {
      if (!t.done || t.completedAt == null) continue;
      final d = _dateOnly(t.completedAt!);
      if (d.year == monthAnchor.year && d.month == monthAnchor.month) {
        map[d] = (map[d] ?? 0) + 1;
      }
    }
    return map;
  }

  /// 某月累计完成数（日历页顶部概览用）。
  int completionsInMonthCount(DateTime monthAnchor) =>
      completionsInMonth(monthAnchor).values.fold(0, (a, b) => a + b);

  /// 某天完成的所有任务（按完成时间倒序），点击日历格查看当天明细用。
  List<Task> tasksCompletedOn(DateTime day) {
    final d = _dateOnly(day);
    final list = _tasks
        .where((t) =>
            t.done &&
            t.completedAt != null &&
            _dateOnly(t.completedAt!) == d)
        .toList();
    list.sort((a, b) => b.completedAt!.compareTo(a.completedAt!));
    return list;
  }

  // ===== 首页筛选（看板统计卡点击跳转）=====
  TaskFilter _taskFilter = TaskFilter.all;
  TaskFilter get taskFilter => _taskFilter;
  void setTaskFilter(TaskFilter f) {
    if (_taskFilter == f) return;
    _taskFilter = f;
    notifyListeners();
  }

  /// 看板/首页注册的「跳回首页」回调：统计卡点击后由 scaffold 切换 Tab。
  void Function()? _onRequestHome;
  set onRequestHome(void Function()? cb) => _onRequestHome = cb;
  void requestHomeWithFilter(TaskFilter f) {
    _taskFilter = f;
    _onRequestHome?.call();
    notifyListeners();
  }

  /// 看板两列分组：待办 / 已完成（保留列表原顺序）。
  Map<TaskStatus, List<Task>> get kanbanGroups {
    final map = {for (final s in TaskStatus.values) s: <Task>[]};
    for (final t in _tasks) {
      map[t.status]!.add(t);
    }
    return map;
  }

  /// 未完成任务的优先级分布（高/中/低），用于看板「优先级」进度条。
  Map<Priority, int> get priorityCounts {
    final map = {for (final p in Priority.values) p: 0};
    for (final t in _tasks) {
      if (!t.done) map[t.priority] = map[t.priority]! + 1;
    }
    return map;
  }

  /// 首页分区计数：逾期 / 今天 / 未来 / 每天 / 已完成。
  /// 口径与首页完全一致（按「天」比较截止日期，每日提醒任务单独成段、不参与日期切分），
  /// 供分享卡片直接复用，避免再依赖首页私有的 _dueDayDiff。
  Map<String, int> get sectionCounts {
    int? dayDiff(DateTime? due) {
      if (due == null) return null;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      return DateTime(due.year, due.month, due.day).difference(today).inDays;
    }

    final active = _tasks.where((t) => !t.done && !t.isRepeating);
    final overdue = active.where((t) => (dayDiff(t.dueDate) ?? 0) < 0).length;
    final today = active.where((t) => dayDiff(t.dueDate) == 0).length;
    final future =
        active.where((t) => t.dueDate == null || dayDiff(t.dueDate)! > 0).length;
    final repeat = _tasks.where((t) => t.isRepeating && !t.done).length;
    final done = _tasks.where((t) => t.done).length;
    return {
      'overdue': overdue,
      'today': today,
      'future': future,
      'repeat': repeat,
      'done': done,
    };
  }

  /// 首页分区任务列表：逾期 / 今天 / 未来 / 每天 / 已完成（各自已排序）。
  /// 与首页 [_section] 完全一致的分组与排序口径，供分享卡片列出「详细事件 / 任务」，
  /// 而非只有计数。
  Map<String, List<Task>> get homeTasks {
    int? dayDiff(DateTime? due) {
      if (due == null) return null;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      return DateTime(due.year, due.month, due.day).difference(today).inDays;
    }

    // 未完成 + 非重复，按截止日期切分为 逾期 / 今天 / 未来。
    final active = _tasks.where((t) => !t.done && !t.isRepeating).toList();
    final overdue = active
        .where((t) => (dayDiff(t.dueDate) ?? 0) < 0)
        .toList()
      ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!)); // 拖最久的排前
    final today = active
        .where((t) => dayDiff(t.dueDate) == 0)
        .toList()
      ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final future = active.where((t) {
      final d = dayDiff(t.dueDate);
      return d == null || d > 0;
    }).toList()
      ..sort((a, b) {
        if (a.dueDate == null && b.dueDate == null) return 0;
        if (a.dueDate == null) return 1;
        if (b.dueDate == null) return -1;
        return a.dueDate!.compareTo(b.dueDate!);
      });
    // 重复任务单独成段，按提醒时刻升序。
    final repeat = _tasks.where((t) => t.isRepeating && !t.done).toList()
      ..sort((a, b) => (a.repeatMinute ?? 24 * 60)
          .compareTo(b.repeatMinute ?? 24 * 60));
    // 已完成统一进「已完成」。
    final done = _tasks.where((t) => t.done).toList();
    return {
      'overdue': overdue,
      'today': today,
      'future': future,
      'repeat': repeat,
      'done': done,
    };
  }

  /// 把任务在 待办/已完成 之间移动（看板拖拽 / 点击切换）。
  void setStatus(String id, TaskStatus s) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final cur = _tasks[i];
    if (cur.status == s) return;
    _tasks[i] = cur.copyWith(
      status: s,
      completedAt: s == TaskStatus.done ? DateTime.now() : null,
    );
    if (_tasks[i].isRepeating) {
      _rescheduleRepeatOnCompletion(_tasks[i]);
    } else {
      _reconcileDeadlineOnCompletion(_tasks[i]);
    }
    notifyListeners();
    _persist();
  }

  void toggleDone(String id) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final willDone = !_tasks[i].done;
    _tasks[i] = _tasks[i].copyWith(
      status: willDone ? TaskStatus.done : TaskStatus.todo,
      completedAt: willDone ? DateTime.now() : null,
    );
    // 重复任务完成/取消完成：重排重复提醒。当天已完成则跳过今日（不弹今天提醒），
    // 否则照常挂今日；同一通知 id 覆盖掉旧闹钟。
    if (_tasks[i].isRepeating) {
      _rescheduleRepeatOnCompletion(_tasks[i]);
    } else {
      _reconcileDeadlineOnCompletion(_tasks[i]);
    }
    notifyListeners();
    _persist();
  }

  int _idSeq = 8;
  /// 新建任务：插入到列表头部，自动分配唯一 id；有截止时间或每日提醒则调度。
  void addTask(Task task) {
    final newTask = task.copyWith(id: (_idSeq++).toString());
    _tasks.insert(0, newTask);
    _scheduleRemindersFor(newTask);
    notifyListeners();
    _persist();
  }

  /// 更新已有任务：保留 id / done / completedAt / subtask 计数，
  /// 仅修改标题·优先级·分类·截止时间·每日提醒；相关字段变化时同步重排本地提醒。
  void updateTask(Task updated) {
    final i = _tasks.indexWhere((t) => t.id == updated.id);
    if (i == -1) return;
    final old = _tasks[i];
    _tasks[i] = old.copyWith(
      title: updated.title,
      priority: updated.priority,
      category: updated.category,
      dueDate: updated.dueDate,
      repeat: updated.repeat,
      repeatWeekdays: updated.repeatWeekdays,
      repeatInterval: updated.repeatInterval,
      repeatMinute: updated.repeatMinute,
      repeatAnchor: updated.repeatAnchor,
      note: updated.note,
    );
    // 截止时间或重复设置发生变化时，先取消旧调度再统一重排，避免状态不一致。
    final remindersChanged = old.dueDate != updated.dueDate ||
        old.repeat != updated.repeat ||
        old.repeatMinute != updated.repeatMinute ||
        old.repeatInterval != updated.repeatInterval ||
        !_listEq(old.repeatWeekdays, updated.repeatWeekdays) ||
        old.repeatAnchor != updated.repeatAnchor;
    if (remindersChanged) {
      _cancelRemindersFor(updated.id);
      _scheduleRemindersFor(_tasks[i]);
    }
    notifyListeners();
    _persist();
  }

  // ===== 删除（移入回收站，带撤销）=====
  // 用批量撤销缓冲，使「单个删除」与「多选批量删除」共用同一套撤销逻辑。
  List<Task> _lastBatch = [];
  List<int> _lastBatchIndices = [];

  /// 批量删除指定 id 的任务：从任务列表移除，移入回收站（记录删除时间），
  /// 并取消其全部本地提醒。返回被删除的任务列表（按原始索引升序）。
  /// 注意：每次调用都会覆盖上一次删除的撤销缓冲（仅可撤销最近一次删除操作）。
  List<Task> _removeMany(List<String> ids) {
    // 收集待删任务的原始索引与对象（升序）
    final toRemove = <int, Task>{};
    for (final id in ids) {
      final i = _tasks.indexWhere((t) => t.id == id);
      if (i != -1) toRemove[i] = _tasks[i];
    }
    final sortedIdx = toRemove.keys.toList()..sort(); // 升序
    // 按索引降序删除，保证删除时索引依然有效
    for (final i in sortedIdx.reversed) {
      final r = _tasks.removeAt(i);
      _cancelRemindersFor(r.id);
      _trash.insert(0, r.copyWith(deletedAt: DateTime.now()));
    }
    _lastBatch = sortedIdx.map((i) => toRemove[i]!).toList(); // 升序
    _lastBatchIndices = sortedIdx; // 升序，与 _lastBatch 一一对应
    notifyListeners();
    _persist();
    return _lastBatch;
  }

  /// 删除指定 id 的任务：从任务列表移除，并移入回收站（记录删除时间）。
  /// 返回被删除的任务（用于撤销 / 提示）。
  Task? deleteTask(String id) {
    final removed = _removeMany([id]);
    return removed.isEmpty ? null : removed.first;
  }

  /// 多选批量删除：一次删除多个任务（移入回收站，可整体撤销）。
  void deleteTasks(List<String> ids) => _removeMany(ids);

  /// 撤销上一次删除（支持批量）：从回收站取回并按原始索引归位，恢复其本地提醒。
  void undoDelete() {
    if (_lastBatch.isEmpty) return;
    for (var k = 0; k < _lastBatch.length; k++) {
      final r = _lastBatch[k];
      final idx = _lastBatchIndices[k].clamp(0, _tasks.length);
      _tasks.insert(idx, r);
      _trash.removeWhere((t) => t.id == r.id);
      _scheduleRemindersFor(r);
    }
    _lastBatch = [];
    _lastBatchIndices = [];
    notifyListeners();
    _persist();
  }

  /// 从回收站恢复任务到任务列表（清除 deletedAt，放回顶部），并恢复其本地提醒。
  void restoreFromTrash(String id) {
    final i = _trash.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final t = _trash.removeAt(i);
    final restored = t.copyWith(deletedAt: null);
    _tasks.insert(0, restored);
    _scheduleRemindersFor(restored);
    notifyListeners();
    _persist();
  }

  /// 在回收站中彻底删除某任务（不可恢复），并取消其本地提醒。
  void permanentDelete(String id) {
    _trash.removeWhere((t) => t.id == id);
    _cancelRemindersFor(id);
    notifyListeners();
    _persist();
  }

  /// 清空回收站（全部彻底删除），并取消其中所有任务的本地提醒。
  void clearTrash() {
    if (_trash.isEmpty) return;
    for (final t in _trash) {
      _cancelRemindersFor(t.id);
    }
    _trash.clear();
    notifyListeners();
    _persist();
  }

  /// 完整备份数据（任务 + 偏好 + 可选回收站），用于「备份与恢复」导出。
  /// [includeTrash] 为 true 时一并将回收站任务写入备份。
  Map<String, dynamic> backupData({bool includeTrash = true}) => {
        'version': 1,
        'app': '有条',
        'tasks': _tasks.map((t) => t.toJson()).toList(),
        'trash': includeTrash
            ? _trash.map((t) => t.toJson()).toList()
            : <Map<String, dynamic>>[],
        'theme_mode': _themeMode.index,
        'notifications_enabled': _notificationsEnabled,
        'sound_enabled': _soundEnabled,
      };

  /// 备份 JSON 字符串。
  String backupJson([bool includeTrash = true]) =>
      jsonEncode(backupData(includeTrash: includeTrash));

  /// 从备份 JSON 字符串恢复：覆盖全部任务与偏好，并重排通知。
  /// [includeTrash] 为 true 且备份含回收站时，用备份的回收站覆盖当前回收站。
  Future<void> restoreFromJson(String raw, {bool includeTrash = true}) async {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final list = (data['tasks'] as List?) ?? [];
    _tasks
      ..clear()
      ..addAll(list.map((e) => Task.fromJson(e as Map<String, dynamic>)));
    if (includeTrash) {
      final trashList = (data['trash'] as List?) ?? [];
      _trash
        ..clear()
        ..addAll(trashList.map((e) => Task.fromJson(e as Map<String, dynamic>)));
    }
    final themeIdx = data['theme_mode'];
    if (themeIdx is int && themeIdx >= 0 && themeIdx < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[themeIdx];
    }
    if (data['notifications_enabled'] is bool) {
      _notificationsEnabled = data['notifications_enabled'];
    }
    if (data['sound_enabled'] is bool) _soundEnabled = data['sound_enabled'];
    NotificationService.instance.enabled = _notificationsEnabled;
    NotificationService.instance.cancelAll();
    if (_notificationsEnabled) _rescheduleAllActive();
    _recomputeIdSeq();
    notifyListeners();
    await _persist();
  }

  /// 导出可读 CSV（标题,优先级,分类,截止时间,状态,完成时间,是否已删除）。
  /// [includeTrash] 为 true 时，回收站任务也一并列出（最后一列标记为「是」）。
  String exportCsv({bool includeTrash = false}) {
    final buf = StringBuffer();
    buf.writeln('标题,优先级,分类,截止时间,状态,完成时间,是否已删除');
    void writeRow(Task t, bool deleted) {
      final due = t.dueDate == null ? '' : _fmt(t.dueDate!);
      final completed = t.completedAt == null ? '' : _fmt(t.completedAt!);
      buf.writeln('"${_esc(t.title)}","${_prioLabel(t.priority)}",'
          '"${_catLabel(t.category)}","$due","${t.done ? '已完成' : '未完成'}","$completed",'
          '"${deleted ? '是' : '否'}"');
    }

    for (final t in _tasks) {
      writeRow(t, false);
    }
    if (includeTrash) {
      for (final t in _trash) {
        writeRow(t, true);
      }
    }
    return buf.toString();
  }

  /// 导出可读 Markdown 清单（未完成 / 已完成两组；可选回收站）。
  /// [includeTrash] 为 true 且回收站非空时，追加「回收站」分组。
  String exportMarkdown({bool includeTrash = false}) {
    final buf = StringBuffer();
    buf.writeln('# 有条 任务导出');
    buf.writeln('');
    buf.writeln('> 导出时间：${_fmt(DateTime.now())}');
    buf.writeln('');
    buf.writeln('## 未完成（${_tasks.where((e) => !e.done).length}）');
    for (final t in _tasks.where((e) => !e.done)) {
      final due = t.dueDate == null ? '' : ' ｜ 截止 ${_fmt(t.dueDate!)}';
      final rep = t.repeatFull.isNotEmpty ? ' ｜ ${t.repeatFull}' : '';
      buf.writeln('- [ ] ${_esc(t.title)} ｜ ${_prioLabel(t.priority)} / ${_catLabel(t.category)}$due$rep');
    }
    buf.writeln('');
    buf.writeln('## 已完成（${_tasks.where((e) => e.done).length}）');
    for (final t in _tasks.where((e) => e.done)) {
      final c = t.completedAt == null ? '' : ' ｜ 完成于 ${_fmt(t.completedAt!)}';
      final rep = t.repeatFull.isNotEmpty ? ' ｜ ${t.repeatFull}' : '';
      buf.writeln('- [x] ${_esc(t.title)} ｜ ${_prioLabel(t.priority)} / ${_catLabel(t.category)}$c$rep');
    }
    if (includeTrash && _trash.isNotEmpty) {
      buf.writeln('');
      buf.writeln('## 回收站（${_trash.length}）');
      for (final t in _trash) {
        final d = t.deletedAt == null ? '' : ' ｜ 删除于 ${_fmt(t.deletedAt!)}';
        buf.writeln('- [x] ${_esc(t.title)} ｜ ${_prioLabel(t.priority)} / ${_catLabel(t.category)}$d');
      }
    }
    return buf.toString();
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  static String _fmtMinute(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  static String _prioLabel(Priority p) =>
      p == Priority.high ? '高' : p == Priority.medium ? '中' : '低';
  static String _catLabel(Category c) =>
      c == Category.work ? '工作' : c == Category.life ? '生活' : '学习';
  static String _esc(String s) => s.replaceAll('"', '""');

  /// 新建任务时按 dueDate 调度本地通知
  Future<void> scheduleFor(Task task) async {
    await NotificationService.instance.scheduleForTask(task);
  }

  /// 为单个任务调度其全部本地提醒（截止提醒 + 重复提醒）。
  /// 重复提醒只在「有截止日期且截止日期未过」时才调度，逾期后自动停止。
  void _scheduleRemindersFor(Task t) {
    if (t.dueDate != null) {
      NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
    }
    if (t.isRepeating && t.repeatMinute != null &&
        t.dueDate != null && !_dateHasPassed(t.dueDate!)) {
      NotificationService.instance.scheduleRepeatReminder(t, playSound: _soundEnabled);
    }
  }

  /// 取消单个任务的全部本地提醒（截止提醒 + 重复提醒）。
  void _cancelRemindersFor(String id) {
    NotificationService.instance.cancel(id);
    NotificationService.instance.cancelRepeatReminder(id);
  }

  /// 重复任务完成态变更后（toggleDone / setStatus / 取消完成）重排其重复提醒。
  /// 仅当任务仍「未过截止日」才挂；具体「是否跳过今日」由通知服务依据
  /// [Task.done] + [Task.completedAt] 是否为今天自行判断（当天已完成→挂明天）。
  void _rescheduleRepeatOnCompletion(Task t) {
    if (t.isRepeating &&
        t.repeatMinute != null &&
        t.dueDate != null &&
        !_dateHasPassed(t.dueDate!)) {
      NotificationService.instance.scheduleRepeatReminder(t, playSound: _soundEnabled);
    }
  }

  /// 非重复任务完成态变更后：取消 / 恢复其一次性「截止时间提醒」。
  /// - 完成（含提前完成）：取消已调度的截止提醒，避免到期后仍弹出。
  /// - 取消完成：若截止时间未过，恢复调度。
  /// 重复任务不在此处理——其整体截止提醒仍有效（只是当天完成由
  /// [_rescheduleRepeatOnCompletion] 跳过今日重复提醒），故直接跳过。
  void _reconcileDeadlineOnCompletion(Task t) {
    if (t.isRepeating) return;
    if (t.done) {
      NotificationService.instance.cancel(t.id);
    } else if (t.dueDate != null && t.dueDate!.isAfter(DateTime.now())) {
      NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
    }
  }

  /// 统一重排所有活动任务的提醒：未完成且未过期的截止提醒 + 未过期的重复提醒。
  /// 用于开关/声音变化、启动时刷新。
  void _rescheduleAllActive() {
    final now = DateTime.now();
    for (final t in _tasks) {
      if (!t.done && t.dueDate != null && t.dueDate!.isAfter(now)) {
        NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
      }
      if (t.isRepeating && t.repeatMinute != null &&
          t.dueDate != null && !_dateHasPassed(t.dueDate!)) {
        NotificationService.instance.scheduleRepeatReminder(t, playSound: _soundEnabled);
      }
    }
  }

  /// 两个 int 列表内容是否相等（[List] 默认 == 比较引用，重复星期需按内容比较）。
  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 判断日期是否已完全过去（以「今天 00:00」为界，与 dueDate 的 23:59 语义一致）。
  static bool _dateHasPassed(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(d.year, d.month, d.day).isBefore(today);
  }
}

/// 监听 App 生命周期：回到前台（resumed）时补一次每日重置检查，
/// 覆盖「App 后台挂了一夜、系统节流了周期守护」的边界。
class _LifecycleObserver extends WidgetsBindingObserver {
  final TaskProvider _provider;
  _LifecycleObserver(this._provider);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _provider.checkDailyReset();
    }
  }
}
