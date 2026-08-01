import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/completion_ring.dart';
import 'package:todolist/widgets/stat_card.dart';
import 'package:todolist/widgets/category_progress.dart';
import 'package:todolist/widgets/week_trend.dart';

class BoardScreen extends StatelessWidget {
  const BoardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final progressColor = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final today = DateFormat('M月d日').format(DateTime.now());

    return Column(
      children: [
        const TopAppBar(title: '看板'),
        Expanded(
          child: Consumer<TaskProvider>(
            builder: (context, provider, _) {
              final rate = provider.completionRate;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppColors.pagePadX,
                  8,
                  AppColors.pagePadX,
                  20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 今日概览
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppColors.contentGap),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('今日概览',
                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: onBg)),
                          Text(today, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: ext.meta)),
                        ],
                      ),
                    ),
                    // 完成率卡片
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(AppColors.cardRadius),
                      ),
                      child: Row(
                        children: [
                          CompletionRing(value: rate, centerText: '${(rate * 100).round()}%'),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('已完成', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ext.meta)),
                                Text('${provider.completed} / ${provider.total}',
                                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: progressColor)),
                                Text('今日任务完成率', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ext.meta)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // 统计网格 2×2
                    Row(
                      children: [
                        Expanded(
                          child: StatCard(value: '${provider.total}', label: '总任务', valueColor: onBg),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: StatCard(value: '${provider.completed}', label: '已完成', valueColor: progressColor),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: StatCard(value: '${provider.overdue}', label: '逾期', valueColor: AppColors.lightHigh),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: StatCard(value: '${provider.inProgress}', label: '进行中', valueColor: progressColor),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // 分类进度
                    CategoryProgress(progress: provider.categoryProgress()),
                    const SizedBox(height: 24),
                    // 周趋势
                    WeekTrend(
                      values: provider.weekTrend,
                      dates: provider.weekTrendDates,
                      lastWeekValues: provider.lastWeekTrend,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
