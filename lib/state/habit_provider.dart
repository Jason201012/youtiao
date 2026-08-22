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

  /// 进程内自增序号，叠加到习惯 id 上，避免同一毫秒内连续建习惯时 id 撞车
  /// （撞 id 会导致 _memHabits 按 id 存 Map 时后者覆盖前者，静默丢习惯，
  /// 且两个习惯对象的打卡会串号）。与 [NotificationService._habitSlotOf] 用
  /// hashCode 折叠无关，改 id 格式不影响通知槽位映射。
  static int _habitSeq = 0;

  /// 全部习惯（含归档）。UI 可按需过滤。
  List<Habit> get habits => List.unmodifiable(_habits);

  /// 未归档的习惯（首页/今日列表展示用）。
  List<Habit> get activeHabits =>
      _habits.where((h) => !h.archived).toList();

  /// 按 id 查找习惯，找不到返回 null（通知稍后提醒等场景用）。
  Habit? byId(String id) {
    for (final h in _habits) {
      if (h.id == id) return h;
    }
    return null;
  }

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
    final id = '${DateTime.now().microsecondsSinceEpoch}.${_habitSeq++}';
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

  /// 返回某习惯在近 [days] 天内（含今天）已打卡的 date-only 集合，供热力图着色。
  Set<DateTime> checkedDays(Habit habit, int days) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: days - 1));
    final set = <DateTime>{};
    for (final c in _checkIns) {
      if (c.habitId != habit.id) continue;
      final d = DateTime(c.date.year, c.date.month, c.date.day);
      if (!d.isBefore(start)) set.add(d);
    }
    return set;
  }

  /// 返回某习惯在 [start, end]（date-only，含端点）内已打卡的日期集合。
  ///
  /// 与 [checkedDays] 的「近 N 天」口径互补：月报 / 年报需要任意历史区间，
  /// 这里只是换一种读法，不新增任何存储。
  Set<DateTime> checkedDaysBetween(Habit habit, DateTime start, DateTime end) {
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    final set = <DateTime>{};
    for (final c in _checkIns) {
      if (c.habitId != habit.id) continue;
      final d = DateTime(c.date.year, c.date.month, c.date.day);
      if (d.isBefore(s) || d.isAfter(e)) continue;
      set.add(d);
    }
    return set;
  }

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

  /// 全部打卡日期集合（date-only，去重），供热力图整体视图着色。
  Set<DateTime> get allCheckedDays => _allDates;

  /// 返回近 [days] 天内（含今天）按「日」聚合的打卡次数，供多习惯聚合热力图分级着色。
  Map<DateTime, int> checkInCountsByDay(int days) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: days - 1));
    final map = <DateTime, int>{};
    for (final c in _checkIns) {
      final d = DateTime(c.date.year, c.date.month, c.date.day);
      if (d.isBefore(start)) continue;
      map[d] = (map[d] ?? 0) + 1;
    }
    return map;
  }

  // ===== 备份 / 导出 / 恢复（并入「备份与恢复」「导出数据」）=====

  /// 完整备份数据（习惯 + 打卡记录），用于「备份与恢复」导出。
  /// 以独立键 ['habits'] / ['check_ins'] 写入，老备份缺这些键时恢复逻辑会跳过，
  /// 不会误清现有习惯数据。
  Map<String, dynamic> backupData() => {
        'habits': _habits.map((h) => h.toJson()).toList(),
        'check_ins': _checkIns.map((c) => c.toJson()).toList(),
      };

  /// 从备份 JSON 恢复：仅恢复备份中实际存在的部分（[habits] / [check_ins]）。
  /// 老备份无这两个键时不触碰现有习惯，避免「恢复任务备份反而清空习惯」。
  Future<void> restoreFromJson(Map<String, dynamic> data) async {
    if (data['habits'] is List) {
      final habitsList = data['habits'] as List;
      _habits
        ..clear()
        ..addAll(
            habitsList.map((e) => Habit.fromJson(e as Map<String, dynamic>)));
      // 取消旧提醒并按恢复的 habits 重新调度（仅习惯提醒，不动任务通知）。
      for (final h in _habits) {
        await NotificationService.instance.cancelHabitReminder(h.id);
        if (!h.archived && h.reminderMinute != null) {
          await NotificationService.instance.scheduleHabitReminder(
            h,
            checkedToday: isCheckedToday(h),
          );
        }
      }
    }
    if (data['check_ins'] is List) {
      final checkList = data['check_ins'] as List;
      _checkIns
        ..clear()
        ..addAll(
            checkList.map((e) => CheckIn.fromJson(e as Map<String, dynamic>)));
    }
    await _persistHabits();
    await _persistCheckIns();
    notifyListeners();
  }

  /// 导出 CSV：先列习惯表（含当前/最长连续、累计打卡），再列打卡记录表。
  String exportCsv() {
    final buf = StringBuffer();
    buf.writeln('习惯,表情,创建时间,当前连续(天),最长连续(天),累计打卡,提醒,是否归档');
    for (final h in _habits) {
      final reminder =
          h.reminderMinute == null ? '' : _fmtMinute(h.reminderMinute!);
      buf.writeln('"${_esc(h.title)}","${_esc(h.emoji)}","${_fmt(h.createdAt)}",'
          '${currentStreak(h)},${longestStreak(h)},${checkInCount(h)},'
          '"$reminder","${h.archived ? '是' : '否'}"');
    }
    buf.writeln();
    buf.writeln('习惯,打卡日期');
    final titleById = {for (final h in _habits) h.id: h.title};
    for (final c in _checkIns) {
      final name = titleById[c.habitId] ?? c.habitId;
      buf.writeln('"${_esc(name)}","${CheckIn.dateKey(c.date)}"');
    }
    return buf.toString();
  }

  /// 导出 Markdown：习惯清单（含连续/累计）+ 打卡记录列表。
  String exportMarkdown() {
    final buf = StringBuffer();
    buf.writeln('# 有条 习惯导出');
    buf.writeln('');
    buf.writeln('> 导出时间：${_fmt(DateTime.now())}');
    buf.writeln('');
    if (_habits.isEmpty) {
      buf.writeln('_暂无习惯_');
      return buf.toString();
    }
    buf.writeln('## 习惯（${_habits.length}）');
    for (final h in _habits) {
      final reminder =
          h.reminderMinute == null ? '无' : _fmtMinute(h.reminderMinute!);
      buf.writeln('- ${_esc(h.emoji)} ${_esc(h.title)} ｜ 当前连续 '
          '${currentStreak(h)} 天 · 最长 ${longestStreak(h)} 天 · 累计 '
          '${checkInCount(h)} 次 ｜ 提醒 $reminder${h.archived ? ' ｜ 已归档' : ''}');
    }
    if (_checkIns.isNotEmpty) {
      buf.writeln('');
      buf.writeln('## 打卡记录（${_checkIns.length}）');
      final titleById = {for (final h in _habits) h.id: h.title};
      for (final c in _checkIns) {
        final name = titleById[c.habitId] ?? c.habitId;
        buf.writeln('- ${CheckIn.dateKey(c.date)} ｜ ${_esc(name)}');
      }
    }
    return buf.toString();
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  static String _fmtMinute(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  static String _esc(String s) => s.replaceAll('"', '""');

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
