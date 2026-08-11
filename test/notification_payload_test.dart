import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/notification_service.dart';

void main() {
  group('NotificationService payload 解析', () {
    test('parseTaskId 正常解析 task: 前缀', () {
      expect(
        NotificationService.parseTaskId('task:1754000000000'),
        '1754000000000',
      );
    });

    test('parseTaskId 对无前缀返回 null', () {
      expect(NotificationService.parseTaskId('habit:abc'), isNull);
      expect(NotificationService.parseTaskId('随机字符串'), isNull);
    });

    test('parseTaskId 对 null / 空返回 null', () {
      expect(NotificationService.parseTaskId(null), isNull);
      expect(NotificationService.parseTaskId(''), isNull);
    });

    test('parseTaskId 任务 id 本身含冒号也不误切', () {
      const payload = 'task:1754:0000:0000';
      expect(
        NotificationService.parseTaskId(payload),
        '1754:0000:0000',
      );
    });

    test('parseHabitId 正常解析 habit: 前缀', () {
      expect(
        NotificationService.parseHabitId('habit:1754000000000'),
        '1754000000000',
      );
    });

    test('parseHabitId 对 task:/空/null 返回 null', () {
      expect(NotificationService.parseHabitId('task:123'), isNull);
      expect(NotificationService.parseHabitId(null), isNull);
      expect(NotificationService.parseHabitId(''), isNull);
    });

    test('前缀常量与调度透传用的字面量一致', () {
      expect(NotificationService.payloadTaskPrefix, 'task:');
      expect(NotificationService.payloadHabitPrefix, 'habit:');
    });
  });
}
