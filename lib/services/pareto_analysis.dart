/// 帕累托（80/20）分析：把若干 (标签, 数值) 项按数值降序，计算各自的占比与累计占比，
/// 并找出「关键的少数」——累计达到 [threshold]（默认 80%）所需的项数。
///
/// 纯函数、零 Flutter 依赖，便于单测与复用（回顾页、统计页均可调用）。
class ParetoItem {
  /// 项标签（如分类名「工作」/任务标题）。
  final String label;

  /// 项原始数值（如专注秒数）。
  final int value;

  /// 该项占总量的比例 0..1。
  final double share;

  /// 降序排列下的累计占比 0..1。
  final double cumulative;

  const ParetoItem({
    required this.label,
    required this.value,
    required this.share,
    required this.cumulative,
  });
}

class ParetoResult {
  /// 已按 value 降序排列的明细。
  final List<ParetoItem> items;

  /// 有效数值总和（剔除 <=0 的条目后）。
  final int total;

  /// 达到 [threshold] 所需的项数（若始终不到阈值则为全部项数）。
  final int vitalFewCount;

  /// 以上切点处的累计占比 0..1。
  final double vitalFewShare;

  /// 是否至少有 1 个有效项。
  final bool hasData;

  const ParetoResult({
    required this.items,
    required this.total,
    required this.vitalFewCount,
    required this.vitalFewShare,
    required this.hasData,
  });

  /// [raw] 为 (标签, 数值) 列表；数值 <= 0 的条目被忽略。
  /// [threshold] 关键少数阈值，默认 0.8（即经典 80/20 分析）。
  static ParetoResult compute(
    List<(String, int)> raw, {
    double threshold = 0.8,
  }) {
    final positive = raw.where((e) => e.$2 > 0).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final total = positive.fold<int>(0, (s, e) => s + e.$2);
    if (total <= 0) {
      return const ParetoResult(
        items: [],
        total: 0,
        vitalFewCount: 0,
        vitalFewShare: 0,
        hasData: false,
      );
    }
    final items = <ParetoItem>[];
    double cum = 0;
    int vitalFew = positive.length;
    double vitalShare = 1.0;
    bool found = false;
    for (int i = 0; i < positive.length; i++) {
      final share = positive[i].$2 / total;
      cum += share;
      items.add(ParetoItem(
        label: positive[i].$1,
        value: positive[i].$2,
        share: share,
        cumulative: cum,
      ));
      if (!found && cum >= threshold) {
        vitalFew = i + 1;
        vitalShare = cum;
        found = true;
      }
    }
    return ParetoResult(
      items: items,
      total: total,
      vitalFewCount: vitalFew,
      vitalFewShare: vitalShare,
      hasData: true,
    );
  }

  /// 头部单一项是否独自占据 80% 以上（典型的「单点压倒性」投入结构）。
  bool get isDominant =>
      hasData && items.isNotEmpty && items.first.share >= 0.8;
}
