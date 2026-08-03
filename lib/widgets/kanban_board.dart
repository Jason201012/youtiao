import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 看板三列：待办 / 进行中 / 已完成。
/// - 长按卡片可拖拽到其它列，松手即改状态；
/// - 单击卡片在 待办→进行中→已完成→待办 间循环切换（ColorOS 上更稳妥的兜底交互）。
class KanbanBoard extends StatelessWidget {
  const KanbanBoard({super.key});

  static const List<(TaskStatus, String)> _cols = [
    (TaskStatus.todo, '待办'),
    (TaskStatus.doing, '进行中'),
    (TaskStatus.done, '已完成'),
  ];

  static Color _colColor(BuildContext context, TaskStatus s) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (s == TaskStatus.doing) {
      return isDark ? const Color(0xFF80C0FF) : const Color(0xFF378ADD);
    }
    if (s == TaskStatus.done) return const Color(0xFF0F6E56);
    return appColors(context).meta;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TaskProvider>();
    final groups = provider.kanbanGroups;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('看板',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onBackground,
            )),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (status, title) in _cols)
              Expanded(
                child: _Column(
                  title: title,
                  color: _colColor(context, status),
                  tasks: groups[status] ?? const [],
                  status: status,
                  provider: provider,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Column extends StatelessWidget {
  final String title;
  final Color color;
  final List<Task> tasks;
  final TaskStatus status;
  final TaskProvider provider;
  const _Column({
    required this.title,
    required this.color,
    required this.tasks,
    required this.status,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return DragTarget<Task>(
      onWillAcceptWithDetails: (d) => d.data.status != status,
      onAcceptWithDetails: (d) {
        provider.setStatus(d.data.id, status);
      },
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.08) : ext.track.withOpacity(0.35),
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
            border: active
                ? Border.all(color: color.withOpacity(0.5), width: 1)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onBackground,
                      )),
                  const Spacer(),
                  Text('${tasks.length}',
                      style: TextStyle(fontSize: 12, color: ext.meta)),
                ],
              ),
              const SizedBox(height: 8),
              for (final t in tasks) _KanbanCard(task: t, provider: provider),
            ],
          ),
        );
      },
    );
  }
}

class _KanbanCard extends StatelessWidget {
  final Task task;
  final TaskProvider provider;
  const _KanbanCard({required this.task, required this.provider});

  static void _cycle(TaskProvider p, Task t) {
    final next = t.status == TaskStatus.todo
        ? TaskStatus.doing
        : t.status == TaskStatus.doing
            ? TaskStatus.done
            : TaskStatus.todo;
    p.setStatus(t.id, next);
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prio = isDark ? task.priority.darkColor() : task.priority.lightColor();
    final done = task.status == TaskStatus.done;
    final dueHint = _dueHint(task);
    final overdue = dueHint == '逾期' && !done;

    final content = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        border: done ? null : Border.all(color: ext.track, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 14,
                margin: const EdgeInsets.only(top: 2, right: 6),
                decoration: BoxDecoration(
                  color: prio,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Text(
                  task.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: done ? ext.meta : onBg,
                    decoration: done ? TextDecoration.lineThrough : null,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (dueHint.isNotEmpty || task.isRepeating) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (task.isRepeating) Icon(Symbols.repeat, size: 13, color: ext.meta),
                if (task.isRepeating && dueHint.isNotEmpty) const SizedBox(width: 4),
                if (dueHint.isNotEmpty)
                  Text(
                    dueHint,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: overdue ? AppColors.lightHigh : ext.meta,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _cycle(provider, task),
      child: LongPressDraggable<Task>(
        data: task,
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: 96,
            child: content,
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: content),
        child: content,
      ),
    );
  }

  static String _dueHint(Task t) {
    if (t.dueDate == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(t.dueDate!.year, t.dueDate!.month, t.dueDate!.day);
    final diff = d.difference(today).inDays;
    if (diff > 0) return '$diff天后';
    if (diff == 0) return '今天';
    if (diff == -1) return '昨天';
    return '逾期';
  }
}
