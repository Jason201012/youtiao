/// 一次习惯打卡记录（按「习惯 + 日期」唯一）。
///
/// 仅记录「某习惯在某天打过卡」，不存重复值；取消打卡即删除对应记录。
class CheckIn {
  final String id;
  final String habitId;
  /// date-only（时分秒清零）。
  final DateTime date;

  const CheckIn({
    required this.id,
    required this.habitId,
    required this.date,
  });

  /// 由习惯 id 与日期生成稳定主键（同一天重复打卡不会产生新记录）。
  factory CheckIn.forDay(String habitId, DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return CheckIn(
      id: '$habitId@${_key(d)}',
      habitId: habitId,
      date: d,
    );
  }

  static String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'habitId': habitId,
        'date': date.toIso8601String(),
      };

  factory CheckIn.fromJson(Map<String, dynamic> j) => CheckIn(
        id: j['id'] as String,
        habitId: j['habitId'] as String? ?? '',
        date: j['date'] is String
            ? DateTime.parse(j['date'] as String)
            : DateTime.now(),
      );

  /// date-only 比较用 key。
  static String dateKey(DateTime d) => _key(d);
}
