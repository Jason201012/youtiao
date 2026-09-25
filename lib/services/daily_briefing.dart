import 'package:todolist/services/app_log.dart';
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
  int interrupts = 0,
}) {
  final lines = <String>[];
  lines.add('今日完成任务：$completedTasks 个');
  lines.add('专注时长：$focusMinutes 分钟 · 完成番茄 $pomodoros 个');
  // F2：专注打断次数展示闭环——只显示「有打断」时才加这一行，避免日常无打断时噪音。
  if (interrupts > 0) {
    lines.add('专注被打断：$interrupts 次');
  }
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
  // P2-1：专注 / 习惯三项同样按 [now]（投递日）聚合，与上方任务口径对齐。
  // 此前取的是「本机当前日」，晚简报被重排到次日投递时会出现
  // 「今日完成任务 0，专注 X 分钟」的混合口径。
  final focusMin = focus.focusSecOn(now) ~/ 60;
  final pomodoros = focus.completedOn(now);
  // P2-6（v2.9.5 审计）：分母必须先按 `shouldCheckInOn(now)` 过滤，不能直接取
  // `activeHabits.length`。
  //
  // 旧实现下「每周一/三/五 · 21:00 提醒」的习惯在**周二**晚简报里仍进分母，而
  // [Habit.shouldCheckInOn] 判 false → `isTargetMetOn` 恒 false → 分子不进，
  // 于是每周有 2 天白收一条「习惯 0/1 · 未完成」的暗示。
  //
  // 这与今日卡（`today.dart` 加 `shouldCheckIn` 分子）、今日页、列表/详情主判定、
  // 挽留文案全都按 `shouldCheckInOn` 过滤的口径打架——同一件事在 5 个入口
  // 得到 2 种答案。分子与分母必须同源：先滤出「今天该打卡的」，再在其中数达标的。
  // 源列表用 `habit.activeHabits`（已滤 archived；此前误写成未定义的 `active`）。
  final dueToday =
      habit.activeHabits.where((h) => h.shouldCheckInOn(now)).toList();
  final habitDue = dueToday.length;
  var habitDone = 0;
  for (final h in dueToday) {
    // T1-2：达成口径——量化习惯需当日累计量达标，仅有记录不算「已达成」。
    if (habit.isTargetMetOn(h, now)) habitDone++;
  }
  // F2：打断数据展示闭环——晚简报补一行「专注被打断 X 次」，按同一投递日聚合。
  final interrupts = focus.interruptCountOn(now);
  return buildEveningBrief(
    completedTasks: completedToday,
    focusMinutes: focusMin,
    pomodoros: pomodoros,
    habitDone: habitDone,
    habitDue: habitDue,
    interrupts: interrupts,
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
/// F-07 修复（原「已知残留限制」）：通知曾以 `matchDateTimeComponents=time` 每日重复，
/// 同一份烘焙文案会按天重发，用户连续多日不开 App 时第二日起内容全部滞后
/// （「今日完成任务 0 个」连念数日）。现 [NotificationService.scheduleBriefing]
/// 改为**一次性闹钟**，只投递下一班，内容必然对应投递日。
///
/// 代价与兜底：简报不再具备「系统侧每日自循环」能力，完全依赖本函数的重排时机——
/// 已在 `main.dart` 的启动 / `AppLifecycleState.resumed` / 设置页切换三处挂载，
/// 另外 15 分钟守护（[TaskProvider.checkDailyReset]）在跨天时也会重排，
/// 覆盖「App 一直挂在后台跨过 00:00」的边界。
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

/// P1-7 重排「习惯漏卡挽留」通知：每天固定时刻提醒一次「今天该打卡却还没打卡」的习惯。
///
/// 与简报同一套路——文案在**调度时**烘焙（系统闹钟到点时 App 未必在内存），
/// 因此需要在启动、回到前台、习惯或打卡变动时重排，让内容跟上最新口径。
///
/// F4 增强：时刻 [nudgeMinute]（自 00:00 起的分钟数，默认 23:00）可配置；
/// [enabled]=false（或通知总开关关闭）时直接取消、不再排；排程时由
/// [NotificationService.scheduleHabitNudge] 统一感知勿扰区间。
///
/// 兜底策略：
/// - 通知总开关关闭 / [enabled]=false → 直接取消，不排；
/// - 今天没有漏卡（含「已全部打卡」和「今天本就不该打卡」）→ 取消而非排一条空的；
/// - 多个习惯漏卡 → 聚合成**一条**通知，避免 23:00 连弹 N 条变成骚扰；
/// - 全程包 try/catch——挽留是锦上添花，任何失败都不该影响主流程。
///
/// 调用点：`main.dart` 启动后、`AppLifecycleState.resumed` 时（与简报并排）、
/// 以及 `HabitProvider.onHabitsChanged` 打卡/增删变动回调。
Future<void> rescheduleHabitNudge(
  HabitProvider habit, {
  bool enabled = true,
  int nudgeMinute = 23 * 60,
}) async {
  final svc = NotificationService.instance;
  try {
    // F4：独立开关 + 通知总开关任一关闭即取消（不排）。
    if (!svc.enabled || !enabled) {
      await svc.cancelHabitNudge();
      return;
    }
    final now = DateTime.now();
    // 先算已达标集合：只遍历一次 habits，避免 missedOn 内部反复调用判定函数。
    // T1-2：口径用「达标」而非「有记录」——量化习惯只喝了 1/8 杯仍应被挽留，
    // 否则「没喝够」永远收不到提醒，量化目标形同虚设。
    final checkedIds = habit.habits
        .where((h) => habit.isTargetMetOn(h, now))
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
      // P3-4：把「漏卡口径日」与「实际投递时刻」一并交给文案层。挽留若因跨天 /
      // 勿扰顺延落到次日（如 23:00 排程被推到次日 07:05），文案里的「今天」在送达时
      // 已然说谎，需改写成明确日期。时刻口径与调度层同源（同一静态函数），不会漂移。
      forDay: now,
      deliversAt: NotificationService.nextHabitNudgeTime(nudgeMinute, from: now),
    );
    // 单个漏卡时带上具体 id，点击直达该习惯；多个则落习惯页由用户自己挑。
    final payload = missed.length == 1
        ? '${NotificationService.payloadHabitPrefix}${missed.first.id}'
        : NotificationService.payloadHabitPrefix;
    await svc.scheduleHabitNudge(
      title: t.title,
      body: t.body,
      payload: payload,
      nudgeMinute: nudgeMinute, // F4：可配置时刻
    );
  } catch (e) {
    AppLog.d('[HabitNudge] 重排失败：$e');
  }
}

/// P2-2（v2.8.7 审计）：重排全部「触发时刻在排程时按当前提醒时区烘焙」的
/// 固定时刻提醒——早晚简报 × 2、习惯漏卡挽留、回收站过期预告。这些都是
/// 一次性闹钟（F-07），切换提醒时区后若只重排任务提醒，它们的已挂落点仍按
/// 旧时区计算，要等下次「启动 / 跨天钩子」才重建——期间会按旧时区错时响一次，
/// 「时区立即生效」对常驻提醒落空。本函数与 onDayChanged 的全量重排入口对齐。
///
/// 各开关关闭时对应分支自动转为取消（与 [rescheduleBriefings] /
/// [rescheduleHabitNudge] / [NotificationService.scheduleTrashExpireNotice]
/// 的关闭语义一致），可在任意开关组合下安全调用。
/// 调用点：设置页切换提醒时区（settings_screen）、备份恢复完成后（backup_sheet）。
Future<void> rescheduleFixedTimeReminders(
    TaskProvider task, FocusProvider focus, HabitProvider habit) async {
  try {
    await rescheduleBriefings(task, focus, habit);
    await rescheduleHabitNudge(habit,
        enabled: task.habitNudgeEnabled, nudgeMinute: task.habitNudgeMinute);
    // 回收站过期预告：列表为空时内部自动取消残留，与「重排」语义一致。
    await NotificationService.instance
        .scheduleTrashExpireNotice(task.trashExpiringTomorrow)
        .catchError((_) {});
  } catch (e) {
    AppLog.d('[DailyBriefing] 固定时刻提醒重排失败：$e');
  }
}
