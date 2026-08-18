import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/notification_service.dart';

void main() {
  group('snooze 稍后提醒', () {
    test('snoozeActionId 常量契约', () {
      expect(NotificationService.snoozeActionId, 'snooze');
    });

    test('snooze 后 payload 仍可被解析（保证稍后提醒后再点通知能跳转）', () {
      // snoozeTaskReminder / snoozeHabitReminder 复用与一次性提醒相同的 payload 格式，
      // 故 10 分钟后重新弹出的通知点击仍能解析出实体 id 并跳转。
      const taskPayload = '${NotificationService.payloadTaskPrefix}123';
      expect(NotificationService.parseTaskId(taskPayload), '123');
      const habitPayload = '${NotificationService.payloadHabitPrefix}456';
      expect(NotificationService.parseHabitId(habitPayload), '456');
    });
  });
}
