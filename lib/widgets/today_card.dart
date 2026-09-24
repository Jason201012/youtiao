import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/today.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 首页「今日」摘要卡（屏A）：3 个小指标 + 「查看今日安排 →」。
/// 整卡可点击进入 [TodayScreen]。
class TodayCard extends StatelessWidget {
  final TodayAggregate today;
  final VoidCallback? onTap;
  const TodayCard({super.key, required this.today, this.onTap});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final onBg = Theme.of(context).colorScheme.onBackground;

    final habitValue =
        today.habitExpected == 0 ? '0' : '${today.habitDone}/${today.habitExpected}';
    final items = [
      _MiniStat(value: '${today.completedToday}', label: '今日完成', color: accent),
      _MiniStat(value: '${today.focusMinutes}', label: '专注分', color: accent),
      _MiniStat(value: habitValue, label: '已打卡', color: accent),
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
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '今日',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: onBg,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                today.dateLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: ext.meta,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Text(
                    '查看今日安排',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Symbols.arrow_forward_ios, size: 12, color: accent),
                ],
              ),
            ],
          ),
          SizedBox(height: 12, child: Divider(color: ext.track, height: 1, thickness: 1)),
          const SizedBox(height: 14),
          Row(
            children: [
              for (int i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _miniStatCell(context, items[i])),
              ],
            ],
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

  Widget _miniStatCell(BuildContext context, _MiniStat s) => Column(
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
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: appColors(context).meta,
            ),
          ),
        ],
      );
}

class _MiniStat {
  final String value;
  final String label;
  final Color color;
  const _MiniStat({required this.value, required this.label, required this.color});
}

/// 今日聚合分享长图卡片。
///
/// 固定 [width] 逻辑像素（默认 360），内部强制套用 lightTheme/darkTheme，
/// 锁定文字缩放为 1.0，外层用 RepaintBoundary 截图后按 pixelRatio 3 导出。
class TodayShareCard extends StatelessWidget {
  final TodayAggregate today;
  final bool dark;
  final double width;
  const TodayShareCard({
    super.key,
    required this.today,
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
      _Header(dateLabel: today.dateLabel),
      const SizedBox(height: 14),
      _Section(
        title: '今日核心',
        child: _CoreMetrics(today: today),
      ),
    ];
    void add(Widget w) {
      blocks.add(const SizedBox(height: 12));
      blocks.add(w);
    }

    add(_Section(title: '今日待办', child: _TodoList(today: today)));
    add(_Section(title: '今日待打卡', child: _HabitList(today: today)));
    add(_Section(title: '今日专注', child: _FocusBlock(today: today)));

    blocks.add(const SizedBox(height: 16));
    blocks.add(const _Footer());
    return blocks;
  }
}

/// 顶部品牌行。
class _Header extends StatelessWidget {
  final String dateLabel;
  const _Header({required this.dateLabel});

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
          child: Icon(Symbols.today, size: 21, color: accent),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '有条 · 今日',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: onBg,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              dateLabel,
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

/// 板块外壳（与 ReviewSection 同款视觉）。
class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: onBg,
            ),
          ),
          SizedBox(height: 12, child: Divider(color: ext.track, height: 1, thickness: 1)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// 今日核心 2×2 指标。
class _CoreMetrics extends StatelessWidget {
  final TodayAggregate today;
  const _CoreMetrics({required this.today});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final habitValue = today.habitExpected == 0
        ? '0'
        : '${today.habitDone}/${today.habitExpected}';
    final items = [
      _Cell(value: '${today.todoCount - today.completedToday}', label: '今日待办', color: accent),
      _Cell(value: '${today.completedToday}', label: '今日已完成', color: accent),
      _Cell(value: '${today.focusMinutes}', label: '今日专注(分)', color: accent),
      _Cell(value: habitValue, label: '习惯打卡', color: accent),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 2.0,
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
                    color: it.color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  it.label,
                  style: TextStyle(fontSize: 12, color: ext.meta),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Cell {
  final String value;
  final String label;
  final Color color;
  const _Cell({required this.value, required this.label, required this.color});
}

/// 今日待办列表（仅前若干条，避免长图过长）。
class _TodoList extends StatelessWidget {
  final TodayAggregate today;
  const _TodoList({required this.today});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final list = today.pendingTasks.take(6).toList();
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('今天没有待办事项', style: TextStyle(fontSize: 13, color: ext.meta)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < list.length; i++)
          _TodoRow(
            task: list[i],
            isLast: i == list.length - 1,
            onBg: onBg,
            meta: ext.meta,
          ),
      ],
    );
  }
}

class _TodoRow extends StatelessWidget {
  final Task task;
  final bool isLast;
  final Color onBg;
  final Color meta;
  const _TodoRow({
    required this.task,
    required this.isLast,
    required this.onBg,
    required this.meta,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: Row(
        children: [
          _checkbox(context, false),
          const SizedBox(width: 10),
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
    );
  }

  Widget _checkbox(BuildContext context, bool done) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: done ? accent : Colors.transparent,
        border: Border.all(color: accent, width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: done
          ? const Icon(Symbols.check, size: 13, color: Colors.white)
          : null,
    );
  }
}

/// 今日待打卡列表。
class _HabitList extends StatelessWidget {
  final TodayAggregate today;
  const _HabitList({required this.today});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final list = today.habits;
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('还没有习惯，去添加一个吧', style: TextStyle(fontSize: 13, color: ext.meta)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < list.length; i++)
          _HabitRow(
            status: list[i],
            isLast: i == list.length - 1,
            onBg: onBg,
            meta: ext.meta,
            accent: accent,
          ),
      ],
    );
  }
}

class _HabitRow extends StatelessWidget {
  final TodayHabitStatus status;
  final bool isLast;
  final Color onBg;
  final Color meta;
  final Color accent;
  const _HabitRow({
    required this.status,
    required this.isLast,
    required this.onBg,
    required this.meta,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final checked = status.checked;
    // T1-2：量化习惯显示「今日 x/y」而不是「待打卡 / 已打卡」——
    // 「喝了 3 杯但目标 8 杯」既不该显示「已打卡」，也不该显示「待打卡」。
    // P3-5（v2.9.3 审计）：量化分支此前忽略 [status.shouldCheckIn]——
    // 「每周一三五 · 8 杯水」在周二（休息日）显示「今日 0/8」，
    // 与布尔习惯的「今天不打卡」口径不一致；现休息日统一显示「今天不打卡」
    // （有记录时仍优先展示进度，保留补录事实）。
    final label = checked
        ? (status.habit.isQuantified
            ? (status.met
                ? '已达标 ${status.value}/${status.target}'
                : '今日 ${status.value}/${status.target}')
            : '已打卡')
        : (status.shouldCheckIn
            ? (status.habit.isQuantified
                ? '今日 ${status.value}/${status.target}'
                : '待打卡')
            : '今天不打卡');
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: Row(
        children: [
          Text(status.habit.emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status.habit.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: onBg),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: (checked && !status.habit.isQuantified) || status.met
                  ? accent
                  : meta,
            ),
          ),
        ],
      ),
    );
  }
}

/// 今日专注：summary + 进度条 + 会话行。
class _FocusBlock extends StatelessWidget {
  final TodayAggregate today;
  const _FocusBlock({required this.today});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        if (today.sessions.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (int i = 0; i < today.sessions.length && i < 5; i++)
            _SessionRow(
              session: today.sessions[i],
              isLast: i == today.sessions.length - 1 || i == 4,
              onBg: onBg,
              meta: ext.meta,
            ),
        ],
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
          Text(
            '$h:$m · 专注 ${durMin}分',
            style: TextStyle(fontSize: 12, color: onBg),
          ),
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
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ext.meta),
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
