import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/notification_service.dart';

/// F-02 回归：重复提醒通知 id 唯一性 + int32 边界 + 段位不重叠。
void main() {
  test('多任务 × 多星期槽 id 全部唯一（枚举 1..500 × 0..7）', () {
    final seen = <int>{};
    for (var id = 1; id <= 500; id++) {
      for (var d = 0; d < 8; d++) {
        final nid = NotificationService.repeatNotifyIdOf(id.toString(), d);
        expect(seen.contains(nid), isFalse,
            reason: 'id=$id day=$d 与既有通知 id 碰撞：$nid');
        seen.add(nid);
      }
    }
    // 共 4000 个互异 id。
    expect(seen.length, 500 * 8);
  });

  test('非数字（hashCode 兜底）任务 id 也不碰撞数字段溢出', () {
    final a = NotificationService.repeatNotifyIdOf('xyz', 0);
    final b = NotificationService.repeatNotifyIdOf('abc', 7);
    expect(a, isNot(b));
  });

  test('取值落在 int32 上限内且不越界', () {
    // 理论最大值：1600000000 + (29999999) * 8 + 7 = 1839999999 < 2^31-1。
    var max = 0;
    for (var id = 1; id <= 100000; id++) {
      for (var d = 0; d < 8; d++) {
        final nid = NotificationService.repeatNotifyIdOf(id.toString(), d);
        expect(nid, lessThan(2147483647));
        max = nid > max ? nid : max;
      }
    }
    expect(max, lessThan(2147483647));
  });

  test('与 snooze 段（1900000000+）、习惯段（1000000000+）不重叠', () {
    // snooze 段为 1900000000 + (base%10000000)，范围约 [19e8, 1909999999]。
    // 习惯段为 1000000000 + s*10 + day，范围约 [1e9, 1000999907]。
    // 重复段为 [1.6e9, 1.84e9]，理论上三者在合法 id 范围内无交集。
    final repeatIds = <int>{};
    for (var id = 1; id <= 200000; id++) {
      for (var d = 0; d < 8; d++) {
        repeatIds.add(NotificationService.repeatNotifyIdOf(id.toString(), d));
      }
    }
    // 习惯段最大 1000999907、snooze 段最小 1900000000 都已超出重复段 [1.6e9,1.84e9]，
    // 但为稳妥仍校验：重复段任一 id 不应落在 [1e9, 1.01e9] 或 [1.9e9, 1.91e9] 内。
    for (final nid in repeatIds) {
      expect(nid >= 1000000000 && nid <= 1000999907, isFalse);
      expect(nid >= 1900000000 && nid <= 1909999999, isFalse);
    }
  });
}
