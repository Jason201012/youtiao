/// T3-2（v2.9.2 功能增强）：任务「完成 / 取消完成 + 10 秒撤销」的唯一 UI 入口。
///
/// ## 为什么要有这个文件
///
/// 报告 T3-2：删除有撤销、看板改状态有撤销（P3-10），唯独**首页 / 今日页 / 详情页 /
/// 日历弹层**的勾选完成没有任何反悔入口——误触首页勾选后只能进详情页手动改回。
/// 这里把四个入口的「勾选 → 提示 → 撤销」收成一个函数，与看板侧
/// `kanban_board._cycle` 的快照撤销完全同构：
///
/// - 撤销走 [TaskProvider.restoreTaskSnapshotPersisted]（整体快照回滚，先撤在途
///   提醒再按快照重排），**不**用反向 `toggleDone`——后者会写新的 completedAt /
///   doneDates，无法精确还原（P3-10 定下的契约，v2.9.4 审计）。
///   U2-1（v3.0.6 审计）：由「存在语义」的 `restoreTaskSnapshot` 改为「落盘语义」
///   的 `restoreTaskSnapshotPersisted`（与通知侧 main._doTaskUndo 同款），
///   统一走 [taskUndoAction] 三分支，见其注释。
/// - 文案/时长/超时提示统一走 `showUndoSnackBar` 唯一实现（P3-5）。
/// - [task] 必须是**勾选前**的对象：它同时是撤销快照与文案判据
///   （`task.done` 为勾选前状态）。
library;

import 'package:flutter/material.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';

/// U2-1（v3.0.6 审计）：任务侧 App 内写入口的落盘失败**统一提示**——与习惯侧
/// `showCheckInPersistFailedHint`（habit_screen.dart）同文案同口径。provider 的
/// setStatus / toggleDone / markOccurrenceDone 自 P2-1（v3.0.5 审计）起透传
/// `_persist` 结果，但 App 内 5 处调用点全部 fire-and-forget：DB 异常时横幅照弹
/// 「已完成（10 秒内可撤销）」、列表照显完成，重启回退为未完成——与通知面刚修掉
/// 的谎报完全同构，只是发生在 App 内。任务侧 provider **不做内存回滚**
/// （与习惯侧 P3-2 的口径差异，v3.0.5 报告核查备注 A 已接受），故提示文案
/// 为「数据未保存」而非「操作未生效」。
void showTaskPersistFailedHint(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('写入失败：数据未保存，请重试')),
  );
}

/// U2-1（v3.0.6 审计）：任务侧撤销回调的统一包装（单条 / 批量共用），消费
/// [TaskProvider.restoreTaskSnapshotPersisted] 的落盘结果，与通知侧
/// main._doTaskUndo 同款三分支：
/// - 落盘成功 → true（横幅正常收起）；
/// - 任务已删 → false（由 showUndoSnackBar 唯一实现弹「撤销已失效」）；
/// - 落盘失败但任务仍在（内存撤销已生效、仅未持久化）→ 如实弹
///   [showTaskPersistFailedHint] 并返回 true——旧实现经 restoreTaskSnapshot
///   的「存在语义」走到这里会弹「撤销已失效」，把实际已生效的撤销误报为
///   失效（P3-1，v3.0.6 审计同款错位）。
UndoAction taskUndoAction(
  BuildContext context,
  TaskProvider provider,
  List<Task> snapshots,
) {
  return () async {
    var ok = true;
    var notSaved = false;
    for (final s in snapshots) {
      final r = await provider.restoreTaskSnapshotPersisted(s);
      if (!r) {
        if (provider.byId(s.id) == null) {
          ok = false; // 任务已删：真失效
        } else {
          notSaved = true; // 落盘失败、内存撤销已生效
        }
      }
    }
    if (notSaved && context.mounted) showTaskPersistFailedHint(context);
    return ok;
  };
}

/// 切换 [task] 的完成态并弹 10 秒撤销提示。
///
/// U2-1（v3.0.6 审计）：按落盘结果反馈——失败先弹「写入失败」提示、**仍给**
/// 撤销横幅（任务侧 provider 不内存回滚，UI 显示的完成态需要撤销入口；
/// 撤销本身也会重试落盘）。旧实现 fire-and-forget 后无条件弹横幅，DB 异常时
/// 用户看到「已完成（10 秒内可撤销）」却不知数据未保存。
Future<void> toggleDoneWithUndo(
    BuildContext context, TaskProvider provider, Task task) async {
  final ok = await provider.toggleDone(task.id);
  if (!context.mounted) return;
  if (!ok) showTaskPersistFailedHint(context);
  final title = task.title.isEmpty ? '(无标题)' : task.title;
  showUndoSnackBar(
    context,
    content: undoContent(
        task.done ? '已把「$title」移回待办' : '已完成「$title」'),
    onUndo: taskUndoAction(context, provider, [task]),
  );
}
