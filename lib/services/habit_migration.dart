/// T1-3：任务 → 习惯的字段映射（纯函数内核）。
///
/// 「反复出现的『每天都做』型任务」与「习惯」本是同一件事的两种表达：
/// 前者靠任务重复规则硬撑、完成历史散落在任务域；后者才有打卡、连续天数、
/// 热力图与周目标。原实现（v2.6.2 起）的「转为习惯」只是**丢标题**建一条
/// 「每天、无提醒、无周目标」的空习惯——星期、提醒时刻、每周循环次数全部丢失，
/// 用户还得去习惯页重设一遍，等于「手工重录 + 一次点击」。
///
/// 本文件把映射规则收成一处、做成纯函数（不依赖 Flutter、不碰任何 Provider），
/// 因此可以逐条钉死单测；UI 只负责把 [HabitDraft] 交给
/// [HabitProvider.addHabitFromDraft]。
library;

import 'package:todolist/models/task.dart';

/// 由任务推导出的习惯字段草稿（不含 emoji / 颜色 / id / createdAt 等由 UI 决定的项）。
class HabitDraft {
  /// 习惯标题（取自任务标题，已 trim）。
  final String title;

  /// 打卡星期（1=周一 … 7=周日）；空列表 = 每天。
  final List<int> weekdays;

  /// 每日提醒时刻（自 00:00 起的分钟数）；null = 不提醒。
  final int? reminderMinute;

  /// 每周目标次数（0 = 不启用）。由重复规则折算出的「每周循环次数」，
  /// 让习惯页能直接显示「本周 3/5 次」这类进度。
  final int weeklyGoal;

  /// 映射过程中被**丢弃**的语义（供 UI 如实告知用户，而不是静默吞掉）。
  ///
  /// 例：`每月 15 号` 的月内规则无法用「星期 + 周目标」表达，
  /// 转换后提醒节奏会变——必须让用户看得见，避免「转完发现提醒变了」的黑箱感。
  final List<String> droppedNotes;

  const HabitDraft({
    required this.title,
    this.weekdays = const [],
    this.reminderMinute,
    this.weeklyGoal = 0,
    this.droppedNotes = const [],
  });

  /// 打卡日的可读文案（用于转换预览弹层）。
  String get weekdaysLabel {
    if (weekdays.isEmpty) return '每天';
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final sorted = weekdays.where((d) => d >= 1 && d <= 7).toList()..sort();
    return '每周 ${sorted.map((d) => names[d - 1]).join('、')}';
  }

  /// 提醒时刻的可读文案。
  String get reminderLabel {
    final m = reminderMinute;
    if (m == null) return '不提醒';
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  /// 周目标的可读文案。
  String get weeklyGoalLabel => weeklyGoal <= 0 ? '不启用' : '每周 $weeklyGoal 次';

  /// 核心映射：任务 → 习惯草稿。
  ///
  /// 规则（一一对应，可单测）：
  /// - **标题**：任务标题（trim）；空标题回退「未命名习惯」以免建出无名习惯。
  /// - **打卡日**：
  ///   - `每周一/三/五` → 相同的星期集合；
  ///   - `仅工作日` → 周一到周五；
  ///   - `每天` / `每隔 1 天` / 不重复 → 每天（空列表）；
  ///   - `每隔 N 天`（N>1）→ 每天 + 周目标折算（见下），并记入 [droppedNotes]；
  ///   - `每月…` → 每天 + 周目标 1，并记入 [droppedNotes]。
  /// - **提醒时刻**：优先取重复提醒时刻 [Task.repeatMinute]；重复任务未写时刻时
  ///   回退到截止时间 [Task.dueDate] 的时分（「每天 09:00 交周报」的实际响铃点）；
  ///   两者皆无 → 不提醒（不擅自替用户安排打扰时间）。
  /// - **周目标**：`每天` → 7；`仅工作日` → 5；`每周X天` → 天数；
  ///   `每隔 N 天` → `(7 / N).ceil()`（每周大约几次，至少 1）；`每月…` → 1；
  ///   不重复 → 0（一次性任务没有「每周几次」可言）。
  static HabitDraft fromTask(Task task) {
    final title = task.title.trim();
    final dropped = <String>[];

    var weekdays = const <int>[];
    var weeklyGoal = 0;

    switch (task.repeat) {
      case RepeatType.none:
        // 一次性任务也允许转习惯（用户想把它变成日常），按「每天」处理、无周目标。
        break;
      case RepeatType.daily:
        weeklyGoal = 7;
        break;
      case RepeatType.weekday:
        weekdays = const [1, 2, 3, 4, 5];
        weeklyGoal = 5;
        break;
      case RepeatType.weekly:
        final wd = task.repeatWeekdays.where((d) => d >= 1 && d <= 7).toSet().toList()
          ..sort();
        if (wd.isEmpty) {
          // 规则异常（weekly 却没写星期）：回退「每天」，避免转出一个永不出现的习惯。
          dropped.add('原任务未指定星期，已按「每天」创建');
        } else {
          weekdays = wd;
          weeklyGoal = wd.length;
        }
        break;
      case RepeatType.interval:
        final n = task.repeatInterval < 1 ? 1 : task.repeatInterval;
        if (n == 1) {
          weeklyGoal = 7; // 「每隔 1 天」等价于每天
        } else {
          weeklyGoal = (7 / n).ceil().clamp(1, 7);
          dropped.add('「每隔 $n 天」已折算为每周 $weeklyGoal 次');
        }
        break;
      case RepeatType.monthly:
        weeklyGoal = 1;
        dropped.add('「每月」规则无法用星期表达，已折算为每周 1 次');
        break;
    }

    // 提醒时刻：重复提醒时刻优先，其次截止时间的时分。
    int? reminder = task.repeatMinute;
    if (reminder == null && task.dueDate != null) {
      reminder = task.dueDate!.hour * 60 + task.dueDate!.minute;
    }
    if (reminder != null && (reminder < 0 || reminder > 1439)) reminder = null;

    return HabitDraft(
      title: title.isEmpty ? '未命名习惯' : title,
      weekdays: weekdays,
      reminderMinute: reminder,
      weeklyGoal: weeklyGoal,
      droppedNotes: dropped,
    );
  }
}
