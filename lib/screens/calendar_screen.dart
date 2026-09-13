import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/services/lunar_calendar.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/command_palette_button.dart';
import 'package:todolist/widgets/focus_chart.dart';
import 'package:todolist/widgets/past_due_guard.dart';

/// 任务日历（月 / 周视图）：
/// - 按任务到期日（dueDate）排布，月视图每格显示当天到期任务，周视图为 7 天列；
/// - 支持长按任务拖拽到目标日期改期（DragTarget + LongPressDraggable）；
/// - 保留完成数热力底色作为装饰（GitHub 贡献图风格），点击日期查看当天明细并可勾选完成。
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _focused; // 月视图锚点（当月 1 号）
  late DateTime _viewDate; // 周视图锚点（所在周的某天）
  String _view = 'month'; // 'month' | 'week'
  DateTime? _timelineDay; // 周视图专注时段面板所选日期（null = 今天）

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focused = DateTime(now.year, now.month, 1);
    _viewDate = now;
  }

  void _shiftMonth(int delta) =>
      setState(() => _focused = DateTime(_focused.year, _focused.month + delta, 1));

  /// U19：一键回到「今天」所在月份（翻了很久的月历找不回来时的出路）。
  void _goToday() {
    final now = DateTime.now();
    final target = DateTime(now.year, now.month, 1);
    // 若已在该月（或今天是该月 1 号即聚焦本月）无需重设。
    if (_focused.year == target.year && _focused.month == target.month) return;
    setState(() {
      _focused = target;
      _viewDate = now;
    });
  }

  void _shiftWeek(int delta) =>
      setState(() => _viewDate = _viewDate.add(Duration(days: 7 * delta)));

  /// 把任务改期到 newDate（保留原时分），并提示。
  ///
  /// P3-1（v2.8.8 审计）：此前直接 `updateTask(copyWith(dueDate))`、无任何判定，
  /// 是 v2.8.4「同一件事的提示口径统一」里唯一漏网的入口——用户可静默把任务拖到
  /// 昨天/上周，改完后任务立刻以「逾期」身份出现且没有任何提醒。现接入统一守卫
  /// [PastDueGuard]（与新建 / 详情页改期 / 批量改期 / 逾期区顺延同口径）。
  Future<void> _reschedule(Task task, DateTime newDate) async {
    final old = task.dueDate;
    if (old == null) return;
    final newDue =
        DateTime(newDate.year, newDate.month, newDate.day, old.hour, old.minute);
    if (_sameDay(newDue, old)) return; // 拖回原日期不处理

    // 目标截止时刻（dueDate − reminderOffsetMin）已早于当前时刻 → 保存后提醒
    // 永远不会触发，弹框让用户显式确认；取消则终止本次改期、不写库。
    if (newDue.isBefore(DateTime.now())) {
      final ok = await PastDueGuard.confirm(
        context,
        count: 1,
        detail: '目标日（${DateFormat('M月d日').format(newDue)} '
            '${old.hour.toString().padLeft(2, '0')}:'
            '${old.minute.toString().padLeft(2, '0')}）的截止时刻'
            '已早于当前时刻，改期后提醒将不会触发。\n\n仍要改期吗？',
      );
      if (!ok) return;
    }
    if (!mounted) return; // 弹框期间本页可能已被销毁

    final updated = task.copyWith(dueDate: newDue);
    Provider.of<TaskProvider>(context, listen: false).updateTask(updated);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已改期至 ${DateFormat('M月d日').format(newDue)}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final onBg = Theme.of(context).colorScheme.onBackground;
    final provider = Provider.of<TaskProvider>(context);
    final today =
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

    return Column(
      children: [
        const TopAppBar(
          title: '日历',
          // U4：命令面板移动端入口。
          actions: [CommandPaletteButton(currentIndex: 2)],
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                AppColors.pagePadX, 8, AppColors.pagePadX, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 概览 + 视图切换
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('连续 ${provider.currentStreak} 天',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: onBg)),
                    _buildViewToggle(ext, base),
                  ],
                ),
                const SizedBox(height: AppColors.contentGap),
                if (_view == 'month')
                  _buildMonthCard(provider, base, isDark, onBg, ext, today)
                else
                  _buildWeekView(provider, base, isDark, onBg, ext, today),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildViewToggle(dynamic ext, Color base) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _segBtn('月', _view == 'month', ext, base,
              () => setState(() => _view = 'month')),
          _segBtn('周', _view == 'week', ext, base,
              () => setState(() => _view = 'week')),
        ],
      ),
    );
  }

  Widget _segBtn(
      String label, bool active, dynamic ext, Color base, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        decoration: BoxDecoration(
          color: active ? base : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : ext.meta)),
      ),
    );
  }

  Widget _buildMonthCard(TaskProvider provider, Color base, bool isDark,
      Color onBg, dynamic ext, DateTime today) {
    final monthCount = provider.completionsInMonthCount(_focused);
    final counts = provider.completionsInMonth(_focused);

    final first = DateTime(_focused.year, _focused.month, 1);
    final daysInMonth = DateTime(_focused.year, _focused.month + 1, 0).day;
    final leading = (first.weekday - 1) % 7;
    final totalCells = leading + daysInMonth;
    final trailing = (7 - (totalCells % 7)) % 7;
    final cells = totalCells + trailing;

    const weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

    return Container(
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
                onPressed: () => _shiftMonth(-1),
                icon: Icon(Symbols.chevron_left, size: 22, color: onBg),
                splashRadius: 18,
                tooltip: '上个月',
              ),
              Text('${_focused.year}年${_focused.month}月 · 完成 $monthCount',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold, color: onBg)),
              IconButton(
                onPressed: () => _shiftMonth(1),
                icon: Icon(Symbols.chevron_right, size: 22, color: onBg),
                splashRadius: 18,
                tooltip: '下个月',
              ),
            ],
          ),
          // U19：翻离本月后显示「回到今天」快捷入口（本月内隐藏，避免噪音）。
          if (!(_focused.year == today.year && _focused.month == today.month))
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _goToday,
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10)),
                icon: const Icon(Symbols.today, size: 16),
                label: const Text('回到今天'),
              ),
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
                _buildMonthCell(i, leading, daysInMonth, _focused, today,
                    counts, base, isDark, onBg, ext, provider),
            ],
          ),
          const SizedBox(height: 12),
          // 图例
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('完成越少', style: TextStyle(fontSize: 11, color: ext.meta)),
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
              Text('完成越多', style: TextStyle(fontSize: 11, color: ext.meta)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMonthCell(
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
    final isToday = _sameDay(date, today);
    final dueTasks = provider.tasksDueOn(date);
    final isFuture = date.isAfter(today);
    final focusMin =
        (Provider.of<FocusProvider>(context, listen: false).totalSecOn(date) / 60)
            .round();
    final focusLabel =
        focusMin >= 60 ? '${(focusMin / 60).toStringAsFixed(1)}h' : '${focusMin}分';
    final strong = level >= 3;
    final textColor =
        strong ? Colors.white : (isFuture ? ext.meta.withAlpha(150) : onBg);
    // P0-3：农历 / 节气 / 传统节日标注（纯离线换算；设置项关闭时留空不渲染）。
    final lunar = provider.calendarLunar ? lunarLabelOf(date) : LunarLabel.empty;

    return DragTarget<Task>(
      // 稳定 Key（date-only）：便于自动化测试精确定位某一天的投放目标，
      // 不参与布局与交互逻辑。
      key: ValueKey('cal-month-cell-${date.year}-${date.month}-${date.day}'),
      // P3-2（v2.8.8 审计）：重复任务的 dueDate 只是占位，拖拽改期是「假成功」，
      // 故在投放侧也一并拒绝（兜底：即便有其它来源的拖拽也不放行）。
      onWillAcceptWithDetails: (details) =>
          !details.data.done && !details.data.isRepeating,
      onAcceptWithDetails: (details) => _reschedule(details.data, date),
      builder: (ctx, candidate, rejected) => GestureDetector(
        onTap: () => _openDay(provider, date),
        child: Container(
          margin: const EdgeInsets.all(2),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: candidate.isNotEmpty
                ? base.withAlpha(70)
                : _heatColor(level, base, isDark),
            borderRadius: BorderRadius.circular(AppColors.progressRadius),
            border: isToday
                ? Border.all(color: base, width: 2)
                : (candidate.isNotEmpty
                    ? Border.all(color: base, width: 1.5)
                    : null),
          ),
          padding: const EdgeInsets.fromLTRB(3, 3, 3, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text('$dayNum',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              isToday ? FontWeight.bold : FontWeight.w500,
                          color: textColor)),
                  const SizedBox(width: 2),
                  // P0-3：农历小字靠右对齐，格子窄时自动省略，不挤压日期数字。
                  if (lunar.text.isNotEmpty)
                    Expanded(
                      child: Text(
                        lunar.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 9,
                          color: lunar.isFestival
                              ? (strong ? Colors.white : ext.accent)
                              : textColor.withAlpha(170),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              if (dueTasks.isNotEmpty)
                ...[
                  for (final t in dueTasks.take(2))
                    _taskChip(t, onBg, isDark, ext, dense: true),
                  if (dueTasks.length > 2)
                    Padding(
                      padding: const EdgeInsets.only(top: 1, left: 2),
                      child: Text('+${dueTasks.length - 2}',
                          style: TextStyle(fontSize: 10, color: ext.meta)),
                    ),
                if (focusMin > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 1, left: 2),
                    child: Row(
                      children: [
                        Icon(Symbols.timer, size: 9, color: ext.meta),
                        const SizedBox(width: 2),
                        Text(focusLabel,
                            style: TextStyle(fontSize: 10, color: ext.meta)),
                      ],
                    ),
                  ),
                ],
            ],
          ),
        ),
      ),
    );
  }

  /// 单个任务条：完成态灰显且不可拖；未完成态可长按拖拽改期。
  Widget _taskChip(Task task, Color onBg, bool isDark, dynamic ext,
      {bool dense = false}) {
    final pColor = _priorityColor(task.priority, isDark);
    final hasTime = _hasTime(task.dueDate);
    final time = hasTime ? DateFormat('HH:mm').format(task.dueDate!) : '';
    final child = Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 2),
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 4 : 8, vertical: dense ? 2 : 7),
      decoration: BoxDecoration(
        color: task.done ? Colors.transparent : pColor.withAlpha(26),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: pColor.withAlpha(task.done ? 50 : 110), width: 1),
      ),
      child: Row(
        children: [
          if (!dense)
            Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                    color: pColor, borderRadius: BorderRadius.circular(2))),
          if (!dense) const SizedBox(width: 6),
          Expanded(
            child: Text(task.title.isNotEmpty ? task.title : '(无标题)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: dense ? 10 : 13,
                    fontWeight: FontWeight.w500,
                    color: task.done ? ext.meta : onBg,
                    decoration: task.done ? TextDecoration.lineThrough : null)),
          ),
          if (time.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(time,
                  style: TextStyle(fontSize: dense ? 9 : 11, color: ext.meta)),
            ),
        ],
      ),
    );

    if (task.done) return child; // 已完成不可拖拽改期

    // P3-2（v2.8.8 审计）：重复任务的提醒 / 循环由 repeatMinute / repeatUntil /
    // skipDates 表达，dueDate 自 v2.8.5 起已不再被录入侧钉为「创建当天 23:59」，
    // 语义上只是占位。此前日历仍允许把它拖到任意日期并写 dueDate：用户看到
    // 「已改期至 X」的 SnackBar 以为生效，实际当天照常循环、提醒时刻不变——假成功；
    // 且这条被拖出的占位 dueDate 在「结束重复」后会重新参与日期分区，让任务显示在
    // 错误日期。故禁用拖拽，长按给出正确路径提示（详情页「仅此一次改期」）。
    if (task.isRepeating) {
      return GestureDetector(
        // translucent（而非 opaque）：本层只「加」一个长按识别器，且让指针继续穿透，
        // 使外层日期格的 onTap（打开当天详情）不被吞掉——opaque 会把点击截留在此处，
        // 让重复任务卡片失去原有的「点一下看当天」行为。
        behavior: HitTestBehavior.translucent,
        onLongPress: () {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text('重复任务不支持拖拽改期，请在详情页使用「仅此一次改期」'),
                duration: Duration(seconds: 3),
              ),
            );
        },
        child: child,
      );
    }

    return LongPressDraggable<Task>(
      data: task,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 140,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: pColor.withAlpha(160), width: 1),
          ),
          child: Text(task.title.isNotEmpty ? task.title : '(无标题)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: onBg)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: child),
      child: child,
    );
  }

  Widget _buildWeekView(TaskProvider provider, Color base, bool isDark,
      Color onBg, dynamic ext, DateTime today) {
    final start = _weekStart(_viewDate);
    final days = List.generate(7, (i) => start.add(Duration(days: i)));
    const labels = ['一', '二', '三', '四', '五', '六', '日'];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Column(
        children: [
          // 周导航
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed: () => _shiftWeek(-1),
                icon: Icon(Symbols.chevron_left, size: 22, color: onBg),
                splashRadius: 18,
                tooltip: '上一周',
              ),
              Text('${start.month}月${start.day}日 - ${days[6].month}月${days[6].day}日',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold, color: onBg)),
              IconButton(
                onPressed: () => _shiftWeek(1),
                icon: Icon(Symbols.chevron_right, size: 22, color: onBg),
                splashRadius: 18,
                tooltip: '下一周',
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 专注时段块状映射（P1-7）
          _buildFocusTimeline(provider, base, isDark, onBg, ext, today, days),
          const SizedBox(height: 16),
          // 横向 7 天列
          SizedBox(
            height: 460,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < 7; i++)
                    _weekColumn(days[i], labels[i], provider, base, isDark,
                        onBg, ext, today),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 专注时段块状映射面板（P1-7）：在周视图中按所选日期展示当天的专注时段条。
  Widget _buildFocusTimeline(TaskProvider provider, Color base, bool isDark,
      Color onBg, dynamic ext, DateTime today, List<DateTime> days) {
    final focus = Provider.of<FocusProvider>(context);
    final selected = _timelineDay ?? today;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Symbols.schedule, size: 18, color: ext.accent),
            const SizedBox(width: 6),
            Text('专注时段',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold, color: onBg)),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final d in days)
                _dayChip(d, _sameDay(d, selected), onBg, ext, base, today),
            ],
          ),
        ),
        const SizedBox(height: 8),
        FocusDayTimeline(day: selected, focus: focus),
      ],
    );
  }

  Widget _dayChip(DateTime d, bool active, Color onBg, dynamic ext, Color base,
      DateTime today) {
    final isToday = _sameDay(d, today);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => setState(() => _timelineDay = d),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active ? base : ext.chip,
            borderRadius: BorderRadius.circular(20),
            border: isToday && !active ? Border.all(color: base, width: 1) : null,
          ),
          child: Text('${d.month}/${d.day}${isToday ? ' 今' : ''}',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : ext.meta)),
        ),
      ),
    );
  }

  Widget _weekColumn(DateTime d, String label, TaskProvider provider, Color base,
      bool isDark, Color onBg, dynamic ext, DateTime today) {
    final dueTasks = provider.tasksDueOn(d);
    final isToday = _sameDay(d, today);
    final track = isDark ? AppColors.darkTrack : AppColors.lightTrack;
    return DragTarget<Task>(
      // P3-2（v2.8.8 审计）：重复任务的 dueDate 只是占位，拖拽改期是「假成功」，
      // 故在投放侧也一并拒绝（兜底：即便有其它来源的拖拽也不放行）。
      onWillAcceptWithDetails: (details) =>
          !details.data.done && !details.data.isRepeating,
      onAcceptWithDetails: (details) => _reschedule(details.data, d),
      builder: (ctx, candidate, rejected) => Container(
        width: 132,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: candidate.isNotEmpty
              ? base.withAlpha(40)
              : track.withAlpha(120),
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
          border: isToday
              ? Border.all(color: base, width: 2)
              : (candidate.isNotEmpty
                  ? Border.all(color: base, width: 1.5)
                  : Border.all(color: track, width: 1)),
        ),
        child: Column(
          children: [
            // 日期头条
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: ext.meta)),
                  const SizedBox(height: 2),
                  Text('${d.day}',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isToday ? base : onBg)),
                ],
              ),
            ),
            Divider(height: 1, color: track),
            Expanded(
              child: dueTasks.isEmpty
                  ? Center(
                      child: Text('无任务',
                          style: TextStyle(fontSize: 12, color: ext.meta)))
                  : ListView.separated(
                      padding: const EdgeInsets.all(6),
                      itemCount: dueTasks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (_, idx) =>
                          _taskChip(dueTasks[idx], onBg, isDark, ext),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDay(TaskProvider provider, DateTime date) {
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
        builder: (_, controller) => Consumer<TaskProvider>(
          builder: (ctx2, p, _) {
            final tasks = p.tasksDueOn(date);
            // U7：取 appColors 让暗色模式也能正确显示次要文本。
            final ext = appColors(ctx2);
            return Column(
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
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: onBg)),
                      const SizedBox(width: 8),
                      Text('到期 ${tasks.length} 个',
                          // U7：用 ext.meta 替代硬编码的 lightMeta，否则暗色
                          // 模式下「M 月 d 日」旁的次要文本仍是浅灰、读不清。
                          style: TextStyle(fontSize: 13, color: ext.meta)),
                    ],
                  ),
                ),
                const Divider(height: 16),
                Expanded(
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    children: [
                      if (tasks.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 20),
                          child: Center(
                              child: Text('当天没有到期任务',
                                  style: TextStyle(color: ext.meta))),
                        )
                      else
                        for (final t in tasks)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: Checkbox(
                                    value: t.done,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    onChanged: (v) => p.toggleDone(t.id),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                        color: _priorityColor(t.priority, isDark),
                                        borderRadius: BorderRadius.circular(3))),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(t.title,
                                          style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              color: onBg,
                                              decoration: t.done
                                                  ? TextDecoration.lineThrough
                                                  : null)),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${t.category.label}${t.dueDate != null ? " · ${DateFormat("HH:mm").format(t.dueDate!)}" : ""}',
                                        // U7：同上。
                                        style: TextStyle(
                                            fontSize: 12, color: ext.meta),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      _focusSectionForDay(context, date, onBg),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 某日期所在周的周一（每周首日）。
DateTime _weekStart(DateTime d) {
  final base = DateTime(d.year, d.month, d.day);
  return base.subtract(Duration(days: base.weekday - 1));
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

bool _hasTime(DateTime? d) {
  if (d == null) return false;
  return d.hour != 0 || d.minute != 0;
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
  if (p == Priority.medium)
    return isDark ? AppColors.darkMedium : AppColors.lightMedium;
  return isDark ? AppColors.darkLow : AppColors.lightLow;
}

/// 某天的专注记录区块（在日历「日期详情」底部展示）：列出当天结束的专注会话。
Widget _focusSectionForDay(BuildContext context, DateTime date, Color onBg) {
  final focus = Provider.of<FocusProvider>(context, listen: false);
  final sessions = focus.sessionsOn(date);
  if (sessions.isEmpty) return const SizedBox.shrink();
  final ext = appColors(context);
  // U7：用 ext.meta 替代硬编码的 lightMeta，暗色模式下「N 次」计数可读。
  final meta = ext.meta;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 16),
      Row(
        children: [
          Icon(Symbols.timer, size: 16, color: ext.meta),
          const SizedBox(width: 6),
          Text('专注记录',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold, color: onBg)),
          const Spacer(),
          Text('${sessions.length} 次',
              style: TextStyle(fontSize: 12, color: meta)),
        ],
      ),
      const SizedBox(height: 8),
      for (final s in sessions)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
              color: ext.chip,
              borderRadius: BorderRadius.circular(AppColors.cardRadius),
            ),
            child: Row(
              children: [
                Icon(
                  s.completed ? Symbols.local_fire_department : Symbols.timer,
                  size: 18,
                  color: ext.meta,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.taskTitle ?? '独立专注',
                          style: TextStyle(fontSize: 13, color: onBg),
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(
                        '${TimeOfDay.fromDateTime(s.startedAt).format(context)} → '
                        '${TimeOfDay.fromDateTime(s.endedAt).format(context)}',
                        style: TextStyle(fontSize: 11, color: meta),
                      ),
                    ],
                  ),
                ),
                Text(formatFocusDuration(s.durationSec),
                    style: TextStyle(fontSize: 13, color: meta)),
              ],
            ),
          ),
        ),
    ],
  );
}
