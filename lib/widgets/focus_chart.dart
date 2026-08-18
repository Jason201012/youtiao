import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 近 7 日专注柱状图（零依赖，自绘圆角柱 + 星期标签）。
/// [secs] 长度须为 7，由旧到新；空数据全部为 0 时显示最小占位柱。
class FocusWeekBars extends StatelessWidget {
  final List<int> secs;
  final AppColorsExt ext;
  const FocusWeekBars({super.key, required this.secs, required this.ext});

  static const List<String> _wd = ['一', '二', '三', '四', '五', '六', '日'];

  List<String> _labels() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final out = <String>[];
    for (var i = 6; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      out.add(_wd[(d.weekday - 1) % 7]);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final max = secs.fold(0, (a, b) => a > b ? a : b);
    final labels = _labels();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (secs[i] > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('${(secs[i] / 60).round()}',
                        style: TextStyle(fontSize: 10, color: ext.meta)),
                  ),
                Container(
                  height: max == 0 ? 6 : (6 + 70 * secs[i] / max),
                  width: 16,
                  decoration: BoxDecoration(
                    color: ext.accent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Text(labels[i], style: TextStyle(fontSize: 11, color: ext.meta)),
              ],
            ),
          ),
      ],
    );
  }
}

/// 单个习惯的打卡热力：近 [days] 天的小方块网格（已打卡=accent，未打卡=track）。
class FocusHabitHeatmap extends StatelessWidget {
  final Habit habit;
  final Set<DateTime> checkedDays;
  final int days;
  final AppColorsExt ext;
  const FocusHabitHeatmap({
    super.key,
    required this.habit,
    required this.checkedDays,
    required this.days,
    required this.ext,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cells = <Widget>[];
    for (var i = days - 1; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final on = checkedDays.any((c) =>
          c.year == d.year && c.month == d.month && c.day == d.day);
      cells.add(Container(
        width: 14,
        height: 14,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: on ? ext.accent : ext.track,
          borderRadius: BorderRadius.circular(3),
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(habit.title,
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onBackground)),
        const SizedBox(height: 8),
        Wrap(children: cells),
      ],
    );
  }
}

/// 专注页底部「近 7 日」总览：专注柱状图 + 各习惯打卡热力。
/// 同时 watch [FocusProvider] 与 [HabitProvider]，数据变化时自动刷新。
class FocusWeekOverview extends StatelessWidget {
  const FocusWeekOverview({super.key});

  @override
  Widget build(BuildContext context) {
    final focus = context.watch<FocusProvider>();
    final habit = context.watch<HabitProvider>();
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final secs = focus.last7FocusSecs();
    final habits = habit.activeHabits;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('近 7 日',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: onBg)),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('专注时长', style: TextStyle(fontSize: 13, color: ext.meta)),
              const SizedBox(height: 12),
              FocusWeekBars(secs: secs, ext: ext),
              if (habits.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('习惯打卡', style: TextStyle(fontSize: 13, color: ext.meta)),
                const SizedBox(height: 12),
                for (final h in habits) ...[
                  FocusHabitHeatmap(
                    habit: h,
                    checkedDays: habit.checkedDays(h, 21),
                    days: 21,
                    ext: ext,
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}
