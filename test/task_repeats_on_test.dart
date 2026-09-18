import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';

/// F-08 回归：repeatsOn 必须按「date-only」判定，与调用方传入带时分的 DateTime
/// 无关，否则「结束日期含当日」的契约会被破坏（传了时刻就误判已结束）。
void main() {
  group('repeatsOn 日期归一化（F-08）', () {
    test('结束日当天（带时分）仍算生效，不会误判已结束', () {
      // 每天重复，repeatUntil = 2026-09-06（含当日）。
      final t = Task(
        id: '1',
        title: 'a',
        priority: Priority.medium,
        category: Category.work,
        repeat: RepeatType.daily,
        repeatMinute: 450,
        repeatUntil: '2026-09-06',
      );
      // 结束日当天 23:59 传入：归一化后应判定为仍生效。
      expect(
          t.repeatsOn(DateTime(2026, 9, 6, 23, 59)), isTrue,
          reason: '结束日当天即便带时分也应算循环日');
      // 次日 00:00 起才真正结束。
      expect(t.repeatsOn(DateTime(2026, 9, 7, 0, 0)), isFalse);
    });

    test('带时分的 day 与零点化后的 day 判等', () {
      final t = Task(
        id: '2',
        title: 'b',
        priority: Priority.medium,
        category: Category.work,
        repeat: RepeatType.weekly,
        repeatWeekdays: const [DateTime.sunday],
        repeatMinute: 450,
      );
      // 2026-08-09 是周日，带时分与零点都应命中。
      expect(t.repeatsOn(DateTime(2026, 8, 9, 8, 0)), isTrue);
      expect(t.repeatsOn(DateTime(2026, 8, 9, 23, 59)), isTrue);
      // 周一不命中。
      expect(t.repeatsOn(DateTime(2026, 8, 10, 12, 0)), isFalse);
    });
  });
}
