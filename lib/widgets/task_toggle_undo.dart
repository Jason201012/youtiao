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
import 'package:todolist/widgets/sheet_message.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';

/// U2-1（v3.0.6 审计）：任务侧 App 内写入口的落盘失败**统一提示**——与习惯侧
/// `showCheckInPersistFailedHint`（habit_screen.dart）同口径。provider 的
/// setStatus / toggleDone / markOccurrenceDone 自 P2-1（v3.0.5 审计）起透传
/// `_persist` 结果，P2-2（v3.0.7 审计）起新建 / 编辑 / 删除 / 循环控制等全部
/// 写入口统一返回 `Future<bool>`，App 内各调用点消费结果后弹本提示。任务侧
/// provider **不做内存回滚**（与习惯侧 P3-2 的口径差异，v3.0.5 报告核查备注 A
/// 已接受），故提示文案为「数据未保存」而非「操作未生效」。
///
/// P3-2（v3.0.7 审计）：区分 [TaskProvider.dbLoadFailed]（安全模式）——旧文案
/// 对所有失败一律「请重试」，而安全模式下 `_persist()` **恒** false（设计行为：
/// 保护坏库不被内存态覆盖），顶部横幅已如实告知「本次修改不会保存」：此时再弹
/// 「写入失败：请重试」既与横幅重复、又是误导（重试必然再失败）。安全模式改为
/// 指向根因的文案，真正的 DB 异常才说「自动一并保存」（全量 replaceTasks 写，
/// 后续任意一次成功写入即自愈——U2-2，v3.0.7 审计：把「请重试」落到具体可执行
/// 的动作上，撤销类一次性 action 场景没有重试载体，「继续操作即落库」是事实）。
///
/// [provider] 可空（测试 / 无 provider 上下文）：缺省时按「非安全模式」处理。
///
/// P3-7（v3.0.8 审计）：[rolledBack] 参数——addTask / addTasksBulk 等**新建**入口
/// 落盘失败时会回滚内存（任务已不存在，「继续其它操作会自动一并保存」对它不成立：
/// 没有任何后续写入会把不存在的任务带回来）。这些入口传 rolledBack: true，文案改为
/// 「新建未生效，请重试」——旧实现让新建侧也用通用文案，用户可能因此不再点保存，
/// 以为「等等就会自己存上」。
void showTaskPersistFailedHint(BuildContext context,
    {TaskProvider? provider, bool rolledBack = false}) {
  final safeMode = provider?.dbLoadFailed ?? false;
  // P2-2（v3.1.6 审计）：新建 / 编辑弹层内的失败回执必须显示在弹层内，
  // 否则挂在主 Scaffold 的 SnackBar 被弹层整块遮挡，用户只看到「弹层没关」。
  showSheetSnackBar(
    context,
    SnackBar(
      content: Text(safeMode
          ? '安全模式下更改不会保存：已阻止写入以保护数据库，请先修复或恢复后再试'
          : rolledBack
              ? '新建未生效，请重试'
              : '写入失败：数据未保存；继续其它操作会自动一并保存'),
    ),
  );
}

/// P3-3（v3.0.7 审计）：`Future<bool>` 的 false 双义之二——「任务不存在」。
/// setStatus / toggleDone / markOccurrenceDone / unmarkOccurrenceDone 对
/// `i == -1` 一律返回 false，与「落盘失败」压进同一个值；四种失败的 UI 后果
/// 完全不同（一个是重试也无济于事的实体消失，一个是可自愈的持久化问题）。
/// 消费方在 false 时按 `provider.byId(id) == null` 拆开，走本提示而非
/// [showTaskPersistFailedHint]——与 [taskUndoAction] / 通知侧
/// main._doComplete / _doTaskUndo 既有的 byId 判空口径对齐（项目自己早已承认
/// 这两义必须区分，只是 App 内 4 个消费点没跟上）。
void showTaskMissingHint(BuildContext context) {
  // P2-2（v3.1.6 审计）：同 showTaskPersistFailedHint，弹层内可见。
  showSheetSnackBar(
    context,
    const SnackBar(content: Text('任务已不存在：可能刚被删除，请刷新后查看')),
  );
}

/// P3-3（v3.0.7 审计）：完成族 4 个写入口（setStatus / toggleDone /
/// markOccurrenceDone / unmarkOccurrenceDone）的统一消费助手——[result] 为
/// provider 返回值，[taskId] 为被操作任务。ok=true 静默；false 时按 byId
/// 判空二选一（实体消失 → [showTaskMissingHint]；落盘失败 → 带安全模式分化的
/// [showTaskPersistFailedHint]）。
void consumeTaskWriteResult(
  BuildContext context,
  TaskProvider provider,
  String taskId,
  Future<bool> result,
) {
  result.then((ok) {
    if (ok) return;
    if (!context.mounted) return;
    if (provider.byId(taskId) == null) {
      showTaskMissingHint(context);
    } else {
      showTaskPersistFailedHint(context, provider: provider);
    }
  });
}

/// P2-2（v3.0.7 审计）：复合撤销闭包（「移到下一天」/「仅此一次改期」）里
/// 消费「修改类」写入口（unskipOccurrence 等）的统一助手，拆开 false 双义：
/// - ok=true → 成功；
/// - false 且实体已不在列表 → 真失效（返回 false，由 showUndoSnackBar 统一提示）；
/// - false 且实体仍在 → 内存写入已生效、仅未持久化（全量写自愈）：弹
///   [showTaskPersistFailedHint] 并按成功返回 true（与 [taskUndoAction] 的
///   notSaved 分支同口径，不把已生效的撤销误报为失效）。
Future<bool> consumeUndoWrite(
  BuildContext context,
  TaskProvider provider,
  String entityId,
  Future<bool> result,
) async {
  final ok = await result;
  if (ok) return true;
  if (provider.byId(entityId) == null) return false;
  if (context.mounted) showTaskPersistFailedHint(context, provider: provider);
  return true;
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
    // P3-2（v3.0.7 审计）：失败提示改走安全模式分化版（见
    // [showTaskPersistFailedHint]）——安全模式下「请重试」是误导。
    if (notSaved && context.mounted) {
      showTaskPersistFailedHint(context, provider: provider);
    }
    return ok;
  };
}

/// 切换 [task] 的完成态并弹 10 秒撤销提示。
///
/// U2-1（v3.0.6 审计）：按落盘结果反馈——失败先弹「写入失败」提示、**仍给**
/// 撤销横幅（任务侧 provider 不内存回滚，UI 显示的完成态需要撤销入口；
/// 撤销本身也会重试落盘）。旧实现 fire-and-forget 后无条件弹横幅，DB 异常时
/// 用户看到「已完成（10 秒内可撤销）」却不知数据未保存。
/// P3-3（v3.0.7 审计）：false 双义拆开——任务不存在走 [showTaskMissingHint]，
/// 落盘失败走安全模式分化的 [showTaskPersistFailedHint]。
Future<void> toggleDoneWithUndo(
    BuildContext context, TaskProvider provider, Task task) async {
  final ok = await provider.toggleDone(task.id);
  if (!context.mounted) return;
  if (!ok) {
    if (provider.byId(task.id) == null) {
      showTaskMissingHint(context);
    } else {
      showTaskPersistFailedHint(context, provider: provider);
    }
  }
  final title = task.title.isEmpty ? '(无标题)' : task.title;
  showUndoSnackBar(
    context,
    content: undoContent(
        task.done ? '已把「$title」移回待办' : '已完成「$title」'),
    onUndo: taskUndoAction(context, provider, [task]),
  );
}
