import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/schedule_advisor.dart' show kDefaultEstimateMinutes;
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
// U2-3（v2.9.5 审计）：拖拽改期复用统一撤销条（10 秒 + 超时提示），与逾期顺延同口径。
import 'package:todolist/widgets/undo_snack_bar.dart';
import 'package:todolist/widgets/task_toggle_undo.dart';
// T2-1（v2.9.2 功能增强）：日历格长按直达新建任务（复用 TaskSheet 草稿预填）。
import 'package:todolist/widgets/new_task_sheet.dart';
// U2-4（v2.9.1 审计）：日历日期弹层里的任务行可点进任务详情页。
import 'package:todolist/screens/task_detail_screen.dart';

/// 任务日历（月 / 周视图）：
/// - 按任务到期日（dueDate）排布，月视图每格显示当天到期任务，周视图为 7 天列；
/// - 支持长按任务拖拽到目标日期改期（DragTarget + LongPressDraggable）；
/// - 保留完成数热力底色作为装饰（GitHub 贡献图风格），点击日期查看当天明细并可勾选完成。
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  /// U2-3（v2.9.6 审计）：MainScaffold 切到日历 Tab 时调用，通知 State
  /// 「若不在本月则回本月」（保活后 initState 不再随切换执行，见 State 内注释）。
  static void notifyTodaySeen() => _CalendarScreenState.bumpTodaySignal();

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _focused; // 月视图锚点（当月 1 号）
  late DateTime _viewDate; // 周视图锚点（所在周的某天）
  String _view = 'month'; // 'month' | 'week'
  DateTime? _timelineDay; // 周视图专注时段面板所选日期（null = 今天）

  /// U2-3（v2.9.6 审计）：Tab 保活后 [initState] 不再随切换执行，「进入日历
  /// 自动落在今天所在月份」的旧行为静默失效——翻到几个月前后切走再切回，
  /// 仍停在旧月份，用户可能以为「任务没刷新」。MainScaffold 切到日历 Tab 时
  /// 经 [CalendarScreen.notifyTodaySeen] 触发本信号，State 自行判断是否回
  /// 本月（已在本月则无感）。
  static final ValueNotifier<int> _todaySignal = ValueNotifier<int>(0);

  static void bumpTodaySignal() => _todaySignal.value++;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focused = DateTime(now.year, now.month, 1);
    _viewDate = now;
    _todaySignal.addListener(_onTodaySignal);
  }

  @override
  void dispose() {
    _todaySignal.removeListener(_onTodaySignal);
    super.dispose();
  }

  void _onTodaySignal() {
    final now = DateTime.now();
    // 仅当不在本月时回跳：用户停在本月（只是周视图翻到了别的周）不受打扰。
    if (_focused.year != now.year || _focused.month != now.month) {
      _goToday();
    }
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

    // 目标「提醒时刻」（dueDate − reminderOffsetMin）已早于当前时刻 → 保存后提醒
    // 永远不会触发，弹框让用户显式确认；取消则终止本次改期、不写库。
    //
    // P2-3（v2.9.1 审计）：判定必须**减去提醒提前量**再比较——旧实现只比截止时刻
    // （注释却声称比的是 `dueDate − reminderOffsetMin`，口径与注释不符）。于是
    // 「截止明日 10:15、提前 30 分钟提醒」的任务，今天 10:00 拖到今天 10:15 时
    // 截止时刻还没过、不弹守卫，保存后提醒时刻 09:45 早已过去 → 静默丢提醒，
    // 与 v2.8.4「同一件事提示口径统一」及 P3-1 的承诺相悖。
    final guardAt = newDue.subtract(Duration(minutes: task.reminderOffsetMin));
    if (guardAt.isBefore(DateTime.now())) {
      final ok = await PastDueGuard.confirm(
        context,
        count: 1,
        detail: '目标日（${DateFormat('M月d日').format(newDue)} '
            '${old.hour.toString().padLeft(2, '0')}:'
            '${old.minute.toString().padLeft(2, '0')}）的提醒时刻'
            '${task.reminderOffsetMin > 0 ? '（提前 ${task.reminderOffsetMin} 分钟）' : ''}'
            '已早于当前时刻，改期后提醒将不会触发。\n\n仍要改期吗？',
      );
      if (!ok) return;
    }
    if (!mounted) return; // 弹框期间本页可能已被销毁

    // U2-3（v2.9.5 审计）：**补撤销**。此前拖拽改期只弹一条 2 秒、无 action 的
    // 「已改期至 X」，与逾期顺延 / 批量顺延的 10 秒撤销口径不对等——拖错一次
    // 只能自己再拖回去，而拖拽的落点精度又远不如点选。
    //
    // N18（v3.0.9 审计）：撤销改走 [taskUndoAction]（widgets/task_toggle_undo.dart）
    // ——原注释称走 [TaskProvider.restoreTaskSnapshot]，该 API 已删除。
    // taskUndoAction 内部按完成前快照整体回滚（restoreTaskSnapshotPersisted：
    // 先撤在途提醒再按快照重排），dueDate 变化应触发的提醒重排由 provider
    // 写路径负责，调用方不必自己记得重排（漏一次就是静默丢提醒）。
    final provider = Provider.of<TaskProvider>(context, listen: false);
    final updated = task.copyWith(dueDate: newDue);
    // P2-2（v3.0.7 审计）：updateTask 透传落盘结果——失败弹提示（内存改期
    // 已生效、全量写自愈），撤销横幅照常给。
    final ok = await provider.updateTask(updated);
    // U3-5 / L16（v3.0.8 审计）：await 后统一先判 mounted 再做后续——旧实现
    // 仅在失败分支检查，成功路径紧接着对（可能已销毁的）context 调
    // showUndoSnackBar → ScaffoldMessenger.of 触发
    // 「Looking up a deactivated widget's ancestor is unsafe」。
    if (!mounted) return;
    if (!ok) {
      if (provider.byId(task.id) == null) {
        showTaskMissingHint(context);
      } else {
        showTaskPersistFailedHint(context, provider: provider);
      }
    }
    showUndoSnackBar(
      context,
      content: undoContent('已改期至 ${DateFormat('M月d日').format(newDue)}'),
      // P2-2（v2.9.6 审计）：撤销返回值曾表示「是否生效」（任务已删除时
      // false），由唯一实现统一提示「撤销已失效」。
      // P2-2②（v3.0.7 审计）：撤销走 taskUndoAction 三分支（落盘语义，
      // 落盘失败不再误报「撤销已失效」；已删除的快照 API「存在语义」恒返
      // true 会把失败当成功——该 API 已于 U3-4（v3.0.8）删除）。
      onUndo: taskUndoAction(context, provider, [task]),
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
    // T2-1/T2-2：当天到期 + 跨天区间覆盖的任务。
    // P3-10（v2.9.9 审计）：区间带排前面——take(2) 的截断窗口里优先保住跨天
    // 区间带（它承载的是整段任务的可见性；单条任务还有 +N 兜底）。
    final spanTasks = _spanTasksOn(provider, date);
    final dueTasks = [
      ...spanTasks,
      ..._dueTasksOn(provider, date),
    ];
    // T2-1 / P2-8 / P2-9（v2.9.9 审计）：当日「计划占时」合计改走单一口径
    // [planMinutesOn]（与排程建议同源兜底、跨天只在首日计、暂停/跳过不计）。
    final planMin = planMinutesOn(provider, date);
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
        // T2-1（v2.9.2 功能增强）：长按空档直接建任务（截止日预填为当天）。
        onLongPress: () => _createTaskOn(date),
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
                // T2-1：当日计划占时合计（与专注行同款弱化样式，仅有时显示）。
                if (planMin > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 1, left: 2),
                    child: Row(
                      children: [
                        Icon(Symbols.schedule, size: 9, color: ext.meta),
                        const SizedBox(width: 2),
                        Text(_planLabel(planMin),
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
    // T2-1 / T2-2（v2.9.2 功能增强）：条上时间标签三态——
    // ① 跨天区间任务：显示「起-止」日期带（M/d-M/d），一眼看出这是区间带的一段；
    // ② 带时刻且有预估的一次性任务：显示「起-止」时刻（截止 − 预估 = 占用起点），
    //    周视图的轻量「时间网格」表达，无需整页像素网格即可看出占时；
    // ③ 其余：维持原「HH:mm」或空。
    final String time;
    if (_isSpanTask(task)) {
      final s = task.startDate!;
      final d0 = task.dueDate!;
      time = '${s.month}/${s.day}-${d0.month}/${d0.day}';
    } else if (_hasTime(task.dueDate)) {
      final end = task.dueDate!;
      if (!task.done && task.hasEstimate) {
        final start =
            end.subtract(Duration(minutes: task.estimateMinutes!));
        time = '${DateFormat('HH:mm').format(start)}-'
            '${DateFormat('HH:mm').format(end)}';
      } else {
        time = DateFormat('HH:mm').format(end);
      }
    } else {
      time = '';
    }
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
                // U2（v2.9.0 审计）：列表 / 日程视图放宽到 2 行，与任务列表、看板卡片
                // 口径统一（原先此处与任务列表都是 1 行，长标题只剩首行）。
                // 月视图的密集条（dense）保持 1 行：格子高度固定，2 行会溢出。
                maxLines: dense ? 1 : 2,
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

    // T2-2（v2.9.2 功能增强）：跨天区间任务不支持拖拽改期——改 dueDate 会把
    // 区间带撕裂（startDate 仍是旧起点，区间语义残缺），长按给出正确路径提示
    // （详情页调整开始/截止时间）。translucent 让点击仍穿透到日期格。
    if (_isSpanTask(task)) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('跨天任务不支持拖拽改期，请在详情页调整开始/截止时间'),
              duration: Duration(seconds: 3),
            ),
          );
        },
        child: child,
      );
    }

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
          // U3-2（v2.9.5 审计）：去掉 `..hideCurrentSnackBar()`——U2-4 修复
          // （首页删除撤销）已确立「不主动清场、靠 ScaffoldMessenger 队列」
          // 的口径，此处仍清场会把队列里尚未点掉的撤销横幅一起收走。
          ScaffoldMessenger.of(context).showSnackBar(
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
    // T2-1/T2-2：当天到期 + 跨天区间覆盖的任务。
    final dueTasks = _tasksOnDay(provider, d);
    final isToday = _sameDay(d, today);
    final track = isDark ? AppColors.darkTrack : AppColors.lightTrack;
    // P3-9（v2.9.9 审计）：周视图补当日计划占时合计（月视图有、周视图此前没有）。
    final planMin = planMinutesOn(provider, d);
    return DragTarget<Task>(
      // P3-2（v2.8.8 审计）：重复任务的 dueDate 只是占位，拖拽改期是「假成功」，
      // 故在投放侧也一并拒绝（兜底：即便有其它来源的拖拽也不放行）。
      onWillAcceptWithDetails: (details) =>
          !details.data.done && !details.data.isRepeating,
      onAcceptWithDetails: (details) => _reschedule(details.data, d),
      builder: (ctx, candidate, rejected) => GestureDetector(
        // T2-1（v2.9.2 功能增强）：周视图列同样支持长按建任务（与月视图格一致）。
        onLongPress: () => _createTaskOn(d),
        child: Container(
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
            // P3-9（v2.9.9 审计）：当日计划占时合计（与月视图同款弱化样式）。
            if (planMin > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                child: Row(
                  children: [
                    Icon(Symbols.schedule, size: 10, color: ext.meta),
                    const SizedBox(width: 2),
                    Text('计划 ${_planLabel(planMin)}',
                        style: TextStyle(fontSize: 10, color: ext.meta)),
                  ],
                ),
              ),
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
      ),
    );
  }

  /// T2-1（v2.9.2 功能增强）：日历格长按直达新建任务——落点日期预填为截止日，
  /// 补上「日历直接建任务」的入口空白（此前日历纯只读，看到空档还得回首页新建）。
  /// 23:59 = 纯日期形态（dueIsPureDateForm），语义即「当天截止」而非具体时刻。
  void _createTaskOn(DateTime date) {
    TaskSheet.show(
      context,
      draft: Task(
        id: '',
        title: '',
        priority: Priority.medium,
        category: Category.work,
        dueDate: DateTime(date.year, date.month, date.day, 23, 59),
      ),
    );
  }

  // P2-8 / P2-9 / P2-11 的当日任务与占时逻辑见文件尾部的顶层函数
  //（_dueTasksOn / _spanTasksOn / _tasksOnDay / planMinutesOn）——纯
  // 「provider + date → 结果」，不读 State 字段，顶层化后可不经 widget 直测。

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
            // T2-1/T2-2：当天到期 + 跨天区间覆盖的任务。
            final tasks = _tasksOnDay(p, date);
            // P3-9（v2.9.9 审计）：计数拆开——旧文案「到期 N 个」把跨天任务一并
            // 计入（把「覆盖到当天」说成「当天到期」）；同时补当日计划占时合计。
            final dueCount = _dueTasksOn(p, date).length;
            final spanCount = tasks.length - dueCount;
            final planMin = planMinutesOn(p, date);
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
                      Text(
                        spanCount > 0
                            ? '到期 $dueCount 个 · 另有跨天 $spanCount 段'
                            : '到期 $dueCount 个',
                        // U7：用 ext.meta 替代硬编码的 lightMeta，否则暗色
                        // 模式下「M 月 d 日」旁的次要文本仍是浅灰、读不清。
                        style: TextStyle(fontSize: 13, color: ext.meta),
                      ),
                      if (planMin > 0) ...[
                        const SizedBox(width: 10),
                        Icon(Symbols.schedule, size: 12, color: ext.meta),
                        const SizedBox(width: 2),
                        Text('计划 ${_planLabel(planMin)}',
                            style:
                                TextStyle(fontSize: 12, color: ext.meta)),
                      ],
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
                            // U2-4（v2.9.1 审计）：整个日历模块此前**没有**任何到达
                            // 任务详情页的路径（弹层里只有勾选框可点，点标题毫无反应），
                            // 用户在日历上看到任务却无法查看/编辑它的备注、子任务、附件。
                            // 现让整行可点：先收起日期弹层，再推详情页；返回即回到日历。
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                Navigator.pop(ctx2);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        TaskDetailScreen(taskId: t.id),
                                  ),
                                );
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 4),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: Checkbox(
                                        value: t.done,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        // T3-2（v2.9.2 功能增强）：勾选完成带 10 秒撤销。
                                        onChanged: (v) =>
                                            toggleDoneWithUndo(context, p, t),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                            color: _priorityColor(
                                                t.priority, isDark),
                                            borderRadius:
                                                BorderRadius.circular(3))),
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
                                                      ? TextDecoration
                                                          .lineThrough
                                                      : null)),
                                          const SizedBox(height: 2),
                                          Text(
                                            // P3-16（v3.0.0 审计）：纯日期形态
                                            // （00:00/23:59）不再显示「00:00」
                                            // 式时刻，与 P2-10 的 _hasTime 判据
                                            // 同源（月格/周视图口径一致）。
                                            '${t.category.label}'
                                            '${t.dueDate != null && _hasTime(t.dueDate) ? " · ${DateFormat("HH:mm").format(t.dueDate!)}" : ""}',
                                            // U7：同上。
                                            style: TextStyle(
                                                fontSize: 12, color: ext.meta),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(Symbols.chevron_right,
                                        size: 18, color: ext.meta),
                                  ],
                                ),
                              ),
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

/// P2-11（v2.9.9 审计）：当天到期任务——重复任务须 [Task.repeatsOn] 当天才
/// 展示（repeatsOn 含 skipDates 判定：暂停中 / 已跳过的重复任务不再出现在
/// 日历、不计占时）。旧实现只按 dueDate 匹配，暂停态的重复任务照常出现。
///
/// 顶层纯函数（provider + date → 结果，不读 State 字段），月格 / 周视图 /
/// 日期弹层与单测共用；v2.9.9 验收轮自 `_CalendarScreenState` 上提。
List<Task> _dueTasksOn(TaskProvider provider, DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  return provider.tasksDueOn(day).where((t) {
    if (t.isRepeating && !t.repeatsOn(day)) return false;
    return true;
  }).toList();
}

/// T2-1 / T2-2（v2.9.2 功能增强）：跨天区间覆盖的天。区间任务在其截止日已由
/// 到期列表收录，这里只补「起止之间的其余天」，天然去重；区间内按开始日排序。
///
/// P3-13（v3.0.0 审计）：区间任务的中间日若落在该任务的跳过集合内
/// （暂停窗口写入的循环日 / 单独跳过日）则不再显示——暂停中的重复「区间
/// 任务」在中间日此前照常出现，与到期列表的 P2-11 过滤口径矛盾。非循环日
/// 的中间日不在 skipDates 内，区间显示不受影响（保守过滤，不破坏现有
/// 非暂停区间的展示）。
List<Task> _spanTasksOn(TaskProvider provider, DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  final span = provider.tasks
      .where((t) {
        if (t.deletedAt != null || t.dueDate == null || t.startDate == null) {
          return false;
        }
        if (!_isSpanTask(t)) return false;
        if (Task.isSameDay(t.dueDate!, day)) return false; // 截止日已在 due 列表
        // P3-13：该日被显式跳过（含暂停窗口内的循环日）→ 不显示。
        if (t.isRepeating && t.skipDates.contains(Task.ymdKey(day))) {
          return false;
        }
        final s0 =
            DateTime(t.startDate!.year, t.startDate!.month, t.startDate!.day);
        final d0 =
            DateTime(t.dueDate!.year, t.dueDate!.month, t.dueDate!.day);
        return !day.isBefore(s0) && !day.isAfter(d0);
      })
      .toList()
    ..sort((a, b) => a.startDate!.compareTo(b.startDate!));
  return span;
}

/// T2-1 / T2-2：日历某天应展示的任务 = 当天到期（[P2-11 过滤]）+ 跨天区间。
List<Task> _tasksOnDay(TaskProvider provider, DateTime date) =>
    [..._dueTasksOn(provider, date), ..._spanTasksOn(provider, date)];

/// P2-8 / P2-9（v2.9.9 审计）：当日「计划占时」合计（单一口径，月视图 /
/// 周视图 / 日期弹层共用）。顶层纯函数（provider + date → 结果），可不经
/// widget 直测（v2.9.9 验收轮自 `_CalendarScreenState` 上提）。
///
/// - **P2-8**：未完成任务无预估时按 [kDefaultEstimateMinutes] 兜底——与排程
///   建议（schedule_advisor）同一口径，此前日历只计有预估任务、两处「计划
///   占时」不可比；
/// - **P2-9**：跨天区间任务**只在首日**计入完整预估——旧实现区间覆盖到的
///   每天各计一次完整值，N 天任务被计 N 次（日合计虚高）；
/// - 已完成不计；暂停中的重复任务已在 [_dueTasksOn] 被过滤（P2-11）。
///
/// P3-14（v3.0.0 审计）：取值口径与排程建议**完全同源**——旧实现
/// `estimateMinutes ?? kDefaultEstimateMinutes` 在「预估=0」（UI 不可产生，
/// 仅手改备份 / iCal 可达）时计 0，而排程侧 hasEstimate（>0 才有效）计 30，
/// 两处「计划占时」在病态数据上仍不可比。统一改走 [Task.hasEstimate]。
int planMinutesOn(TaskProvider provider, DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  var total = 0;
  for (final t in _dueTasksOn(provider, day)) {
    if (t.done) continue;
    total += t.hasEstimate ? t.estimateMinutes! : kDefaultEstimateMinutes;
  }
  for (final t in _spanTasksOn(provider, day)) {
    if (t.done) continue;
    final s0 =
        DateTime(t.startDate!.year, t.startDate!.month, t.startDate!.day);
    if (s0 != day) continue; // P2-9：只在区间首日计入完整预估
    total += t.hasEstimate ? t.estimateMinutes! : kDefaultEstimateMinutes;
  }
  return total;
}

/// T2-2（v2.9.2 功能增强）：跨天区间任务判定——startDate 的日期部分**严格早于**
/// dueDate 的日期部分（同日起止是「时段任务」，不算区间）。
bool _isSpanTask(Task t) {
  final s = t.startDate;
  final d = t.dueDate;
  if (s == null || d == null) return false;
  final s0 = DateTime(s.year, s.month, s.day);
  final d0 = DateTime(d.year, d.month, d.day);
  return s0.isBefore(d0);
}

/// T2-1（v2.9.2 功能增强）：分钟 → 紧凑时长文案（<60 显示「N分」，否则「X.Xh」），
/// 与月视图专注行的既有口径一致。
String _planLabel(int mins) {
  if (mins < 60) return '${mins}分';
  final h = mins / 60;
  return h == h.roundToDouble() ? '${h.round()}h' : '${h.toStringAsFixed(1)}h';
}

/// T2-1：截止是否带「具体时刻」。
///
/// P2-10（v2.9.9 审计）：复用 [dueIsPureDateForm]（00:00 与 23:59 都是纯日期
/// 形态）——旧实现只判 `hour != 0 || minute != 0`，长按新建预填的 23:59 被
/// 误判为「带时刻」，任务条恒显示「起-止」时刻（如 23:29-23:59），与
/// 「23:59 = 当天截止」的语义自相矛盾。判秒口径与 dueIsPureDateForm 一致
/// （不判秒）。
bool _hasTime(DateTime? d) => d != null && !dueIsPureDateForm(d);

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
