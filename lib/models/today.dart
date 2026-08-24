import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';

/// 今日聚合视图的聚合模型（零新存储）。
///
/// 全部字段都来自 TaskProvider / FocusProvider / HabitProvider 的**公开状态**，
/// 不新增任何表或字段：今日待办/已完成、今日专注分钟与番茄数、今日专注会话、
/// 今日习惯及其打卡状态，都在内存里基于已有数据计算。设计稿口径见
/// Ardot fileId 712985468083091。
class TodayAggregate {
  /// 聚合基准日（date-only）。
  final DateTime date;

  /// 今日待办（未完成、且属于今日事务）列表，按截止时间升序（无截止排末）。
  final List<Task> pendingTasks;
  /// 今日已完成数（当日事件里已 done 的数量）。
  final int completedToday;
  /// 今日事务总数（pending + completedToday）。
  final int todoCount;

  /// 今日专注分钟数（专注阶段秒数 / 60，四舍五入）。
  final int focusMinutes;
  /// 今日完成的番茄数（跑满预设时长的专注阶段）。
  final int pomodoroCount;
  /// 今日专注目标（分钟）。纯展示用，无存储，默认 120。
  final int focusGoalMinutes;

  /// 今日专注会话明细（按结束时间倒序）。
  final List<FocusSession> sessions;

  /// 今日习惯及其打卡状态（仅活动习惯）。
  final List<TodayHabitStatus> habits;

  const TodayAggregate({
    required this.date,
    required this.pendingTasks,
    required this.completedToday,
    required this.todoCount,
    required this.focusMinutes,
    required this.pomodoroCount,
    required this.focusGoalMinutes,
    required this.sessions,
    required this.habits,
  });

  /// 今日专注完成度 0..1（超额不溢出）。
  double get focusProgress =>
      focusGoalMinutes <= 0 ? 0.0 : (focusMinutes / focusGoalMinutes).clamp(0.0, 1.0);

  /// 今日习惯应打卡总数（shouldCheckIn 为 true 的数量）。
  int get habitExpected => habits.where((h) => h.shouldCheckIn).length;
  /// 今日习惯已打卡总数（checked 为 true 的数量）。
  int get habitDone => habits.where((h) => h.checked).length;

  /// 今日日期文案，如「8月9日 周日」。
  String get dateLabel {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final w = date.weekday; // 1=周一 … 7=周日
    final wName = (w >= 1 && w <= 7) ? names[w - 1] : '';
    return '${date.month}月${date.day}日 周$wName';
  }

  /// 从三个 Provider 的当前公开状态聚合出今日快照。
  ///
  /// 进面板/进页时取一次即可；数据在查看期间不变（与分享卡片同理）。
  factory TodayAggregate.fromProviders(
    TaskProvider task,
    FocusProvider focus,
    HabitProvider habit,
  ) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // —— 任务：复刻 TaskProvider._isEventToday（私有，无法直接调用）——
    int completedToday = 0;
    final pendingTasks = <Task>[];
    for (final t in task.tasks) {
      if (!_isEventToday(t, today)) continue;
      if (t.done) {
        completedToday++;
      } else {
        pendingTasks.add(t);
      }
    }
    pendingTasks.sort((a, b) {
      if (a.dueDate == null && b.dueDate == null) return 0;
      if (a.dueDate == null) return 1;
      if (b.dueDate == null) return -1;
      return a.dueDate!.compareTo(b.dueDate!);
    });
    final todoCount = pendingTasks.length + completedToday;

    // —— 专注 ——
    final focusMinutes = (focus.todayFocusSec / 60).round();
    final pomodoroCount = focus.todayCompleted;
    final sessions = focus.sessionsOn(today);

    // —— 习惯 ——
    final habits = <TodayHabitStatus>[
      for (final h in habit.activeHabits)
        TodayHabitStatus(
          habit: h,
          shouldCheckIn: h.shouldCheckInOn(today),
          checked: habit.isCheckedToday(h),
          streak: habit.currentStreak(h),
        ),
    ];

    return TodayAggregate(
      date: today,
      pendingTasks: pendingTasks,
      completedToday: completedToday,
      todoCount: todoCount,
      focusMinutes: focusMinutes,
      pomodoroCount: pomodoroCount,
      focusGoalMinutes: task.focusGoalMinutes,
      sessions: sessions,
      habits: habits,
    );
  }

  /// 复刻 TaskProvider._isEventToday：判断任务是否为「今天的事务」。
  /// 未删除，且（无截止日期 / 截止日期为今天 / 今天为循环日）；非循环且无截止视为当天。
  static bool _isEventToday(Task t, DateTime today) {
    if (t.deletedAt != null) return false;
    final d = DateTime(today.year, today.month, today.day);
    if (t.dueDate != null) {
      final due = DateTime(t.dueDate!.year, t.dueDate!.month, t.dueDate!.day);
      if (due == d) return true;
    } else if (!t.isRepeating) {
      return true;
    }
    return t.repeatsOn(d);
  }
}

/// 单个活动习惯在今日的状态。
class TodayHabitStatus {
  final Habit habit;
  /// 今天是否应打卡（按 weekday 过滤；空列表=每天）。
  final bool shouldCheckIn;
  /// 今天是否已打卡。
  final bool checked;
  /// 当前连续打卡天数。
  final int streak;
  const TodayHabitStatus({
    required this.habit,
    required this.shouldCheckIn,
    required this.checked,
    required this.streak,
  });
}
