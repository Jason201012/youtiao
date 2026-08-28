/// 重复任务「未来 N 天预览」弹层（P0-5，纯离线）。
///
/// 遍历 [Task.occurrencesBetween] 给出未来 30 天（默认）的循环命中日；
/// 每行支持「标记完成 / 跳过一次 / 移到下一天」三种逐次操作，分别写入
/// [Task.completedAt]（当天记录，与循环任务「当天已完成」语义同源）或 [Task.skipDates]
/// （跳过 / 顺延均复用既有跳过逻辑，零新增存储）。
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';

class OccurrenceSheet {
  static Future<void> show(
    BuildContext context,
    Task task,
    TaskProvider provider,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _OccurrenceBody(task: task, provider: provider),
    );
  }
}

class _OccurrenceBody extends StatefulWidget {
  final Task task;
  final TaskProvider provider;
  const _OccurrenceBody({required this.task, required this.provider});

  @override
  State<_OccurrenceBody> createState() => _OccurrenceBodyState();
}

class _OccurrenceBodyState extends State<_OccurrenceBody> {
  late Task _task;

  @override
  void initState() {
    super.initState();
    _task = widget.task;
  }

  void _refresh() {
    final latest = widget.provider.byId(_task.id);
    if (latest != null && mounted) setState(() => _task = latest);
  }

  bool _isDone(DateTime d) =>
      _task.done && _task.completedAt != null && Task.isSameDay(_task.completedAt!, d);
  bool _isSkipped(DateTime d) => _task.skipDates.contains(Task.ymdKey(d));

  void _markDone(DateTime d) {
    widget.provider.updateTask(_task.copyWith(
      status: TaskStatus.done,
      completedAt: DateTime(d.year, d.month, d.day),
    ));
    _refresh();
  }

  void _skip(DateTime d, {bool defer = false}) {
    final key = Task.ymdKey(d);
    if (_task.skipDates.contains(key)) return;
    widget.provider.updateTask(_task.copyWith(skipDates: [..._task.skipDates, key]));
    _refresh();
    if (defer && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已移到下一天（下次将顺延一个完整周期）')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final occ = _task.occurrencesBetween(DateTime.now());
    final weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('未来循环日预览',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('「${_task.title}」· 共 ${occ.length} 个循环日',
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          const Divider(height: 1),
          Expanded(
            child: occ.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('未来 30 天内没有循环日（可能已到结束日期）。',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  )
                : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: occ.length,
                    itemBuilder: (_, i) {
                      final d = occ[i];
                      final done = _isDone(d);
                      final skipped = _isSkipped(d);
                      final wd = weekdayNames[(d.weekday - 1).clamp(0, 6)];
                      return ListTile(
                        leading: Icon(
                          done
                              ? Symbols.check_circle
                              : skipped
                                  ? Symbols.block
                                  : Symbols.repeat,
                          color: done
                              ? Colors.green
                              : skipped
                                  ? Colors.grey
                                  : Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(
                          '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} 周$wd',
                        ),
                        subtitle: Text(
                          done ? '已完成' : skipped ? '已跳过' : '待处理',
                          style: TextStyle(
                            color: done ? Colors.green : skipped ? Colors.grey : null,
                          ),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'done') _markDone(d);
                            if (v == 'skip') _skip(d);
                            if (v == 'defer') _skip(d, defer: true);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'done', child: Text('标记完成')),
                            PopupMenuItem(value: 'skip', child: Text('跳过一次')),
                            PopupMenuItem(value: 'defer', child: Text('移到下一天')),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
