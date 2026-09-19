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
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/services/app_nav.dart';
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
                  // 今日待打卡
                  ReviewSection(
                    child: _HabitList(
                      today: today,
                      accent: accent,
                      ext: ext,
                      onToggle: (h) => habit.toggleCheckInToday(h),
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

  Widget _checkbox() => Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(color: accent, width: 1.5),
          borderRadius: BorderRadius.circular(6),
        ),
      );
}

/// 今日待打卡。
class _HabitList extends StatelessWidget {
  final TodayAggregate today;
  final Color accent;
  final AppColorsExt ext;
  final void Function(Habit) onToggle;
  const _HabitList({
    required this.today,
    required this.accent,
    required this.ext,
    required this.onToggle,
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
  const _HabitTile({
    required this.status,
    required this.isLast,
    required this.accent,
    required this.onBg,
    required this.meta,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final canCheckIn = status.shouldCheckIn;
    final checked = status.checked;
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        children: [
          Text(status.habit.emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status.habit.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: onBg),
            ),
          ),
          const SizedBox(width: 8),
          if (!canCheckIn)
            Text('今天不打卡', style: TextStyle(fontSize: 12, color: meta))
          else
            SizedBox(
              height: 31,
              child: checked
                  ? OutlinedButton.icon(
                      onPressed: () => onToggle(status.habit),
                      icon: Icon(Symbols.check, size: 14, color: accent),
                      label: Text('已打卡',
                          style: TextStyle(fontSize: 12, color: accent)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppColors.chipRadius),
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
                          borderRadius: BorderRadius.circular(AppColors.chipRadius),
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
