import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/new_task_sheet.dart';

/// 识别备注中的 http(s) 链接并渲染为可点击文本（其余部分保持普通文本）。
/// 正则匹配 http:// 或 https:// 起头的连续非空白字符。点击用 url_launcher 打开。
class _NoteText extends StatelessWidget {
  final String text;
  final Color color;
  const _NoteText({required this.text, required this.color});

  static final RegExp _urlRe = RegExp(r'https?://[^\s]+');

  @override
  Widget build(BuildContext context) {
    final matches = _urlRe.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: TextStyle(fontSize: 14, color: color));
    }
    final spans = <InlineSpan>[];
    int cursor = 0;
    final linkColor = Theme.of(context).colorScheme.primary;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(
          text: text.substring(cursor, m.start),
          style: TextStyle(fontSize: 14, color: color),
        ));
      }
      final url = text.substring(m.start, m.end);
      spans.add(TextSpan(
        text: url,
        style: TextStyle(fontSize: 14, color: linkColor, decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()
          ..onTap = () async {
            final uri = Uri.tryParse(url);
            if (uri != null && await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
      ));
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(
        text: text.substring(cursor),
        style: TextStyle(fontSize: 14, color: color),
      ));
    }
    return RichText(text: TextSpan(children: spans));
  }
}

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
                  _NoteText(text: task.note, color: onBg),
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
                if (task.startDate != null)
                  _RowItem(
                      icon: Symbols.event_available,
                      label: '开始',
                      value: _dueLabel(task.startDate)),
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

          // 转为习惯（S5）：把当前任务一键转为日常习惯，并询问是否删除原任务（走回收站可撤销）。
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _convertToHabit(context, task),
              icon: const Icon(Symbols.repeat),
              label: const Text('转为习惯'),
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

/// 把任务一键转为习惯（S5）。
///
/// 逻辑：用任务标题建一条「每天」打卡的习惯（emoji 用默认✅，强调色用品牌色，
/// 不携带提醒时间——让用户后续在习惯页自行设置提醒时机，避免误打扰）。
/// 建完后询问是否删除原任务：选「删除」则走 deleteTask（进回收站、可撤销），
/// 不选则保留任务（用户可同时保留任务与习惯，互不影响）。
Future<void> _convertToHabit(BuildContext context, Task task) async {
  final habit = context.read<HabitProvider>();
  // 习惯默认「每天」打卡（weekdays 空=每天），emoji✅，品牌色，无提醒。
  final brandColor = Theme.of(context).colorScheme.primary.value;
  await habit.addHabit(
    title: task.title,
    emoji: '✅',
    colorValue: brandColor,
    weekdays: const [], // 空=每天
    reminderMinute: null, // 不自动提醒，用户后续自行设置
  );

  if (!context.mounted) return;
  // 询问是否删除原任务（默认保留，避免误删）。选「删除」才进回收站（可撤销）。
  final remove = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('已转为习惯'),
      content: const Text('已把该任务创建为「每天」打卡的习惯。是否同时删除原任务？（删除后可在回收站撤销）'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('保留任务'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除任务'),
        ),
      ],
    ),
  );
  if (remove == true) {
    context.read<TaskProvider>().deleteTask(task.id);
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已转为习惯（可在「习惯」页设置提醒）')),
    );
    Navigator.pop(context);
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
