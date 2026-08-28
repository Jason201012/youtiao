/// 一个习惯：可每日/按周几打卡，记录连续与累计次数。
///
/// 与任务模型解耦：习惯自成一套轻量模型，仅依赖 SQLite 的整段 JSON 存储
/// （见 [LocalDatabase] 的 habits 表），不包含提醒调度等复杂逻辑。
class Habit {
  final String id;
  final String title;
  final String emoji;
  /// 卡片强调色（hex int），用于列表/详情的视觉区分。
  final int colorValue;
  /// 需要打卡的星期（1=周一 … 7=周日）；空列表表示「每天」。
  final List<int> weekdays;
  /// 每日提醒时间（自 00:00 起的分钟数）；null 表示不提醒。
  /// 提醒按 [weekdays] 过滤：空列表=每天固定时刻；非空=每个所选星期各一次。
  final int? reminderMinute;
  final DateTime createdAt;
  final bool archived;
  /// 每周目标打卡次数（0 = 不启用，1..14）。新增字段，旧数据缺省 0（零迁移）。
  final int weeklyGoal;

  const Habit({
    required this.id,
    required this.title,
    this.emoji = '✅',
    this.colorValue = 0xFF0061A4,
    this.weekdays = const [],
    this.reminderMinute,
    required this.createdAt,
    this.archived = false,
    this.weeklyGoal = 0,
  });

  /// 某天是否应打卡（按 weekday 过滤；空列表=每天）。
  bool shouldCheckInOn(DateTime day) =>
      weekdays.isEmpty || weekdays.contains(day.weekday);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'emoji': emoji,
        'color': colorValue,
        'weekdays': weekdays,
        'reminderMinute': reminderMinute,
        'createdAt': createdAt.toIso8601String(),
        'archived': archived,
        'weeklyGoal': weeklyGoal,
      };

  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '✅',
        colorValue: j['color'] as int? ?? 0xFF0061A4,
        weekdays: (j['weekdays'] as List?)?.map((e) => e as int).toList() ?? [],
        reminderMinute: j['reminderMinute'] as int?,
        createdAt: j['createdAt'] is String
            ? DateTime.parse(j['createdAt'] as String)
            : DateTime.now(),
        archived: j['archived'] as bool? ?? false,
        weeklyGoal: j['weeklyGoal'] as int? ?? 0,
      );

  /// 复制并覆盖部分字段。
  ///
  /// 注意 [reminderMinute] 是可空字段，传 null 无法与「不修改」区分，
  /// 因此清除提醒必须显式传 `clearReminder: true`。
  Habit copyWith({
    String? title,
    String? emoji,
    int? colorValue,
    List<int>? weekdays,
    int? reminderMinute,
    bool clearReminder = false,
    bool? archived,
    int? weeklyGoal,
  }) =>
      Habit(
        id: id,
        title: title ?? this.title,
        emoji: emoji ?? this.emoji,
        colorValue: colorValue ?? this.colorValue,
        weekdays: weekdays ?? this.weekdays,
        reminderMinute:
            clearReminder ? null : (reminderMinute ?? this.reminderMinute),
        createdAt: createdAt,
        archived: archived ?? this.archived,
        weeklyGoal: weeklyGoal ?? this.weeklyGoal,
      );
}
