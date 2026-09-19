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

  /// 每日目标量（T1-2，1..9999）。null = 布尔打卡（只记「打没打」，旧行为）。
  ///
  /// 「每天喝 8 杯水」「阅读 30 分钟」这类**定量习惯**此前完全没有承载：模型只有布尔
  /// 打卡 + [weeklyGoal] 周次数，[CheckIn] 也不记数量。本字段给出「一天要做多少个单位」，
  /// 达成与否由当日累计量 [CheckIn.value] 与它比对得出。
  /// 序列化为 `dailyTarget`，旧数据缺省 null（向后兼容，零迁移）。
  final int? dailyTarget;

  /// 宽限日（T1-4，0..3）：每周允许「计划日缺卡」而不断签的天数。
  ///
  /// 现实中的习惯很难 100% 无缺勤，一次正当理由（生病 / 出差）就让连续天数归零，
  /// 会让人直接放弃。宽限日把「每周最多 N 次失手」写成规则：缺卡消耗该周的宽限额度，
  /// 额度用尽才断签。0 = 关闭（旧行为，缺卡即断）。
  /// 序列化为 `graceDays`，旧数据缺省 0（向后兼容，零迁移）。
  final int graceDays;

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
    this.dailyTarget,
    this.graceDays = 0,
  });

  /// 某天是否应打卡（按 weekday 过滤；空列表=每天）。
  bool shouldCheckInOn(DateTime day) =>
      weekdays.isEmpty || weekdays.contains(day.weekday);

  /// T1-2：是否为「量化习惯」（设了 positive 的每日目标量）。
  bool get isQuantified => dailyTarget != null && dailyTarget! > 0;

  /// T1-2：生效的每日目标量；布尔习惯返回 1（达成即「打过卡」）。
  int get effectiveTarget => isQuantified ? dailyTarget! : 1;

  /// T1-2：某日累计量是否达成目标。
  bool targetMetBy(int value) => value >= effectiveTarget;

  /// T1-2：进度 0..1（超额不溢出）。
  double progressRatioOf(int value) =>
      (value / effectiveTarget).clamp(0.0, 1.0).toDouble();

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
        'dailyTarget': dailyTarget,
        'graceDays': graceDays,
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
        weeklyGoal: (j['weeklyGoal'] as int? ?? 0).clamp(0, 14),
        // T1-2 / T1-4：备份是显式不可信输入，越界值一律回落默认——
        // 目标量 <=0 / 非整数 → 视为布尔习惯；宽限日夹到 [0,3]。
        dailyTarget: _clampTarget(j['dailyTarget']),
        graceDays: ((j['graceDays'] as num?)?.toInt() ?? 0).clamp(0, 3),
      );

  /// 解析每日目标量：非数值 / <=0 / 超出上界一律返回 null（= 布尔打卡）。
  static int? _clampTarget(dynamic v) {
    if (v is! num) return null;
    final n = v.toInt();
    if (n < 1 || n > 9999) return null;
    return n;
  }

  /// 复制并覆盖部分字段。
  ///
  /// 注意 [reminderMinute] 与 [dailyTarget] 都是可空字段，传 null 无法与「不修改」区分，
  /// 因此清除提醒必须显式传 `clearReminder: true`，取消量化目标传 `clearDailyTarget: true`。
  Habit copyWith({
    String? title,
    String? emoji,
    int? colorValue,
    List<int>? weekdays,
    int? reminderMinute,
    bool clearReminder = false,
    bool? archived,
    int? weeklyGoal,
    int? dailyTarget,
    bool clearDailyTarget = false,
    int? graceDays,
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
        dailyTarget: clearDailyTarget ? null : (dailyTarget ?? this.dailyTarget),
        graceDays: graceDays ?? this.graceDays,
      );
}
