import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';

void main() {
  group('Task.reminderOffsetMin', () {
    test('默认值 0（向后兼容旧数据）', () {
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.medium,
        category: Category.work,
      );
      expect(t.reminderOffsetMin, 0);
    });

    test('toJson / fromJson 往返保留偏移量', () {
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.medium,
        category: Category.work,
        dueDate: DateTime(2026, 8, 11, 9, 0),
        reminderOffsetMin: 15,
      );
      final json = t.toJson();
      expect(json['reminderOffsetMin'], 15);
      final back = Task.fromJson(json);
      expect(back.reminderOffsetMin, 15);
    });

    test('旧数据缺字段时回退为 0', () {
      final back = Task.fromJson({
        'id': '1',
        'title': 't',
        'priority': 'medium',
        'category': 'work',
      });
      expect(back.reminderOffsetMin, 0);
    });

    test('copyWith 默认保留原值', () {
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.medium,
        category: Category.work,
        reminderOffsetMin: 30,
      );
      expect(t.copyWith(title: 'x').reminderOffsetMin, 30);
    });

    test('copyWith 可修改偏移量', () {
      final t = Task(
        id: '1',
        title: 't',
        priority: Priority.medium,
        category: Category.work,
        reminderOffsetMin: 30,
      );
      expect(t.copyWith(reminderOffsetMin: 5).reminderOffsetMin, 5);
    });
  });
}
