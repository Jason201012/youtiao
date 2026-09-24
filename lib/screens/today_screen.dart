import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/today.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/screens/task_detail_screen.dart';
import 'package:todolist/screens/habit_screen.dart'
    show toggleHabitWithUndo, incrementWithCelebration;
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/services/app_nav.dart';
import 'package:todolist/services/schedule_advisor.dart';
import 'package:todolist/widgets/review_card.dart';
import 'package:todolist/widgets/today_share_sheet.dart';

/// 今日聚合页：从首页「今日」摘要卡 push 进来。
///
/// 不新增 tab（6→7 会破坏 Material 3 的节奏），也不新增任何存储，
/// 数据在 build 时由三个 Provider 聚合出一份快照；勾选任务 / 打卡会即时反映（watch）。
class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final task = context.watch<TaskProvider>();
    final focus = context.watch<FocusProvider>();
    final habit = context.watch<HabitProvider>();
    final today = TodayAggregate.fromProviders(task, focus, habit);

    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final onBg = Theme.of(context).colorScheme.onBackground;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: SafeArea(
        child: Column(
          children: [
            TopAppBar(
              title: '今日',
              onBack: () => Navigator.of(context).pop(),
              actions: [
                IconButton(
                  onPressed: () => showTodayShareSheet(context, today: today),
                  icon: Icon(Symbols.ios_share, size: 24, color: onBg),
                  tooltip: '分享今日',
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
                  // 日期 chip
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: ext.chip,
                      borderRadius: BorderRadius.circular(AppColors.chipRadius),
                    ),
                    child: Text(
                      today.dateLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 今日核心 2×2
                  ReviewSection(child: _CoreGrid(today: today, accent: accent)),
                  const SizedBox(height: 12),
                  // 今日待办（可勾选）
                  ReviewSection(
                    child: _TodoList(
                      today: today,
                      accent: accent,
                      onToggle: (t) => task.toggleDone(t.id),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // T1-1：今日排程建议（纯本地顺延预估，零新存储）
                  ReviewSection(
                    child: _ScheduleAdvisor(
                      today: today,
                      accent: accent,
                      ext: ext,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 今日待打卡
                  ReviewSection(
                    child: _HabitList(
                      today: today,
                      accent: accent,
                      ext: ext,
                      // U2-2（v2.9.3 审计）：取消打卡改走带 10 秒撤销的入口，
                      // 与习惯列表圆圈同口径（此前轻点即撤、误触无提示）。
                      onToggle: (h) => toggleHabitWithUndo(context, habit, h),
                      // U3-1（v2.9.3 审计）：今日页「+1」改走与习惯页相同的
                      // 庆祝路径——达标那一刻有反馈，用户不再以为没生效。
                      onIncrement: (h) =>
                          incrementWithCelebration(context, habit, h),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 今日专注
                  ReviewSection(child: _FocusSummary(today: today, ext: ext)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 今日核心 2×2：今日待办 / 今日已完成 / 今日专注(分) / 习惯打卡。
class _CoreGrid extends StatelessWidget {
  final TodayAggregate today;
  final Color accent;
  const _CoreGrid({required this.today, required this.accent});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final habitValue = today.habitExpected == 0
        ? '0'
        : '${today.habitDone}/${today.habitExpected}';
    final items = [
      _Item(value: '${today.todoCount - today.completedToday}', label: '今日待办'),
      _Item(value: '${today.completedToday}', label: '今日已完成'),
      _Item(value: '${today.focusMinutes}', label: '今日专注(分)'),
      _Item(value: habitValue, label: '习惯打卡'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('今日核心',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 2.2,
          children: [
            for (final it in items)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: ext.track.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      it.value,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(it.label, style: TextStyle(fontSize: 12, color: ext.meta)),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Item {
  final String value;
  final String label;
  const _Item({required this.value, required this.label});
}

/// 今日待办（可勾选）。
class _TodoList extends StatelessWidget {
  final TodayAggregate today;
  final Color accent;
  final void Function(Task) onToggle;
  const _TodoList({
    required this.today,
    required this.accent,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final list = today.pendingTasks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('今日待办',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('今天已完成所有待办 🎉',
                style: TextStyle(fontSize: 13, color: ext.meta)),
          )
        else
          for (int i = 0; i < list.length; i++)
            _TodoTile(
              task: list[i],
              isLast: i == list.length - 1,
              accent: accent,
              onBg: onBg,
              meta: ext.meta,
              onToggle: onToggle,
            ),
      ],
    );
  }
}

class _TodoTile extends StatelessWidget {
  final Task task;
  final bool isLast;
  final Color accent;
  final Color onBg;
  final Color meta;
  final void Function(Task) onToggle;
  const _TodoTile({
    required this.task,
    required this.isLast,
    required this.accent,
    required this.onBg,
    required this.meta,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    // U6：整行点击进任务详情（与首页/看板交互一致）；勾选完成改由最左侧
    // 的 Checkbox 自身处理，不再让整行 toggle——避免误触「明明想看看详情、
    // 结果被勾掉了」。
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: task.id)),
      ),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
        child: Row(
          children: [
            // U6：Checkbox 自身即可触发 toggle——保持原 _checkbox 视觉（空心
            // 边框圆角），点击区域仍由 InkWell 接管进入详情；改用 Checkbox
            // 是为了符合 a11y 预期（语义化勾选控件）。
            Checkbox(
              value: task.done,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (_) => onToggle(task),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: onBg),
              ),
            ),
            const SizedBox(width: 8),
            Text(_taskTime(task), style: TextStyle(fontSize: 11, color: meta)),
          ],
        ),
      ),
    );
  }
}

/// T1-1：今日「排程建议」卡。
///
/// 输入只是今日未完成待办（[TodayAggregate.pendingTasks]）与当前时刻，输出由
/// [buildScheduleAdvice] 这个纯函数算出「串行顺延」的预计起止时刻——不新增任何
/// 存储、不发任何网络请求，符合项目「严格离线」红线。
///
/// 展示三条信息：① 汇总（项数 / 总时长 / 预计完成时刻）；② 每条任务的预计时段与
/// 时长；③ 两类风险提示——「预计来不及」（超过截止时间）与「可能高估 / 低估」
/// （与累计专注时长比对，仅一次性任务，见 schedule_advisor 的 P2-3 口径）。
///
/// U2-4（v2.9.3 审计）：①全部完成时不再误报「今天没有待办」；②头部可点击折叠，
/// 收起明细行、保留汇总行（折叠态为会话内状态，不落盘）。
class _ScheduleAdvisor extends StatefulWidget {
  final TodayAggregate today;
  final Color accent;
  final AppColorsExt ext;
  const _ScheduleAdvisor({
    required this.today,
    required this.accent,
    required this.ext,
  });

  @override
  State<_ScheduleAdvisor> createState() => _ScheduleAdvisorState();
}

class _ScheduleAdvisorState extends State<_ScheduleAdvisor> {
  /// 最多展示的条目数：再多用户也读不完，且会把页面拉得很长。
  static const int _maxRows = 8;

  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final today = widget.today;
    final accent = widget.accent;
    final ext = widget.ext;
    final onBg = Theme.of(context).colorScheme.onBackground;
    final meta = ext.meta;
    final advice = buildScheduleAdvice(today.pendingTasks);
    final rows = advice.items.take(_maxRows).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // U2-4：头部可点折叠/展开，右侧给状态箭头。
        InkWell(
          onTap: () => setState(() => _collapsed = !_collapsed),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Text('排程建议',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('截止 → 时长 → 优先级',
                    style: TextStyle(fontSize: 11, color: meta)),
                const SizedBox(width: 6),
                Icon(
                  _collapsed ? Symbols.expand_more : Symbols.expand_less,
                  size: 18,
                  color: meta,
                  semanticLabel: _collapsed ? '展开排程明细' : '收起排程明细',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // U2-4：完成态换文案——用户刚做完所有事，不该再被告知「没有待办」。
        Text(
          advice.isEmpty
              ? (today.completedToday > 0
                  ? '今日待办已全部完成'
                  : '今天没有待办，无需排程')
              : advice.summary,
          style: TextStyle(fontSize: 12, color: meta),
        ),
        if (!advice.isEmpty && !_collapsed) ...[
          const SizedBox(height: 10),
          for (int i = 0; i < rows.length; i++)
            _ScheduleRow(
              item: rows[i],
              isLast: i == rows.length - 1,
              accent: accent,
              onBg: onBg,
              meta: meta,
            ),
          if (advice.items.length > rows.length)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('另有 ${advice.items.length - rows.length} 项未列出',
                  style: TextStyle(fontSize: 11, color: meta)),
            ),
          if (advice.missedDueCount > 0) ...[
            const SizedBox(height: 8),
            _AdviceNote(
              // U3-3（v2.9.3 审计）：警示改用体系内的黑白样式（警示图标 + 正文色）。
              icon: Symbols.warning,
              color: onBg,
              text: '${advice.missedDueCount} 项按顺延预计会超过截止时间，'
                  '建议先处理最紧急的一项或缩短预估',
            ),
          ],
          if (advice.overrunMinutes > 0) ...[
            const SizedBox(height: 6),
            _AdviceNote(
              icon: Symbols.schedule,
              color: meta,
              text: '今天剩余时间预计不够，超出约 ${formatMinutes(advice.overrunMinutes)}',
            ),
          ],
          if (advice.guessedCount > 0) ...[
            const SizedBox(height: 6),
            _AdviceNote(
              icon: Symbols.info,
              color: meta,
              text: '${advice.guessedCount} 项未设预计时长，'
                  '按 ${advice.defaultMinutes} 分钟估算（可在任务里填写）',
            ),
          ],
        ],
      ],
    );
  }
}

/// 排程建议的一行：预计时段 + 标题 + 时长 + 风险/偏差标记。
class _ScheduleRow extends StatelessWidget {
  final ScheduleItem item;
  final bool isLast;
  final Color accent;
  final Color onBg;
  final Color meta;
  const _ScheduleRow({
    required this.item,
    required this.isLast,
    required this.accent,
    required this.onBg,
    required this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final bias = item.biasLabel;
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              item.windowLabel,
              style: TextStyle(fontSize: 12, color: accent, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.task.title.isEmpty ? '(无标题)' : item.task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: onBg),
                ),
                const SizedBox(height: 2),
                Text(
                  <String>[
                    // 未显式设预估值时加「约」，避免把占位值伪装成用户设定。
                    '${item.explicit ? '' : '约 '}${formatMinutes(item.minutes)}',
                    if (item.missedDue) '预计超过截止',
                    if (bias != null) bias,
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 11,
                    // U3-3（v2.9.3 审计）：超时标记回到黑白——正文色比 meta 更重，
                    // 不引入彩色也能形成层级。
                    color: item.missedDue ? onBg : meta,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 排程建议底部的说明行（图标 + 弱化文案）。
class _AdviceNote extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _AdviceNote({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 11, color: color)),
        ),
      ],
    );
  }
}

/// 今日待打卡。
class _HabitList extends StatelessWidget {
  final TodayAggregate today;
  final Color accent;
  final AppColorsExt ext;
  final void Function(Habit) onToggle;
  /// T1-2：量化习惯的「+1」快速累加。
  final void Function(Habit) onIncrement;
  const _HabitList({
    required this.today,
    required this.accent,
    required this.ext,
    required this.onToggle,
    required this.onIncrement,
  });

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    final list = today.habits;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('今日待打卡',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        // P3-6（v2.9.3 审计）：量化习惯的「今日合计」叙事入口——
        // 此前 [TodayAggregate.habitValueToday] / [habitValueTarget] 定义后零消费。
        if (today.habitValueTarget > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '量化合计 · 今日 ${today.habitValueToday}/${today.habitValueTarget}',
              style: TextStyle(fontSize: 12, color: ext.meta),
            ),
          ),
        const SizedBox(height: 12),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            // U20：空状态从纯文字改为可操作入口——点「去创建」跳到习惯 Tab。
            child: Row(
              children: [
                Text('还没有习惯，去添加一个吧',
                    style: TextStyle(fontSize: 13, color: ext.meta)),
                const SizedBox(width: 10),
                TextButton.icon(
                  onPressed: () => AppNav.jumpToTab(4),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  icon: const Icon(Symbols.add, size: 16),
                  label: const Text('去创建'),
                ),
              ],
            ),
          )
        else
          for (int i = 0; i < list.length; i++)
            _HabitTile(
              status: list[i],
              isLast: i == list.length - 1,
              accent: accent,
              onBg: onBg,
              meta: ext.meta,
              onToggle: onToggle,
              onIncrement: onIncrement,
            ),
      ],
    );
  }
}

class _HabitTile extends StatelessWidget {
  final TodayHabitStatus status;
  final bool isLast;
  final Color accent;
  final Color onBg;
  final Color meta;
  final void Function(Habit) onToggle;
  final void Function(Habit) onIncrement;
  const _HabitTile({
    required this.status,
    required this.isLast,
    required this.accent,
    required this.onBg,
    required this.meta,
    required this.onToggle,
    required this.onIncrement,
  });

  @override
  Widget build(BuildContext context) {
    final canCheckIn = status.shouldCheckIn;
    final checked = status.checked;
    final quantified = status.habit.isQuantified;
    // T1-2：量化习惯的按钮语义是「+1 累加」（喝了再点一次），
    // 与布尔习惯的「打卡 / 取消打卡」不同；达标后用文案与图标区分，不再改行为。
    final met = status.met;
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        children: [
          Text(status.habit.emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.habit.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: onBg),
                ),
                if (quantified)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      met
                          ? '今日 ${status.value}/${status.target} · 已达标'
                          : '今日 ${status.value}/${status.target}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: met ? FontWeight.w600 : FontWeight.normal,
                        color: met ? accent : meta,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!canCheckIn)
            Text('今天不打卡', style: TextStyle(fontSize: 12, color: meta))
          else
            SizedBox(
              height: 31,
              child: quantified
                  ? FilledButton.icon(
                      // 已达标后仍允许继续累加（记录超额量），只是视觉上弱化。
                      onPressed: () => onIncrement(status.habit),
                      icon: const Icon(Symbols.add, size: 14),
                      label: const Text('+1', style: TextStyle(fontSize: 12)),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        backgroundColor: met ? accent.withValues(alpha: 0.18) : null,
                        foregroundColor: met ? accent : null,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppColors.chipRadius),
                        ),
                      ),
                    )
                  : checked
                      ? OutlinedButton.icon(
                          onPressed: () => onToggle(status.habit),
                          icon: Icon(Symbols.check, size: 14, color: accent),
                          label: Text('已打卡',
                              style: TextStyle(fontSize: 12, color: accent)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppColors.chipRadius),
                            ),
                            side: BorderSide(color: accent),
                          ),
                        )
                      : FilledButton(
                          onPressed: () => onToggle(status.habit),
                          child: const Text('打卡', style: TextStyle(fontSize: 12)),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppColors.chipRadius),
                            ),
                          ),
                        ),
            ),
        ],
      ),
    );
  }
}

/// 今日专注：summary + 进度条 + 会话行。
class _FocusSummary extends StatelessWidget {
  final TodayAggregate today;
  final AppColorsExt ext;
  const _FocusSummary({required this.today, required this.ext});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('今日专注',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Text(
          '今日专注 ${today.focusMinutes} 分 / 目标 ${today.focusGoalMinutes} 分',
          style: TextStyle(fontSize: 13, color: ext.meta),
        ),
        const SizedBox(height: 8),
        Container(
          height: 8,
          decoration: BoxDecoration(
            color: ext.track,
            borderRadius: BorderRadius.circular(AppColors.progressRadius),
          ),
          child: FractionallySizedBox(
            widthFactor: today.focusProgress,
            alignment: Alignment.centerLeft,
            child: Container(
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(AppColors.progressRadius),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (today.sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('今天还没有专注记录',
                style: TextStyle(fontSize: 13, color: ext.meta)),
          )
        else
          for (int i = 0; i < today.sessions.length; i++)
            _SessionRow(
              session: today.sessions[i],
              isLast: i == today.sessions.length - 1,
              onBg: onBg,
              meta: ext.meta,
            ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final FocusSession session;
  final bool isLast;
  final Color onBg;
  final Color meta;
  const _SessionRow({
    required this.session,
    required this.isLast,
    required this.onBg,
    required this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final h = session.startedAt.hour.toString().padLeft(2, '0');
    final m = session.startedAt.minute.toString().padLeft(2, '0');
    final durMin = (session.durationSec / 60).round();
    final detail = session.taskTitle ?? '独立专注';
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
      child: Row(
        children: [
          Text('$h:$m · 专注 ${durMin}分',
              style: TextStyle(fontSize: 12, color: onBg)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: meta),
            ),
          ),
        ],
      ),
    );
  }
}

/// 任务行右侧时间文案：有截止时间显示 HH:mm；重复无截止显示重复摘要；否则「全天」。
String _taskTime(Task t) {
  if (t.dueDate != null) {
    final h = t.dueDate!.hour.toString().padLeft(2, '0');
    final m = t.dueDate!.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  // P3-2（v2.9.1 审计）：已「结束重复」的任务（repeat 字段仍在、repeatUntil 已过）
  // 不能再显示「每天 / 每周 一、三」这类规则文案——它会同时落进「今天 / 未来」分区并
  // 静默不提醒，用户会以为「结束重复」没生效。U3（v2.9.0 审计）已在任务行加了
  // 「已结束重复」角标，此处是同一口径的横向推广。
  if (t.repeatEnded) return '已结束重复';
  if (t.isRepeating) return t.repeatSummary;
  return '全天';
}
