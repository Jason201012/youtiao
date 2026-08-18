import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';

/// 成就分组（决定成就墙上的分节顺序与标题）。
enum AchievementGroup { habit, task, focus, mixed }

extension AchievementGroupLabel on AchievementGroup {
  String get label {
    switch (this) {
      case AchievementGroup.habit:
        return '习惯';
      case AchievementGroup.task:
        return '任务';
      case AchievementGroup.focus:
        return '专注';
      case AchievementGroup.mixed:
        return '综合';
    }
  }
}

/// 成就解锁所需的统计上下文。
///
/// 全部字段都能从 TaskProvider / FocusProvider / HabitProvider 的公开状态现算
/// （见 [AchievementContext.fromProviders]），不新增任何存储。
class AchievementContext {
  /// 累计打卡次数（所有习惯合计）。
  final int totalCheckIns;

  /// 历史最长连续打卡天数（跨习惯同日只计一次）。
  final int longestStreak;

  /// 当前连续打卡天数。
  final int currentStreak;

  /// 已创建习惯数（含归档）。
  final int habitCount;

  /// 已完成任务数（来自 TaskProvider）。
  final int completedTasks;

  /// 累计专注分钟（来自 FocusProvider）。
  final int focusMinutes;

  /// 累计完成的番茄数（跑满预设时长的专注阶段）。
  final int pomodoroCount;

  /// 有专注记录的天数（按 date-only 去重）。
  final int focusDays;

  /// 单日完成任务数的历史最高值。
  final int maxTasksInDay;

  /// 早上 9 点前完成的任务数。
  final int earlyTasks;

  /// 晚上 22 点后完成的任务数。
  final int nightTasks;

  const AchievementContext({
    this.totalCheckIns = 0,
    this.longestStreak = 0,
    this.currentStreak = 0,
    this.habitCount = 0,
    this.completedTasks = 0,
    this.focusMinutes = 0,
    this.pomodoroCount = 0,
    this.focusDays = 0,
    this.maxTasksInDay = 0,
    this.earlyTasks = 0,
    this.nightTasks = 0,
  });

  /// 从三个 Provider 的公开状态现算一份成就上下文（零新存储）。
  factory AchievementContext.fromProviders(
    TaskProvider task,
    FocusProvider focus,
    HabitProvider habit,
  ) {
    // —— 任务侧：单日峰值 / 早鸟 / 夜猫 ——
    final perDay = <DateTime, int>{};
    int early = 0;
    int night = 0;
    for (final t in task.tasks) {
      if (!t.done || t.completedAt == null) continue;
      final c = t.completedAt!;
      final d = DateTime(c.year, c.month, c.day);
      perDay[d] = (perDay[d] ?? 0) + 1;
      if (c.hour < 9) early++;
      if (c.hour >= 22) night++;
    }
    int maxInDay = 0;
    for (final v in perDay.values) {
      if (v > maxInDay) maxInDay = v;
    }

    // —— 专注侧：番茄数 / 专注天数 ——
    int pomodoro = 0;
    final focusDates = <DateTime>{};
    for (final s in focus.sessions) {
      if (s.phase != FocusPhase.focus) continue;
      if (s.completed) pomodoro++;
      focusDates
          .add(DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day));
    }

    return AchievementContext(
      totalCheckIns: habit.totalCheckIns,
      longestStreak: habit.overallLongestStreak,
      currentStreak: habit.overallCurrentStreak,
      habitCount: habit.habitCount,
      completedTasks: task.completed,
      focusMinutes: focus.totalSec ~/ 60,
      pomodoroCount: pomodoro,
      focusDays: focusDates.length,
      maxTasksInDay: maxInDay,
      earlyTasks: early,
      nightTasks: night,
    );
  }
}

/// 一项成就（静态定义 + 解锁判定 + 可选进度）。
///
/// 绝大多数成就是「攒够某个数」的计数型，用 [Achievement.counter] 声明后即可
/// 自动获得进度条与「32/50」这样的进度文案；少数复合条件用
/// [Achievement.custom]，只有解锁与否、不显示进度。
class Achievement {
  final String id;
  final String title;
  final String desc;
  final String emoji;
  final AchievementGroup group;

  /// 计数型成就的目标值；0 表示无进度（复合成就）。
  final int target;

  /// 计数型成就的当前值取法；null 表示无进度。
  final int Function(AchievementContext)? _value;

  final bool Function(AchievementContext) _unlocked;

  /// 计数型成就：达到 [target] 即解锁，并自动带进度。
  Achievement.counter({
    required this.id,
    required this.title,
    required this.desc,
    required this.emoji,
    required this.group,
    required this.target,
    required int Function(AchievementContext) value,
  })  : _value = value,
        _unlocked = ((c) => value(c) >= target);

  /// 复合条件成就：自定义判定，不显示进度条。
  const Achievement.custom({
    required this.id,
    required this.title,
    required this.desc,
    required this.emoji,
    required this.group,
    required bool Function(AchievementContext) unlocked,
  })  : target = 0,
        _value = null,
        _unlocked = unlocked;

  bool unlocked(AchievementContext ctx) => _unlocked(ctx);

  /// 是否为带进度条的计数型成就。
  bool get hasProgress => _value != null && target > 0;

  /// 当前进度值（复合成就恒为 0）。
  int value(AchievementContext ctx) => _value?.call(ctx) ?? 0;

  /// 进度 0..1（复合成就：解锁 1、未解锁 0）。
  double progress(AchievementContext ctx) {
    if (!hasProgress) return unlocked(ctx) ? 1.0 : 0.0;
    final v = value(ctx) / target;
    return v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
  }

  /// 进度文案，如「32/50」；复合成就返回 null。
  String? progressLabel(AchievementContext ctx) {
    if (!hasProgress) return null;
    final v = value(ctx);
    return '${v > target ? target : v}/$target';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'desc': desc,
        'emoji': emoji,
        'group': group.name,
      };
}

/// 全部成就定义（顺序即展示顺序，同组相邻）。
final List<Achievement> allAchievements = [
  // ===== 习惯 =====
  Achievement.counter(
    id: 'first_checkin',
    title: '第一步',
    desc: '完成第一次习惯打卡',
    emoji: '🌱',
    group: AchievementGroup.habit,
    target: 1,
    value: (c) => c.totalCheckIns,
  ),
  Achievement.counter(
    id: 'streak_3',
    title: '三日打鱼',
    desc: '连续打卡 3 天',
    emoji: '🔥',
    group: AchievementGroup.habit,
    target: 3,
    value: (c) => c.longestStreak,
  ),
  Achievement.counter(
    id: 'streak_7',
    title: '一周不辍',
    desc: '连续打卡 7 天',
    emoji: '🔥',
    group: AchievementGroup.habit,
    target: 7,
    value: (c) => c.longestStreak,
  ),
  Achievement.counter(
    id: 'streak_30',
    title: '月度铁人',
    desc: '连续打卡 30 天',
    emoji: '🏔️',
    group: AchievementGroup.habit,
    target: 30,
    value: (c) => c.longestStreak,
  ),
  Achievement.counter(
    id: 'checkin_100',
    title: '百日坚持',
    desc: '累计打卡 100 次',
    emoji: '💯',
    group: AchievementGroup.habit,
    target: 100,
    value: (c) => c.totalCheckIns,
  ),
  Achievement.counter(
    id: 'checkin_500',
    title: '千锤百炼',
    desc: '累计打卡 500 次',
    emoji: '🧗',
    group: AchievementGroup.habit,
    target: 500,
    value: (c) => c.totalCheckIns,
  ),
  Achievement.counter(
    id: 'habits_3',
    title: '三好习惯',
    desc: '同时养成 3 个习惯',
    emoji: '🗂️',
    group: AchievementGroup.habit,
    target: 3,
    value: (c) => c.habitCount,
  ),

  // ===== 任务 =====
  Achievement.counter(
    id: 'tasks_1',
    title: '开张大吉',
    desc: '完成第一个任务',
    emoji: '🎉',
    group: AchievementGroup.task,
    target: 1,
    value: (c) => c.completedTasks,
  ),
  Achievement.counter(
    id: 'tasks_50',
    title: '任务达人',
    desc: '累计完成 50 个任务',
    emoji: '✅',
    group: AchievementGroup.task,
    target: 50,
    value: (c) => c.completedTasks,
  ),
  Achievement.counter(
    id: 'tasks_200',
    title: '清单杀手',
    desc: '累计完成 200 个任务',
    emoji: '🗡️',
    group: AchievementGroup.task,
    target: 200,
    value: (c) => c.completedTasks,
  ),
  Achievement.counter(
    id: 'day_10',
    title: '高产一日',
    desc: '单日完成 10 个任务',
    emoji: '⚡',
    group: AchievementGroup.task,
    target: 10,
    value: (c) => c.maxTasksInDay,
  ),
  Achievement.counter(
    id: 'early_bird',
    title: '早起鸟',
    desc: '早上 9 点前完成 10 个任务',
    emoji: '🌅',
    group: AchievementGroup.task,
    target: 10,
    value: (c) => c.earlyTasks,
  ),
  Achievement.counter(
    id: 'night_owl',
    title: '夜猫子',
    desc: '晚上 22 点后完成 10 个任务',
    emoji: '🌙',
    group: AchievementGroup.task,
    target: 10,
    value: (c) => c.nightTasks,
  ),

  // ===== 专注 =====
  Achievement.counter(
    id: 'focus_60',
    title: '专注一小时',
    desc: '累计专注 60 分钟',
    emoji: '⏱️',
    group: AchievementGroup.focus,
    target: 60,
    value: (c) => c.focusMinutes,
  ),
  Achievement.counter(
    id: 'focus_600',
    title: '十小时心流',
    desc: '累计专注 600 分钟',
    emoji: '🧠',
    group: AchievementGroup.focus,
    target: 600,
    value: (c) => c.focusMinutes,
  ),
  Achievement.counter(
    id: 'pomo_50',
    title: '番茄五十',
    desc: '完成 50 个番茄',
    emoji: '🍅',
    group: AchievementGroup.focus,
    target: 50,
    value: (c) => c.pomodoroCount,
  ),
  Achievement.counter(
    id: 'focus_days_30',
    title: '专注常客',
    desc: '在 30 个不同的日子专注过',
    emoji: '📅',
    group: AchievementGroup.focus,
    target: 30,
    value: (c) => c.focusDays,
  ),

  // ===== 综合 =====
  Achievement.custom(
    id: 'master',
    title: '习惯大师',
    desc: '5 个习惯且累计打卡 200 次',
    emoji: '🏅',
    group: AchievementGroup.mixed,
    unlocked: (c) => c.habitCount >= 5 && c.totalCheckIns >= 200,
  ),
  Achievement.custom(
    id: 'all_round',
    title: '全面开花',
    desc: '完成 20 个任务 + 打卡 20 次 + 专注 60 分钟',
    emoji: '🌸',
    group: AchievementGroup.mixed,
    unlocked: (c) =>
        c.completedTasks >= 20 && c.totalCheckIns >= 20 && c.focusMinutes >= 60,
  ),
];

/// 已解锁数量。
int unlockedAchievementCount(AchievementContext ctx) =>
    allAchievements.where((a) => a.unlocked(ctx)).length;

/// 按分组切分（保持 [AchievementGroup] 的声明顺序，空组不返回）。
Map<AchievementGroup, List<Achievement>> achievementsByGroup() {
  final map = <AchievementGroup, List<Achievement>>{};
  for (final g in AchievementGroup.values) {
    final list = allAchievements.where((a) => a.group == g).toList();
    if (list.isNotEmpty) map[g] = list;
  }
  return map;
}

/// 距离解锁最近的若干个未解锁成就（按进度降序），用于「即将解锁」提示。
List<Achievement> nextAchievements(AchievementContext ctx, {int limit = 3}) {
  final locked = allAchievements.where((a) => !a.unlocked(ctx)).toList()
    ..sort((a, b) => b.progress(ctx).compareTo(a.progress(ctx)));
  return locked.length > limit ? locked.sublist(0, limit) : locked;
}
