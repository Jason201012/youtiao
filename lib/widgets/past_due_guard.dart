import 'package:flutter/material.dart';
import 'package:todolist/models/task.dart';

/// P3-5：统一的「过去时刻」提醒守卫。
///
/// 一次性任务的截止提醒 = `dueDate − reminderOffsetMin`；该时刻若已经过去，
/// 保存后提醒**永远不会触发**——「保存成功却静默失效」对提醒类 App 是信任级伤害。
/// 此前只有「新建 / 编辑任务弹层」的保存路径有这条警告，批量改期、逾期区
/// 「顺延到今天」等入口口径不一（同一件事有的地方提示、有的地方不提示）。
/// 这里把**判定**与**提示**集中到一处，各入口复用，避免再出现「某个入口不提示」
/// 的缺口，也避免三份措辞逐渐漂移。
///
/// 刻意**不**把重复任务算进来：重复任务的提醒由 `repeatMinute` 驱动、按规则再次
/// 循环，本次时刻过了下次照响，不存在「永久失效」，提示反而是误报。
class PastDueGuard {
  PastDueGuard._();

  /// 纯函数：[t] 是否存在一个「已经过去、永远无法触发」的截止提醒。
  ///
  /// 口径与 [Task.reminderOffsetMin] 的契约一致：
  /// - 重复任务不看 `dueDate`（提醒由重复规则驱动，会再次触发）→ 不算；
  /// - 无截止时间 → 不算（没有提醒可谈）；
  /// - 已完成 / 已在回收站的任务 → 不算（本就不会再排提醒）。
  static bool isReminderDead(Task t, DateTime now) {
    if (t.isRepeating) return false;
    if (t.done || t.deletedAt != null) return false;
    final d = t.dueDate;
    if (d == null) return false;
    return d.isBefore(now);
  }

  /// 预演一次批量改期：返回「改期后截止提醒即永久失效」的任务条数。
  ///
  /// [transform] 必须是即将提交给 `TaskProvider.batchUpdate` 的同一个函数，
  /// 这样预演与实际落库口径严格一致，不会出现「提示了但其实没事 / 没事但提示了」。
  static int countDeadAfter(
    List<Task> targets,
    Task Function(Task task) transform,
    DateTime now,
  ) {
    var n = 0;
    for (final t in targets) {
      final after = transform(t);
      if (isReminderDead(after, now)) n++;
    }
    return n;
  }

  /// 弹「截止时间已过」确认框。
  ///
  /// [count] 为受影响任务数；[detail] 为可选的补充说明（如具体日期时刻）。
  /// 返回 `true` 表示用户明确选择「仍要保存 / 仍要改期」。
  static Future<bool> confirm(
    BuildContext context, {
    required int count,
    String? detail,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('截止时间已过'),
        content: Text(
          detail ??
              (count == 1
                  ? '所选截止时间已早于当前时刻，保存后提醒将不会触发。'
                  : '$count 项任务的截止时间已早于当前时刻，改期后提醒将不会触发。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('返回修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('仍要保存'),
          ),
        ],
      ),
    );
    return ok == true;
  }
}
