import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/task.dart';
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
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;
  const TaskRow({
    super.key,
    required this.task,
    this.onToggle,
    this.onLongPress,
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
    final content = Container(
      height: hasNote ? 78 : 64,
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
          // 标题（+ 备注预览）
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  task.title,
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
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 截止信息 + 每日提醒标识
          _MetaInfo(task: task, ext: ext),
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

/// 任务行右侧信息：每日提醒标识（🔁 HH:mm）+ 截止时间。
class _MetaInfo extends StatelessWidget {
  final Task task;
  final AppColorsExt ext;
  const _MetaInfo({required this.task, required this.ext});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (task.dailyReminder && task.dailyReminderMinute != null) {
      final hh = task.dailyReminderMinute! ~/ 60;
      final mm = task.dailyReminderMinute! % 60;
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.repeat, size: 14, color: ext.meta),
            const SizedBox(width: 2),
            Text(
              '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}',
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
