import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/search_index.dart';

/// 测试用：以最小字段构造一个任务，其余取合理默认值。
Task _task({
  String? title,
  Priority? priority,
  Category? category,
  List<String>? tags,
  String? note,
  RepeatType? repeat,
  List<int>? repeatWeekdays,
  int? repeatInterval,
}) {
  return Task(
    id: 't-${title ?? 'x'}-${DateTime.now().microsecondsSinceEpoch}',
    title: title ?? '默认任务',
    priority: priority ?? Priority.medium,
    category: category ?? Category.work,
    repeat: repeat ?? RepeatType.none,
    repeatWeekdays: repeatWeekdays ?? const [],
    repeatInterval: repeatInterval ?? 2,
    note: note ?? '',
    tags: tags ?? const [],
  );
}

/// 测试用：以最小字段构造一个习惯。
Habit _habit({
  String? title,
  List<int>? weekdays,
  int? reminderMinute,
}) {
  return Habit(
    id: 'h-${title ?? 'x'}-${DateTime.now().microsecondsSinceEpoch}',
    title: title ?? '默认习惯',
    weekdays: weekdays ?? const [],
    createdAt: DateTime(2026, 1, 1),
    reminderMinute: reminderMinute,
  );
}

void main() {
  group('GlobalSearch - 任务匹配', () {
    test('标题命中', () {
      final t = _task(title: '买菜做饭');
      expect(GlobalSearch.query('买菜', tasks: [t], habits: const []).tasks,
          contains(t));
    });

    test('标签命中', () {
      final t = _task(title: '跑步', tags: ['运动']);
      expect(GlobalSearch.query('运动', tasks: [t], habits: const []).tasks,
          contains(t));
    });

    test('分类中文 label 命中（工作）', () {
      final t = _task(title: '开会', category: Category.work);
      expect(GlobalSearch.query('工作', tasks: [t], habits: const []).tasks,
          contains(t));
    });

    test('分类英文 name 命中（work）', () {
      final t = _task(title: '开会', category: Category.work);
      expect(GlobalSearch.query('work', tasks: [t], habits: const []).tasks,
          contains(t));
    });

    test('优先级中文命中（高）', () {
      final t = _task(title: '救火', priority: Priority.high);
      expect(GlobalSearch.query('高', tasks: [t], habits: const []).tasks,
          contains(t));
    });

    test('备注命中', () {
      final t = _task(title: '读书', note: '每天读30分钟');
      expect(GlobalSearch.query('30分钟', tasks: [t], habits: const []).tasks,
          contains(t));
    });

    test('重复摘要命中（每天）', () {
      final t = _task(title: '背单词', repeat: RepeatType.daily);
      expect(GlobalSearch.query('每天', tasks: [t], habits: const []).tasks,
          contains(t));
    });

    test('忽略大小写（英文标题）', () {
      final t = _task(title: 'Buy Milk');
      expect(GlobalSearch.query('milk', tasks: [t], habits: const []).tasks,
          contains(t));
    });

    test('空关键字返回空结果', () {
      final t = _task(title: '买菜');
      final r = GlobalSearch.query('   ', tasks: [t], habits: const []);
      expect(r.tasks, isEmpty);
      expect(r.total, 0);
    });

    test('未命中返回空', () {
      final t = _task(title: '买菜');
      expect(GlobalSearch.query('跑步', tasks: [t], habits: const []).tasks,
          isEmpty);
    });
  });

  group('GlobalSearch - 习惯匹配', () {
    test('标题命中', () {
      final h = _habit(title: '晨跑');
      expect(GlobalSearch.query('晨跑', tasks: const [], habits: [h]).habits,
          contains(h));
    });

    test('频率「每天」命中', () {
      final h = _habit(title: '喝水', weekdays: const []);
      expect(GlobalSearch.query('每天', tasks: const [], habits: [h]).habits,
          contains(h));
    });

    test('频率「每周 一 三 五」按星期名命中', () {
      final h = _habit(title: '健身', weekdays: const [1, 3, 5]);
      expect(GlobalSearch.query('周一', tasks: const [], habits: [h]).habits,
          contains(h));
    });

    test('提醒时间 HH:mm 命中', () {
      final h = _habit(title: '冥想', reminderMinute: 8 * 60 + 30);
      expect(GlobalSearch.query('08:30', tasks: const [], habits: [h]).habits,
          contains(h));
    });

    test('提醒时间按小时数字命中', () {
      final h = _habit(title: '冥想', reminderMinute: 8 * 60 + 30);
      expect(GlobalSearch.query('8', tasks: const [], habits: [h]).habits,
          contains(h));
    });

    test('未命中返回空', () {
      final h = _habit(title: '晨跑');
      expect(GlobalSearch.query('游泳', tasks: const [], habits: [h]).habits,
          isEmpty);
    });
  });

  group('GlobalSearch - 分组与总数', () {
    test('跨两类同时命中，total 正确', () {
      final t = _task(title: '夜跑', tags: ['运动']);
      final h = _habit(title: '晨跑');
      final r = GlobalSearch.query('跑', tasks: [t], habits: [h]);
      expect(r.tasks, contains(t));
      expect(r.habits, contains(h));
      expect(r.total, 2);
    });

    test('只命中任务时习惯组为空', () {
      final t = _task(title: '写周报');
      final h = _habit(title: '晨跑');
      final r = GlobalSearch.query('周报', tasks: [t], habits: [h]);
      expect(r.tasks, contains(t));
      expect(r.habits, isEmpty);
    });

    test('空关键字两类皆空', () {
      final r = GlobalSearch.query('',
          tasks: [_task(title: 'x')], habits: [_habit(title: 'y')]);
      expect(r.tasks, isEmpty);
      expect(r.habits, isEmpty);
      expect(r.total, 0);
    });
  });
}
