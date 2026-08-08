import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 任务行：高 64，圆角 14，surface 填充。
/// 左：优先级色条(3×36) → 勾选框(22) → 标题(15) → 截止信息(12)
///
/// [selecting] 为 true 时进入多选模式：左侧显示选择框（已选为高亮实心圆），
/// 整行点击切换选中（[onSelect]），不再响应长按编辑与勾选完成。
class TaskRow extends StatelessWidget {
  final Task task;
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;
  const TaskRow({
    super.key,
    required this.task,
    this.onToggle,
    this.onLongPress,
    this.onTap,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
  });

  Color _priorityColor(BuildContext context) {
    final ext = appColors(context);
    if (task.done) return ext.meta; // 已完成：灰
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? task.priority.darkColor() : task.priority.lightColor();
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final primary = Theme.of(context).colorScheme.primary;
    final titleColor = task.done ? ext.meta : onBg;

    // 左侧指示：多选模式显示选择框；否则显示优先级色条 + 完成勾选框
    late final Widget leading;
    if (selecting) {
      leading = Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: selected ? primary : Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? primary : ext.meta),
        ),
        child: selected
            ? const Icon(Symbols.check, size: 14, color: Colors.white)
            : null,
      );
    } else {
      leading = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 优先级色条
          Container(
            width: 3,
            height: 36,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: _priorityColor(context),
              borderRadius: BorderRadius.circular(AppColors.ringBarRadius),
            ),
          ),
          // 勾选框
          GestureDetector(
            onTap: onToggle,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: task.done ? primary : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: ext.meta),
              ),
              child: task.done
                  ? const Icon(Symbols.check, size: 14, color: Colors.white)
                  : null,
            ),
          ),
        ],
      );
    }

    final hasNote = task.note.isNotEmpty;
    final hasSub = task.subtasks.isNotEmpty;
    final hasTag = task.tags.isNotEmpty;
    final content = Container(
      height: (hasNote || hasSub || hasTag) ? 78 : 64,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        // 多选模式：已选项加一层淡色高亮边框，便于辨识
        border: selecting && selected
            ? Border.all(color: primary.withOpacity(0.6), width: 1.5)
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          if (!selecting) const SizedBox(width: 12),
          // 标题（+ 备注预览 + 标签 + 子任务进度）。普通模式下整块可点击打开详情。
          Expanded(
            child: _TitleBlock(
              task: task,
              ext: ext,
              titleColor: titleColor,
              hasNote: hasNote,
              hasSub: hasSub,
              hasTag: hasTag,
              onTap: onTap,
            ),
          ),
          const SizedBox(width: 12),
          // 截止信息 + 每日提醒标识 + 累计专注
          _MetaInfo(task: task, ext: ext),
          if (!task.done) ...[
            const SizedBox(width: 6),
            // 「专注」按钮：直接进入专注页并预选本任务
            IconButton(
              onPressed: () {
                final focus = context.read<FocusProvider>();
                focus.requestTask(task.id, task.title);
              },
              icon: Icon(Symbols.timer, size: 20, color: primary),
              tooltip: '开始专注',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ],
        ],
      ),
    );

    // 多选模式：整行点击切换选中
    if (selecting) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onSelect,
        child: content,
      );
    }
    // 普通模式：长按整行打开编辑（勾选框仅切换完成态）
    if (onLongPress == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: content,
    );
  }

}

String _dueLabel(DateTime? due) {
  if (due == null) return '无截止';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(due.year, due.month, due.day);
  final diff = d.difference(today).inDays;
  final time = ' ${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}';
  if (diff == 0) return '今天$time';
  if (diff == 1) return '明天$time';
  if (diff == -1) return '昨天$time';
  if (diff < 0) return '已逾期$time';
  return '${due.month}月${due.day}日$time';
}

/// 累计专注时长格式化：<60 分钟显示「N分钟」，否则「N小时M分」。
String _focusLabel(int sec) {
  final m = (sec / 60).round();
  if (m < 60) return '$m分钟';
  final h = m ~/ 60;
  final mm = m % 60;
  return mm == 0 ? '${h}小时' : '${h}小时$mm分';
}

/// 任务行标题区：标题 + 备注预览 + 子任务进度 + 标签。
/// 普通模式下整块可点击打开详情（[onTap]）；多选 / 无 onTap 时仅展示。
class _TitleBlock extends StatelessWidget {
  final Task task;
  final AppColorsExt ext;
  final Color titleColor;
  final bool hasNote;
  final bool hasSub;
  final bool hasTag;
  final VoidCallback? onTap;
  const _TitleBlock({
    required this.task,
    required this.ext,
    required this.titleColor,
    required this.hasNote,
    required this.hasSub,
    required this.hasTag,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final displayTitle = task.title.isNotEmpty ? task.title : '(无标题)';
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          displayTitle,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: titleColor,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (hasNote) ...[
          const SizedBox(height: 3),
          Text(
            task.note,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: ext.meta,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (hasSub) ...[
          const SizedBox(height: 5),
          _SubProgress(task: task, ext: ext),
        ],
        if (hasTag) ...[
          const SizedBox(height: 5),
          _TagChips(task: task, ext: ext),
        ],
      ],
    );
    if (onTap == null) return column;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: column,
    );
  }
}

/// 任务行右侧信息：每日提醒标识（🔁 HH:mm）+ 截止时间。
class _MetaInfo extends StatelessWidget {
  final Task task;
  final AppColorsExt ext;
  const _MetaInfo({required this.task, required this.ext});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (task.isRepeating && task.repeatFull.isNotEmpty) {
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.repeat, size: 14, color: ext.meta),
            const SizedBox(width: 2),
            Text(
              task.repeatFull,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
            ),
          ],
        ),
      );
    }
    children.add(
      Text(
        _dueLabel(task.dueDate),
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
      ),
    );
    if (task.focusSecTotal > 0) {
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.timer, size: 14, color: ext.meta),
            const SizedBox(width: 2),
            Text(
              _focusLabel(task.focusSecTotal),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
            ),
          ],
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          children[i],
        ],
      ],
    );
  }
}

/// 任务行内的子任务进度：『✓ done/total』文案 + 一条细进度条。
class _SubProgress extends StatelessWidget {
  final Task task;
  final AppColorsExt ext;
  const _SubProgress({required this.task, required this.ext});

  @override
  Widget build(BuildContext context) {
    final total = task.subtaskTotal;
    final done = task.subtaskDone;
    final ratio = total == 0 ? 0.0 : done / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.checklist, size: 13, color: ext.meta),
            const SizedBox(width: 4),
            Text(
              '$done/$total',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 120,
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 3,
            backgroundColor: ext.track,
            valueColor: AlwaysStoppedAnimation<Color>(ext.accent),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}

/// 任务行内的标签 chips：每个标签显示为「#标签」小圆角块。
class _TagChips extends StatelessWidget {
  final Task task;
  final AppColorsExt ext;
  const _TagChips({required this.task, required this.ext});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: task.tags
          .where((t) => t.isNotEmpty)
          .map((tag) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Text(
                  '#$tag',
                  style: TextStyle(fontSize: 12, color: ext.meta),
                ),
              ))
          .toList(),
    );
  }
}
