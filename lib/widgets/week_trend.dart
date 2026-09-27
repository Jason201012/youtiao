import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 周趋势：标题 + 本周总数胶囊 + 日期区间 + 7 柱（底部对齐，今天高亮）+ 星期标签 + 4 项汇总。
/// 数据由 TaskProvider.weekTrend / weekTrendDates / lastWeekTrend 提供。
class WeekTrend extends StatelessWidget {
  final List<int> values;
  final List<DateTime> dates;
  final List<int> lastWeekValues;
  const WeekTrend({
    super.key,
    required this.values,
    required this.dates,
    required this.lastWeekValues,
  });

  static const _wk = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    // 新U3-5（v2.9.7 审计）：今日高亮改由主题色派生（实心柱 → 55% 透明、
    // 计数数字 → 实色 primary），替代硬编码 0xFF4DA3FF / 0xFF80C0FF——
    // 不随用户自定义主题色，偏离纯黑白设计偏好。
    final primary = Theme.of(context).colorScheme.primary;
    final todayBarFill = primary.withValues(alpha: 0.55);
    final chipBg = isDark ? AppColors.darkChip : AppColors.lightChip;
    final meta = ext.meta;
    final onBg = Theme.of(context).colorScheme.onBackground;

    final max = values.isEmpty ? 1 : values.reduce((a, b) => a > b ? a : b);
    final total = values.fold<int>(0, (a, b) => a + b);
    final avg = values.isEmpty ? 0.0 : total / values.length;
    final lastTotal = lastWeekValues.fold<int>(0, (a, b) => a + b);
    final change =
        lastTotal == 0 ? null : ((total - lastTotal) / lastTotal * 100).round();
    final bestIndex = values.isEmpty ? -1 : values.indexWhere((v) => v == max);
    final bestDay = bestIndex == -1
        ? '—'
        : '周${_wk[dates[bestIndex].weekday - 1]}';

    final dateFmt = DateFormat('M月d日');
    final dateRange = dates.isEmpty
        ? ''
        : '${dateFmt.format(dates.first)} – ${dateFmt.format(dates.last)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头部：标题 + 本周总数胶囊
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '近 7 日完成趋势',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: onBg,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: chipBg,
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
              ),
              child: Text(
                '本周 $total',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 日期区间
        Text(
          dateRange,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: meta,
          ),
        ),
        const SizedBox(height: 12),
        // 柱状图：本周实色柱 + 上周同期淡色柱（同一刻度对比），每根柱上方显示当天完成数
        SizedBox(
          height: 74,
          child: Builder(builder: (context) {
            final lastMax = lastWeekValues.isEmpty
                ? 0
                : lastWeekValues.reduce((a, b) => a > b ? a : b);
            final scaleMax = (max == 0 && lastMax == 0) ? 1 : (max > lastMax ? max : lastMax);
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int i = 0; i < values.length; i++)
                  Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        '${values[i]}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: i == values.length - 1 ? primary : fill,
                        ),
                      ),
                      const SizedBox(height: 3),
                      SizedBox(
                        width: 40,
                        height: 56,
                        child: Stack(
                          alignment: Alignment.bottomCenter,
                          children: [
                            // 上周同期（淡）
                            Container(
                              width: 40,
                              height: (lastWeekValues[i] / scaleMax) * 56,
                              decoration: BoxDecoration(
                                color: meta.withOpacity(0.22),
                                borderRadius:
                                    BorderRadius.circular(AppColors.progressRadius),
                              ),
                            ),
                            // 本周（实色，略窄以便对比）
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 7),
                              child: Container(
                                width: 26,
                                height: (values[i] / scaleMax) * 56,
                                decoration: BoxDecoration(
                                  color:
                                      i == values.length - 1 ? todayBarFill : fill,
                                  borderRadius:
                                      BorderRadius.circular(AppColors.progressRadius),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            );
          }),
        ),
        const SizedBox(height: 8),
        // 星期标签
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final d in dates)
              SizedBox(
                width: 40,
                child: Text(
                  _wk[d.weekday - 1],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: meta,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        // 汇总指标：本周完成 / 日均 / 较上周 / 最佳日
        Row(
          children: [
            _Metric(value: '$total', label: '本周完成', valueColor: onBg, meta: meta),
            _Metric(
              value: avg.toStringAsFixed(1),
              label: '日均',
              valueColor: onBg,
              meta: meta,
            ),
            _Metric(
              value: change == null ? '—' : '${change >= 0 ? '+' : ''}$change%',
              label: '较上周',
              valueColor: change == null || change < 0 ? onBg : fill,
              meta: meta,
            ),
            _Metric(value: bestDay, label: '最佳日', valueColor: onBg, meta: meta),
          ],
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String value;
  final String label;
  final Color valueColor;
  final Color meta;
  const _Metric({
    required this.value,
    required this.label,
    required this.valueColor,
    required this.meta,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: valueColor,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: meta,
            ),
          ),
        ],
      ),
    );
  }
}
