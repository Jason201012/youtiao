import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/period_review.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/stat_card.dart';
import 'package:todolist/widgets/review_card.dart';
import 'package:todolist/widgets/category_progress.dart';

/// 月报 / 年报的板块组件集合。
///
/// 视觉语言与 [review_card.dart] 的周报板块完全对齐：统一用 [ReviewSection]
/// 外壳（surface + 圆角 14）、复用 [FocusRankRow] / [HabitProgressRow] 行组件、
/// 复用 [CategoryProgress] 分类分布。区别仅在趋势桶的粒度（月报按天 / 年报按月）
/// 以及指标卡带上「环比」。

/// 4 连指标 + 环比：本月完成 / 专注(分) / 番茄数 / 习惯达成，下方一行环比胶囊。
class PeriodMetrics extends StatelessWidget {
  final PeriodReview r;
  const PeriodMetrics(this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final onBg = Theme.of(context).colorScheme.onBackground;
    final u = r.period.unitLabel; // 本月 / 本年

    final habitPct = r.habitPercent;
    final habitColor = habitPct >= 80
        ? const Color(0xFF0F6E56)
        : (habitPct >= 50 ? accent : ext.meta);

    final items = [
      _Metric(value: '${r.completedCount}', label: '$u完成', color: accent),
      _Metric(value: '${r.focusMinutes}', label: '专注(分)', color: accent),
      _Metric(value: '${r.pomodoroCount}', label: '番茄数', color: accent),
      _Metric(value: '$habitPct%', label: '习惯达成', color: habitColor),
    ];

    Color deltaColor(int d) {
      if (d > 0) return const Color(0xFF0F6E56);
      if (d < 0) return isDark ? AppColors.darkHigh : AppColors.lightHigh;
      return ext.meta;
    }

    final String focusDeltaText;
    final fd = r.focusMinutesDelta;
    if (fd == 0) {
      focusDeltaText = '与${r.period.prevLabel}持平';
    } else {
      focusDeltaText = '较${r.period.prevLabel} ${fd > 0 ? '+' : ''}${fd}分';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.7,
          children: [
            for (final it in items)
              StatCard(value: it.value, label: it.label, valueColor: it.color),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _DeltaChip(
              label: r.completedDeltaLabel,
              color: deltaColor(r.completedDelta),
            ),
            _DeltaChip(label: focusDeltaText, color: deltaColor(fd)),
          ],
        ),
      ],
    );
  }
}

class _Metric {
  final String value;
  final String label;
  final Color color;
  const _Metric({required this.value, required this.label, required this.color});
}

class _DeltaChip extends StatelessWidget {
  final String label;
  final Color color;
  const _DeltaChip({required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.chipRadius),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 区间趋势柱状图：月报按天（最多 31 柱）/ 年报按月（12 柱）。
/// 与周报 [WeekTrend] 同一视觉，但无「上周同期」对比（周期模型只存当前周期桶），
/// 标签按月报稀疏化、年报全显，最高产桶高亮。
class PeriodTrend extends StatelessWidget {
  final PeriodReview r;
  const PeriodTrend(this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final bestFill =
        isDark ? const Color(0xFF80C0FF) : const Color(0xFF4DA3FF);
    final chipBg = isDark ? AppColors.darkChip : AppColors.lightChip;
    final meta = ext.meta;
    final onBg = Theme.of(context).colorScheme.onBackground;

    final values = r.buckets;
    final labels = r.bucketLabels;
    final total = values.fold<int>(0, (a, b) => a + b);
    final max = values.isEmpty ? 1 : values.reduce((a, b) => a > b ? a : b);
    final avg = r.totalDays == 0 ? 0.0 : r.completedCount / r.totalDays;
    final bestLabel = r.bestBucketLabel ?? '—';
    final isYear = r.period == ReviewPeriod.year;

    final rangeText = isYear ? '${r.start.year} 年' : r.rangeLabel;

    bool showLabel(int i) =>
        isYear || i % 5 == 0 || i == values.length - 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '${r.period.unitLabel}完成趋势',
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
                '${r.period.unitLabel} $total',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          rangeText,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: meta,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 96,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (int i = 0; i < values.length; i++)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (showLabel(i) && values[i] > 0)
                        Text(
                          '${values[i]}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: i == r.bestBucketIndex ? bestFill : fill,
                          ),
                        ),
                      const SizedBox(height: 3),
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        height: max == 0 ? 2 : (values[i] / max) * 72,
                        decoration: BoxDecoration(
                          color: i == r.bestBucketIndex ? bestFill : fill,
                          borderRadius:
                              BorderRadius.circular(AppColors.progressRadius),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (int i = 0; i < values.length; i++)
              Expanded(
                child: Text(
                  showLabel(i) ? labels[i] : '',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isYear ? 10 : 9,
                    fontWeight: FontWeight.w500,
                    color: meta,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _TrendMetric(
                value: '$total',
                label: '${r.period.unitLabel}完成',
                valueColor: onBg,
                meta: meta),
            _TrendMetric(
                value: avg.toStringAsFixed(1),
                label: '日均',
                valueColor: onBg,
                meta: meta),
            _TrendMetric(
                value: '${r.activeDays}',
                label: '活跃天数',
                valueColor: onBg,
                meta: meta),
            _TrendMetric(
                value: bestLabel,
                label: isYear ? '最佳月' : '最佳日',
                valueColor: onBg,
                meta: meta),
          ],
        ),
      ],
    );
  }
}

class _TrendMetric extends StatelessWidget {
  final String value;
  final String label;
  final Color valueColor;
  final Color meta;
  const _TrendMetric({
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

/// 专注去向 Top3（本期累计专注秒数降序），复用 [FocusRankRow]。
class PeriodFocusBlock extends StatelessWidget {
  final PeriodReview r;
  const PeriodFocusBlock(this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final onBg = Theme.of(context).colorScheme.onBackground;

    return ReviewSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('专注去向',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          if (r.focusTop.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('本期还没有专注记录',
                  style: TextStyle(fontSize: 13, color: ext.meta)),
            )
          else
            for (int i = 0; i < r.focusTop.length; i++)
              FocusRankRow(
                rank: i + 1,
                stat: r.focusTop[i],
                accent: accent,
                onBg: onBg,
                meta: ext.meta,
                isLast: i == r.focusTop.length - 1,
              ),
        ],
      ),
    );
  }
}

/// 习惯打卡：每个活动习惯在本期内的达成情况，复用 [HabitProgressRow]。
class PeriodHabitBlock extends StatelessWidget {
  final PeriodReview r;
  const PeriodHabitBlock(this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;

    return ReviewSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('习惯打卡',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          if (r.habits.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('本期还没有打卡记录',
                  style: TextStyle(fontSize: 13, color: ext.meta)),
            )
          else
            for (int i = 0; i < r.habits.length; i++)
              HabitProgressRow(
                habit: r.habits[i].habit,
                done: r.habits[i].done,
                expected: r.habits[i].expected,
                rate: r.habits[i].rate,
                isLast: i == r.habits.length - 1,
                onBg: onBg,
                meta: ext.meta,
              ),
        ],
      ),
    );
  }
}

/// 分类分布：把本期各分类完成数换算成「占完成总量的比例」后复用 [CategoryProgress]。
class PeriodCategoryBlock extends StatelessWidget {
  final PeriodReview r;
  const PeriodCategoryBlock(this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final total =
        r.categoryCount.values.fold<int>(0, (a, b) => a + b);
    final progress = <Category, double>{
      for (final c in Category.values)
        c: total == 0 ? 0.0 : (r.categoryCount[c]! / total),
    };
    return ReviewSection(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: CategoryProgress(progress: progress),
    );
  }
}

/// 月报 / 年报分享长图卡片。
///
/// 与 [ReviewShareCard] 同款约束：固定 [width] 逻辑像素（默认 360）、强制套用
/// lightTheme/darkTheme、锁定文字缩放 1.0、外层 RepaintBoundary 截图 pixelRatio 3。
class PeriodReviewShareCard extends StatelessWidget {
  final PeriodReview review;
  final bool dark;
  final double width;
  const PeriodReviewShareCard({
    super.key,
    required this.review,
    this.dark = false,
    this.width = 360,
  });

  @override
  Widget build(BuildContext context) {
    final theme = dark ? darkTheme : lightTheme;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: Theme(
        data: theme,
        child: Builder(
          builder: (context) => Material(
            color: theme.colorScheme.background,
            child: SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _buildBlocks(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBlocks(BuildContext context) {
    final blocks = <Widget>[
      _Header(title: review.title, range: review.rangeLabel),
      const SizedBox(height: 14),
      ReviewSection(child: PeriodMetrics(review)),
    ];
    void add(Widget w) {
      blocks.add(const SizedBox(height: 12));
      blocks.add(w);
    }

    add(ReviewSection(
      padding: const EdgeInsets.all(10),
      child: PeriodTrend(review),
    ));
    add(PeriodFocusBlock(review));
    add(PeriodHabitBlock(review));
    add(PeriodCategoryBlock(review));

    blocks.add(const SizedBox(height: 16));
    blocks.add(const _Footer());
    return blocks;
  }
}

/// 顶部品牌行。
class _Header extends StatelessWidget {
  final String title;
  final String range;
  const _Header({required this.title, required this.range});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: accent.withOpacity(isDark ? 0.24 : 0.12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(Symbols.calendar_month, size: 21, color: accent),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '有条 · $title',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: onBg,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              range,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: ext.meta,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 底部署名。
class _Footer extends StatelessWidget {
  const _Footer();
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 1, color: ext.track),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              '有条 · 极简待办清单',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: ext.meta,
              ),
            ),
            const Spacer(),
            Text(
              'gitee.com/jason1012/youtiao',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: ext.meta.withOpacity(0.75),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
