import 'package:flutter/material.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/trend_chart.dart';

/// 完成趋势 + 连续打卡：顶部「连续 N 天」hero，下方周期切换（周/月/年）柱状图 + 汇总指标。
/// 渲染委托给统一的 [TrendChart]（与专注趋势共用同一套视觉）。
/// 数据由 [TaskProvider.currentStreak]/[TaskProvider.longestStreak] 与传入的 [tasks] 计算。
class TrendStats extends StatefulWidget {
  final List<Task> tasks;
  final int currentStreak;
  final int longestStreak;

  const TrendStats({
    super.key,
    required this.tasks,
    required this.currentStreak,
    required this.longestStreak,
  });

  @override
  State<TrendStats> createState() => _TrendStatsState();
}

class _TrendStatsState extends State<TrendStats> {
  TrendPeriod _period = TrendPeriod.week;

  static const _wk = ['一', '二', '三', '四', '五', '六', '日'];

  static DateTime _d(DateTime d) => DateTime(d.year, d.month, d.day);

  List<DateTime> _lastNDays(int n) {
    final today = _d(DateTime.now());
    return List.generate(n, (i) => today.subtract(Duration(days: n - 1 - i)));
  }

  List<int> _dailyCounts(List<DateTime> days) {
    final counts = List.filled(days.length, 0);
    for (final t in widget.tasks) {
      if (!t.done || t.completedAt == null) continue;
      final idx = days.indexWhere((x) => x.isAtSameMomentAs(_d(t.completedAt!)));
      if (idx != -1) counts[idx]++;
    }
    return counts;
  }

  List<DateTime> _monthsOfYear() {
    final now = DateTime.now();
    return List.generate(12, (i) => DateTime(now.year, i + 1, 1));
  }

  List<int> _monthlyCounts(List<DateTime> months) {
    final counts = List.filled(months.length, 0);
    for (final t in widget.tasks) {
      if (!t.done || t.completedAt == null) continue;
      final d = t.completedAt!;
      final idx = months.indexWhere((m) => m.year == d.year && m.month == d.month);
      if (idx != -1) counts[idx]++;
    }
    return counts;
  }

  int get _todayCount {
    final today = _d(DateTime.now());
    int n = 0;
    for (final t in widget.tasks) {
      if (t.done && t.completedAt != null && _d(t.completedAt!) == today) n++;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final meta = ext.meta;
    final onBg = Theme.of(context).colorScheme.onBackground;

    late List<int> values;
    late List<String> labels;
    late int highlight;
    List<int>? compare;
    late List<(String, String)> metrics;

    switch (_period) {
      case TrendPeriod.week:
        final days = _lastNDays(7);
        values = _dailyCounts(days);
        final prev = days.map((d) => d.subtract(const Duration(days: 7))).toList();
        compare = _dailyCounts(prev);
        labels = days.map((d) => _wk[d.weekday - 1]).toList();
        highlight = values.length - 1;
        final total = values.fold(0, (a, b) => a + b);
        final lastTotal = compare.fold(0, (a, b) => a + b);
        final change = lastTotal == 0
            ? null
            : (((total - lastTotal) / lastTotal) * 100).round();
        final maxV = values.reduce((a, b) => a > b ? a : b);
        final bestIdx = values.indexWhere((v) => v == maxV);
        final best = bestIdx < 0 ? '—' : '周${_wk[days[bestIdx].weekday - 1]}';
        metrics = [
          ('$total', '本周完成'),
          (total == 0 ? '0.0' : (total / 7).toStringAsFixed(1), '日均'),
          (change == null ? '—' : '${change >= 0 ? '+' : ''}$change%', '较上周'),
          (best, '最佳日'),
        ];
        break;
      case TrendPeriod.month:
        final now = DateTime.now();
        final upTo = now.day;
        final days = List.generate(upTo, (i) => DateTime(now.year, now.month, i + 1));
        values = _dailyCounts(days);
        labels = days.map((d) => '${d.day}').toList();
        highlight = values.length - 1;
        final total = values.fold(0, (a, b) => a + b);
        final avg = upTo == 0 ? 0.0 : total / upTo;
        final maxV = values.isEmpty ? 0 : values.reduce((a, b) => a > b ? a : b);
        final bestIdx = values.indexWhere((v) => v == maxV);
        final best = bestIdx < 0 ? '—' : '${days[bestIdx].day}日';
        metrics = [
          ('$total', '本月完成'),
          (avg.toStringAsFixed(1), '日均'),
          (best, '最佳日'),
          ('${widget.longestStreak}', '最长连续'),
        ];
        break;
      case TrendPeriod.year:
        final months = _monthsOfYear();
        values = _monthlyCounts(months);
        labels = months.map((m) => '${m.month}月').toList();
        highlight = values.length - 1;
        final total = values.fold(0, (a, b) => a + b);
        final avg = total / 12;
        final maxV = values.reduce((a, b) => a > b ? a : b);
        final bestIdx = values.indexWhere((v) => v == maxV);
        final best = bestIdx < 0 ? '—' : '${months[bestIdx].month}月';
        metrics = [
          ('$total', '本年完成'),
          (avg.toStringAsFixed(1), '月均'),
          (best, '最佳月'),
          ('${widget.longestStreak}', '最长连续'),
        ];
        break;
    }

    return TrendChart(
      title: '完成趋势',
      period: _period,
      onPeriod: (p) => setState(() => _period = p),
      hero: _StreakHero(
        current: widget.currentStreak,
        longest: widget.longestStreak,
        todayCount: _todayCount,
        fill: fill,
        meta: meta,
        onBg: onBg,
      ),
      values: values,
      labels: labels,
      highlight: highlight,
      compare: compare,
      metrics: metrics,
    );
  }
}

class _StreakHero extends StatelessWidget {
  final int current;
  final int longest;
  final int todayCount;
  final Color fill;
  final Color meta;
  final Color onBg;
  const _StreakHero({
    required this.current,
    required this.longest,
    required this.todayCount,
    required this.fill,
    required this.meta,
    required this.onBg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fill.withOpacity(0.10),
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Row(
        children: [
          Icon(
            Icons.local_fire_department,
            color: const Color(0xFFFF7043),
            size: 30,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '连续打卡 $current 天',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: onBg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '最长 $longest 天 · 今日完成 $todayCount 项',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: meta,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
