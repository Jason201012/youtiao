import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/habit_nudge.dart';

/// 2026-08-28 是周五（DateTime.weekday == 5），2026-08-29 是周六（== 6）。
/// 固定日期避免测试随运行当天变化而偶发失败。
final DateTime friday = DateTime(2026, 8, 28);
final DateTime saturday = DateTime(2026, 8, 29);

Habit _h(
  String id, {
  String title = '习惯',
  String emoji = '✅',
  List<int> weekdays = const [],
  int? reminderMinute = 480, // 默认 08:00，即「设过提醒」
  bool archived = false,
}) =>
    Habit(
      id: id,
      title: title,
      emoji: emoji,
      weekdays: weekdays,
      reminderMinute: reminderMinute,
      createdAt: DateTime(2026, 1, 1),
      archived: archived,
    );

void main() {
  group('HabitNudge.isDueOn 今日应打卡判定', () {
    test('weekdays 为空视为每天', () {
      expect(HabitNudge.isDueOn(_h('a'), friday), isTrue);
      expect(HabitNudge.isDueOn(_h('a'), saturday), isTrue);
    });

    test('weekdays 命中当天才算', () {
      final onlySat = _h('a', weekdays: const [6]);
      expect(HabitNudge.isDueOn(onlySat, friday), isFalse);
      expect(HabitNudge.isDueOn(onlySat, saturday), isTrue);
    });

    test('未设提醒的不挽留（避免打扰沉默用户）', () {
      expect(HabitNudge.isDueOn(_h('a', reminderMinute: null), friday), isFalse);
    });

    test('已归档的不挽留', () {
      expect(HabitNudge.isDueOn(_h('a', archived: true), friday), isFalse);
    });
  });

  group('HabitNudge.missedOn 漏卡筛选', () {
    test('排除已打卡项，并保持输入顺序', () {
      final habits = [_h('a', title: 'A'), _h('b', title: 'B'), _h('c', title: 'C')];
      final missed = HabitNudge.missedOn(habits, friday, {'b'});
      expect(missed.map((h) => h.id).toList(), ['a', 'c']);
    });

    test('今天本就不该打卡的习惯不计入漏卡', () {
      final habits = [_h('a'), _h('b', weekdays: const [6])]; // b 只在周六
      final missed = HabitNudge.missedOn(habits, friday, {});
      expect(missed.map((h) => h.id).toList(), ['a']);
    });

    test('全部已打卡时返回空', () {
      final habits = [_h('a'), _h('b')];
      expect(HabitNudge.missedOn(habits, friday, {'a', 'b'}), isEmpty);
    });
  });

  group('HabitNudge.text 文案生成', () {
    test('空清单返回空文案（调用方据此取消通知）', () {
      final t = HabitNudge.text([], streakAfterCheckIn: (_) => 5);
      expect(t.isNotEmpty, isFalse);
      expect(t.title, '');
    });

    test('单个习惯且补卡后连续 >1 天：点出连续天数', () {
      final t = HabitNudge.text(
        [_h('a', title: '读书', emoji: '📚')],
        streakAfterCheckIn: (_) => 5,
      );
      expect(t.title, '📚 读书 还没打卡');
      expect(t.body, '还差一步就连续 5 天了，睡前补上还来得及');
    });

    test('单个习惯且补卡后仅 1 天：不说「连续 1 天」', () {
      final t = HabitNudge.text(
        [_h('a', title: '读书')],
        streakAfterCheckIn: (_) => 1,
      );
      expect(t.body, '今天还没打卡，睡前补上还来得及');
      expect(t.body, isNot(contains('连续')));
    });

    test('多个习惯聚合为一条，最多列 3 个名字', () {
      final habits = [
        _h('a', title: 'A'),
        _h('b', title: 'B'),
        _h('c', title: 'C'),
      ];
      final t = HabitNudge.text(habits, streakAfterCheckIn: (_) => 9);
      expect(t.title, '还有 3 个习惯没打卡');
      expect(t.body, 'A、B、C，睡前补上不中断连续记录');
    });

    test('超过 3 个习惯用「等 N 项」兜住，避免文案过长被截断', () {
      final habits = List.generate(5, (i) => _h('h$i', title: 'H$i'));
      final t = HabitNudge.text(habits, streakAfterCheckIn: (_) => 2);
      expect(t.title, '还有 5 个习惯没打卡');
      expect(t.body, 'H0、H1、H2 等 5 项，睡前补上不中断连续记录');
    });
  });

  group('HabitNudge 常量', () {
    test('挽留时刻为 23:00', () {
      expect(HabitNudge.nudgeMinute, 23 * 60);
    });
  });
}
