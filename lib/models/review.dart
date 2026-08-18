import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';

/// 回顾周报的聚合模型（零新存储）。
///
/// 全部字段都来自 TaskProvider / FocusProvider / HabitProvider 的**公开状态**，
/// 不新增任何表或字段：本周区间（周一 00:00 – 周日 23:59:59）内的任务完成数、
/// 专注时长、番茄数、习惯达成率、分类分布、专注去向 Top、各习惯本周进度，都在内存里
/// 基于已有数据计算。设计稿口径见 Ardot fileId 712647748961343。
class WeeklyReview {
  /// 本周一（date-only）。
  final DateTime weekStart;
  /// 本周日（date-only）。
  final DateTime weekEnd;

  /// 本周完成任务数（按 completedAt 落在周区间内计数）。
  final int completedCount;
  /// 本周专注阶段总秒数（不含休息）。
  final int focusSec;
  /// 本周完成的番茄数（跑满预设时长的专注阶段）。
  final int pomodoroCount;
  /// 本周整体习惯达成率 0..1（实际打卡 / 应打卡，跨所有活动习惯）。
  final double habitRate;
  /// 本周各习惯「应打卡」总次数（仅活动习惯、仅其设定的星期）。
  final int habitExpected;
  /// 本周各习惯「已打卡」总次数。
  final int habitDone;

  /// 本周每日完成数（周一→周日，7 项）。
  final List<int> trend;
  /// 上周每日完成数（周一→周日，7 项），用于环比。
  final List<int> lastTrend;
  /// 本周的日期列表（周一→周日，7 项，date-only）。
  final List<DateTime> weekDates;

  /// 本周分类完成率（分母=该分类现有任务总数，分子=本周完成的该分类任务数）。
  final Map<Category, double> categoryProgress;

  /// 本周专注去向 Top（按累计专注秒数降序，最多 3 条，仅含带任务名的会话）。
  final List<TaskFocusStat> focusTop;

  /// 每个活动习惯的本周进度。
  final List<HabitWeekStat> habits;

  const WeeklyReview({
    required this.weekStart,
    required this.weekEnd,
    required this.completedCount,
    required this.focusSec,
    required this.pomodoroCount,
    required this.habitRate,
    required this.habitExpected,
    required this.habitDone,
    required this.trend,
    required this.lastTrend,
    required this.weekDates,
    required this.categoryProgress,
    required this.focusTop,
    required this.habits,
  });

  /// 周区间文案，如「8月3日 – 8月9日」。
  String get weekRangeLabel {
    String f(DateTime d) => '${d.month}月${d.day}日';
    return '${f(weekStart)} – ${f(weekEnd)}';
  }

  /// 本周专注分钟数（展示用）。
  int get focusMinutes => (focusSec / 60).round();
  /// 本周习惯达成百分比（展示用）。
  int get habitPercent => (habitRate * 100).round();

  /// 从三个 Provider 的当前公开状态聚合出一份周报快照。
  ///
  /// 进面板/进页时取一次即可；数据在查看期间不变（与分享卡片同理）。
  factory WeeklyReview.fromProviders(
    TaskProvider task,
    FocusProvider focus,
    HabitProvider habit,
  ) {
    final start = _mondayOf(DateTime.now());
    final end = start.add(const Duration(days: 6));

    // —— 任务完成 ——
    int completedCount = 0;
    final catTotal = <Category, int>{};
    final catDone = <Category, int>{};
    for (final c in Category.values) {
      catTotal[c] = 0;
      catDone[c] = 0;
    }
    final trend = <int>[];
    final weekDates = <DateTime>[];
    for (int i = 0; i < 7; i++) {
      final day = start.add(Duration(days: i));
      weekDates.add(day);
      trend.add(0);
    }
    for (final t in task.tasks) {
      catTotal[t.category] = catTotal[t.category]! + 1;
      if (t.done && t.completedAt != null && _inWeek(t.completedAt!, start, end)) {
        completedCount++;
        catDone[t.category] = catDone[t.category]! + 1;
        final idx = _dayIndex(t.completedAt!, start);
        if (idx >= 0 && idx < 7) trend[idx]++;
      }
    }
    final lastTrend = List.filled(7, 0);
    final prevStart = start.subtract(const Duration(days: 7));
    for (final t in task.tasks) {
      if (t.done && t.completedAt != null && _inWeek(t.completedAt!, prevStart, start.subtract(const Duration(days: 1)))) {
        final idx = _dayIndex(t.completedAt!, prevStart);
        if (idx >= 0 && idx < 7) lastTrend[idx]++;
      }
    }
    final categoryProgress = <Category, double>{
      for (final c in Category.values)
        c: catTotal[c]! == 0 ? 0.0 : (catDone[c]! / catTotal[c]!),
    };

    // —— 专注 ——
    int focusSec = 0;
    int pomodoroCount = 0;
    final focusMap = <String, TaskFocusStat>{};
    for (final s in focus.sessions) {
      if (!_inWeek(s.endedAt, start, end)) continue;
      if (s.phase == FocusPhase.focus) {
        focusSec += s.durationSec;
        if (s.completed) pomodoroCount++;
      }
      if (s.taskId == null) continue;
      final ex = focusMap[s.taskId!];
      if (ex == null) {
        focusMap[s.taskId!] = TaskFocusStat(
          taskId: s.taskId!,
          title: s.taskTitle ?? '任务',
          totalSec: s.durationSec,
          count: 1,
        );
      } else {
        focusMap[s.taskId!] = TaskFocusStat(
          taskId: ex.taskId,
          title: ex.title,
          totalSec: ex.totalSec + s.durationSec,
          count: ex.count + 1,
        );
      }
    }
    final focusTop = focusMap.values.toList()
      ..sort((a, b) => b.totalSec.compareTo(a.totalSec));
    if (focusTop.length > 3) {
      focusTop.removeRange(3, focusTop.length);
    }

    // —— 习惯 ——
    int habitExpected = 0;
    int habitDone = 0;
    final habits = <HabitWeekStat>[];
    final checkedCache = <String, Set<DateTime>>{};
    for (final h in habit.activeHabits) {
      int expected = 0;
      for (int i = 0; i < 7; i++) {
        if (h.shouldCheckInOn(start.add(Duration(days: i)))) expected++;
      }
      final checked = checkedCache.putIfAbsent(h.id, () => habit.checkedDays(h, 7));
      int done = 0;
      for (int i = 0; i < 7; i++) {
        final day = start.add(Duration(days: i));
        if (checked.contains(day)) done++;
      }
      habitExpected += expected;
      habitDone += done;
      habits.add(HabitWeekStat(
        habit: h,
        expected: expected,
        done: done,
        rate: expected == 0 ? 0.0 : (done / expected),
      ));
    }
    habits.sort((a, b) => b.rate.compareTo(a.rate));
    final habitRate =
        habitExpected == 0 ? 0.0 : (habitDone / habitExpected);

    return WeeklyReview(
      weekStart: start,
      weekEnd: end,
      completedCount: completedCount,
      focusSec: focusSec,
      pomodoroCount: pomodoroCount,
      habitRate: habitRate,
      habitExpected: habitExpected,
      habitDone: habitDone,
      trend: trend,
      lastTrend: lastTrend,
      weekDates: weekDates,
      categoryProgress: categoryProgress,
      focusTop: focusTop,
      habits: habits,
    );
  }

  // ===== 日期工具（date-only 比较，与 Provider 内部口径一致）=====

  /// 取 [d] 所在周的周一（00:00）。
  static DateTime _mondayOf(DateTime d) {
    final today = DateTime(d.year, d.month, d.day);
    // DateTime.weekday：1=周一 … 7=周日
    final diff = today.weekday - DateTime.monday;
    return today.subtract(Duration(days: diff));
  }

  /// [x] 的 date-only 是否落在 [start, end]（均含）。
  static bool _inWeek(DateTime x, DateTime start, DateTime end) {
    final d = DateTime(x.year, x.month, x.day);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  /// [x] 相对 [start]（周一）的周内下标 0..6，不在范围内返回 -1。
  static int _dayIndex(DateTime x, DateTime start) {
    final d = DateTime(x.year, x.month, x.day);
    final diff = d.difference(start).inDays;
    return (diff >= 0 && diff < 7) ? diff : -1;
  }
}

/// 单个活动习惯的本周进度。
class HabitWeekStat {
  final Habit habit;
  final int expected; // 本周应打卡次数
  final int done; // 本周已打卡次数
  final double rate; // done / expected，0..1
  const HabitWeekStat({
    required this.habit,
    required this.expected,
    required this.done,
    required this.rate,
  });
}
