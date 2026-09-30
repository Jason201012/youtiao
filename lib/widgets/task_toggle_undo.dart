/// T3-2（v2.9.2 功能增强）：任务「完成 / 取消完成 + 10 秒撤销」的唯一 UI 入口。
///
/// ## 为什么要有这个文件
///
/// 报告 T3-2：删除有撤销、看板改状态有撤销（P3-10），唯独**首页 / 今日页 / 详情页 /
/// 日历弹层**的勾选完成没有任何反悔入口——误触首页勾选后只能进详情页手动改回。
/// 这里把四个入口的「勾选 → 提示 → 撤销」收成一个函数，与看板侧
/// `kanban_board._cycle` 的快照撤销完全同构：
///
/// - 撤销走 [TaskProvider.restoreTaskSnapshot]（整体快照回滚，先撤在途提醒再按
///   快照重排），**不**用反向 `toggleDone`——后者会写新的 completedAt / doneDates，
///   无法精确还原（P3-10 定下的契约，v2.9.4 审计）。
/// - 文案/时长/超时提示统一走 `showUndoSnackBar` 唯一实现（P3-5）。
/// - [task] 必须是**勾选前**的对象：它同时是撤销快照与文案判据
///   （`task.done` 为勾选前状态）。
library;

import 'package:flutter/material.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';

/// 切换 [task] 的完成态并弹 10 秒撤销提示。
void toggleDoneWithUndo(BuildContext context, TaskProvider provider, Task task) {
  provider.toggleDone(task.id);
  final title = task.title.isEmpty ? '(无标题)' : task.title;
  showUndoSnackBar(
    context,
    content: undoContent(
        task.done ? '已把「$title」移回待办' : '已完成「$title」'),
    onUndo: () async => provider.restoreTaskSnapshot(task),
  );
}
