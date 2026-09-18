import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// F-05 回归：删除撤销必须按「邻居 id」归位，而非按删除时的陈旧下标。
///
/// 旧实现记 `_lastBatchIndices`，删除后再新增/删/拖拽过的任务，按旧下标插回会错位，
/// 且旧 order 与邻居不连续。本测试模拟「删 B → 新增 D → 撤销」场景：
/// 若用下标归位，撤销会插到错误位置；按 id 归位应把 B 放回 A、C 之间。
///
/// P3-5（v2.9.0 审计）：本文件此前**无法编译**（`Task` 缺 required 的
/// priority/category，且 `_installMocks` 未定义）——整条用例从未真正跑起来，
/// 却被计入「5 条历史预存失败」。这里补齐构造参数与 mock 装配。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

Task _mk(String id) => Task(
      id: id,
      title: 'T$id',
      priority: Priority.medium,
      category: Category.work,
      status: TaskStatus.todo,
      repeat: RepeatType.none,
    );

Future<TaskProvider> _build(List<String> ids) async {
  final p = TaskProvider();
  final json = <String, dynamic>{
    'version': 2,
    'tasks': ids.map((id) => _mk(id).toJson()).toList(),
    'trash': <dynamic>[],
    'notifications_enabled': false,
    'sound_enabled': false,
  };
  await p.restoreFromJson(jsonEncode(json));
  return p;
}

void main() {
  setUp(() {
    _installMocks();
    useMemoryDatabase();
  });

  test('删除后列表变动，撤销仍按邻居 id 归位（F-05）', () async {
    final p = await _build(['A', 'B', 'C']);
    p.deleteTasks(['B']); // 列表变为 [A, C]
    expect(p.tasks.any((t) => t.id == 'B'), isFalse);
    p.addTask(_mk('D')); // 新任务插到头部：[D, A, C]

    p.undoDelete(); // 撤销 B → 应回到 A 与 C 之间

    final order = p.tasks.map((t) => t.id).toList();
    expect(order.contains('B'), isTrue, reason: 'B 应被撤销找回');
    expect(order.indexOf('A'), lessThan(order.indexOf('B')),
        reason: 'B 应在 A 之后（按邻居 id 归位）');
    expect(order.indexOf('B'), lessThan(order.indexOf('C')),
        reason: 'B 应在 C 之前（回到原相邻位置）');
    // 旧 order 已被重算、无空洞/重复：
    final orders = p.tasks.map((t) => t.order).toList();
    expect(orders.toSet().length, orders.length, reason: 'order 不应有重复');
  });

  test('删除后未再变动，撤销回到原位', () async {
    final p = await _build(['A', 'B', 'C']);
    p.deleteTasks(['B']);
    p.undoDelete();
    expect(p.tasks.map((t) => t.id).toList(), ['A', 'B', 'C']);
  });

  test('批量删除多个相邻任务，撤销全部找回', () async {
    final p = await _build(['A', 'B', 'C', 'D']);
    p.deleteTasks(['B', 'C']);
    p.undoDelete();
    // 同时删除的相邻任务以「首邻居 id」为锚，二者内部先后不保证，但都归位到 A 与 D 之间。
    final order = p.tasks.map((t) => t.id).toList();
    expect(order.toSet(), {'A', 'B', 'C', 'D'});
    expect(order.indexOf('A'), lessThan(order.indexOf('B')));
    expect(order.indexOf('B'), lessThan(order.indexOf('D')));
    expect(order.indexOf('A'), lessThan(order.indexOf('C')));
    expect(order.indexOf('C'), lessThan(order.indexOf('D')));
  });
}
