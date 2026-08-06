import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';

void main() {
  group('Task.fromJson / toJson 往返', () {
    test('保留核心字段与重复规则', () {
      final t = Task(
        id: '42',
        title: '写测试',
        priority: Priority.high,
        category: Category.study,
        dueDate: DateTime(2026, 8, 10, 9, 30),
        status: TaskStatus.todo,
        repeat: RepeatType.weekly,
        repeatWeekdays: const [1, 3, 5],
        repeatMinute: 450,
        repeatAnchor: DateTime(2026, 8, 1),
        note: '备注',
      );
      final j = t.toJson();
      final t2 = Task.fromJson(j);
      expect(t2.id, '42');
      expect(t2.title, '写测试');
      expect(t2.priority, Priority.high);
      expect(t2.category, Category.study);
      expect(t2.dueDate, DateTime(2026, 8, 10, 9, 30));
      expect(t2.repeat, RepeatType.weekly);
      expect(t2.repeatWeekdays, const [1, 3, 5]);
      expect(t2.repeatMinute, 450);
      expect(t2.repeatAnchor, DateTime(2026, 8, 1));
      expect(t2.note, '备注');
    });
  });

  group('Task 状态解析（兼容旧数据）', () {
    test('done / todo / doing / null', () {
      expect(
        Task.fromJson({
          'id': '1',
          'title': 'a',
          'priority': 'high',
          'category': 'work',
          'status': 'done',
        }).done,
        isTrue,
      );
      expect(
        Task.fromJson({
          'id': '1',
          'title': 'a',
          'priority': 'high',
          'category': 'work',
          'status': 'todo',
        }).done,
        isFalse,
      );
      // 旧版 doing 归并为待办
      expect(
        Task.fromJson({
          'id': '1',
          'title': 'a',
          'priority': 'high',
          'category': 'work',
          'status': 'doing',
        }).done,
        isFalse,
      );
      // 缺 status 字段时回退 todo
      expect(
        Task.fromJson({
          'id': '1',
          'title': 'a',
          'priority': 'high',
          'category': 'work',
        }).done,
        isFalse,
      );
    });

    test('旧数据 dailyReminder=true -> RepeatType.daily', () {
      final t = Task.fromJson({
        'id': '1',
        'title': 'a',
        'priority': 'high',
        'category': 'work',
        'dailyReminder': true,
      });
      expect(t.repeat, RepeatType.daily);
    });
  });

  group('Task.repeatsOn', () {
    final wed = DateTime(2026, 8, 5); // 周三 (weekday 3)
    final fri = DateTime(2026, 8, 7); // 周五
    final sat = DateTime(2026, 8, 8); // 周六

    test('daily 每天成立', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
          repeat: RepeatType.daily,
        ).repeatsOn(wed),
        isTrue,
      );
    });
    test('none 永远不成立', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
        ).repeatsOn(wed),
        isFalse,
      );
    });
    test('weekly 命中星期', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
          repeat: RepeatType.weekly,
          repeatWeekdays: const [3],
        ).repeatsOn(wed),
        isTrue,
      );
    });
    test('weekly 不命中星期', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
          repeat: RepeatType.weekly,
          repeatWeekdays: const [1],
        ).repeatsOn(wed),
        isFalse,
      );
    });
    test('weekday 工作日成立 / 周末不成立', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
          repeat: RepeatType.weekday,
        ).repeatsOn(fri),
        isTrue,
      );
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
          repeat: RepeatType.weekday,
        ).repeatsOn(sat),
        isFalse,
      );
    });
    test('interval 按锚点 + N 天取模', () {
      final anchor = DateTime(2026, 8, 1);
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.low,
        category: Category.life,
        repeat: RepeatType.interval,
        repeatInterval: 2,
        repeatAnchor: anchor,
      );
      expect(t.repeatsOn(anchor), isTrue); // diff 0
      expect(t.repeatsOn(anchor.add(const Duration(days: 1))), isFalse);
      expect(t.repeatsOn(anchor.add(const Duration(days: 2))), isTrue);
      expect(t.repeatsOn(anchor.subtract(const Duration(days: 1))), isFalse); // 锚点之前
    });
  });

  group('Task.repeatSummary / repeatFull', () {
    test('none -> 空串', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
        ).repeatSummary,
        '',
      );
    });
    test('daily -> 每天', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
          repeat: RepeatType.daily,
        ).repeatSummary,
        '每天',
      );
    });
    test('weekly -> 每周 一、三', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
          repeat: RepeatType.weekly,
          repeatWeekdays: const [1, 3],
        ).repeatSummary,
        '每周 一、三',
      );
    });
    test('repeatFull 含提醒时刻', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
          repeat: RepeatType.daily,
          repeatMinute: 450,
        ).repeatFull,
        '每天 07:30',
      );
    });
  });

  group('Task.copyWith / done / isRepeating', () {
    test('copyWith 只覆盖传入字段', () {
      final t = Task(
        id: '1',
        title: 'a',
        priority: Priority.low,
        category: Category.life,
      );
      final c = t.copyWith(title: 'b', status: TaskStatus.done);
      expect(c.title, 'b');
      expect(c.done, isTrue);
      expect(c.priority, Priority.low); // 未变
      expect(c.category, Category.life); // 未变
    });
    test('isRepeating 由 repeat 决定', () {
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
        ).isRepeating,
        isFalse,
      );
      expect(
        Task(
          id: '1',
          title: 't',
          priority: Priority.low,
          category: Category.life,
          repeat: RepeatType.daily,
        ).isRepeating,
        isTrue,
      );
    });
  });

  group('copyWith 清空语义（哨兵区分未传与显式 null）', () {
    final base = Task(
      id: '1',
      title: 'a',
      priority: Priority.low,
      category: Category.life,
      dueDate: DateTime(2026, 1, 1),
      completedAt: DateTime(2026, 1, 2),
      deletedAt: DateTime(2026, 1, 3),
    );
    test('传 null 真正清空可空字段', () {
      final c = base.copyWith(dueDate: null, completedAt: null, deletedAt: null);
      expect(c.dueDate, isNull);
      expect(c.completedAt, isNull);
      expect(c.deletedAt, isNull);
    });
    test('省略可空字段则保留旧值', () {
      final k = base.copyWith(title: 'b');
      expect(k.dueDate, DateTime(2026, 1, 1));
      expect(k.completedAt, DateTime(2026, 1, 2));
      expect(k.deletedAt, DateTime(2026, 1, 3));
    });
  });
}
