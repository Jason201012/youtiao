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
  final DateTime createdAt;
  final bool archived;

  const Habit({
    required this.id,
    required this.title,
    this.emoji = '✅',
    this.colorValue = 0xFF0061A4,
    this.weekdays = const [],
    required this.createdAt,
    this.archived = false,
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
        'createdAt': createdAt.toIso8601String(),
        'archived': archived,
      };

  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '✅',
        colorValue: j['color'] as int? ?? 0xFF0061A4,
        weekdays: (j['weekdays'] as List?)?.map((e) => e as int).toList() ?? [],
        createdAt: j['createdAt'] is String
            ? DateTime.parse(j['createdAt'] as String)
            : DateTime.now(),
        archived: j['archived'] as bool? ?? false,
      );

  Habit copyWith({
    String? title,
    String? emoji,
    int? colorValue,
    List<int>? weekdays,
    bool? archived,
  }) =>
      Habit(
        id: id,
        title: title ?? this.title,
        emoji: emoji ?? this.emoji,
        colorValue: colorValue ?? this.colorValue,
        weekdays: weekdays ?? this.weekdays,
        createdAt: createdAt,
        archived: archived ?? this.archived,
      );
}
