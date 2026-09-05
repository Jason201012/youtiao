/// 重复任务「未来 N 天预览」弹层（P0-5，纯离线）。
///
/// 遍历 [Task.occurrencesBetween] 给出未来 30 天（默认）的循环命中日；
/// 每行支持「标记完成 / 跳过一次 / 移到下一天」三种逐次操作，分别走
/// [TaskProvider.markOccurrenceDone] / [TaskProvider.unmarkOccurrenceDone] /
/// [TaskProvider.skipOccurrence]（三者均为 occurrence 级入口，写入
/// [Task.doneDates] / [Task.skipDates]，避免此前 `updateTask(copyWith(status))`
/// 被 `_applyTaskUpdate` 强制回填旧状态而丢失的 100% 无效路径）。
///
/// 「移到下一天」额外走 [TaskProvider.rescheduleOnceOccurrence]，把当天加入
/// skipDates 后另建一次性副本落到 newDay，零新概念。
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

  bool _isDone(DateTime d) => _task.isDoneOn(d);
  bool _isSkipped(DateTime d) => _task.skipDates.contains(Task.ymdKey(d));

  void _markDone(DateTime d) {
    // F1：之前 `updateTask(copyWith(status:done))` 路径被 _applyTaskUpdate 强制
    // 回填旧 status，写入静默丢失、UI 无变化。这里走 provider 显式 occurrence
    // 入口，等价于 toggleDone：doneDates 落点 + 重排提醒。
    if (_isDone(d)) {
      widget.provider.unmarkOccurrenceDone(_task.id, d);
    } else {
      widget.provider.markOccurrenceDone(_task.id, d);
    }
    _refresh();
  }

  void _skip(DateTime d, {bool defer = false}) {
    // P2-2：所有重复类型都走 provider.skipOccurrence（内部已统一重排提醒），
    // 不再用 updateTask 写 skipDates，避免 reminder 链路与列表标记脱节。
    if (_isSkipped(d)) return;
    if (defer) {
      // 「移到下一天」= 把当前 occurrence 跳过 + 在新日期另落一次性副本。
      final newDay = d.add(const Duration(days: 1));
      widget.provider.rescheduleOnceOccurrence(
        _task.id,
        newDay,
        origDay: d,
      );
      _refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已移到 ${newDay.month.toString().padLeft(2, '0')}-${newDay.day.toString().padLeft(2, '0')}（已新建一次性副本）',
            ),
            action: SnackBarAction(
              label: '撤销',
              onPressed: () {
                // 撤销 = 把当天的 skipDates 撤销（兜底：仍写入，但弹提示让用户知道）。
                // 一次性副本需要单独删，这里只能简化处理：若副本标题 = 「原任务标题」
                // 且 dueDate = newDay，则一并删除。
                final copy = widget.provider.tasks.firstWhere(
                  (t) =>
                      t.title == _task.title &&
                      t.dueDate != null &&
                      t.dueDate!.year == newDay.year &&
                      t.dueDate!.month == newDay.month &&
                      t.dueDate!.day == newDay.day,
                  orElse: () => _task,
                );
                if (!identical(copy, _task)) {
                  widget.provider.permanentDelete(copy.id);
                }
              },
            ),
          ),
        );
      }
      return;
    }
    widget.provider.skipOccurrence(_task.id, day: d);
    _refresh();
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
                      // U16：完成态原硬编码 Colors.green，深色主题下刺眼且与
                      // App 语义色脱节；改主色（与全局完成勾选一致）。
                      final doneColor = Theme.of(context).colorScheme.primary;
                      return ListTile(
                        leading: Icon(
                          done
                              ? Symbols.check_circle
                              : skipped
                                  ? Symbols.block
                                  : Symbols.repeat,
                          color: done
                              ? doneColor
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
                            color:
                                done ? doneColor : skipped ? Colors.grey : null,
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
