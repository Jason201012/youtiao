import 'package:flutter/material.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 优先级分布：高/中/低三条进度条，展示未完成任务在各优先级的占比。
/// [counts] 来自 TaskProvider.priorityCounts（仅统计未完成任务）。
class PriorityDistribution extends StatelessWidget {
  final Map<Priority, int> counts;
  const PriorityDistribution({super.key, required this.counts});

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    const order = [Priority.high, Priority.medium, Priority.low];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('优先级',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: onBg)),
        const SizedBox(height: 12),
        for (final p in order)
          _PriorityRow(
            label: p == Priority.high ? '高' : p == Priority.medium ? '中' : '低',
            count: counts[p] ?? 0,
            ratio: total == 0 ? 0 : (counts[p] ?? 0) / total,
            color: isDark ? p.darkColor() : p.lightColor(),
          ),
      ],
    );
  }
}

class _PriorityRow extends StatelessWidget {
  final String label;
  final int count;
  final double ratio;
  final Color color;
  const _PriorityRow({
    required this.label,
    required this.count,
    required this.ratio,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: onBg)),
              Text('$count',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ext.meta)),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: 8,
            decoration: BoxDecoration(
              color: ext.track,
              borderRadius: BorderRadius.circular(AppColors.progressRadius),
            ),
            child: FractionallySizedBox(
              widthFactor: ratio.clamp(0, 1),
              alignment: Alignment.centerLeft,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(AppColors.progressRadius),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
