import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/new_task_sheet.dart';

/// 任务详情页：展示标题 / 备注 / 标签 / 截止重复 / 累计专注 / 子任务勾选，
/// 并提供编辑、开始专注、删除操作。数据通过 [TaskProvider.byId] 实时读取，
/// 子任务勾选与完成态即时反映到列表。
class TaskDetailScreen extends StatelessWidget {
  final String taskId;
  const TaskDetailScreen({super.key, required this.taskId});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TaskProvider>();
    final task = provider.byId(taskId);
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final primary = Theme.of(context).colorScheme.primary;

    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const Center(child: Text('任务不存在或已删除')),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final priorityColor = task.done
        ? ext.meta
        : (isDark ? task.priority.darkColor() : task.priority.lightColor());

    return Scaffold(
      appBar: AppBar(
        title: const Text('任务详情'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.edit),
            tooltip: '编辑',
            onPressed: () => TaskSheet.show(context, task: task),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppColors.pagePadX),
        children: [
          // 标题卡：优先级色条 + 勾选框 + 标题
          _Card(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 4,
                  height: 46,
                  margin: const EdgeInsets.only(right: 12, top: 2),
                  decoration: BoxDecoration(
                    color: priorityColor,
                    borderRadius: BorderRadius.circular(AppColors.ringBarRadius),
                  ),
                ),
                GestureDetector(
                  onTap: () => provider.toggleDone(task.id),
                  child: Container(
                    width: 24,
                    height: 24,
                    margin: const EdgeInsets.only(right: 12, top: 2),
                    decoration: BoxDecoration(
                      color: task.done ? primary : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(color: ext.meta),
                    ),
                    child: task.done
                        ? const Icon(Symbols.check, size: 16, color: Colors.white)
                        : null,
                  ),
                ),
                Expanded(
                  child: Text(
                    task.title.isNotEmpty ? task.title : '(无标题)',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: task.done ? ext.meta : onBg,
                      decoration: task.done
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 备注
          if (task.note.isNotEmpty) ...[
            const SizedBox(height: AppColors.contentGap),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('备注'),
                  const SizedBox(height: 6),
                  Text(task.note,
                      style: TextStyle(fontSize: 14, color: onBg)),
                ],
              ),
            ),
          ],

          // 标签
          if (task.tags.isNotEmpty) ...[
            const SizedBox(height: AppColors.contentGap),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('标签'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: task.tags
                        .where((t) => t.isNotEmpty)
                        .map((tag) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: ext.chip,
                                borderRadius:
                                    BorderRadius.circular(AppColors.chipRadius),
                              ),
                              child: Text('#$tag',
                                  style:
                                      TextStyle(fontSize: 12, color: ext.meta)),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ],

          // 截止 / 重复 / 累计专注
          const SizedBox(height: AppColors.contentGap),
          _Card(
            child: Column(
              children: [
                _RowItem(
                    icon: Symbols.event, label: '截止', value: _dueLabel(task.dueDate)),
                if (task.isRepeating)
                  _RowItem(
                      icon: Symbols.repeat,
                      label: '重复',
                      value: task.repeatFull),
                _RowItem(
                    icon: Symbols.timer,
                    label: '累计专注',
                    value: _focusLabel(task.focusSecTotal)),
              ],
            ),
          ),

          // 子任务
          if (task.subtasks.isNotEmpty) ...[
            const SizedBox(height: AppColors.contentGap),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const _Label('子任务'),
                      const Spacer(),
                      Text('${task.subtaskDone}/${task.subtaskTotal}',
                          style: TextStyle(fontSize: 13, color: ext.meta)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: task.subtaskTotal == 0
                        ? 0
                        : task.subtaskDone / task.subtaskTotal,
                    minHeight: 4,
                    backgroundColor: ext.track,
                    valueColor: AlwaysStoppedAnimation<Color>(ext.accent),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 4),
                  for (final s in task.subtasks)
                    _SubTile(
                      sub: s,
                      onChanged: (_) => provider.toggleSubTask(task.id, s.id),
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),

          // 开始专注
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                context.read<FocusProvider>().requestTask(task.id, task.title);
                Navigator.pop(context);
              },
              icon: const Icon(Symbols.timer),
              label: const Text('开始专注'),
            ),
          ),
          const SizedBox(height: 12),

          // 删除（带二次确认，避免误删）
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除任务'),
                        content: const Text('确认删除该任务？此操作可在任务列表滑动删除后撤销。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    ) ??
                    false;
                if (!confirmed) return;
                provider.deleteTask(task.id);
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Symbols.delete),
              label: const Text('删除'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情页统一卡片容器。
class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
        child: child,
      );
}

/// 分区小标题。
class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: appColors(context).meta),
      );
}

/// 一行（图标 + 标签 + 值）。
class _RowItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _RowItem(
      {required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: ext.meta),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 13, color: ext.meta)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onBackground),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// 子任务勾选项。
class _SubTile extends StatelessWidget {
  final SubTask sub;
  final ValueChanged<bool?> onChanged;
  const _SubTile({required this.sub, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return InkWell(
      onTap: () => onChanged(!sub.done),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              sub.done ? Symbols.check_circle : Symbols.circle,
              size: 20,
              color: sub.done ? ext.accent : ext.meta,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                sub.title,
                style: TextStyle(
                  fontSize: 14,
                  color: sub.done
                      ? ext.meta
                      : Theme.of(context).colorScheme.onBackground,
                  decoration: sub.done ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _dueLabel(DateTime? due) {
  if (due == null) return '无截止';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(due.year, due.month, due.day);
  final diff = d.difference(today).inDays;
  final time =
      ' ${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}';
  if (diff == 0) return '今天$time';
  if (diff == 1) return '明天$time';
  if (diff == -1) return '昨天$time';
  if (diff < 0) return '已逾期$time';
  return '${due.month}月${due.day}日$time';
}

String _focusLabel(int sec) {
  final m = (sec / 60).round();
  if (m < 60) return '$m分钟';
  final h = m ~/ 60;
  final mm = m % 60;
  return mm == 0 ? '${h}小时' : '${h}小时$mm分';
}
