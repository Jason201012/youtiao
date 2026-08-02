import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/background_service.dart';

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
      // 重新调度所有「未完成且未过期」的提醒，应用新状态
      final now = DateTime.now();
      for (final t in _tasks) {
        if (!t.done && t.dueDate != null && t.dueDate!.isAfter(now)) {
          NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
        }
      }
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
    // 重新调度所有「未完成且未过期」的提醒，应用新的声音设置
    if (_notificationsEnabled) {
      final now = DateTime.now();
      for (final t in _tasks) {
        if (!t.done && t.dueDate != null && t.dueDate!.isAfter(now)) {
          NotificationService.instance.scheduleForTask(t, playSound: v);
        }
      }
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
    // 启动时为已有「未完成且未过期」的任务重新调度提醒（老任务/初始 mock 也能响）
    if (_notificationsEnabled) {
      final now = DateTime.now();
      for (final t in _tasks) {
        if (!t.done && t.dueDate != null && t.dueDate!.isAfter(now)) {
          NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
        }
      }
    }
    _recomputeIdSeq();
    notifyListeners();
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
      done: true,
      completedAt: DateTime.now().add(const Duration(days: -2)),
    ),
    Task(
      id: '6',
      title: '给绿植浇水',
      priority: Priority.low,
      category: Category.life,
      done: true,
      completedAt: DateTime.now().add(const Duration(days: -4)),
    ),
    Task(
      id: '7',
      title: '完成算法作业',
      priority: Priority.high,
      category: Category.study,
      done: true,
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
  int get inProgress => _tasks.where((t) => !t.done).length;
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

  void toggleDone(String id) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final willDone = !_tasks[i].done;
    _tasks[i] = _tasks[i].copyWith(
      done: willDone,
      completedAt: willDone ? DateTime.now() : null,
    );
    notifyListeners();
    _persist();
  }

  int _idSeq = 8;
  /// 新建任务：插入到列表头部，自动分配唯一 id；有截止时间则调度提醒。
  void addTask(Task task) {
    final newTask = task.copyWith(id: (_idSeq++).toString());
    _tasks.insert(0, newTask);
    if (newTask.dueDate != null) {
      NotificationService.instance.scheduleForTask(newTask, playSound: _soundEnabled);
    }
    notifyListeners();
    _persist();
  }

  /// 更新已有任务：保留 id / done / completedAt / subtask 计数，
  /// 仅修改标题·优先级·分类·截止时间；截止时间变化时同步重排本地提醒。
  void updateTask(Task updated) {
    final i = _tasks.indexWhere((t) => t.id == updated.id);
    if (i == -1) return;
    final old = _tasks[i];
    _tasks[i] = old.copyWith(
      title: updated.title,
      priority: updated.priority,
      category: updated.category,
      dueDate: updated.dueDate,
    );
    if (old.dueDate != updated.dueDate) {
      if (updated.dueDate != null) {
        NotificationService.instance.scheduleForTask(_tasks[i], playSound: _soundEnabled);
      } else {
        NotificationService.instance.cancel(updated.id);
      }
    }
    notifyListeners();
    _persist();
  }

  // ===== 删除（移入回收站，带撤销）=====
  Task? _lastRemoved;
  int _lastRemovedIndex = -1;

  /// 删除指定 id 的任务：从任务列表移除，并移入回收站（记录删除时间）。
  /// 返回被删除的任务（用于撤销）。
  Task? deleteTask(String id) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i == -1) return null;
    _lastRemoved = _tasks[i];
    _lastRemovedIndex = i;
    final removed = _tasks.removeAt(i);
    // 移入回收站（置 deletedAt）
    _trash.insert(0, removed.copyWith(deletedAt: DateTime.now()));
    notifyListeners();
    _persist();
    return _lastRemoved;
  }

  /// 撤销上一次删除：从回收站取回并还原到原位置。
  void undoDelete() {
    if (_lastRemoved == null) return;
    final idx = _lastRemovedIndex.clamp(0, _tasks.length);
    _tasks.insert(idx, _lastRemoved!);
    _trash.removeWhere((t) => t.id == _lastRemoved!.id);
    _lastRemoved = null;
    _lastRemovedIndex = -1;
    notifyListeners();
    _persist();
  }

  /// 从回收站恢复任务到任务列表（清除 deletedAt，放回顶部）。
  void restoreFromTrash(String id) {
    final i = _trash.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final t = _trash.removeAt(i);
    _tasks.insert(0, t.copyWith(deletedAt: null));
    notifyListeners();
    _persist();
  }

  /// 在回收站中彻底删除某任务（不可恢复）。
  void permanentDelete(String id) {
    _trash.removeWhere((t) => t.id == id);
    notifyListeners();
    _persist();
  }

  /// 清空回收站（全部彻底删除）。
  void clearTrash() {
    if (_trash.isEmpty) return;
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
    if (_notificationsEnabled) {
      final now = DateTime.now();
      for (final t in _tasks) {
        if (!t.done && t.dueDate != null && t.dueDate!.isAfter(now)) {
          NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
        }
      }
    }
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
      buf.writeln('- [ ] ${_esc(t.title)} ｜ ${_prioLabel(t.priority)} / ${_catLabel(t.category)}$due');
    }
    buf.writeln('');
    buf.writeln('## 已完成（${_tasks.where((e) => e.done).length}）');
    for (final t in _tasks.where((e) => e.done)) {
      final c = t.completedAt == null ? '' : ' ｜ 完成于 ${_fmt(t.completedAt!)}';
      buf.writeln('- [x] ${_esc(t.title)} ｜ ${_prioLabel(t.priority)} / ${_catLabel(t.category)}$c');
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
  static String _prioLabel(Priority p) =>
      p == Priority.high ? '高' : p == Priority.medium ? '中' : '低';
  static String _catLabel(Category c) =>
      c == Category.work ? '工作' : c == Category.life ? '生活' : '学习';
  static String _esc(String s) => s.replaceAll('"', '""');

  /// 新建任务时按 dueDate 调度本地通知
  Future<void> scheduleFor(Task task) async {
    await NotificationService.instance.scheduleForTask(task);
  }
}
