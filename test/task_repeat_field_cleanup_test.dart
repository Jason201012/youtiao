import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';

/// P2-3 回归：编辑弹层保存前的「非适用字段」归一化（[Task.normalizedRepeatFields]）。
///
/// 场景：用户在弹层里把「每隔 3 天」改回「不重复」、或把截止时间清空。此前这些字段
/// 被无条件写回旧值，残留脏数据会污染备份导出与「未来 30 天预览」，并让
/// TaskProvider 的 remindersChanged 判定把无害残留误判成「提醒变了」而触发无谓重排。
///
/// 归一化只清**确定不生效**的字段，会改变行为的字段一律不动（尤其 repeatAnchor）。
Task _base() => Task(
      id: '1',
      title: 'T',
      priority: Priority.medium,
      category: Category.work,
      dueDate: DateTime(2026, 9, 11, 9, 0),
      repeat: RepeatType.interval,
      repeatInterval: 3,
      repeatMinute: 450,
      repeatAnchor: DateTime(2026, 9, 1),
      repeatUntil: '2026-12-31',
      reminderOffsetMin: 15,
    );

void main() {
  group('Task.normalizedRepeatFields（P2-3）', () {
    test('切回「不重复」：清 repeatUntil、repeatInterval，并保留其余字段', () {
      final t = _base()
          .copyWith(
            repeat: RepeatType.none,
            repeatMinute: null,
            // 弹层里「不重复」时 weekdays 传空列表（原实现已处理）。
            repeatWeekdays: const [],
          )
          .normalizedRepeatFields();

      expect(t.repeatUntil, isNull, reason: '不重复时结束日期无意义');
      expect(t.repeatInterval, 1, reason: '不重复时间隔无意义，回落默认值');
      expect(t.repeat, RepeatType.none);
      // 有截止时间 → 提前量仍然生效，必须保留。
      expect(t.reminderOffsetMin, 15);
      // 锚点刻意保留：惰性字段，保留可让「改回每隔 N 天」沿用原相位。
      expect(t.repeatAnchor, DateTime(2026, 9, 1));
    });

    test('清空截止时间 → 提前量一并清掉（无截止时不可能生效）', () {
      final t = _base()
          .copyWith(dueDate: null)
          .normalizedRepeatFields();
      expect(t.reminderOffsetMin, 0, reason: '无截止时间时提前量纯属脏数据');
      // 仍为重复任务 → 结束日期 / 间隔保留。
      expect(t.repeatUntil, '2026-12-31');
      expect(t.repeatInterval, 3);
    });

    test('每周重复：清间隔、保留结束日期', () {
      final t = _base()
          .copyWith(repeat: RepeatType.weekly, repeatWeekdays: const [3, 5])
          .normalizedRepeatFields();
      expect(t.repeatInterval, 1);
      expect(t.repeatUntil, '2026-12-31');
    });

    test('已是干净状态时是幂等的（不产生任何字段变化）', () {
      final clean = Task(
        id: '2',
        title: 'C',
        priority: Priority.medium,
        category: Category.work,
        repeat: RepeatType.daily,
        repeatMinute: 480,
      );
      final once = clean.normalizedRepeatFields();
      expect(once.toJson(), clean.toJson());
      expect(once.normalizedRepeatFields().toJson(), clean.toJson());
    });

    test('不清理 anchor（非 interval 类型下也保留）', () {
      final t = _base()
          .copyWith(repeat: RepeatType.daily)
          .normalizedRepeatFields();
      expect(t.repeatAnchor, DateTime(2026, 9, 1),
          reason: 'anchor 对非 interval 惰性，清理反而会改变「改回每隔 N 天」的相位');
    });
  });
}
