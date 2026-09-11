import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/widgets/past_due_guard.dart';

/// P3-5 回归：「过去时刻」提醒守卫的判定口径。
///
/// 一次性任务的截止提醒 = dueDate − reminderOffsetMin。该时刻若已过去，保存 / 改期后
/// 提醒**永远不会触发**——必须提示用户；而重复任务由 repeatMinute 驱动、会再次循环
/// 触发，不存在「永久失效」，提示反而是误报。
Task _mk(
  String id, {
  DateTime? due,
  RepeatType repeat = RepeatType.none,
  TaskStatus status = TaskStatus.todo,
  DateTime? deletedAt,
}) =>
    Task(
      id: id,
      title: 'T$id',
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
      repeat: repeat,
      repeatMinute: repeat == RepeatType.none ? null : 450,
      status: status,
      deletedAt: deletedAt,
    );

void main() {
  final now = DateTime(2026, 9, 11, 15, 0);

  group('PastDueGuard.isReminderDead', () {
    test('一次性任务且截止时刻已过 → 提醒永久失效', () {
      expect(
        PastDueGuard.isReminderDead(_mk('1', due: DateTime(2026, 9, 11, 9, 0)), now),
        isTrue,
      );
    });

    test('一次性任务截止时刻未到 → 正常', () {
      expect(
        PastDueGuard.isReminderDead(_mk('1', due: DateTime(2026, 9, 11, 18, 0)), now),
        isFalse,
      );
    });

    test('无截止时间 → 没有提醒可谈', () {
      expect(PastDueGuard.isReminderDead(_mk('1'), now), isFalse);
    });

    test('重复任务即使截止时刻已过也不算失效（会按规则再次触发）', () {
      expect(
        PastDueGuard.isReminderDead(
          _mk('1', due: DateTime(2026, 9, 11, 9, 0), repeat: RepeatType.daily),
          now,
        ),
        isFalse,
      );
    });

    test('已完成 / 回收站中的任务不算失效', () {
      expect(
        PastDueGuard.isReminderDead(
          _mk('1', due: DateTime(2026, 9, 11, 9, 0), status: TaskStatus.done),
          now,
        ),
        isFalse,
      );
      expect(
        PastDueGuard.isReminderDead(
          _mk('1',
              due: DateTime(2026, 9, 11, 9, 0), deletedAt: DateTime(2026, 9, 10)),
          now,
        ),
        isFalse,
      );
    });
  });

  group('PastDueGuard.countDeadAfter（批量改期预演）', () {
    test('只统计「改期后失效」的任务，口径与实际落库的同一个 transform 一致', () {
      final targets = [
        _mk('1', due: DateTime(2026, 9, 1, 9, 0)), // 改到今天 09:00 → 已过
        _mk('2', due: DateTime(2026, 9, 1, 18, 0)), // 改到今天 18:00 → 未过
        _mk('3', due: DateTime(2026, 9, 1, 9, 0), repeat: RepeatType.daily),
        _mk('4'), // 无截止 → 与 today/tomorrow 模式同为「原样跳过」
      ];
      // 模拟 batch_edit「顺延到今天」：保留原时分、仅平移日期。
      final dead = PastDueGuard.countDeadAfter(targets, (t) {
        final d = t.dueDate;
        if (d == null) return t;
        return t.copyWith(dueDate: DateTime(2026, 9, 11, d.hour, d.minute));
      }, now);
      expect(dead, 1, reason: '仅 #1 会在改期后失去提醒');
    });
  });
}
