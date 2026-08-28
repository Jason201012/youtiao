import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/period_review.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/models/review_narrative.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/review_card.dart';
import 'package:todolist/widgets/period_review_card.dart';
import 'package:todolist/widgets/review_share_sheet.dart';

/// 月报 / 年报页：从首页「回顾」入口 push 进来。
///
/// 不新增 tab（6 个已是 Material 3 上限）、不新增任何存储，数据在 build 时由三个
/// Provider 聚合出一份快照。支持月报 / 年报切换 + 左右翻页（未来周期禁用前进）。
class PeriodReviewScreen extends StatefulWidget {
  const PeriodReviewScreen({super.key});

  @override
  State<PeriodReviewScreen> createState() => _PeriodReviewScreenState();
}

class _PeriodReviewScreenState extends State<PeriodReviewScreen> {
  ReviewPeriod _period = ReviewPeriod.month;
  DateTime _anchor = DateTime.now();

  /// 是否可以继续前进（翻到下一周期）：锚点已达当前周期首日则禁用。
  bool get _canForward {
    final now = DateTime.now();
    final currentStart = _period == ReviewPeriod.month
        ? DateTime(now.year, now.month, 1)
        : (_period == ReviewPeriod.year
            ? DateTime(now.year, 1, 1)
            : PeriodReview.semesterStartOf(now));
    return _anchor.isBefore(currentStart);
  }

  void _shift(int delta) {
    setState(() => _anchor = PeriodReview.shiftAnchor(_period, _anchor, delta));
  }

  void _setPeriod(ReviewPeriod p) {
    if (p == _period) return;
    setState(() {
      _period = p;
      _anchor = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final task = context.read<TaskProvider>();
    final focus = context.read<FocusProvider>();
    final habit = context.read<HabitProvider>();
    final r = PeriodReview.fromProviders(
      task,
      focus,
      habit,
      period: _period,
      anchor: _anchor,
    );

    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: SafeArea(
        child: Column(
          children: [
            TopAppBar(
              title: r.title,
              onBack: () => Navigator.of(context).pop(),
              actions: [
                IconButton(
                  onPressed: () =>
                      showPeriodReviewShareSheet(context, review: r),
                  icon: Icon(Symbols.ios_share, size: 24, color: onBg),
                  tooltip: '分享${_period.label}',
                  splashRadius: 20,
                ),
              ],
            ),
            // 控制行：上一周期 / 月报·年报切换 / 下一周期
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppColors.pagePadX, 4, AppColors.pagePadX, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => _shift(-1),
                    icon: Icon(Symbols.chevron_left, size: 22, color: onBg),
                    tooltip: '上一${_period.label}',
                    splashRadius: 18,
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<ReviewPeriod>(
                    segments: const [
                      ButtonSegment(
                          value: ReviewPeriod.month, label: Text('月报')),
                      ButtonSegment(
                          value: ReviewPeriod.year, label: Text('年报')),
                      ButtonSegment(
                          value: ReviewPeriod.semester, label: Text('学期报')),
                    ],
                    selected: {_period},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => _setPeriod(s.first),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _canForward ? () => _shift(1) : null,
                    icon: Icon(Symbols.chevron_right, size: 22, color: onBg),
                    tooltip: '下一${_period.label}',
                    splashRadius: 18,
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppColors.pagePadX,
                  4,
                  AppColors.pagePadX,
                  24,
                ),
                children: [
                  // 区间胶囊
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: ext.chip,
                      borderRadius: BorderRadius.circular(AppColors.chipRadius),
                    ),
                    child: Text(
                      r.rangeLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: onBg,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  NarrativeCard(text: buildPeriodNarrative(r)),
                  const SizedBox(height: 12),
                  ReviewSection(child: PeriodMetrics(r)),
                  const SizedBox(height: 12),
                  ReviewSection(
                    padding: const EdgeInsets.all(10),
                    child: PeriodTrend(r),
                  ),
                  const SizedBox(height: 12),
                  PeriodFocusBlock(r),
                  const SizedBox(height: 12),
                  PeriodHabitBlock(r),
                  const SizedBox(height: 12),
                  PeriodCategoryBlock(r),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
