/// 一个习惯：可每日/按周几打卡，记录连续与累计次数。
///
/// 与任务模型解耦：习惯自成一套轻量模型，仅依赖 SQLite 的整段 JSON 存储
/// （见 [LocalDatabase] 的 habits 表），不包含提醒调度等复杂逻辑。
class Habit {
  /// P3-4（v2.9.4 审计）：每日目标量的合法上界，**读写两侧共用**。
  ///
  /// 此前上限 9999 在 [Habit._clampTarget]（读侧）与 `HabitProvider` 的
  /// `addHabit` / `updateHabit`（写侧）各写一遍字面量，日后调界必然漏改一侧。
  static const int maxDailyTarget = 9999;

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

  /// P3-10（v2.9.4 审计）：每周**计划打卡天数**（[weekdays] 为空 = 7 天）。
  ///
  /// 存在的理由：`weeklyGoal`（每周目标次数）的上界此前写死 14，于是
  /// 「每周一三五」的习惯也能设「每周 14 次」——目标永远不可达，达成率恒为
  /// 一段死数字，白给用户一个「做不到」的进度条。上界应随计划天数联动。
  ///
  /// P3-15（v2.9.5 审计）：本成员与 [clampWeeklyGoal] 在 `lib/` 无生产调用
  /// （仅测试引用）——UI 两处都要在「正在编辑、Habit 尚不存在」时算上界，只能用
  /// 静态的 [plannedDaysOf]；写入侧三处同理。保留为**静态判据的实例对称形式**：
  /// 语义正确、有测试锁定，且日后若新增「对已有习惯夹取」的入口可直接复用。
  int get plannedDaysPerWeek => weekdays.isEmpty ? 7 : weekdays.length;

  /// 由 [weekdays] 推出每周计划天数（空 = 每天 = 7）。
  static int plannedDaysOf(List<int> weekdays) =>
      weekdays.isEmpty ? 7 : weekdays.length;

  /// 夹取每周目标次数到「0 = 不启用，1..计划天数」。
  ///
  /// 静态形式是必要的：新建路径里 `Habit` 实例尚不存在（正在构造中），
  /// 只能拿入参 [weekdays] 算。实例方法 [clampWeeklyGoal] 供已有习惯使用。
  ///
  /// 读侧（[fromJson]，P2-5）与写侧（`HabitProvider` 三处）都走这里——
  /// 判据只有这一处，两侧不会漂移。
  static int clampWeeklyGoalTo(int v, List<int> weekdays) =>
      v.clamp(0, plannedDaysOf(weekdays)).toInt();

  /// 夹取每周目标次数到「0 = 不启用，1..计划天数」。
  ///
  /// 供 UI 与写入侧共用，避免两侧各写一份判据再次漂移（与 [maxDailyTarget]
  /// 同理）。
  int clampWeeklyGoal(int v) => clampWeeklyGoalTo(v, weekdays);

  /// P3-7（v2.9.6 审计）：**生效的**周目标量——[weeklyGoal] 的展示 / 统计
  /// 统一消费点（概览「本周达标」、[HabitProvider.weeklyGoalMet]、
  /// `consecutiveGoalWeeks` 等）读这里而非裸字段。
  ///
  /// 裸字段保留 fromJson 的原值（保真，见 fromJson 注释）；本 getter 按当前
  /// 计划天数夹取，夹取判据与写入侧同为 [clampWeeklyGoalTo] 单一真源。
  /// 用户在编辑层显式保存时写入侧才会把收敛值落库。
  int get effectiveWeeklyGoal => clampWeeklyGoal(weeklyGoal);

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

  factory Habit.fromJson(Map<String, dynamic> j) {
    // P3-7（v2.9.6 审计）：**不再在读取时夹取** [weeklyGoal]——读侧夹取意味着
    // 「读取即静默收敛」，收敛值会随下一次 `_persistHabits()` 落库，用户的原
    // 目标量被不可恢复地改写（`7 → 3` 后把打卡日改回「每天」也回不来）。
    // 现在模型层保留**原值**（[toJson] 原样落库），展示与统计消费统一走
    // [effectiveWeeklyGoal]（按当前计划天数夹取）；用户在编辑层显式保存时
    // 才由写入侧收敛到合法值。备份 / 数据库里的原值全程保真。
    //
    // 读侧与写入侧语义仍统一：夹取判据只有一个真源 [clampWeeklyGoalTo]。
    final weekdays =
        (j['weekdays'] as List?)?.map((e) => e as int).toList() ?? const <int>[];
    return Habit(
      id: j['id'] as String,
      title: j['title'] as String? ?? '',
      emoji: j['emoji'] as String? ?? '✅',
      colorValue: j['color'] as int? ?? 0xFF0061A4,
      weekdays: weekdays,
      reminderMinute: j['reminderMinute'] as int?,
      createdAt: j['createdAt'] is String
          ? DateTime.parse(j['createdAt'] as String)
          : DateTime.now(),
      archived: j['archived'] as bool? ?? false,
      weeklyGoal: (j['weeklyGoal'] as num?)?.toInt() ?? 0,
      // T1-2 / T1-4：备份是显式不可信输入，越界值一律回落默认——
      // 目标量 <=0 / 非整数 → 视为布尔习惯；宽限日夹到 [0,3]。
      dailyTarget: _clampTarget(j['dailyTarget']),
      graceDays: ((j['graceDays'] as num?)?.toInt() ?? 0).clamp(0, 3),
    );
  }

  /// 解析每日目标量。
  ///
  /// P3-4（v2.9.4 审计）：此前「超出上界」与「<=0」同归 `null`，于是
  /// 手工改过的备份里 `dailyTarget: 20000` 会被**静默降级成布尔习惯**——
  /// 用户的量化语义被整体改掉（进度条消失、目标变1），且没有任何提示。
  /// 写入侧（`HabitProvider.addHabit` / `updateHabit`）对超上界是**夹到
  /// [maxDailyTarget]**，两侧语义必须一致，所以现在读侧同样夹取。
  /// 夹取意味着「目标量偏大」被保留下来（仍可 +1 累加），而不是丢掉。
  ///
  /// 仍回落 `null` 的只有两类：非数值（脏数据）与 `<=0`（「取消量化」
  /// 本就是 `null`，两者在 UI 上等价，都表示布尔习惯）。
  static int? _clampTarget(dynamic v) {
    if (v is! num) return null;
    final n = v.toInt();
    if (n < 1) return null;
    return n > maxDailyTarget ? maxDailyTarget : n;
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
