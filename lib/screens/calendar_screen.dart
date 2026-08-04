import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';

/// 完成日历 + 热力图：月历视图按每天完成数着色（GitHub 贡献图风格），
/// 点击有完成的日期弹出当天完成的任务明细。复用 streak 已采集的 completedAt 数据。
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  // 当前展示的月份（取该月 1 号），可前后翻月。
  late DateTime _focused;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focused = DateTime(now.year, now.month, 1);
  }

  void _shift(int delta) =>
      setState(() => _focused = DateTime(_focused.year, _focused.month + delta, 1));

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final onBg = Theme.of(context).colorScheme.onBackground;
    final provider = Provider.of<TaskProvider>(context);
    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

    final monthCount = provider.completionsInMonthCount(_focused);
    final counts = provider.completionsInMonth(_focused);

    // 月历网格计算（周一为每周首日）
    final first = DateTime(_focused.year, _focused.month, 1);
    final daysInMonth = DateTime(_focused.year, _focused.month + 1, 0).day;
    final leading = (first.weekday - 1) % 7;
    final totalCells = leading + daysInMonth;
    final trailing = (7 - (totalCells % 7)) % 7;
    final cells = totalCells + trailing;

    const weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

    return Column(
      children: [
        const TopAppBar(title: '完成日历'),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                AppColors.pagePadX, 8, AppColors.pagePadX, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 本月概览
                Padding(
                  padding: const EdgeInsets.only(bottom: AppColors.contentGap),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('完成日历',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold, color: onBg)),
                      Text('本月完成 $monthCount 个 · 连续 ${provider.currentStreak} 天',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500, color: ext.meta)),
                    ],
                  ),
                ),
                // 日历卡片
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(AppColors.cardRadius),
                  ),
                  child: Column(
                    children: [
                      // 月份导航
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            onPressed: () => _shift(-1),
                            icon: Icon(Symbols.chevron_left, size: 22, color: onBg),
                            splashRadius: 18,
                            tooltip: '上个月',
                          ),
                          Text(DateFormat('yyyy年M月').format(_focused),
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: onBg)),
                          IconButton(
                            onPressed: () => _shift(1),
                            icon: Icon(Symbols.chevron_right, size: 22, color: onBg),
                            splashRadius: 18,
                            tooltip: '下个月',
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // 星期表头
                      Row(
                        children: [
                          for (final w in weekLabels)
                            Expanded(
                              child: Center(
                                child: Text(w,
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: ext.meta)),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // 日期网格
                      GridView.count(
                        crossAxisCount: 7,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        childAspectRatio: 1.0,
                        children: [
                          for (int i = 0; i < cells; i++)
                            _buildCell(
                              i,
                              leading,
                              daysInMonth,
                              _focused,
                              today,
                              counts,
                              base,
                              isDark,
                              onBg,
                              ext,
                              provider,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // 图例
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('完成越少',
                              style: TextStyle(fontSize: 11, color: ext.meta)),
                          const SizedBox(width: 6),
                          for (int l = 0; l <= 4; l++)
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: _heatColor(l, base, isDark),
                                borderRadius: BorderRadius.circular(AppColors.progressRadius),
                              ),
                            ),
                          const SizedBox(width: 6),
                          Text('完成越多',
                              style: TextStyle(fontSize: 11, color: ext.meta)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCell(
    int i,
    int leading,
    int daysInMonth,
    DateTime focused,
    DateTime today,
    Map<DateTime, int> counts,
    Color base,
    bool isDark,
    Color onBg,
    dynamic ext,
    TaskProvider provider,
  ) {
    // 前导/尾随空白格
    if (i < leading || i >= leading + daysInMonth) {
      return const SizedBox.shrink();
    }
    final dayNum = i - leading + 1;
    final date = DateTime(focused.year, focused.month, dayNum);
    final count = counts[date] ?? 0;
    final level = _level(count);
    final isToday = date.isAtSameMomentAs(today);
    final isFuture = date.isAfter(today);
    final strong = level >= 3;
    final textColor = strong
        ? Colors.white
        : (isFuture ? ext.meta.withAlpha(150) : onBg);

    return GestureDetector(
      onTap: count > 0 ? () => _openDay(provider, date, count) : null,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: _heatColor(level, base, isDark),
          borderRadius: BorderRadius.circular(AppColors.progressRadius),
          border: isToday
              ? Border.all(color: base, width: 2)
              : null,
        ),
        child: Center(
          child: Text(
            '$dayNum',
            style: TextStyle(
              fontSize: 13,
              fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

  void _openDay(TaskProvider provider, DateTime date, int count) {
    final tasks = provider.tasksCompletedOn(date);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onBg = Theme.of(context).colorScheme.onBackground;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, controller) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkTrack : AppColors.lightTrack,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  Text(DateFormat('M月d日').format(date),
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold, color: onBg)),
                  const SizedBox(width: 8),
                  Text('完成 $count 个',
                      style: const TextStyle(fontSize: 13, color: AppColors.lightMeta)),
                ],
              ),
            ),
            const Divider(height: 16),
            Expanded(
              child: ListView.separated(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                itemCount: tasks.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, idx) {
                  final t = tasks[idx];
                  final pColor = _priorityColor(t.priority, isDark);
                  return Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: pColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.title,
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: onBg)),
                            const SizedBox(height: 2),
                            Text(
                              '${t.category.label} · ${DateFormat('HH:mm').format(t.completedAt!)} 完成',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.lightMeta),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 完成数 → 热力等级（0~4）。
int _level(int n) {
  if (n <= 0) return 0;
  if (n == 1) return 1;
  if (n == 2) return 2;
  if (n == 3) return 3;
  return 4;
}

/// 热力等级 → 颜色（level0 用轨道灰，其余用主题主色按透明度递增）。
Color _heatColor(int level, Color base, bool isDark) {
  switch (level) {
    case 0:
      return isDark ? AppColors.darkTrack : AppColors.lightTrack;
    case 1:
      return base.withAlpha(60);
    case 2:
      return base.withAlpha(110);
    case 3:
      return base.withAlpha(170);
    default:
      return base.withAlpha(235);
  }
}

/// 优先级 → 主色（与看板/首页配色一致）。
Color _priorityColor(Priority p, bool isDark) {
  if (p == Priority.high) return isDark ? AppColors.darkHigh : AppColors.lightHigh;
  if (p == Priority.medium) return isDark ? AppColors.darkMedium : AppColors.lightMedium;
  return isDark ? AppColors.darkLow : AppColors.lightLow;
}
