import 'package:flutter/material.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';

/// 习惯 / 打卡的状态层：管理习惯列表、每日打卡记录、连续天数统计与持久化。
///
/// 与 TaskProvider / FocusProvider 解耦，仅依赖 [LocalDatabase] 的 habits /
/// check_ins 两张表（整段 JSON 存储）。所有统计在内存中基于打卡日期集合计算，
/// 逻辑单纯、易测。
class HabitProvider extends ChangeNotifier {
  final List<Habit> _habits = [];
  final List<CheckIn> _checkIns = [];

  /// 全部习惯（含归档）。UI 可按需过滤。
  List<Habit> get habits => List.unmodifiable(_habits);

  /// 未归档的习惯（首页/今日列表展示用）。
  List<Habit> get activeHabits =>
      _habits.where((h) => !h.archived).toList();

  Future<void> load() async {
    try {
      final db = LocalDatabase.instance;
      // 内存后端（测试）无需打开真实 SQLite；仅在生产（非内存）模式确保建表。
      if (!LocalDatabase.testUseMemory) {
        await db.db;
      }
      _habits
        ..clear()
        ..addAll(await db.loadHabits());
      _checkIns
        ..clear()
        ..addAll(await db.loadCheckIns());
    } catch (e, stack) {
      debugPrint('HabitProvider 加载失败（习惯/打卡暂不可用）：$e\n$stack');
      _habits.clear();
      _checkIns.clear();
    }
    notifyListeners();
  }

  /// 新建习惯（自动生成 id 与时间戳）。
  Future<void> addHabit({
    required String title,
    required String emoji,
    required int colorValue,
    required List<int> weekdays,
    int? reminderMinute,
  }) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final h = Habit(
      id: id,
      title: title,
      emoji: emoji,
      colorValue: colorValue,
      weekdays: weekdays,
      reminderMinute: reminderMinute,
      createdAt: DateTime.now(),
    );
    _habits.add(h);
    await _persistHabits();
    // 若设置了提醒，立即调度每日打卡提醒（失败静默，不影响建习惯）。
    if (reminderMinute != null) {
      await NotificationService.instance.scheduleHabitReminder(h);
    }
    notifyListeners();
  }

  /// 更新某习惯的每日提醒时间（null = 取消提醒）。先取消旧提醒，再按新值调度/保持静默。
  Future<void> setReminder(Habit habit, int? minute) async {
    final updated =
        habit.copyWith(reminderMinute: minute, clearReminder: minute == null);
    final idx = _habits.indexWhere((h) => h.id == habit.id);
    if (idx == -1) return;
    _habits[idx] = updated;
    await _persistHabits();
    // 取消旧的（无论改/删都先清干净），再按新值重新挂。
    await NotificationService.instance.cancelHabitReminder(habit.id);
    if (minute != null) {
      await NotificationService.instance.scheduleHabitReminder(updated);
    }
    notifyListeners();
  }

  /// 删除习惯及其全部打卡记录（同时取消其提醒通知）。
  Future<void> deleteHabit(String id) async {
    _habits.removeWhere((h) => h.id == id);
    _checkIns.removeWhere((c) => c.habitId == id);
    await NotificationService.instance.cancelHabitReminder(id);
    await _persistHabits();
    await _persistCheckIns();
    notifyListeners();
  }

  /// App 启动时调度全部习惯的提醒（仅对已设提醒时间的活动习惯）。
  /// 由 main 在 habit.load() 后调用一次。失败单个静默不影响其它。
  Future<void> scheduleAllReminders() async {
    for (final h in _habits) {
      if (h.archived || h.reminderMinute == null) continue;
      await NotificationService.instance
          .scheduleHabitReminder(h, checkedToday: isCheckedToday(h));
    }
  }

  /// 今天是否已打卡（按 date-only 判定）。
  bool isCheckedToday(Habit habit) {
    final k = CheckIn.dateKey(DateTime.now());
    return _checkIns.any(
        (c) => c.habitId == habit.id && CheckIn.dateKey(c.date) == k);
  }

  /// 切换今天的打卡状态：已打卡则取消，否则打卡。
  Future<void> toggleCheckInToday(Habit habit) async {
    final k = CheckIn.dateKey(DateTime.now());
    if (isCheckedToday(habit)) {
      _checkIns.removeWhere(
          (c) => c.habitId == habit.id && CheckIn.dateKey(c.date) == k);
    } else {
      _checkIns.add(CheckIn.forDay(habit.id, DateTime.now()));
    }
    await _persistCheckIns();
    notifyListeners();
  }

  /// 在指定日期打卡（用于补打卡 / 历史回溯），已存在则忽略。
  Future<void> checkInOnDay(Habit habit, DateTime day) async {
    final key = CheckIn.dateKey(day);
    if (_checkIns.any(
        (c) => c.habitId == habit.id && CheckIn.dateKey(c.date) == key)) {
      return;
    }
    _checkIns.add(CheckIn.forDay(habit.id, day));
    await _persistCheckIns();
    notifyListeners();
  }

  /// 某习惯累计打卡次数。
  int checkInCount(Habit habit) =>
      _checkIns.where((c) => c.habitId == habit.id).length;

  /// 某习惯当前连续打卡天数（今天未打卡则从昨天起算，避免「还没打卡就显断」）。
  int currentStreak(Habit habit) =>
      _streakFor(_datesOf(habit), allowTodayGap: true);

  /// 某习惯历史最长连续打卡天数。
  int longestStreak(Habit habit) => _streakFor(_datesOf(habit), longest: true);

  // ===== 跨习惯整体统计（成就解锁用）=====

  int get totalCheckIns => _checkIns.length;
  int get habitCount => _habits.length;
  int get overallCurrentStreak =>
      _streakFor(_allDates, allowTodayGap: true);
  int get overallLongestStreak => _streakFor(_allDates, longest: true);

  Set<DateTime> _datesOf(Habit habit) => _checkIns
      .where((c) => c.habitId == habit.id)
      .map((c) => DateTime(c.date.year, c.date.month, c.date.day))
      .toSet();

  Set<DateTime> get _allDates => _checkIns
      .map((c) => DateTime(c.date.year, c.date.month, c.date.day))
      .toSet();

  /// 基于一组 date-only 计算连续天数。
  /// [longest]=true 返回最长连续；否则返回截至今天（允许今天空缺）的当前连续。
  static int _streakFor(
    Set<DateTime> dates, {
    bool longest = false,
    bool allowTodayGap = false,
  }) {
    if (dates.isEmpty) return 0;
    final sorted = dates.toList()..sort();
    if (longest) {
      int best = 1;
      int run = 1;
      for (int i = 1; i < sorted.length; i++) {
        if (sorted[i].difference(sorted[i - 1]).inDays == 1) {
          run++;
          if (run > best) best = run;
        } else {
          run = 1;
        }
      }
      return best;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime cursor = dates.contains(today)
        ? today
        : (allowTodayGap ? today.subtract(const Duration(days: 1)) : today);
    if (!dates.contains(cursor)) return 0;
    int streak = 0;
    while (dates.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  Future<void> _persistHabits() async {
    try {
      await LocalDatabase.instance.replaceHabits(_habits);
    } catch (e) {
      debugPrint('HabitProvider 持久化 habits 失败：$e');
    }
  }
  Future<void> _persistCheckIns() async {
    try {
      await LocalDatabase.instance.replaceCheckIns(_checkIns);
    } catch (e) {
      debugPrint('HabitProvider 持久化 checkIns 失败：$e');
    }
  }
}
