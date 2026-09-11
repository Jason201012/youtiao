import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/habit_nudge.dart';

/// P3-4 回归：习惯挽留的文案在**排程时**烘焙；若投递时刻因跨天 / 勿扰顺延落到次日
/// （如 23:00 的落点撞进勿扰区间，被推迟到次日 07:05），文案里的「今天」在送达时
/// 就成了谎言——用户早上 07:05 读到「今天还没打卡」会误以为特指当天。
/// 修复口径：投递日与漏卡口径日不同日时，用**明确日期**替代「今天」。
Habit _h(String id, {String title = '习惯', String emoji = '✅'}) => Habit(
      id: id,
      title: title,
      emoji: emoji,
      weekdays: const [],
      reminderMinute: 480,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  final day = DateTime(2026, 9, 11, 23, 0); // 口径日：9 月 11 日
  final nextMorning = DateTime(2026, 9, 12, 7, 5); // 顺延后的投递时刻

  group('HabitNudge.text（P3-4 顺延跨天文案）', () {
    test('未顺延（同日投递）时文案保持原口径', () {
      final t = HabitNudge.text(
        [_h('a')],
        streakAfterCheckIn: (_) => 1,
        forDay: day,
        deliversAt: day,
      );
      expect(t.body, '今天还没打卡，睡前补上还来得及');
    });

    test('单习惯顺延跨天：正文改用明确日期', () {
      final t = HabitNudge.text(
        [_h('a')],
        streakAfterCheckIn: (_) => 1,
        forDay: day,
        deliversAt: nextMorning,
      );
      expect(t.body, '9月11日还没打卡，现在补上还来得及');
      expect(t.body.contains('今天'), isFalse, reason: '不得再出现时态错误的「今天」');
    });

    test('单习惯带连续天数、顺延跨天：保留天数并标日期', () {
      final t = HabitNudge.text(
        [_h('a')],
        streakAfterCheckIn: (_) => 8,
        forDay: day,
        deliversAt: nextMorning,
      );
      expect(t.body, '9月11日漏了打卡，补上就是连续 8 天');
    });

    test('多习惯顺延跨天：标题带日期', () {
      final t = HabitNudge.text(
        [_h('a'), _h('b'), _h('c')],
        streakAfterCheckIn: (_) => 9,
        forDay: day,
        deliversAt: nextMorning,
      );
      expect(t.title, '9月11日还有 3 个习惯没打卡');
      expect(t.body, '习惯、习惯、习惯，睡前补上不中断连续记录');
    });

    test('多习惯未顺延：标题保持原样', () {
      final t = HabitNudge.text(
        [_h('a'), _h('b')],
        streakAfterCheckIn: (_) => 9,
        forDay: day,
        deliversAt: day,
      );
      expect(t.title, '还有 2 个习惯没打卡');
    });

    test('向后兼容：不传 forDay / deliversAt 时行为与旧版一致', () {
      final t = HabitNudge.text(
        [_h('a')],
        streakAfterCheckIn: (_) => 1,
      );
      expect(t.body, '今天还没打卡，睡前补上还来得及');
    });
  });
}
