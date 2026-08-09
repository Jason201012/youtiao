import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';

/// 回顾的周期粒度。周报见 [WeeklyReview]，这里承接更长的自然月 / 自然年。
enum ReviewPeriod { month, year }

extension ReviewPeriodLabel on ReviewPeriod {
  /// 分段控件上的短名。
  String get label => this == ReviewPeriod.month ? '月报' : '年报';

  /// 指标卡前缀，如「本月完成」。
  String get unitLabel => this == ReviewPeriod.month ? '本月' : '本年';

  /// 环比文案里的上一周期，如「上月」。
  String get prevLabel => this == ReviewPeriod.month ? '上月' : '去年';
}

/// 单个活动习惯在某周期内的达成情况。
class HabitPeriodStat {
  final Habit habit;
  final int expected; // 周期内应打卡次数（仅其设定的星期）
  final int done; // 周期内已打卡次数
  final double rate; // done / expected，0..1
  const HabitPeriodStat({
    required this.habit,
    required this.expected,
    required this.done,
    required this.rate,
  });
}

/// 月报 / 年报的聚合模型（零新存储）。
///
/// 与 [WeeklyReview] 同一范式：所有字段都由 TaskProvider / FocusProvider /
/// HabitProvider 的**公开状态**在内存中现算，不新增任何表或字段。区别只在于
/// 区间从「本周一→周日」换成自然月 / 自然年，且趋势桶的粒度随之变化
/// （月报按天，年报按月）。
///
/// [anchor] 可注入，便于单测固定时间基准。
class PeriodReview {
  final ReviewPeriod period;

  /// 区间首日（date-only）。
  final DateTime start;

  /// 区间末日（date-only）。
  final DateTime end;

  /// 区间内完成任务数（按 completedAt 计）。
  final int completedCount;

  /// 上一周期完成任务数（环比用）。
  final int prevCompletedCount;

  /// 区间内专注阶段总秒数（不含休息）。
  final int focusSec;

  /// 上一周期专注阶段总秒数（环比用）。
  final int prevFocusSec;

  /// 区间内完成的番茄数（跑满预设时长的专注阶段）。
  final int pomodoroCount;

  /// 区间内整体习惯达成率 0..1。
  final double habitRate;
  final int habitExpected;
  final int habitDone;

  /// 趋势桶：月报=每日完成数（长度=当月天数），年报=每月完成数（长度 12）。
  final List<int> buckets;

  /// 与 [buckets] 等长的横轴标签（月报为「1」「2」…，年报为「1月」「2月」…）。
  final List<String> bucketLabels;

  /// 有任务完成记录的天数（无论月报年报都按「天」计）。
  final int activeDays;

  /// 区间总天数。
  final int totalDays;

  /// 产出最高的那个桶的下标（全为 0 时为 -1）。
  final int bestBucketIndex;

  /// 产出最高的那个桶的完成数。
  final int bestBucketCount;

  /// 区间内各分类完成数。
  final Map<Category, int> categoryCount;

  /// 区间内专注去向 Top（按累计秒数降序，最多 3 条，仅含带任务名的会话）。
  final List<TaskFocusStat> focusTop;

  /// 每个活动习惯在区间内的达成情况（按达成率降序）。
  final List<HabitPeriodStat> habits;

  const PeriodReview({
    required this.period,
    required this.start,
    required this.end,
    required this.completedCount,
    required this.prevCompletedCount,
    required this.focusSec,
    required this.prevFocusSec,
    required this.pomodoroCount,
    required this.habitRate,
    required this.habitExpected,
    required this.habitDone,
    required this.buckets,
    required this.bucketLabels,
    required this.activeDays,
    required this.totalDays,
    required this.bestBucketIndex,
    required this.bestBucketCount,
    required this.categoryCount,
    required this.focusTop,
    required this.habits,
  });

  // ===== 展示派生 =====

  /// 标题，如「2026 年 8 月」/「2026 年」。
  String get title => period == ReviewPeriod.month
      ? '${start.year} 年 ${start.month} 月'
      : '${start.year} 年';

  /// 区间文案，如「8月1日 – 8月31日」。
  String get rangeLabel {
    String f(DateTime d) => '${d.month}月${d.day}日';
    return '${f(start)} – ${f(end)}';
  }

  int get focusMinutes => (focusSec / 60).round();
  int get prevFocusMinutes => (prevFocusSec / 60).round();
  int get habitPercent => (habitRate * 100).round();

  /// 完成数环比（正数=比上一周期多）。
  int get completedDelta => completedCount - prevCompletedCount;

  /// 专注分钟环比。
  int get focusMinutesDelta => focusMinutes - prevFocusMinutes;

  /// 日均完成数（保留 1 位，按区间总天数摊）。
  double get dailyAverage =>
      totalDays == 0 ? 0.0 : completedCount / totalDays;

  /// 最高产的那个桶的文案，如「8月14日」/「3月」；无数据时为 null。
  String? get bestBucketLabel {
    if (bestBucketIndex < 0 || bestBucketCount <= 0) return null;
    return period == ReviewPeriod.month
        ? '${start.month}月${bestBucketIndex + 1}日'
        : '${bestBucketIndex + 1}月';
  }

  /// 环比描述，如「较上月 +12」；持平返回「与上月持平」。
  String get completedDeltaLabel {
    final d = completedDelta;
    if (d == 0) return '与${period.prevLabel}持平';
    return '较${period.prevLabel} ${d > 0 ? '+' : ''}$d';
  }

  // ===== 聚合 =====

  /// 从三个 Provider 的当前公开状态聚合出一份周期报快照。
  factory PeriodReview.fromProviders(
    TaskProvider task,
    FocusProvider focus,
    HabitProvider habit, {
    ReviewPeriod period = ReviewPeriod.month,
    DateTime? anchor,
  }) {
    final a = anchor ?? DateTime.now();
    final range = _rangeOf(period, a);
    final prevRange = _rangeOf(period, _prevAnchor(period, a));
    final start = range.$1;
    final end = range.$2;

    // —— 桶初始化 ——
    final bucketCount = period == ReviewPeriod.month ? end.day : 12;
    final buckets = List<int>.filled(bucketCount, 0);
    final bucketLabels = List<String>.generate(
      bucketCount,
      (i) => period == ReviewPeriod.month ? '${i + 1}' : '${i + 1}月',
    );

    // —— 任务完成 ——
    int completedCount = 0;
    int prevCompletedCount = 0;
    final categoryCount = <Category, int>{for (final c in Category.values) c: 0};
    final doneDays = <DateTime>{};
    for (final t in task.tasks) {
      if (!t.done || t.completedAt == null) continue;
      final d = _dateOnly(t.completedAt!);
      if (_inRange(d, prevRange.$1, prevRange.$2)) prevCompletedCount++;
      if (!_inRange(d, start, end)) continue;
      completedCount++;
      categoryCount[t.category] = categoryCount[t.category]! + 1;
      doneDays.add(d);
      final idx = period == ReviewPeriod.month ? d.day - 1 : d.month - 1;
      if (idx >= 0 && idx < bucketCount) buckets[idx]++;
    }

    int bestBucketIndex = -1;
    int bestBucketCount = 0;
    for (int i = 0; i < buckets.length; i++) {
      if (buckets[i] > bestBucketCount) {
        bestBucketCount = buckets[i];
        bestBucketIndex = i;
      }
    }

    // —— 专注 ——
    int focusSec = 0;
    int prevFocusSec = 0;
    int pomodoroCount = 0;
    final focusMap = <String, TaskFocusStat>{};
    for (final s in focus.sessions) {
      final d = _dateOnly(s.endedAt);
      if (s.phase == FocusPhase.focus &&
          _inRange(d, prevRange.$1, prevRange.$2)) {
        prevFocusSec += s.durationSec;
      }
      if (!_inRange(d, start, end)) continue;
      if (s.phase == FocusPhase.focus) {
        focusSec += s.durationSec;
        if (s.completed) pomodoroCount++;
      }
      if (s.taskId == null) continue;
      final ex = focusMap[s.taskId!];
      focusMap[s.taskId!] = ex == null
          ? TaskFocusStat(
              taskId: s.taskId!,
              title: s.taskTitle ?? '任务',
              totalSec: s.durationSec,
              count: 1,
            )
          : TaskFocusStat(
              taskId: ex.taskId,
              title: ex.title,
              totalSec: ex.totalSec + s.durationSec,
              count: ex.count + 1,
            );
    }
    final focusTop = focusMap.values.toList()
      ..sort((a, b) => b.totalSec.compareTo(a.totalSec));
    if (focusTop.length > 3) focusTop.removeRange(3, focusTop.length);

    // —— 习惯 ——
    final totalDays = end.difference(start).inDays + 1;
    int habitExpected = 0;
    int habitDone = 0;
    final habits = <HabitPeriodStat>[];
    for (final h in habit.activeHabits) {
      // 习惯创建之前的日子不该计入「应打卡」，否则新习惯在年报里永远难看。
      final from = _laterOf(start, _dateOnly(h.createdAt));
      int expected = 0;
      if (!from.isAfter(end)) {
        final days = end.difference(from).inDays + 1;
        for (int i = 0; i < days; i++) {
          if (h.shouldCheckInOn(from.add(Duration(days: i)))) expected++;
        }
      }
      final done = habit.checkedDaysBetween(h, start, end).length;
      habitExpected += expected;
      habitDone += done;
      habits.add(HabitPeriodStat(
        habit: h,
        expected: expected,
        done: done,
        rate: expected == 0 ? 0.0 : (done / expected).clamp(0.0, 1.0),
      ));
    }
    habits.sort((a, b) => b.rate.compareTo(a.rate));
    final habitRate = habitExpected == 0
        ? 0.0
        : (habitDone / habitExpected).clamp(0.0, 1.0);

    return PeriodReview(
      period: period,
      start: start,
      end: end,
      completedCount: completedCount,
      prevCompletedCount: prevCompletedCount,
      focusSec: focusSec,
      prevFocusSec: prevFocusSec,
      pomodoroCount: pomodoroCount,
      habitRate: habitRate,
      habitExpected: habitExpected,
      habitDone: habitDone,
      buckets: buckets,
      bucketLabels: bucketLabels,
      activeDays: doneDays.length,
      totalDays: totalDays,
      bestBucketIndex: bestBucketIndex,
      bestBucketCount: bestBucketCount,
      categoryCount: categoryCount,
      focusTop: focusTop,
      habits: habits,
    );
  }

  // ===== 日期工具（date-only 口径，与其它聚合一致）=====

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _laterOf(DateTime a, DateTime b) =>
      a.isAfter(b) ? a : b;

  static bool _inRange(DateTime d, DateTime start, DateTime end) =>
      !d.isBefore(start) && !d.isAfter(end);

  /// 返回 [anchor] 所在周期的 (首日, 末日)，均为 date-only。
  ///
  /// 月末用 `DateTime(y, m + 1, 0)` 取得（Dart 的 day=0 会回退到上月最后一天），
  /// 天然处理闰年与大小月。
  static (DateTime, DateTime) _rangeOf(ReviewPeriod p, DateTime anchor) {
    if (p == ReviewPeriod.month) {
      return (
        DateTime(anchor.year, anchor.month, 1),
        DateTime(anchor.year, anchor.month + 1, 0),
      );
    }
    return (DateTime(anchor.year, 1, 1), DateTime(anchor.year, 12, 31));
  }

  /// 上一周期的锚点日期。
  static DateTime _prevAnchor(ReviewPeriod p, DateTime anchor) =>
      p == ReviewPeriod.month
          ? DateTime(anchor.year, anchor.month - 1, 1)
          : DateTime(anchor.year - 1, 1, 1);

  /// 相对 [anchor] 前后翻页的新锚点（[delta] 为 -1 / +1）。
  static DateTime shiftAnchor(ReviewPeriod p, DateTime anchor, int delta) =>
      p == ReviewPeriod.month
          ? DateTime(anchor.year, anchor.month + delta, 1)
          : DateTime(anchor.year + delta, 1, 1);
}
