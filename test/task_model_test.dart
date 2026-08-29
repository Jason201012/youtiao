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

  group('SubTask 序列化往返', () {
    test('toJson / fromJson 保留字段', () {
      final s = SubTask(id: 's1', title: '买菜', done: true);
      final j = s.toJson();
      final s2 = SubTask.fromJson(j);
      expect(s2.id, 's1');
      expect(s2.title, '买菜');
      expect(s2.done, isTrue);
    });
    test('fromJson 缺省值安全', () {
      final s = SubTask.fromJson(<String, dynamic>{});
      expect(s.id, '');
      expect(s.title, '');
      expect(s.done, isFalse);
    });
    test('copyWith 仅覆盖传入字段', () {
      final s = SubTask(id: 's1', title: 'a');
      final c = s.copyWith(done: true);
      expect(c.id, 's1');
      expect(c.title, 'a');
      expect(c.done, isTrue);
    });
  });

  group('Task 子任务（派生进度 / 序列化 / 兼容）', () {
    final subs = [
      SubTask(id: 'a', title: '步骤1', done: true),
      SubTask(id: 'b', title: '步骤2', done: false),
      SubTask(id: 'c', title: '步骤3', done: true),
    ];
    test('subtaskTotal / subtaskDone 由列表派生', () {
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.low,
        category: Category.life,
        subtasks: subs,
      );
      expect(t.subtaskTotal, 3);
      expect(t.subtaskDone, 2);
    });
    test('toJson 序列化 subtasks，fromJson 还原', () {
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.low,
        category: Category.life,
        subtasks: subs,
      );
      final j = t.toJson();
      expect(j['subtasks'], isA<List>());
      expect((j['subtasks'] as List).length, 3);
      final t2 = Task.fromJson(j);
      expect(t2.subtaskTotal, 3);
      expect(t2.subtaskDone, 2);
      expect(t2.subtasks[1].title, '步骤2');
      expect(t2.subtasks[1].done, isFalse);
    });
    test('fromJson 缺 subtasks 字段回退空列表（旧数据兼容）', () {
      final t = Task.fromJson({
        'id': '1',
        'title': 't',
        'priority': 'low',
        'category': 'life',
      });
      expect(t.subtasks, isEmpty);
      expect(t.subtaskTotal, 0);
      expect(t.subtaskDone, 0);
    });
    test('copyWith 替换 subtasks', () {
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.low,
        category: Category.life,
      );
      final c = t.copyWith(subtasks: subs);
      expect(c.subtaskTotal, 3);
    });
  });

  group('Task 标签 / 专注累计 / 手动排序字段', () {
    test('tags / focusSecTotal / order 序列化往返', () {
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.low,
        category: Category.life,
        tags: const ['工作', '紧急'],
        focusSecTotal: 1500,
        order: 3.5,
      );
      final j = t.toJson();
      final t2 = Task.fromJson(j);
      expect(t2.tags, const ['工作', '紧急']);
      expect(t2.focusSecTotal, 1500);
      expect(t2.order, 3.5);
    });

    test('缺省值安全（旧数据无新字段回退空标签/0时长/0顺序）', () {
      final t = Task.fromJson({
        'id': '1',
        'title': 't',
        'priority': 'low',
        'category': 'life',
      });
      expect(t.tags, isEmpty);
      expect(t.focusSecTotal, 0);
      expect(t.order, 0.0);
    });

    test('tags 容忍非字符串元素', () {
      final t = Task.fromJson({
        'id': '1',
        'title': 't',
        'priority': 'low',
        'category': 'life',
        'tags': [1, 'a', null, 'b'],
      });
      expect(t.tags, const ['a', 'b']);
    });

    test('copyWith 仅覆盖传入的新字段', () {
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.low,
        category: Category.life,
        tags: const ['x'],
        focusSecTotal: 10,
        order: 2,
      );
      final c = t.copyWith(
        tags: const ['y', 'z'],
        focusSecTotal: 0,
        order: 9,
      );
      expect(c.tags, const ['y', 'z']);
      expect(c.focusSecTotal, 0);
      expect(c.order, 9.0);
      // 未传字段保留旧值
      expect(c.title, 't');
    });
  });

  group('Task.fromJson 标题空值防御（v2.3.10 修复）', () {
    test('title 为 null 时回退为空串', () {
      final t = Task.fromJson({
        'id': '1',
        'priority': 'medium',
        'category': 'life',
        'status': 'todo',
        'done': false,
        'title': null,
      });
      expect(t.title, '');
    });

    test('title 键缺失时回退为空串', () {
      final t = Task.fromJson({
        'id': '2',
        'priority': 'low',
        'category': 'work',
        'status': 'todo',
        'done': false,
      });
      expect(t.title, '');
    });

    test('空串标题不崩溃，toJson 往返一致', () {
      final t = Task(
        id: '3',
        title: '',
        priority: Priority.high,
        category: Category.study,
      );
      final j = t.toJson();
      final t2 = Task.fromJson(j);
      expect(t2.title, '');
      expect(t2.id, '3');
    });
  });

  group('P1-9 每月倒数第 N 天（monthlyFromEnd）', () {
    Task mk({int fromEnd = 0, int day = 1, int? wd, int? wi}) => Task(
          id: 'm1',
          title: '房租',
          priority: Priority.medium,
          category: Category.work,
          repeat: RepeatType.monthly,
          monthlyFromEnd: fromEnd,
          monthlyDay: day,
          monthlyWeekday: wd,
          monthlyWeekIndex: wi,
        );

    test('最后一天：大小月与闰年自动适配', () {
      final t = mk(fromEnd: 1);
      expect(t.repeatsOn(DateTime(2026, 1, 31)), isTrue); // 1 月 31 天
      expect(t.repeatsOn(DateTime(2026, 1, 30)), isFalse);
      expect(t.repeatsOn(DateTime(2026, 2, 28)), isTrue); // 2026 平年
      expect(t.repeatsOn(DateTime(2026, 2, 27)), isFalse);
      expect(t.repeatsOn(DateTime(2026, 4, 30)), isTrue); // 4 月 30 天
      expect(t.repeatsOn(DateTime(2026, 4, 29)), isFalse);
      expect(t.repeatsOn(DateTime(2024, 2, 29)), isTrue); // 2024 闰年
    });

    test('倒数第 2 / 3 天', () {
      final t2 = mk(fromEnd: 2);
      expect(t2.repeatsOn(DateTime(2026, 1, 30)), isTrue);
      expect(t2.repeatsOn(DateTime(2026, 1, 31)), isFalse);
      expect(t2.repeatsOn(DateTime(2026, 2, 27)), isTrue);

      final t3 = mk(fromEnd: 3);
      expect(t3.repeatsOn(DateTime(2026, 1, 29)), isTrue);
      expect(t3.repeatsOn(DateTime(2026, 2, 26)), isTrue);
    });

    test('优先级高于 monthlyDay 与「第 N 个周几」', () {
      final t = mk(fromEnd: 1, day: 15, wd: 7, wi: 5);
      expect(t.repeatsOn(DateTime(2026, 1, 31)), isTrue);
      expect(t.repeatsOn(DateTime(2026, 1, 15)), isFalse);
    });

    test('repeatSummary 文案', () {
      expect(mk(fromEnd: 1).repeatSummary, '每月最后一天');
      expect(mk(fromEnd: 2).repeatSummary, '每月倒数第2天');
      expect(mk(fromEnd: 3).repeatSummary, '每月倒数第3天');
    });

    test('JSON 往返保持字段', () {
      final back = Task.fromJson(mk(fromEnd: 2).toJson());
      expect(back.monthlyFromEnd, 2);
    });

    test('旧数据无该字段时缺省为 0（向后兼容，零迁移）', () {
      final old =
          Task.fromJson({'id': 'm1', 'title': '房租', 'repeat': 'monthly'});
      expect(old.monthlyFromEnd, 0);
      expect(old.repeatsOn(DateTime(2026, 1, 1)), isTrue); // 回落为「每月 1 号」
    });

    test('copyWith 可更新且缺省保持原值', () {
      final t = mk(fromEnd: 1);
      expect(t.copyWith(monthlyFromEnd: 3).monthlyFromEnd, 3);
      expect(t.copyWith().monthlyFromEnd, 1);
    });

    test('预览 occurrencesBetween 自动联动（occurrence_sheet 无需改）', () {
      final occ =
          mk(fromEnd: 1).occurrencesBetween(DateTime(2026, 1, 1), days: 90);
      expect(occ, contains(DateTime(2026, 1, 31)));
      expect(occ, contains(DateTime(2026, 2, 28)));
      expect(occ, contains(DateTime(2026, 3, 31)));
    });
  });
}
