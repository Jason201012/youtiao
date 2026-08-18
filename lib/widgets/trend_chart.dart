import 'package:flutter/material.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 趋势图周期：周 / 月 / 年。
/// 抽成公共枚举，供任务完成趋势（[TrendStats]）与专注趋势（[FocusTrendStats]）共用。
enum TrendPeriod { week, month, year }

/// 通用趋势图表：顶部可选 hero + 标题与周期切换 + 柱状图（支持上一周期对比）+ 汇总指标。
/// 设计为「受控组件」——周期状态由父组件持有，数据（values/labels/metrics）由父组件按周期算好后传入，
/// 从而让任务趋势与专注趋势复用同一套视觉与交互，体验保持一致。
class TrendChart extends StatelessWidget {
  /// 图表标题，如「完成趋势」「专注趋势」。
  final String title;

  /// 柱状图顶部的主视觉卡片（如连续打卡 hero、今日专注 hero），可为空。
  final Widget? hero;

  /// 每个柱子代表的值（整数，单位由调用方约定：任务数为「项」、专注为「分钟」）。
  final List<int> values;

  /// 柱子下方的标签（周为「一二三四五六日」、月/年为「1日」/「1月」等）。
  final List<String> labels;

  /// 高亮柱索引（通常为最新一天/月），用更亮的填充色。
  final int highlight;

  /// 上一周期的同维度值（用于画对比柱），可为空表示不画对比。
  final List<int>? compare;

  /// 底部汇总指标：(值, 标签) 列表，建议 4 项均分一行。
  final List<(String, String)> metrics;

  /// 当前周期（受控）。
  final TrendPeriod period;

  /// 周期切换回调（受控）。
  final ValueChanged<TrendPeriod> onPeriod;

  const TrendChart({
    super.key,
    required this.title,
    this.hero,
    required this.values,
    required this.labels,
    required this.highlight,
    this.compare,
    required this.metrics,
    required this.period,
    required this.onPeriod,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final todayFill = isDark ? const Color(0xFF80C0FF) : const Color(0xFF4DA3FF);
    final chipBg = isDark ? AppColors.darkChip : AppColors.lightChip;
    final meta = ext.meta;
    final onBg = Theme.of(context).colorScheme.onBackground;

    final maxV = values.reduce((a, b) => a > b ? a : b);
    final cmpMax = compare == null ? 0 : compare!.reduce((a, b) => a > b ? a : b);
    final scaleMax = (maxV == 0 && cmpMax == 0) ? 1 : (maxV > cmpMax ? maxV : cmpMax);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hero != null) ...[
          hero!,
          const SizedBox(height: 16),
        ],
        // 标题 + 周期切换
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: onBg),
            ),
            _TrendSegmented(
              value: period,
              onChanged: onPeriod,
              chipBg: chipBg,
              fill: fill,
              onBg: onBg,
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 柱状图：每根柱用 Expanded 均分可用宽度并铺满整行，消除右侧留白
        SizedBox(
          height: 96,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (int i = 0; i < values.length; i++)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        '${values[i]}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: i == highlight ? todayFill : fill,
                        ),
                      ),
                      const SizedBox(height: 3),
                      LayoutBuilder(
                        builder: (c2, bc) {
                          final barW = (bc.maxWidth - 8).clamp(4.0, 30.0);
                          return SizedBox(
                            width: bc.maxWidth,
                            height: 56,
                            child: Stack(
                              alignment: Alignment.bottomCenter,
                              children: [
                                if (compare != null)
                                  Container(
                                    width: barW,
                                    height: (compare![i] / scaleMax) * 56,
                                    decoration: BoxDecoration(
                                      color: meta.withOpacity(0.22),
                                      borderRadius:
                                          BorderRadius.circular(AppColors.progressRadius),
                                    ),
                                  ),
                                Container(
                                  width: barW,
                                  height: (values[i] / scaleMax) * 56,
                                  decoration: BoxDecoration(
                                    color: i == highlight ? todayFill : fill,
                                    borderRadius:
                                        BorderRadius.circular(AppColors.progressRadius),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        child: Text(
                          labels[i],
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: meta,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 汇总指标
        Row(
          children: [
            for (final m in metrics)
              Expanded(
                child: TrendMetric(value: m.$1, label: m.$2, valueColor: onBg, meta: meta),
              ),
          ],
        ),
      ],
    );
  }
}

/// 周期分段切换器（周 / 月 / 年），与任务趋势同源。
class _TrendSegmented extends StatelessWidget {
  final TrendPeriod value;
  final ValueChanged<TrendPeriod> onChanged;
  final Color chipBg;
  final Color fill;
  final Color onBg;
  const _TrendSegmented({
    required this.value,
    required this.onChanged,
    required this.chipBg,
    required this.fill,
    required this.onBg,
  });

  @override
  Widget build(BuildContext context) {
    const items = [
      ('周', TrendPeriod.week),
      ('月', TrendPeriod.month),
      ('年', TrendPeriod.year),
    ];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(AppColors.chipRadius),
      ),
      child: Row(
        children: [
          for (final it in items)
            GestureDetector(
              onTap: () => onChanged(it.$2),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: value == it.$2 ? fill : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Text(
                  it.$1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: value == it.$2 ? Colors.white : onBg,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单个汇总指标（值 + 标签），供趋势图表底部均分一行使用。
class TrendMetric extends StatelessWidget {
  final String value;
  final String label;
  final Color valueColor;
  final Color meta;
  const TrendMetric({
    super.key,
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
