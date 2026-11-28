import 'package:todolist/models/task.dart';

/// 判断任务是否为某日的「当日事件」——TaskProvider 当日统计、今日聚合、
/// 分享卡片三处共用本判据（P2-5，v3.2.0 审计收为单一真源）。
///
/// P2-5：无截止日期的**已完成任务**此前恒被视为「今天的事件」，连内置示例里
/// 4 天前 / 6 天前完成的两条也永久计入，新用户首屏「当日已完成 2」与晚简报
/// 「今日完成 0」直接打架。现改为：未完成仍每天跟随；已完成仅在 [day]
/// 当天完成时才计入，与晚简报的 `completedAt` 口径一致。
///
/// 其它口径保持原样：带 dueDate 的任务按 [dueCompareKey] 归一取日；重复任务
/// 还须当天是循环日（含暂停 / skipDates 判定）。
/// 「某日完成」判据（N-P3-1，v3.2.1 审计）——与 [isTaskEventOn] 并列的**第二个**
/// 概念，不再混用：事件回答「这一天该做哪些事」，完成回答「这一天勾掉了哪些事」。
///
/// 旧实现把「今日完成」写成 `isTaskEventOn(t) && t.done`：一条 11/25 就勾掉、
/// 截止日却是 11/28 的任务，会被算进 11/28 的「今日完成」，而晚简报按
/// `completedAt` 统计为 0——同一屏两套口径。改判据后，看板「今日完成」、
/// 首页「今日完成」筛选与简报全部以完成日为准（[Task.isDoneOn] 单一真源：
/// 重复任务读 doneDates，一次性任务读 completedAt）。
bool isTaskCompletedOn(Task t, DateTime day) {
  if (t.deletedAt != null) return false;
  return t.isDoneOn(day);
}

bool isTaskEventOn(Task t, DateTime day) {
  if (t.deletedAt != null) return false;
  final d = DateTime(day.year, day.month, day.day);
  if (t.dueDate != null) {
    final k = dueCompareKey(t.dueDate!);
    if (DateTime(k.year, k.month, k.day) == d) {
      if (t.isRepeating && !t.repeatsOn(d)) return false;
      return true;
    }
  } else if (!t.isRepeating) {
    if (!t.done) return true;
    final c = t.completedAt;
    return c != null && DateTime(c.year, c.month, c.day) == d;
  }
  return t.repeatsOn(d);
}
