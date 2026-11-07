// A4（v3.1.1 功能增强）：拼音首字母 / 全拼字段由 [PinyinIndex] 单一真源计算
// （与 Task 侧同源），本模型只承载派生结果。
import 'package:todolist/services/pinyin_index.dart';

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
  /// 归档时间戳（L7，v3.0.8 审计）：归档发生时记录，供周期报告把「期内归档」
  /// 习惯的应打卡日截断到归档日——否则归档习惯从月报/年报整段消失，与成就侧
  /// 「归档保留历史」口径不一致。取消归档时清空；旧数据缺省 null（零迁移，
  /// 缺省时周期报告按「全程在期内」的尽力口径统计）。
  final DateTime? archivedAt;
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

  /// A3（v3.1.1 功能增强）：量化单位的展示文案（≤[maxUnitLength] 字符，如
  /// 「杯 / 页 / 次 / 分钟 / 公里」）。空串 = 无单位（旧行为，展示「6/8」）。
  ///
  /// 只影响展示与导出，不参与任何统计 / 达成判定；序列化为 `unit`，
  /// 旧数据缺省空串（向后兼容，零迁移）。
  final String unit;

  /// A3（v3.1.1 功能增强）：习惯列表排序权重（展示层语义，双精度以便插位）。
  ///
  /// 值越小越靠前；同值按 [createdAt]（创建顺序）兜底，因此旧数据全 0 时
  /// 展示顺序与升级前逐位一致（零迁移）。只影响列表展示，不影响打卡 / 统计 /
  /// 连续天数；归档习惯不参与排序。序列化为 `order`，旧数据缺省 0。
  final double order;

  /// A4（v3.1.1 功能增强）：标题拼音首字母串（小写），供习惯搜索按首字母命中
  /// （如「每天阅读」→ "mtyd"）。派生字段：由 [PinyinIndex] 在新建 / 编辑 /
  /// 加载时计算，旧数据缺省空串（向后兼容，零迁移；空串 = 搜索侧跳过该路径）。
  final String pinyinInitials;

  /// A4（v3.1.1 功能增强）：标题拼音全拼串（小写、无分隔，如「每天阅读」→
  /// "meiyuedu"）。与 [pinyinInitials] 同为派生字段，全拼搜索（敲 "yuedu"）
  /// 的数据源；旧数据缺省空串（零迁移），加载路径按标题回填补齐。
  final String pinyinFull;

  /// A3：量化单位的合法上界（读写两侧共用，与 [maxDailyTarget] 同惯例）。
  static const int maxUnitLength = 6;

  const Habit({
    required this.id,
    required this.title,
    this.emoji = '✅',
    this.colorValue = 0xFF0061A4,
    this.weekdays = const [],
    this.reminderMinute,
    required this.createdAt,
    this.archived = false,
    this.archivedAt,
    this.weeklyGoal = 0,
    this.dailyTarget,
    this.graceDays = 0,
    this.unit = '',
    this.order = 0,
    this.pinyinInitials = '',
    this.pinyinFull = '',
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

  /// A3（v3.1.1 功能增强）：量化进度「x/y(+单位)」的**单一真源**。
  ///
  /// 此前「今日 6/8」的拼串散在习惯行 / 今日页 / 今日卡 / 通知确认条四处
  /// （且无单位承载），加单位时必然漏改。全部展示点与 CSV / Excel 导出
  /// 统一消费本方法：
  /// - 无单位（旧行为）：`'6/8'`，与升级前逐字节一致；
  /// - 有单位：`'6/8 杯'`（单位与数值间一个空格）。
  /// 前缀文案（「今日」「已达标」等）由调用方按语境拼接，不进本方法。
  String progressLabelOf(int value) {
    final base = '$value/$effectiveTarget';
    final u = unit.trim();
    return u.isEmpty ? base : '$base $u';
  }

  /// P3-4（v3.1.3 审计）：「数量 + 单位」的单一真源。
  ///
  /// [progressLabelOf] 承载的是「x/y 杯」这类**进度**；新建/编辑层的目标显示、
  /// 详情「≥ 目标才计一天」需要的是**单个数量**带单位。此前这 5 处各自手拼
  /// `'$_dailyTarget / 天'` / `'≥ ${habit.effectiveTarget}'`，加了单位字段却
  /// 没横向推广：同一个习惯列表写「今日 6/8 杯」、编辑层仍写「8 / 天」。
  /// 静态版本供「尚无 Habit 实例」的编辑层使用；无单位时逐字节等于旧文案。
  static String quantityLabel(int value, String unit) {
    final u = unit.trim();
    return u.isEmpty ? '$value' : '$value $u';
  }

  /// [quantityLabel] 的实例便捷入口（详情 / 概览等已持有 Habit 的展示面）。
  String quantityLabelOf(int value) => quantityLabel(value, unit);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'emoji': emoji,
        'color': colorValue,
        'weekdays': weekdays,
        'reminderMinute': reminderMinute,
        'createdAt': createdAt.toIso8601String(),
        'archived': archived,
        'archivedAt': archivedAt?.toIso8601String(),
        'weeklyGoal': weeklyGoal,
        'dailyTarget': dailyTarget,
        'graceDays': graceDays,
        'unit': unit,
        'order': order,
        'pinyinInitials': pinyinInitials,
        'pinyinFull': pinyinFull,
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
      // L7（v3.0.8 审计）：备份是不可信输入，解析失败按「无时间戳」兜底
      // （周期报告侧对 null 有尽力口径），不让脏数据炸掉整份恢复。
      archivedAt: _tryParseDate(j['archivedAt']),
      weeklyGoal: (j['weeklyGoal'] as num?)?.toInt() ?? 0,
      // T1-2 / T1-4：备份是显式不可信输入，越界值一律回落默认——
      // 目标量 <=0 / 非整数 → 视为布尔习惯；宽限日夹到 [0,3]。
      dailyTarget: _clampTarget(j['dailyTarget']),
      graceDays: ((j['graceDays'] as num?)?.toInt() ?? 0).clamp(0, 3),
      // A3（v3.1.1 功能增强）：备份是不可信输入——单位截到上界、非法类型回空串；
      // order 兜底 0（与「旧数据缺省」同态）。
      unit: clampUnit(j['unit']),
      order: (j['order'] as num?)?.toDouble() ?? 0,
      // A4（v3.1.1 功能增强）：旧数据缺省空串（零迁移）；加载 / 恢复路径按标题回填。
      pinyinInitials: j['pinyinInitials'] as String? ?? '',
      pinyinFull: j['pinyinFull'] as String? ?? '',
    );
  }

  /// A3：单位夹取（读 / 写两侧共用真源，与 [clampWeeklyGoalTo] 同惯例）——
  /// 非字符串 / 空串回 `''`；超 [maxUnitLength] 截断（截断而非丢弃：语义保留
  /// 优先，与「目标量越界夹取」同取向）。
  static String clampUnit(dynamic v) {
    if (v is! String) return '';
    final s = v.trim();
    if (s.isEmpty) return '';
    return s.length > maxUnitLength ? s.substring(0, maxUnitLength) : s;
  }

  /// 解析可选时间戳（L7，v3.0.8 审计：`archivedAt`）。脏数据 / 非字符串一律
  /// 返回 null，与「字段缺省」同义——恢复路径绝不因单个坏字段整体失败。
  static DateTime? _tryParseDate(dynamic v) {
    if (v is! String) return null;
    try {
      return DateTime.parse(v);
    } catch (_) {
      return null;
    }
  }

  /// 解析每日目标量。  ///
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
  /// A3：[unit] 的「清除」值就是空串（空串本身合法），直接传 `unit: ''` 即可。
  Habit copyWith({
    String? title,
    String? emoji,
    int? colorValue,
    List<int>? weekdays,
    int? reminderMinute,
    bool clearReminder = false,
    bool? archived,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    int? weeklyGoal,
    int? dailyTarget,
    bool clearDailyTarget = false,
    int? graceDays,
    String? unit,
    double? order,
    String? pinyinInitials,
    String? pinyinFull,
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
        archivedAt:
            clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
        weeklyGoal: weeklyGoal ?? this.weeklyGoal,
        dailyTarget: clearDailyTarget ? null : (dailyTarget ?? this.dailyTarget),
        graceDays: graceDays ?? this.graceDays,
        unit: unit ?? this.unit,
        order: order ?? this.order,
        // A4：派生字段默认保留旧值（与 Task.pinyinInitials 同口径），
        // 由调用方在标题变化时重算。
        pinyinInitials: pinyinInitials ?? this.pinyinInitials,
        pinyinFull: pinyinFull ?? this.pinyinFull,
      );
}
