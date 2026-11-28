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

  /// P2-4（v3.2.0 审计）：写入这条打卡时的**每日目标快照**。
  ///
  /// 旧实现用「当前习惯目标」判定所有历史打卡：把每日目标从 8 提到 12，
  /// 连续 100 天的历史成就瞬间归零。快照让历史按当时的规则保真；旧数据
  /// 缺省 null → 回退当前目标（零迁移，行为与升级前一致）。
  final int? targetAtWrite;

  const CheckIn({
    required this.id,
    required this.habitId,
    required this.date,
    this.value = 1,
    this.targetAtWrite,
  });

  /// 本条打卡是否达到 [target]。
  ///
  /// 目标由调用方（HabitProvider._targetFor）统一裁决：历史日用快照、今天用
  /// 当前目标。这里不再自行消费快照，避免「传入新目标仍被旧快照覆盖」导致
  /// 调高目标后今天的提醒不恢复。
  bool metBy(int target) => value >= target;

  /// 由习惯 id 与日期生成稳定主键（同一天重复打卡不会产生新记录）。
  factory CheckIn.forDay(String habitId, DateTime day,
      {int value = 1, int? target}) {
    final d = DateTime(day.year, day.month, day.day);
    return CheckIn(
      id: '$habitId@${_key(d)}',
      habitId: habitId,
      date: d,
      value: value < 1 ? 1 : value,
      targetAtWrite: target,
    );
  }

  static String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 复制并覆盖累计量（用于「+1 / 设置数量」）。
  /// P2-4：[target] 非空时一并刷新快照——用户显式重设历史日的值，
  /// 等于按当前规则重新认定这一天。
  CheckIn withValue(int v, {int? target}) => CheckIn(
        id: id,
        habitId: habitId,
        date: date,
        value: v < 1 ? 1 : v,
        targetAtWrite: target ?? targetAtWrite,
      );

  /// N-P2-3（v3.2.1 审计）：只补写目标快照（存量记录回填用），不动累计量。
  ///
  /// 与 [withValue] 的区别：后者是「用户重设了这一天」的语义，会顺带改 value；
  /// 回填只补缺失的快照，绝不能碰用户已经记下的量。
  CheckIn withTargetSnapshot(int target) => CheckIn(
        id: id,
        habitId: habitId,
        date: date,
        value: value,
        targetAtWrite: target,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'habitId': habitId,
        'date': date.toIso8601String(),
        'value': value,
        'targetAtWrite': targetAtWrite,
      };

  factory CheckIn.fromJson(Map<String, dynamic> j) => CheckIn(
        id: j['id'] as String,
        habitId: j['habitId'] as String? ?? '',
        date: j['date'] is String
            ? DateTime.parse(j['date'] as String)
            : DateTime.now(),
        // 旧记录无 value → 1（布尔打卡语义）；非法 / 小于 1 的脏值同样夹到 1。
        value: ((j['value'] as num?)?.toInt() ?? 1).clamp(1, 9999),
        // P2-4：备份是不可信输入，快照非法 / 越界一律按「无快照」处理，
        // 回退当前目标（与旧数据零迁移路径同态）。
        targetAtWrite: _clampSnapshot(j['targetAtWrite']),
      );

  static int? _clampSnapshot(dynamic v) {
    if (v is! num) return null;
    final n = v.toInt();
    if (n < 1 || n > 9999) return null;
    return n;
  }

  /// date-only 比较用 key。
  static String dateKey(DateTime d) => _key(d);
}
