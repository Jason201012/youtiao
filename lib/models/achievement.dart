/// 成就解锁所需的统计上下文（由习惯页聚合各 Provider 的数据后传入）。
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

  const AchievementContext({
    this.totalCheckIns = 0,
    this.longestStreak = 0,
    this.currentStreak = 0,
    this.habitCount = 0,
    this.completedTasks = 0,
    this.focusMinutes = 0,
  });
}

/// 一项成就（静态定义 + 解锁判定）。
class Achievement {
  final String id;
  final String title;
  final String desc;
  final String emoji;
  final bool Function(AchievementContext) _unlocked;

  const Achievement({
    required this.id,
    required this.title,
    required this.desc,
    required this.emoji,
    required bool Function(AchievementContext) unlocked,
  }) : _unlocked = unlocked;

  bool unlocked(AchievementContext ctx) => _unlocked(ctx);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'desc': desc,
        'emoji': emoji,
      };
}

/// 全部成就定义（顺序即展示顺序）。
final List<Achievement> allAchievements = [
  Achievement(
    id: 'first_checkin',
    title: '第一步',
    desc: '完成第一次习惯打卡',
    emoji: '🌱',
    unlocked: (c) => c.totalCheckIns >= 1,
  ),
  Achievement(
    id: 'streak_3',
    title: '三日打鱼',
    desc: '连续打卡 3 天',
    emoji: '🔥',
    unlocked: (c) => c.longestStreak >= 3,
  ),
  Achievement(
    id: 'streak_7',
    title: '一周不辍',
    desc: '连续打卡 7 天',
    emoji: '🔥',
    unlocked: (c) => c.longestStreak >= 7,
  ),
  Achievement(
    id: 'checkin_100',
    title: '百日坚持',
    desc: '累计打卡 100 次',
    emoji: '💯',
    unlocked: (c) => c.totalCheckIns >= 100,
  ),
  Achievement(
    id: 'habits_3',
    title: '三好习惯',
    desc: '同时养成 3 个习惯',
    emoji: '🗂️',
    unlocked: (c) => c.habitCount >= 3,
  ),
  Achievement(
    id: 'tasks_50',
    title: '任务达人',
    desc: '累计完成 50 个任务',
    emoji: '✅',
    unlocked: (c) => c.completedTasks >= 50,
  ),
  Achievement(
    id: 'focus_60',
    title: '专注一小时',
    desc: '累计专注 60 分钟',
    emoji: '⏱️',
    unlocked: (c) => c.focusMinutes >= 60,
  ),
  Achievement(
    id: 'master',
    title: '习惯大师',
    desc: '5 个习惯且累计打卡 200 次',
    emoji: '🏅',
    unlocked: (c) => c.habitCount >= 5 && c.totalCheckIns >= 200,
  ),
];
