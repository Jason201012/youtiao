import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/completion_ring.dart';
import 'package:todolist/widgets/stat_card.dart';
import 'package:todolist/widgets/category_progress.dart';
import 'package:todolist/widgets/trend_stats.dart';
import 'package:todolist/widgets/priority_distribution.dart';
import 'package:todolist/widgets/guard_status_card.dart';
import 'package:todolist/widgets/kanban_board.dart';
import 'package:todolist/widgets/share_sheet.dart';

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
        TopAppBar(
          title: '看板',
          actions: [
            // 分享：把看板数据生成一张长图，可保存到相册或直接分享
            IconButton(
              onPressed: () => showShareSheet(context),
              icon: Icon(Symbols.ios_share, size: 24, color: onBg),
              tooltip: '分享看板',
              splashRadius: 20,
            ),
          ],
        ),
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
                    // 概览（标题改为「概览」，统计为全局口径，与数字一致）
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppColors.contentGap),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('概览',
                              style: TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold, color: onBg)),
                          Text(today,
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: ext.meta)),
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
                          CompletionRing(
                              value: rate, centerText: '${(rate * 100).round()}%'),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('已完成',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: ext.meta)),
                                Text('${provider.completed} / ${provider.total}',
                                    style: TextStyle(
                                        fontSize: 30,
                                        fontWeight: FontWeight.bold,
                                        color: progressColor)),
                                Text('任务完成率',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: ext.meta)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // 后台提醒守护状态卡
                    GuardStatusCard(enabled: provider.backgroundGuardEnabled),
                    const SizedBox(height: AppColors.contentGap),
                    // 统计网格 2×2（可点击跳首页筛选）
                    Row(
                      children: [
                        Expanded(
                          child: StatCard(
                            value: '${provider.total}',
                            label: '总任务',
                            valueColor: onBg,
                            onTap: () =>
                                provider.requestHomeWithFilter(TaskFilter.all),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: StatCard(
                            value: '${provider.completed}',
                            label: '已完成',
                            valueColor: progressColor,
                            onTap: () =>
                                provider.requestHomeWithFilter(TaskFilter.done),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: StatCard(
                            value: '${provider.overdue}',
                            label: '逾期',
                            valueColor: AppColors.lightHigh,
                            onTap: () =>
                                provider.requestHomeWithFilter(TaskFilter.overdue),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: StatCard(
                            value: '${provider.inProgress}',
                            label: '进行中',
                            valueColor: progressColor,
                            onTap: () =>
                                provider.requestHomeWithFilter(TaskFilter.doing),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // 优先级分布
                    PriorityDistribution(counts: provider.priorityCounts),
                    const SizedBox(height: 24),
                    // 分类进度
                    CategoryProgress(progress: provider.categoryProgress()),
                    const SizedBox(height: 24),
                    // 完成趋势 + 连续打卡（周/月/年 + streak）
                    TrendStats(
                      tasks: provider.tasks,
                      currentStreak: provider.currentStreak,
                      longestStreak: provider.longestStreak,
                    ),
                    const SizedBox(height: 24),
                    // 看板三列（拖拽 / 点击切换状态）
                    const KanbanBoard(),
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
