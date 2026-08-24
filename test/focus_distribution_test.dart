import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/focus_provider.dart';
import 'test_helpers.dart';

/// 专注时段分布图（A2）的纯聚合逻辑单测。hourDistribution() 按「开始时刻的小时」
/// 把全部会话聚合进 24 个桶，零新存储、纯现算；这里验证分桶与累加口径。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
}

/// 构造一个落在 [hour]:00、时长 [durationSec] 的已完成专注会话。
FocusSession _sessionAt(int hour, int durationSec, {String? id}) => FocusSession(
      id: id ?? 's$hour',
      plannedSec: durationSec,
      durationSec: durationSec,
      completed: true,
      startedAt: DateTime(2026, 8, 10, hour, 0),
      endedAt: DateTime(2026, 8, 10, hour, 0).add(Duration(seconds: durationSec)),
    );

void main() {
  setUpAll(_installMocks);

  test('hourDistribution 默认 24 个桶全 0', () {
    final p = FocusProvider();
    final dist = p.hourDistribution();
    expect(dist.length, 24);
    expect(dist, everyElement(0));
  });

  test('单会话按开始时刻小时入桶', () {
    final p = FocusProvider();
    p.addSession(_sessionAt(9, 1500));
    final dist = p.hourDistribution();
    expect(dist[9], 1500);
    expect(dist.where((e) => e != 0).length, 1);
  });

  test('同一小时多会话累加，不同小时各自入桶', () {
    final p = FocusProvider();
    p.addSession(_sessionAt(14, 600, id: 'a'));
    p.addSession(_sessionAt(14, 900, id: 'b'));
    p.addSession(_sessionAt(23, 300, id: 'c'));
    final dist = p.hourDistribution();
    expect(dist[14], 1500); // 600 + 900
    expect(dist[23], 300);
    expect(dist[0], 0);
  });

  test('跨零点（小时 0）正确入桶', () {
    final p = FocusProvider();
    p.addSession(_sessionAt(0, 120));
    final dist = p.hourDistribution();
    expect(dist[0], 120);
  });
}
