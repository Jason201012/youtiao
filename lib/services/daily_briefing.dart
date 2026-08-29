import 'package:flutter/foundation.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/habit_nudge.dart';
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
///
/// [forDay]：按哪一天的口径聚合。P1-8 —— 文案在**排程时**烘焙，而简报是投递到未来某刻的，
/// 必须按投递日聚合，否则「周一晚排的周二晨报」会算成周一的口径。缺省为当下。
DailyBrief buildEveningBriefFromState(
    TaskProvider task, FocusProvider focus, HabitProvider habit,
    {DateTime? forDay}) {
  final now = forDay ?? DateTime.now();
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
///
/// [forDay]：按哪一天的口径聚合（P1-8，同 [buildEveningBriefFromState]）。
/// 晨报几乎总是在「前一天」就排好，因此这里**必须**传入投递日，
/// 否则「今日到期 / 逾期积压 / 昨日未完成」三项会全部算成排程当天的口径。
DailyBrief buildMorningBriefFromState(
    TaskProvider task, FocusProvider focus, HabitProvider habit,
    {DateTime? forDay}) {
  final now = forDay ?? DateTime.now();
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

/// P0-1 重新排程早晚简报：读取设置开关，按**投递日**聚合数据烘焙通知文案并每日重复调度。
/// 调用方（main 启动 / 设置页切换）在通知总开关开启时调用；关闭则取消两条简报。
///
/// P1-8 时效性：简报文案在排程时烘焙（系统闹钟到点弹出时 App 未必在内存），
/// 故按 [NotificationService.nextBriefingTime] 算出的**投递时刻**聚合，
/// 保证「周二 07:30 送达的晨报」用的是周二的口径，而非排程当下（周一）的口径。
///
/// 已知残留限制：通知以 `matchDateTimeComponents=time` 每日重复，同一份文案会按天重发；
/// 若用户连续多日不打开 App（不触发启动 / 回到前台重排），第二日起内容仍会滞后。
/// 彻底解决需在原生侧每日重烘焙（同 TodayWidgetProvider 直读 youtiao.db 的套路），
/// 改动较大且会让简报口径在 Kotlin / Dart 两边各存一份，暂不实施。
Future<void> rescheduleBriefings(
    TaskProvider task, FocusProvider focus, HabitProvider habit) async {
  final svc = NotificationService.instance;
  if (!task.notificationsEnabled) {
    await svc.cancelBriefing(true);
    await svc.cancelBriefing(false);
    return;
  }
  if (task.briefingEveningEnabled) {
    // P1-8：先算投递时刻，再按投递日聚合。晚简报若排的是今天，口径即今天；
    // 若今天这刻已过（排到明天），口径也相应顺延，不会串到别的一天。
    final when = svc.nextBriefingTime(
        task.briefingEveningHour, task.briefingEveningMinute);
    final b = buildEveningBriefFromState(task, focus, habit, forDay: when);
    await svc.scheduleBriefing(true, task.briefingEveningHour,
        task.briefingEveningMinute,
        title: b.title, body: b.lines.join('\n'));
  } else {
    await svc.cancelBriefing(true);
  }
  if (task.briefingMorningEnabled) {
    // P1-8：晨报几乎总在「前一天」排好（如周一 21:00 排周二 07:30），
    // 必须按投递日聚合，否则会把周一的待办当成周二的今日待办推给用户。
    final when = svc.nextBriefingTime(
        task.briefingMorningHour, task.briefingMorningMinute);
    final b = buildMorningBriefFromState(task, focus, habit, forDay: when);
    await svc.scheduleBriefing(false, task.briefingMorningHour,
        task.briefingMorningMinute,
        title: b.title, body: b.lines.join('\n'));
  } else {
    await svc.cancelBriefing(false);
  }
}

/// P1-7 重排「习惯漏卡挽留」通知：每天 23:00 提醒一次「今天该打卡却还没打卡」的习惯。
///
/// 与简报同一套路——文案在**调度时**烘焙（系统闹钟到点时 App 未必在内存），
/// 因此需要在启动、回到前台、习惯或打卡变动时重排，让内容跟上最新口径。
///
/// 兜底策略：
/// - 通知总开关关闭 → 直接取消，不排；
/// - 今天没有漏卡（含「已全部打卡」和「今天本就不该打卡」）→ 取消而非排一条空的；
/// - 多个习惯漏卡 → 聚合成**一条**通知，避免 23:00 连弹 N 条变成骚扰；
/// - 全程包 try/catch——挽留是锦上添花，任何失败都不该影响主流程。
///
/// 调用点：`main.dart` 启动后、`AppLifecycleState.resumed` 时（与简报并排）。
Future<void> rescheduleHabitNudge(HabitProvider habit) async {
  final svc = NotificationService.instance;
  try {
    if (!svc.enabled) {
      await svc.cancelHabitNudge();
      return;
    }
    final now = DateTime.now();
    // 先算已打卡集合：只遍历一次 habits，避免 missedOn 内部反复调用 isCheckedToday。
    final checkedIds = habit.habits
        .where(habit.isCheckedToday)
        .map((h) => h.id)
        .toSet();
    final missed = HabitNudge.missedOn(habit.habits, now, checkedIds);
    if (missed.isEmpty) {
      await svc.cancelHabitNudge();
      return;
    }
    final t = HabitNudge.text(
      missed,
      // currentStreak 用 allowTodayGap：今天没打卡时是从昨天往回数，
      // 补上今天才等于它 + 1，故这里 +1 才是「补卡后的连续天数」。
      streakAfterCheckIn: (h) => habit.currentStreak(h) + 1,
    );
    // 单个漏卡时带上具体 id，点击直达该习惯；多个则落习惯页由用户自己挑。
    final payload = missed.length == 1
        ? '${NotificationService.payloadHabitPrefix}${missed.first.id}'
        : NotificationService.payloadHabitPrefix;
    await svc.scheduleHabitNudge(title: t.title, body: t.body, payload: payload);
  } catch (e) {
    debugPrint('[HabitNudge] 重排失败：$e');
  }
}
