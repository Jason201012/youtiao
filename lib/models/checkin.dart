/// 一次习惯打卡记录（按「习惯 + 日期」唯一）。
///
/// 记录「某习惯在某天打了多少」：布尔习惯的 [value] 恒为 1（存在记录 = 打过卡），
/// T1-2 起的量化习惯（「每天 8 杯水」）由 [value] 承载当日累计量，
/// 达成与否用 [Habit.dailyTarget] 比对。累计量降到 0 即删除对应记录（撤卡）。
class CheckIn {
  final String id;
  final String habitId;
  /// date-only（时分秒清零）。
  final DateTime date;

  /// 当日累计量（T1-2，≥1）。布尔习惯恒为 1；量化习惯为「今天做了多少个单位」。
  /// 旧数据缺省 1（向后兼容，零迁移）。
  final int value;

  const CheckIn({
    required this.id,
    required this.habitId,
    required this.date,
    this.value = 1,
  });

  /// 由习惯 id 与日期生成稳定主键（同一天重复打卡不会产生新记录）。
  factory CheckIn.forDay(String habitId, DateTime day, {int value = 1}) {
    final d = DateTime(day.year, day.month, day.day);
    return CheckIn(
      id: '$habitId@${_key(d)}',
      habitId: habitId,
      date: d,
      value: value < 1 ? 1 : value,
    );
  }

  static String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 复制并覆盖累计量（用于「+1 / 设置数量」）。
  CheckIn withValue(int v) => CheckIn(
        id: id,
        habitId: habitId,
        date: date,
        value: v < 1 ? 1 : v,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'habitId': habitId,
        'date': date.toIso8601String(),
        'value': value,
      };

  factory CheckIn.fromJson(Map<String, dynamic> j) => CheckIn(
        id: j['id'] as String,
        habitId: j['habitId'] as String? ?? '',
        date: j['date'] is String
            ? DateTime.parse(j['date'] as String)
            : DateTime.now(),
        // 旧记录无 value → 1（布尔打卡语义）；非法 / 小于 1 的脏值同样夹到 1。
        value: ((j['value'] as num?)?.toInt() ?? 1).clamp(1, 9999),
      );

  /// date-only 比较用 key。
  static String dateKey(DateTime d) => _key(d);
}
