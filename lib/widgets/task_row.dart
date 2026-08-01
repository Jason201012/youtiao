import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 任务行：高 64，圆角 14，surface 填充。
/// 左：优先级色条(3×36) → 勾选框(22) → 标题(15) → 截止信息(12)
class TaskRow extends StatelessWidget {
  final Task task;
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;
  const TaskRow({super.key, required this.task, this.onToggle, this.onLongPress});

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

    final content = Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Row(
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
          const SizedBox(width: 12),
          // 标题
          Expanded(
            child: Text(
              task.title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: titleColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          // 截止信息
          Text(
            _dueLabel(task.dueDate),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
          ),
        ],
      ),
    );

    // 长按整行打开编辑（勾选框仅切换完成态）
    if (onLongPress == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: content,
    );
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
}
