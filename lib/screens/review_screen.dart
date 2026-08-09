import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/review.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/review_card.dart';
import 'package:todolist/widgets/week_trend.dart';
import 'package:todolist/widgets/review_share_sheet.dart';

/// 回顾周报页：从首页「本周回顾」摘要卡 push 进来。
///
/// 不新增 tab（6→7 会破坏 Material 3 的节奏），也不新增任何存储，
/// 数据在 build 时由三个 Provider 聚合出一份快照。
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final task = context.read<TaskProvider>();
    final focus = context.read<FocusProvider>();
    final habit = context.read<HabitProvider>();
    final r = WeeklyReview.fromProviders(task, focus, habit);

    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: SafeArea(
        child: Column(
          children: [
            TopAppBar(
              title: '本周回顾',
              onBack: () => Navigator.of(context).pop(),
              actions: [
                IconButton(
                  onPressed: () => showReviewShareSheet(context, review: r),
                  icon: Icon(Symbols.ios_share, size: 24, color: onBg),
                  tooltip: '分享周报',
                  splashRadius: 20,
                ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppColors.pagePadX,
                  8,
                  AppColors.pagePadX,
                  24,
                ),
                children: [
                  // 周区间
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: ext.chip,
                      borderRadius: BorderRadius.circular(AppColors.chipRadius),
                    ),
                    child: Text(
                      r.weekRangeLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: onBg,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ReviewSection(child: WeeklyMetrics(r)),
                  const SizedBox(height: 12),
                  ReviewSection(
                    padding: const EdgeInsets.all(10),
                    child: WeekTrend(
                      values: r.trend,
                      dates: r.weekDates,
                      lastWeekValues: r.lastTrend,
                    ),
                  ),
                  const SizedBox(height: 12),
                  WeeklyFocusBlock(r),
                  const SizedBox(height: 12),
                  WeeklyHabitBlock(r),
                  const SizedBox(height: 12),
                  WeeklyCategoryBlock(r),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
