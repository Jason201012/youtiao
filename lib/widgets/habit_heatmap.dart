import 'package:flutter/material.dart';

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// GitHub 式习惯打卡热力图。
///
/// 展示最近 [weeks] 周（每周 7 行）的打卡密度。默认按 [checkedDays] 二值着色
/// （某天打过卡即高亮）；若提供 [levelOf] 则返回 0..N 的强度，用于多习惯聚合
/// （同一天多次打卡时颜色更深）。不新增任何存储，仅消费调用方传入的日期集合。
class HabitHeatmap extends StatelessWidget {
  final Set<DateTime> checkedDays;
  final int Function(DateTime)? levelOf;
  final int weeks;
  final Color? accent;
  final double cellSize;
  final double gap;
  final bool showWeekdayLabels;
  final bool showMonthLabels;
  final bool showLegend;

  const HabitHeatmap({
    super.key,
    required this.checkedDays,
    this.levelOf,
    this.weeks = 18,
    this.accent,
    this.cellSize = 12,
    this.gap = 3,
    this.showWeekdayLabels = true,
    this.showMonthLabels = true,
    this.showLegend = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accentColor = accent ?? scheme.primary;
    final empty = scheme.surfaceContainerHighest;

    final today = _dateOnly(DateTime.now());
    final dow = (today.weekday - 1) % 7; // 周一=0
    final lastWeekStart = today.subtract(Duration(days: dow));
    final firstWeekStart =
        lastWeekStart.subtract(Duration(days: (weeks - 1) * 7));

    int levelOfDay(DateTime d) {
      if (d.isAfter(today)) return 0;
      return levelOf?.call(d) ?? (checkedDays.contains(d) ? 1 : 0);
    }

    Color cellColor(int level) {
      if (level <= 0) return empty;
      if (levelOf == null) return accentColor; // 单习惯二值：实心高亮
      const steps = [0.35, 0.55, 0.78, 1.0];
      final idx = (level - 1).clamp(0, steps.length - 1);
      return accentColor.withOpacity(steps[idx]);
    }

    const weekdayLabels = ['一', '三', '五']; // 仅显示部分行标签
    final wdColW = showWeekdayLabels ? 16.0 : 0.0;

    Widget monthLabels() {
      final labels = <Widget>[];
      int? prevMonth;
      for (int c = 0; c < weeks; c++) {
        final ws = firstWeekStart.add(Duration(days: c * 7));
        final m = ws.month;
        final show = m != prevMonth;
        prevMonth = m;
        labels.add(SizedBox(
          width: cellSize,
          child: show
              ? Text('${m}月',
                  style: TextStyle(
                      fontSize: 10, color: scheme.onSurface.withOpacity(0.6)))
              : null,
        ));
      }
      return Padding(
        padding: EdgeInsets.only(left: wdColW + gap),
        child: Row(
          children: labels
              .map((w) => Padding(padding: EdgeInsets.only(right: gap), child: w))
              .toList(),
        ),
      );
    }

    final weekColumns = <Widget>[];
    for (int c = 0; c < weeks; c++) {
      final ws = firstWeekStart.add(Duration(days: c * 7));
      final col = <Widget>[];
      for (int r = 0; r < 7; r++) {
        final day = ws.add(Duration(days: r));
        final level = levelOfDay(day);
        col.add(Container(
          width: cellSize,
          height: cellSize,
          margin: EdgeInsets.only(bottom: gap),
          decoration: BoxDecoration(
            color: cellColor(level),
            borderRadius: BorderRadius.circular(3),
          ),
        ));
      }
      weekColumns.add(Padding(
        padding: EdgeInsets.only(right: gap),
        child: Column(children: col),
      ));
    }

    final weekdaysCol = showWeekdayLabels
        ? SizedBox(
            width: wdColW,
            child: Column(
              children: List.generate(7, (r) {
                final label =
                    (r == 0 || r == 2 || r == 4) ? weekdayLabels[r ~/ 2] : null;
                return Container(
                  height: cellSize,
                  margin: EdgeInsets.only(bottom: gap),
                  alignment: Alignment.center,
                  child: label == null
                      ? null
                      : Text(label,
                          style: TextStyle(
                              fontSize: 10,
                              color: scheme.onSurface.withOpacity(0.6))),
                );
              }),
            ),
          )
        : const SizedBox.shrink();

    final grid = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [weekdaysCol, ...weekColumns],
    );

    final legend = showLegend
        ? Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Text('少',
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurface.withOpacity(0.6))),
                const SizedBox(width: 4),
                ...List.generate(5, (i) {
                  final level = levelOf == null ? (i == 0 ? 0 : 1) : i;
                  return Container(
                    width: cellSize,
                    height: cellSize,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      color: cellColor(level),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  );
                }),
                const SizedBox(width: 4),
                Text('多',
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurface.withOpacity(0.6))),
              ],
            ),
          )
        : const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showMonthLabels) monthLabels(),
          grid,
          legend,
        ],
      ),
    );
  }
}

/// 连续天数徽章：火焰图标 + 当前连续天数；可选显示历史最长。
class StreakBadge extends StatelessWidget {
  final int current;
  final int longest;
  final Color? accent;
  final bool showLongest;

  const StreakBadge({
    super.key,
    required this.current,
    this.longest = 0,
    this.accent,
    this.showLongest = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accentColor = accent ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department, size: 14, color: accentColor),
          const SizedBox(width: 3),
          Text('$current 天',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: accentColor)),
          if (showLongest && longest > 0) ...[
            const SizedBox(width: 6),
            Text('最长 $longest',
                style: TextStyle(
                    fontSize: 11, color: scheme.onSurface.withOpacity(0.5))),
          ],
        ],
      ),
    );
  }
}
