import 'package:flutter/material.dart';
import 'package:todolist/services/app_log.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/csv_safe.dart';

/// 习惯 / 打卡的状态层：管理习惯列表、每日打卡记录、连续天数统计与持久化。
///
/// 与 TaskProvider / FocusProvider 解耦，仅依赖 [LocalDatabase] 的 habits /
/// check_ins 两张表（整段 JSON 存储）。所有统计在内存中基于打卡日期集合计算，
/// 逻辑单纯、易测。
class HabitProvider extends ChangeNotifier {
  /// 进程内单例引用（由 main 在构造后写入），供 TaskProvider 自动备份等场景安全取用。
  /// 取前请判空（[instanceOrNull]）；测试/未初始化时为 null。
  static HabitProvider? _instance;
  static HabitProvider? get instanceOrNull => _instance;
  final List<Habit> _habits = [];
  final List<CheckIn> _checkIns = [];

  /// 进程内自增序号，叠加到习惯 id 上，避免同一毫秒内连续建习惯时 id 撞车
  /// （撞 id 会导致 _memHabits 按 id 存 Map 时后者覆盖前者，静默丢习惯，
  /// 且两个习惯对象的打卡会串号）。与 [NotificationService._habitSlotOf] 用
  /// hashCode 折叠无关，改 id 格式不影响通知槽位映射。
  static int _habitSeq = 0;

  /// 全部习惯（含归档）。UI 可按需过滤。
  List<Habit> get habits => List.unmodifiable(_habits);

  /// 全部打卡记录（导出 Excel 的「打卡记录」表使用，避免直接暴露内部可变列表）。
  List<CheckIn> get checkIns => List.unmodifiable(_checkIns);

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
    _instance = this; // 注册单例，供自动备份等场景安全取用
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
      AppLog.d('HabitProvider 加载失败（习惯/打卡暂不可用）：$e\n$stack');
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
    int weeklyGoal = 0,
  }) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}.${_habitSeq++}';
    final h = Habit(
      id: id,
      title: title,
      emoji: emoji,
      colorValue: colorValue,
      weekdays: weekdays,
      reminderMinute: reminderMinute,
      weeklyGoal: weeklyGoal,
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
  bool isCheckedToday(Habit habit) => isCheckedOn(habit, DateTime.now());

  /// 指定日是否已打卡（date-only 判定）。
  /// P2-1：晚简报按**投递日**聚合，不能取「本机当前日」，否则跨天投递时口径会串。
  bool isCheckedOn(Habit habit, DateTime day) {
    final k = CheckIn.dateKey(day);
    return _checkIns.any(
        (c) => c.habitId == habit.id && CheckIn.dateKey(c.date) == k);
  }

  /// P2-2：「习惯/打卡发生变动」时的重排回调，由 `main.dart` 注入。
  ///
  /// 之所以用回调而非直接 import `daily_briefing.dart`：后者反向依赖本文件
  /// （`buildEveningBriefFromState` 需要 `HabitProvider`），直接 import 会形成
  /// 循环依赖。注入式回调是最小改动且**未注入时静默跳过**的兜底方案——
  /// 挽留通知属锦上添花，绝不因回调缺失影响打卡主流程。
  static void Function(HabitProvider provider)? onHabitsChanged;

  /// 统一触发 [onHabitsChanged]；回调本身抛错一律吞掉（不阻断业务、不弹错）。
  void _notifyHabitsChanged() {
    final cb = onHabitsChanged;
    if (cb == null) return;
    try {
      cb(this);
    } catch (e) {
      AppLog.d('[HabitNudge] 变动重排回调失败（已忽略）：$e');
    }
  }

  /// 本周（周一~周日）某习惯的打卡天数（date-only 去重），用于「每周目标」进度。
  int weeklyCheckIns(Habit habit) {
    final monday = _mondayOf(DateTime.now());
    final sunday = monday.add(const Duration(days: 6));
    return _checkIns.where((c) {
      if (c.habitId != habit.id) return false;
      final d = DateTime(c.date.year, c.date.month, c.date.day);
      return !d.isBefore(monday) && !d.isAfter(sunday);
    }).map((c) => CheckIn.dateKey(c.date)).toSet().length;
  }

  /// 本周是否达成了周目标（weeklyGoal>0 且打卡天数 ≥ 目标）。
  bool goalMetThisWeek(Habit habit) =>
      habit.weeklyGoal > 0 && weeklyCheckIns(habit) >= habit.weeklyGoal;

  /// 从本周往前连续达成周目标的周数（断一周即止）；weeklyGoal<=0 返回 0。
  /// 用于「连续 4 周达成周目标」成就判定。
  int consecutiveGoalWeeks(Habit habit, {int weeks = 4}) {
    if (habit.weeklyGoal <= 0) return 0;
    int run = 0;
    final today = DateTime.now();
    for (int w = 0; w < weeks; w++) {
      final monday = _mondayOf(DateTime(today.year, today.month, today.day)
          .subtract(Duration(days: 7 * w)));
      final sunday = monday.add(const Duration(days: 6));
      final count = _checkIns.where((c) {
        if (c.habitId != habit.id) return false;
        final d = DateTime(c.date.year, c.date.month, c.date.day);
        return !d.isBefore(monday) && !d.isAfter(sunday);
      }).map((c) => CheckIn.dateKey(c.date)).toSet().length;
      if (count >= habit.weeklyGoal) {
        run++;
      } else {
        break;
      }
    }
    return run;
  }

  /// 返回某日期所在周的周一（每周首日）。
  static DateTime _mondayOf(DateTime d) {
    final base = DateTime(d.year, d.month, d.day);
    return base.subtract(Duration(days: base.weekday - 1));
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
    // F10：打卡后必须重排当天的习惯提醒。
    // 此前只调 _notifyHabitsChanged()（仅重排 23:00 漏卡挽留），打卡提醒原样挂着：
    // 习惯提醒 21:00、用户 20:00 提前打卡 → 21:00 照常弹「该打卡啦」，
    // 与打卡事实矛盾（任务侧专门做了 skipToday，习惯侧断链）。
    // 反向取消打卡同样要重排，把当天提醒恢复回来。
    _rescheduleReminder(habit);
    // P2-2：打卡变动后重排挽留，避免「已补卡却在 23:00 收到陈旧挽留」。
    _notifyHabitsChanged();
  }

  /// F10：按当前打卡状态重排某习惯的每日提醒（未设提醒 / 已归档则跳过）。
  /// 失败静默——提醒属锦上添花，绝不因调度失败阻断打卡主流程。
  void _rescheduleReminder(Habit habit) {
    if (habit.archived || habit.reminderMinute == null) return;
    NotificationService.instance
        .scheduleHabitReminder(habit, checkedToday: isCheckedToday(habit))
        .catchError((_) => false);
  }

  /// U2：编辑习惯（标题 / 表情 / 颜色 / 星期 / 周目标 / 归档）。
  ///
  /// 此前习惯一旦创建就既不能改名也不能删除（`deleteHabit` 定义后全库零调用），
  /// 名字打错字只能让错误的习惯永远躺在列表、热力图和连续天数榜里。
  /// 提醒时刻变更沿用 [setReminder] 的「先取消旧提醒再重挂」口径。
  Future<void> updateHabit(
    Habit habit, {
    String? title,
    String? emoji,
    int? colorValue,
    List<int>? weekdays,
    int? weeklyGoal,
    bool? archived,
  }) async {
    final idx = _habits.indexWhere((h) => h.id == habit.id);
    if (idx == -1) return;
    final updated = habit.copyWith(
      title: (title != null && title.trim().isNotEmpty) ? title.trim() : null,
      emoji: emoji,
      colorValue: colorValue,
      weekdays: weekdays,
      weeklyGoal: weeklyGoal,
      archived: archived,
    );
    _habits[idx] = updated;
    await _persistHabits();
    // 星期/归档变化会影响提醒落点，统一重排（未设提醒时内部跳过）。
    if (updated.archived) {
      await NotificationService.instance.cancelHabitReminder(updated.id);
    } else {
      _rescheduleReminder(updated);
    }
    notifyListeners();
    _notifyHabitsChanged();
  }

  /// U3：取消指定日期的打卡记录（补卡的反操作，避免「补错卡无法撤回」）。
  Future<void> uncheckInOnDay(Habit habit, DateTime day) async {
    final key = CheckIn.dateKey(day);
    final before = _checkIns.length;
    _checkIns.removeWhere(
        (c) => c.habitId == habit.id && CheckIn.dateKey(c.date) == key);
    if (_checkIns.length == before) return;
    await _persistCheckIns();
    notifyListeners();
    _rescheduleReminder(habit);
    _notifyHabitsChanged();
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
    // F10：补卡同样可能影响「今天」的提醒（补的就是今天），需重排。
    _rescheduleReminder(habit);
    // P2-2：补卡同样算「打卡变动」，需重排挽留。
    _notifyHabitsChanged();
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
  ///
  /// F-4（v2.8.5 审计）：[Habit.weekdays] 非空（每周部分天打卡）的习惯按
  /// 「计划打卡日序列」计算——计划外的休息日不再被当成「断签」。旧实现按
  /// 自然日逐天回退，「每周一/三/五」在周五打完回退到周四即断，连续天数恒 ≤ 1，
  /// 「连续 N 天」类成就对非每日习惯几乎不可达。weekdays 为空（每天）维持原口径。
  int currentStreak(Habit habit) {
    final wd = habit.weekdays.where((d) => d >= 1 && d <= 7).toSet();
    if (wd.isEmpty) return _streakFor(_datesOf(habit), allowTodayGap: true);
    return _plannedStreakFor(_datesOf(habit), wd, allowTodayGap: true);
  }

  /// 某习惯历史最长连续打卡天数。口径同 [currentStreak]（F-4：感知 weekdays）。
  int longestStreak(Habit habit) {
    final wd = habit.weekdays.where((d) => d >= 1 && d <= 7).toSet();
    if (wd.isEmpty) return _streakFor(_datesOf(habit), longest: true);
    return _plannedStreakFor(_datesOf(habit), wd, longest: true);
  }

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

  /// F-4（v2.8.5 审计）：按「计划打卡日序列」计算连续天数，
  /// 供 [weekdays] 非空（每周部分天打卡）的习惯专用。
  ///
  /// 与自然日口径 [_streakFor] 的差异：计划外的日子（休息日）对连续性**中性**，
  /// 只有「计划日缺卡」才断签。计划日序列 = `weekdays` 命中的星期，从今天（或
  /// 最早打卡日）逐自然日回退/前进筛选得到。
  ///
  /// - [longest]=true：从最早打卡日扫到今天，连续的「已打卡计划日」构成 run；
  /// - 否则：从今天往回走计划日序列，[allowTodayGap]=true 时「今天是计划日但
  ///   尚未打卡」不算断（与每天习惯的当天空缺容忍一致）。
  static int _plannedStreakFor(
    Set<DateTime> dates,
    Set<int> weekdays, {
    bool longest = false,
    bool allowTodayGap = false,
  }) {
    if (dates.isEmpty || weekdays.isEmpty) return 0;
    bool isPlanned(DateTime d) => weekdays.contains(d.weekday);
    final earliest =
        dates.reduce((a, b) => a.isBefore(b) ? a : b);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (longest) {
      int best = 0;
      int run = 0;
      for (var d = earliest; !d.isAfter(today); d = d.add(const Duration(days: 1))) {
        if (!isPlanned(d)) continue; // 计划外休息日：中性，不打断 run
        if (dates.contains(d)) {
          run++;
          if (run > best) best = run;
        } else {
          run = 0; // 计划日缺卡 → 断签
        }
      }
      return best;
    }
    var cursor = today;
    // 今天的空缺容忍：今天是计划日但尚未打卡 → 从上一个计划日起算。
    if (isPlanned(cursor) && !dates.contains(cursor) && allowTodayGap) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    int streak = 0;
    // 回退下界为最早打卡日：再往前不可能有打卡记录（防御性，避免脏 weekdays 死循环）。
    while (!cursor.isBefore(earliest)) {
      if (isPlanned(cursor)) {
        if (!dates.contains(cursor)) break;
        streak++;
      }
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

      // 🔴 修复 Bug1（僵尸习惯提醒）：覆盖 _habits 之前，先取消**本机现有全部习惯**
      // 的每日打卡提醒。否则若本机有 H1、备份里只有 H2，恢复后 H1 从列表消失，
      // 但它在系统 AlarmManager 里已排的提醒不会被取消，之后到点仍会弹一个
      // 「点进去找不到的习惯」提醒。
      // （F-2 起习惯提醒也是「一次性闹钟 × 预挂 8 次」，不再由系统周期分量永久循环，
      //  但要挂的槽位依然存在，故这一步取消仍然必要且必须放在覆盖之前。）
      // 对比 TaskProvider.restoreFromJson 的做法（先整体 cancelAll 再重排），
      // 习惯侧此前漏掉了这一步，现补上。
      final oldIds = _habits.map((h) => h.id).toList();
      for (final id in oldIds) {
        await NotificationService.instance.cancelHabitReminder(id);
      }

      _habits
        ..clear()
        ..addAll(
            habitsList.map((e) => Habit.fromJson(e as Map<String, dynamic>)));
      // 取消旧提醒并按恢复的 habits 重新调度（仅习惯提醒，不动任务通知）。
      // 注：上面的 oldIds 取消已覆盖「本机多余习惯」，这里再对恢复的列表逐个
      // 重挂（含 archived/无提醒的跳过），保证最终状态与备份一致。
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
  static String _esc(String s) => csvCell(s);

  Future<void> _persistHabits() async {
    try {
      await LocalDatabase.instance.replaceHabits(_habits);
    } catch (e) {
      AppLog.d('HabitProvider 持久化 habits 失败：$e');
    }
  }
  Future<void> _persistCheckIns() async {
    try {
      await LocalDatabase.instance.replaceCheckIns(_checkIns);
    } catch (e) {
      AppLog.d('HabitProvider 持久化 checkIns 失败：$e');
    }
  }
}
