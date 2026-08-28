import 'package:todolist/models/task.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';

/// 单条简报的结构化结果（title + 多行正文），便于单元测与直接填入通知。
class DailyBrief {
  final String title;
  final List<String> lines;
  const DailyBrief({required this.title, required this.lines});
}

/// 判断两个 DateTime 是否「同年月日」。
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 本地日期 yyyy-MM-dd（与 weeklyCompletedCount / WeeklyReview 统一口径，避免时区误差）。
String _dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// P0-1 晚间简报「今日小结」纯函数：给定当日聚合数据，返回结构化文案。
/// 不依赖任何 Provider / 通知，便于单元测。
DailyBrief buildEveningBrief({
  required int completedTasks,
  required int focusMinutes,
  required int pomodoros,
  required int habitDone,
  required int habitDue,
}) {
  final lines = <String>[];
  lines.add('今日完成任务：$completedTasks 个');
  lines.add('专注时长：$focusMinutes 分钟 · 完成番茄 $pomodoros 个');
  final rate = habitDue == 0
      ? '—'
      : '${((habitDone / habitDue) * 100).round()}%';
  lines.add('习惯达成：$habitDone / $habitDue（$rate）');
  lines.add(_eveningNarrative(
      completedTasks, focusMinutes, habitDue, habitDone));
  return DailyBrief(title: '今日小结', lines: lines);
}

/// 晚间一句话总结模板（纯本地拼装，不接 LLM）。
String _eveningNarrative(
    int completed, int focusMin, int habitDue, int habitDone) {
  if (completed == 0 && focusMin == 0 && habitDone == 0) {
    return '今天很轻松，明天继续加油';
  }
  if (completed >= 3) return '今天效率不错，完成了 $completed 项任务';
  if (focusMin >= 60) return '专注了 $focusMin 分钟，状态在线';
  if (habitDue > 0 && habitDone >= habitDue) return '习惯全部达成，完美收官';
  return '稳扎稳打，保持节奏';
}

/// P0-1 晨间简报「今日待办」纯函数：给定当日到期 / 逾期 / 昨日未完数据，返回结构化文案。
/// [dueToday] / [overdueTop3] / [unfinishedYesterday] 均已由调用方按口径计算好。
DailyBrief buildMorningBrief({
  required List<String> dueToday,
  required List<String> overdueTop3,
  required int unfinishedYesterday,
}) {
  final lines = <String>[];
  lines.add('今日到期：${dueToday.length} 个');
  for (final t in dueToday.take(8)) lines.add('• $t');
  if (overdueTop3.isNotEmpty) {
    lines.add('逾期积压（Top3）：');
    for (final t in overdueTop3) lines.add('• $t');
  }
  lines.add('昨日未完成任务：$unfinishedYesterday 个');
  return DailyBrief(title: '今日待办', lines: lines);
}

/// 从三大 Provider 实时聚合「今日小结」所需数据（口径与首页 / 周报一致，统一本地日期比较）。
DailyBrief buildEveningBriefFromState(
    TaskProvider task, FocusProvider focus, HabitProvider habit) {
  final now = DateTime.now();
  var completedToday = 0;
  for (final t in task.tasks) {
    if (t.done &&
        t.completedAt != null &&
        _sameDay(t.completedAt!, now)) {
      completedToday++;
    }
  }
  final focusMin = focus.todayFocusSec ~/ 60;
  final pomodoros = focus.todayCompleted;
  final active = habit.activeHabits;
  final habitDue = active.length;
  var habitDone = 0;
  for (final h in active) {
    if (habit.isCheckedToday(h)) habitDone++;
  }
  return buildEveningBrief(
    completedTasks: completedToday,
    focusMinutes: focusMin,
    pomodoros: pomodoros,
    habitDone: habitDone,
    habitDue: habitDue,
  );
}

/// 从三大 Provider 实时聚合「今日待办」所需数据。
DailyBrief buildMorningBriefFromState(
    TaskProvider task, FocusProvider focus, HabitProvider habit) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final dueToday = <String>[];
  for (final t in task.tasks) {
    if (t.done) continue;
    final hit = t.isRepeating
        ? t.repeatsOn(today)
        : (t.dueDate != null && _sameDay(t.dueDate!, today));
    if (hit) dueToday.add(t.title);
  }
  // 逾期积压：按逾期天数（dueDate 越早越靠前）取 Top3。
  final overdue = task.tasks
      .where((t) => !t.done && Task.isOverdue(t, now))
      .toList()
    ..sort((a, b) {
      final da = a.dueDate ?? now;
      final db = b.dueDate ?? now;
      return da.compareTo(db);
    });
  final overdueTop3 = overdue.take(3).map((t) => t.title).toList();
  // 昨日未完成任务：未完成的非重复任务，其截止日期在昨天（含）之前。
  final yesterday = today.subtract(const Duration(days: 1));
  final unfinishedYesterday = task.tasks
      .where((t) =>
          !t.done &&
          !t.isRepeating &&
          t.dueDate != null &&
          !_sameDay(t.dueDate!, today) &&
          (t.dueDate!.isBefore(today) || _sameDay(t.dueDate!, yesterday)))
      .length;
  return buildMorningBrief(
    dueToday: dueToday,
    overdueTop3: overdueTop3,
    unfinishedYesterday: unfinishedYesterday,
  );
}

/// P0-1 重新排程早晚简报：读取设置开关，按当日聚合数据烘焙通知文案并每日重复调度。
/// 调用方（main 启动 / 设置页切换）在通知总开关开启时调用；关闭则取消两条简报。
/// 简报内容在调度时烘焙（系统闹钟到点弹出时 App 未必在内存），App 每次启动 / 午夜重置
/// 都会重排，故绝大多数情况下内容反映当日最新口径。
Future<void> rescheduleBriefings(
    TaskProvider task, FocusProvider focus, HabitProvider habit) async {
  final svc = NotificationService.instance;
  if (!task.notificationsEnabled) {
    await svc.cancelBriefing(true);
    await svc.cancelBriefing(false);
    return;
  }
  if (task.briefingEveningEnabled) {
    final b = buildEveningBriefFromState(task, focus, habit);
    await svc.scheduleBriefing(true, task.briefingEveningHour,
        task.briefingEveningMinute,
        title: b.title, body: b.lines.join('\n'));
  } else {
    await svc.cancelBriefing(true);
  }
  if (task.briefingMorningEnabled) {
    final b = buildMorningBriefFromState(task, focus, habit);
    await svc.scheduleBriefing(false, task.briefingMorningHour,
        task.briefingMorningMinute,
        title: b.title, body: b.lines.join('\n'));
  } else {
    await svc.cancelBriefing(false);
  }
}
