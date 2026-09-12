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

  /// F-10：今天的 date-only 值，用于区分「未来循环日」（只可跳过 / 改期）。
  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

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
      // F-2（v2.8.5 审计）：若 newDay 本身就是循环日，provider 只会 skip 本次、
      // **不建副本**（返回 null）——否则目标日循环提醒 + 副本一次性提醒双响，
      // 且循环完成后副本仍挂着。文案与撤销动作据此分支。
      final newDay = d.add(const Duration(days: 1));
      final copy = widget.provider.rescheduleOnceOccurrence(
        _task.id,
        newDay,
        origDay: d,
      );
      _refresh();
      if (context.mounted) {
        final dayLabel =
            '${newDay.month.toString().padLeft(2, '0')}-${newDay.day.toString().padLeft(2, '0')}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(copy == null
                ? '已移到 $dayLabel（该日本就是循环日，由原循环覆盖，无需另建副本）'
                : '已移到 $dayLabel（已新建一次性副本）'),
            action: SnackBarAction(
              label: '撤销',
              onPressed: () {
                // P2-1：撤销必须**双向**还原——① 按 service 返回的副本 id 精确移除
                // 那座一次性副本（原实现按「标题 + 日期」反查，同名任务同一天改期时
                // 会误删另一个真实任务；而且误用了只作用于回收站的 permanentDelete，
                // 副本其实一直留在活动列表里，「撤销」形同虚设）；② 把原日从 skipDates
                // 移除，否则撤销后原日仍显示「已跳过」，UI 对用户说谎。
                if (copy != null) {
                  widget.provider.discardTask(copy.id);
                }
                widget.provider.unskipOccurrence(_task.id, day: d);
                _refresh();
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
                      // F-10：未来循环日**不允许**「标记完成」（预打卡）——那样
                      // 列表显示「已完成」而当天提醒照样响，语义自相矛盾。
                      // 未来日期只提供「跳过一次 / 移到下一天」（都不涉及完成态）。
                      // 例外：该日若**已经**被标记完成（旧版本遗留的预打卡数据），
                      // 仍允许「标记未完成」把脏数据清掉，否则用户无从撤销。
                      final isFuture = d.isAfter(_today);
                      final canToggleDone = !isFuture || done;
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
                          done
                              ? '已完成'
                              : skipped
                                  ? '已跳过'
                                  : isFuture
                                      ? '待处理（未来只可跳过 / 改期）'
                                      : '待处理',
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
                          // P3-2：文案随实例状态动态化——已完成实例此前仍标「标记完成」，
                          // 点下去实际是取消完成，语义与行为相反。
                          itemBuilder: (_) => [
                            if (canToggleDone)
                              PopupMenuItem(
                                  value: 'done',
                                  child: Text(done ? '标记未完成' : '标记完成')),
                            const PopupMenuItem(value: 'skip', child: Text('跳过一次')),
                            const PopupMenuItem(value: 'defer', child: Text('移到下一天')),
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
