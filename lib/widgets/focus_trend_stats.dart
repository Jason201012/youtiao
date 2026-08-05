import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/trend_chart.dart';

/// 专注趋势：复用统一的 [TrendChart]，把「每日专注时长」按周/月/年画出来，
/// 与专注 Tab 呼应、与任务完成趋势视觉一致。
/// 数据来自 [FocusProvider]（每日专注秒数 → 折算为分钟作图）。
class FocusTrendStats extends StatefulWidget {
  final FocusProvider focus;

  const FocusTrendStats({super.key, required this.focus});

  @override
  State<FocusTrendStats> createState() => _FocusTrendStatsState();
}

class _FocusTrendStatsState extends State<FocusTrendStats> {
  TrendPeriod _period = TrendPeriod.week;

  static const _wk = ['一', '二', '三', '四', '五', '六', '日'];

  static DateTime _d(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 某天（date-only）专注分钟数（四舍五入）。
  int _minOn(DateTime day) => (widget.focus.totalSecOn(day) / 60).round();

  List<DateTime> _lastNDays(int n) {
    final today = _d(DateTime.now());
    return List.generate(n, (i) => today.subtract(Duration(days: n - 1 - i)));
  }

  List<int> _dailyMin(List<DateTime> days) =>
      days.map((d) => _minOn(d)).toList();

  List<DateTime> _monthsOfYear() {
    final now = DateTime.now();
    return List.generate(12, (i) => DateTime(now.year, i + 1, 1));
  }

  List<int> _monthlyMin(List<DateTime> months) {
    final now = DateTime.now();
    return months.map((m) {
      // 当年未到的月份记为 0，避免把未来月份算进来
      if (m.year > now.year || (m.year == now.year && m.month > now.month)) return 0;
      int total = 0;
      final dim = DateTime(m.year, m.month + 1, 0).day;
      for (int d = 1; d <= dim; d++) {
        total += _minOn(DateTime(m.year, m.month, d));
      }
      return total;
    }).toList();
  }

  /// 把分钟数格式化为「X分」或「X时」（≥60 分钟显示小时）。
  static String _fmtDur(int min) {
    if (min >= 60) {
      final h = min / 60;
      return '${h >= 10 ? h.round() : h.toStringAsFixed(1)}时';
    }
    return '$min分';
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final meta = ext.meta;
    final onBg = Theme.of(context).colorScheme.onBackground;
    final focusColor = isDark ? const Color(0xFF80C0FF) : const Color(0xFF4DA3FF);

    late List<int> values;
    late List<String> labels;
    late int highlight;
    List<int>? compare;
    late List<(String, String)> metrics;

    switch (_period) {
      case TrendPeriod.week:
        final days = _lastNDays(7);
        values = _dailyMin(days);
        final prev = days.map((d) => d.subtract(const Duration(days: 7))).toList();
        compare = _dailyMin(prev);
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
          (_fmtDur(total), '本周专注'),
          (_fmtDur((total / 7).round()), '日均'),
          (change == null ? '—' : '${change >= 0 ? '+' : ''}$change%', '较上周'),
          (best, '最佳日'),
        ];
        break;
      case TrendPeriod.month:
        final now = DateTime.now();
        final upTo = now.day;
        final days = List.generate(upTo, (i) => DateTime(now.year, now.month, i + 1));
        values = _dailyMin(days);
        labels = days.map((d) => '${d.day}').toList();
        highlight = values.length - 1;
        final total = values.fold(0, (a, b) => a + b);
        final avg = upTo == 0 ? 0 : (total / upTo).round();
        final maxV = values.isEmpty ? 0 : values.reduce((a, b) => a > b ? a : b);
        final bestIdx = values.indexWhere((v) => v == maxV);
        final best = bestIdx < 0 ? '—' : '${days[bestIdx].day}日';
        metrics = [
          (_fmtDur(total), '本月专注'),
          (_fmtDur(avg), '日均'),
          (best, '最佳日'),
          (_fmtDur((widget.focus.totalSec / 60).round()), '累计'),
        ];
        break;
      case TrendPeriod.year:
        final months = _monthsOfYear();
        values = _monthlyMin(months);
        labels = months.map((m) => '${m.month}月').toList();
        highlight = values.length - 1;
        final total = values.fold(0, (a, b) => a + b);
        final avg = (total / 12).round();
        final maxV = values.reduce((a, b) => a > b ? a : b);
        final bestIdx = values.indexWhere((v) => v == maxV);
        final best = bestIdx < 0 ? '—' : '${months[bestIdx].month}月';
        metrics = [
          (_fmtDur(total), '本年专注'),
          (_fmtDur(avg), '月均'),
          (best, '最佳月'),
          (_fmtDur((widget.focus.totalSec / 60).round()), '累计'),
        ];
        break;
    }

    return TrendChart(
      title: '专注趋势',
      period: _period,
      onPeriod: (p) => setState(() => _period = p),
      hero: _FocusHero(
        todayMin: widget.focus.todayTotalSec ~/ 60,
        totalHours: widget.focus.totalSec / 3600,
        todayTomatoes: widget.focus.todayCompleted,
        color: focusColor,
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

/// 专注 hero：今日专注分钟数为主视觉，副标题给出累计小时与今日番茄数。
class _FocusHero extends StatelessWidget {
  final int todayMin;
  final double totalHours;
  final int todayTomatoes;
  final Color color;
  final Color meta;
  final Color onBg;
  const _FocusHero({
    required this.todayMin,
    required this.totalHours,
    required this.todayTomatoes,
    required this.color,
    required this.meta,
    required this.onBg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Row(
        children: [
          Icon(
            Symbols.timer,
            color: color,
            size: 30,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '今日专注 $todayMin 分钟',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: onBg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '累计 ${totalHours.toStringAsFixed(1)} 小时 · 今日完成 $todayTomatoes 个番茄',
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
