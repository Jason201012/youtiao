/// 日历日运算的单一真源（P3-3，v3.2.0 审计）。
///
/// `DateTime.difference().inDays` 是**绝对时长截断**：DST 切换日只有 23/25 小时，
/// 两个本地午夜之间会被截成 0 或 1 天；`midnight.subtract(Duration(days: n))`
/// 同理可能落到 23:00 而非午夜。本项目支持自定义 IANA 提醒时区，设备也可能处于
/// DST 地区，凡「相差几个日历日」「日期 ±N 天」一律走本文件的函数。
///
/// 与既有 interval 重复的 UTC 零点求差（task.dart）同口径，零行为变化（无 DST
/// 时区下逐位等价），旧数据无需迁移。
DateTime dateOnlyOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// 返回 `to 日 − from 日` 的整天数（可负）。
///
/// 两端先取 date-only，再以 UTC 午夜求值，彻底绕开本地 DST 歧义。
int calendarDaysBetween(DateTime from, DateTime to) {
  final a = dateOnlyOf(from);
  final b = dateOnlyOf(to);
  return DateTime.utc(b.year, b.month, b.day)
      .difference(DateTime.utc(a.year, a.month, a.day))
      .inDays;
}

/// 日期加减 N 个**日历日**（保留入参的时分秒；入参为 date-only 时输出仍为 date-only）。
///
/// Dart 的 `DateTime(y, m, d + n, ...)` 会自行归一化月末溢出，因此不会因 DST
/// 出现 23:00 的「伪午夜」；时间段任务平移靠保留时分保证起止不被撕开。
DateTime addCalendarDays(DateTime day, int delta) => DateTime(
      day.year,
      day.month,
      day.day + delta,
      day.hour,
      day.minute,
      day.second,
      day.millisecond,
      day.microsecond,
    );
