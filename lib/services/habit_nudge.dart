import 'package:todolist/models/habit.dart';

/// P1-7：习惯漏卡挽留——每天 23:00 对「今天该打卡却没打卡」的习惯发一条本地通知。
///
/// 本文件**只有纯函数**：不依赖 Flutter 绑定、不读 Provider、不碰通知插件，
/// 因而可以在 headless 下直接单测。通知调度见
/// [NotificationService.scheduleHabitNudge]，重排时机见 `main.dart`。
///
/// 设计前提（与 `daily_briefing.dart` 一致）：通知文案必须在**调度时**烘焙——
/// 系统闹钟到点弹出时 App 未必在内存，没有机会重算。因此 App 每次启动、习惯或
/// 打卡发生变动时都要重排，让文案跟上最新口径。若整天没开过 App，文案会滞后
/// 一天，故措辞刻意避开「过期即变错」的绝对断言（不写死具体日期、不写死天数）。
class HabitNudge {
  HabitNudge._();

  /// 每日挽留默认时刻：23:00（自 00:00 起的分钟数）。
  /// F4：已改为「可配置」——由 [TaskProvider.habitNudgeMinute] + 设置页驱动，
  /// 调度层 [NotificationService.scheduleHabitNudge] 与 [rescheduleHabitNudge]
  /// 均接收该值，此处仅作兜底默认值。
  static const int nudgeMinute = 23 * 60;

  /// 纯函数：[habit] 在 [day] 是否需要打卡。
  /// - 已归档的不算；
  /// - **没设提醒的不算**——报告口径是只挽留「设定过提醒」的习惯，
  ///   对从不开提醒的用户保持沉默，避免无端打扰；
  /// - 星期口径直接复用 [Habit.shouldCheckInOn]（空 weekdays = 每天），
  ///   避免与模型层出现两套判定而悄悄漂移。
  static bool isDueOn(Habit habit, DateTime day) {
    if (habit.archived) return false;
    if (habit.reminderMinute == null) return false;
    return habit.shouldCheckInOn(day);
  }

  /// 纯函数：从 [habits] 中挑出 [day] 应打卡、但 [checkedIds] 里没有的项。
  /// 保持输入顺序，使生成的文案稳定可预期。
  static List<Habit> missedOn(
    List<Habit> habits,
    DateTime day,
    Set<String> checkedIds,
  ) =>
      habits
          .where((h) => isDueOn(h, day) && !checkedIds.contains(h.id))
          .toList();

  /// 纯函数：根据漏卡清单生成通知文案。清单为空时返回空文案（调用方据此取消通知）。
  ///
  /// [streakAfterCheckIn] 应返回「今天补打卡后」的连续天数，即
  /// `HabitProvider.currentStreak(h) + 1`。之所以要 +1：currentStreak 内部用
  /// `allowTodayGap: true`，今天没打卡时是从**昨天**往回数的，补上今天才等于它 + 1。
  static HabitNudgeText text(
    List<Habit> missed, {
    required int Function(Habit habit) streakAfterCheckIn,
  }) {
    if (missed.isEmpty) return const HabitNudgeText.empty();

    // 单个习惯：点名 + 连续天数，最有催促力。
    if (missed.length == 1) {
      final h = missed.first;
      final n = streakAfterCheckIn(h);
      return HabitNudgeText(
        title: '${h.emoji} ${h.title} 还没打卡',
        // n<=1 时不说「连续 1 天」，读着别扭且没信息量。
        body: n > 1
            ? '还差一步就连续 $n 天了，睡前补上还来得及'
            : '今天还没打卡，睡前补上还来得及',
      );
    }

    // 多个习惯：聚合一条，避免 23:00 连弹 N 条通知变成骚扰。
    // 最多列 3 个名字，其余用「等 N 项」兜住，防止文案过长被系统截断。
    final names = missed.take(3).map((h) => h.title).join('、');
    final more = missed.length > 3 ? ' 等 ${missed.length} 项' : '';
    return HabitNudgeText(
      title: '还有 ${missed.length} 个习惯没打卡',
      body: '$names$more，睡前补上不中断连续记录',
    );
  }
}

/// [HabitNudge.text] 的返回值。用不可变小类而非 record，便于断言与后续拓展。
class HabitNudgeText {
  const HabitNudgeText({required this.title, required this.body});

  /// 空文案：表示「无需发通知」，调用方应改为取消已排的通知。
  const HabitNudgeText.empty()
      : title = '',
        body = '';

  /// 通知标题。
  final String title;

  /// 通知正文。
  final String body;

  /// 是否有内容可发。
  bool get isNotEmpty => title.isNotEmpty;
}
