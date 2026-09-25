import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/review.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/models/review_narrative.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:provider/provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/stat_card.dart';
import 'package:todolist/widgets/week_trend.dart';
import 'package:todolist/widgets/category_progress.dart';

/// 统一的板块外壳：surface 底 + 圆角 14 + 内边距。
/// 与 share_card 的 _Section 同款视觉，但此处做成可复用函数组件。
class ReviewSection extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const ReviewSection({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: child,
    );
  }
}

/// 「AI 小结」卡片：把 [buildWeeklyNarrative] / [buildPeriodNarrative] 生成的自然语言
/// 总结用统一的 ReviewSection 外壳 + auto_awesome 图标呈现，与普通板块视觉一致。
class NarrativeCard extends StatelessWidget {
  final String text;
  final String title;
  final EdgeInsets padding;
  const NarrativeCard({
    super.key,
    required this.text,
    this.title = 'AI 小结',
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    return ReviewSection(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.auto_awesome, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: onBg,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 4 连指标：本周完成 / 专注(分) / 番茄数 / 习惯达成。
/// 2×2 网格排布，移动端宽度更从容。
class WeeklyMetrics extends StatelessWidget {
  final WeeklyReview r;
  const WeeklyMetrics(this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final habitPct = r.habitPercent;
    final habitColor = habitPct >= 80
        ? const Color(0xFF0F6E56)
        : (habitPct >= 50 ? accent : ext.meta);

    final items = [
      _Metric(value: '${r.completedCount}', label: '本周完成', color: accent),
      _Metric(value: '${r.focusMinutes}', label: '专注(分)', color: accent),
      _Metric(value: '${r.pomodoroCount}', label: '番茄数', color: accent),
      _Metric(value: '$habitPct%', label: '习惯达成', color: habitColor),
    ];
    return GridView.count(
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
    );
  }
}

class _Metric {
  final String value;
  final String label;
  final Color color;
  const _Metric({required this.value, required this.label, required this.color});
}

/// 专注去向 Top3（本周累计专注秒数降序）。
class WeeklyFocusBlock extends StatelessWidget {
  final WeeklyReview r;
  const WeeklyFocusBlock(this.r, {super.key});

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
              child: Text('本周还没有专注记录',
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

/// 专注去向单行（带排名徽章 + 任务名 + 时长 + 次数）。
/// 抽成公开组件，月报年报的 [PeriodFocusBlock] 可直接复用。
class FocusRankRow extends StatelessWidget {
  final int rank;
  final TaskFocusStat stat;
  final Color accent;
  final Color onBg;
  final Color meta;
  final bool isLast;
  const FocusRankRow({
    super.key,
    required this.rank,
    required this.stat,
    required this.accent,
    required this.onBg,
    required this.meta,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text('$rank',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: accent)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              stat.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: onBg),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatFocusDuration(stat.totalSec),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: meta),
          ),
          const SizedBox(width: 6),
          Text('· ${stat.count}次',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: meta)),
        ],
      ),
    );
  }
}

/// 习惯打卡：每个活动习惯的本周进度（done/expected + 进度条）。
class WeeklyHabitBlock extends StatelessWidget {
  final WeeklyReview r;
  const WeeklyHabitBlock(this.r, {super.key});

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
              child: Text('还没有习惯，去添加一个吧',
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

/// 习惯打卡单行（emoji + 标题 + done/expected + 进度条）。
/// 抽成公开组件并接收原语（habit/done/expected/rate），
/// 月报年报的 [PeriodHabitBlock] 可直接复用，无需关心 HabitWeekStat / HabitPeriodStat 差异。
class HabitProgressRow extends StatelessWidget {
  final Habit habit;
  final int done;
  final int expected;
  final double rate;
  final bool isLast;
  final Color onBg;
  final Color meta;

  /// P3-6（v2.9.3 审计）：区间累计投入量（量化习惯显示「· 累计 240」）。
  /// 周报的 HabitWeekStat 无此数据，缺省 0 = 不展示。
  final int valueSum;
  const HabitProgressRow({
    super.key,
    required this.habit,
    required this.done,
    required this.expected,
    required this.rate,
    required this.isLast,
    required this.onBg,
    required this.meta,
    this.valueSum = 0,
  });

  /// P3-7：把区间累计量换算成「≈ N 天目标量」的可选后缀。
  ///
  /// 「累计 240 个单位」仍是个抽象数——用户知道喝水目标 8 杯/天，
  /// 于是 240 ≈ 30 天，这个换算能让叙事落到自己的习惯尺度上。
  /// 目标量为 0（理论不该发生，`effectiveTarget` 恒 ≥1）或换算结果为 0 时
  /// 返回空串，不显示多余的「≈ 0 天」。
  String _valueUnitHint() {
    final target = habit.effectiveTarget;
    if (target <= 0) return '';
    final days = valueSum ~/ target;
    if (days <= 0) return '';
    return '（≈ $days 天目标量）';
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final color = Color(habit.colorValue);
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(habit.emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  habit.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: onBg),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                // P3-6：量化习惯且区间有投入时，在达成数旁补「累计量」叙事。
                // P3-7（v2.9.4 审计）：原文案「累计 240」是**无量词裸数字**——
                // 240 杯水？240 页？240 分钟？用户无从判断量级是否合理，
                // 于是这段叙事等于没说话。现补「个单位」量词，并在能换算时
                // 附「≈ N 天目标量」（240 单位 / 每日 8 杯 = 30 天），
                // 让抽象总量落回习惯自身的时间尺度上。
                habit.isQuantified && valueSum > 0
                    ? '$done/$expected · 累计 $valueSum 个单位'
                        '${_valueUnitHint()}'
                    : '$done/$expected',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: expected == 0 ? meta : color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: 6,
            decoration: BoxDecoration(
              color: ext.track,
              borderRadius: BorderRadius.circular(AppColors.progressRadius),
            ),
            child: FractionallySizedBox(
              widthFactor: rate.clamp(0, 1),
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

/// 分类分布：复用现有 CategoryProgress（本周分类完成率）。
class WeeklyCategoryBlock extends StatelessWidget {
  final WeeklyReview r;
  const WeeklyCategoryBlock(this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    return ReviewSection(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: CategoryProgress(progress: r.categoryProgress),
    );
  }
}

/// 本周回顾摘要卡（首页嵌入用）：3 个小指标 + 「查看完整周报 →」。
/// 整卡可点击进入 [ReviewScreen]。
class WeeklyReviewCard extends StatelessWidget {
  final WeeklyReview review;
  final VoidCallback? onTap;
  const WeeklyReviewCard({super.key, required this.review, this.onTap});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final onBg = Theme.of(context).colorScheme.onBackground;
    final habitPct = review.habitPercent;
    final habitColor = habitPct >= 80
        ? const Color(0xFF0F6E56)
        : (habitPct >= 50 ? accent : ext.meta);

    final items = [
      _MiniStat(value: '${review.completedCount}', label: '完成', color: accent),
      _MiniStat(value: '${review.focusMinutes}', label: '专注分', color: accent),
      _MiniStat(value: '$habitPct%', label: '习惯', color: habitColor),
    ];

    final card = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.event_repeat, size: 18, color: accent),
              const SizedBox(width: 6),
              Text(
                '本周回顾',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: onBg,
                ),
              ),
              const Spacer(),
              Text(
                review.weekRangeLabel,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (int i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _miniStatCell(context, items[i])),
              ],
            ],
          ),
          const SizedBox(height: 12),
          // 周目标进度（B1）：本周完成任务数 / 周目标数，未设目标时不展示。
          Builder(
            builder: (ctx) {
              final goal = ctx.watch<TaskProvider>().weeklyGoalCount;
              if (goal <= 0) {
                return Row(
                  children: [
                    Text(
                      '查看完整周报',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Symbols.arrow_forward_ios, size: 13, color: accent),
                  ],
                );
              }
              final done = ctx.watch<TaskProvider>().weeklyCompletedCount;
              final ratio = (done / goal).clamp(0.0, 1.0);
              final reached = done >= goal;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Symbols.flag, size: 14,
                          color: reached ? accent : ext.meta),
                      const SizedBox(width: 4),
                      Text(
                        '周目标 $done/$goal',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: reached ? accent : ext.meta,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        reached ? '已达成' : '${(ratio * 100).round()}%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: ext.meta,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 6,
                      backgroundColor: ext.track,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          reached ? accent : ext.meta),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        '查看完整周报',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(Symbols.arrow_forward_ios, size: 13, color: accent),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );

    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppColors.cardRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        onTap: onTap,
        child: card,
      ),
    );
  }

  Widget _miniStatCell(BuildContext context, _MiniStat s) {
    final ext = appColors(context);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: s.color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            s.label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
          ),
        ],
      );
  }
}

class _MiniStat {
  final String value;
  final String label;
  final Color color;
  const _MiniStat({required this.value, required this.label, required this.color});
}

/// 周报分享长图卡片。
///
/// 固定 [width] 逻辑像素（默认 360），内部强制套用 lightTheme/darkTheme，
/// 锁定文字缩放为 1.0，外层用 RepaintBoundary 截图后按 pixelRatio 3 导出。
class ReviewShareCard extends StatelessWidget {
  final WeeklyReview review;
  final bool dark;
  final double width;
  const ReviewShareCard({
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
      _Header(weekRange: review.weekRangeLabel),
      const SizedBox(height: 14),
      NarrativeCard(text: buildWeeklyNarrative(review)),
      const SizedBox(height: 12),
      ReviewSection(child: WeeklyMetrics(review)),
    ];
    void add(Widget w) {
      blocks.add(const SizedBox(height: 12));
      blocks.add(w);
    }

    add(ReviewSection(
      padding: const EdgeInsets.all(10),
      child: WeekTrend(
        values: review.trend,
        dates: review.weekDates,
        lastWeekValues: review.lastTrend,
      ),
    ));
    add(WeeklyFocusBlock(review));
    add(WeeklyHabitBlock(review));
    add(WeeklyCategoryBlock(review));

    blocks.add(const SizedBox(height: 16));
    blocks.add(const _Footer());
    return blocks;
  }
}

/// 顶部品牌行。
class _Header extends StatelessWidget {
  final String weekRange;
  const _Header({required this.weekRange});

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
          child: Icon(Symbols.event_repeat, size: 21, color: accent),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '有条 · 本周回顾',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: onBg,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              weekRange,
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
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'gitee.com/jason1012/youtiao',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: ext.meta.withOpacity(0.75),
                ),
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 周报标题：原 WeekTrend 组件标题写死「近 7 日完成趋势」，周报分享场景中
/// 通过外层板块标题弱化这一措辞；此处不二次包裹，直接复用 WeekTrend 以保证
/// 柱状图视觉与看板分享完全一致。
