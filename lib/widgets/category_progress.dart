import 'package:flutter/material.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 分类进度区：标题 + 3 行（分类头 + 进度条）。
class CategoryProgress extends StatelessWidget {
  final Map<Category, double> progress;
  const CategoryProgress({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('分类', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        for (final c in Category.values)
          _CategoryRow(name: c.label, ratio: progress[c] ?? 0),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final String name;
  final double ratio;
  const _CategoryRow({required this.name, required this.ratio});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? AppColors.darkAccent : AppColors.lightPrimary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: onBg)),
              Text('${(ratio * 100).round()}%',
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
                  color: fill,
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
