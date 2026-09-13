import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/kanban_board.dart';
import 'test_helpers.dart';

/// 看板泳道「有界宽度」布局回归（v2.8.9 发版后修复）。
///
/// 背景：泳道内的泳道头 `Row + Spacer()` 与卡片内 `Expanded(child: Text)` 都要求父级
/// 给出**有界宽度**，但 `Row` 给非 flex 子项的约束是 `BoxConstraints(maxHeight: h)`
/// （maxWidth 无界）。此前泳道作为普通子项塞进 `Row`，拿到无界宽度：
/// - debug：布局阶段抛 `RenderFlex children have non-zero flex but incoming width
///   constraints are unbounded`；
/// - release：无断言，`RenderFlex._computeSizes` 首轮 `canFlex && flex > 0` 判定使 flex
///   子项被当非 flex 处理 → `Spacer` 静默塌成 0（计数紧贴标题）、卡片按内容自适应，
///   注释里承诺的「双列等宽铺满」从未实现。
///
/// 修复（三种分组模式都已覆盖）：
/// - **状态**：两条泳道套 `Expanded` → 各占一半宽度（等宽铺满）；
/// - **分类 / 标签**：列数可变、处于横向滚动视口（`Expanded` 在此同样非法），改为给每条
///   泳道固定宽度 `220px` → 约束有界，同时保留横向滚动。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// `restoreFromJson` 尾部的附件孤儿回收会经 path_provider 取应用文档目录。
class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

Future<TaskProvider> _providerWith(List<Task> tasks) async {
  LocalDatabase.resetMemoryForTest();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  final docs = await Directory.systemTemp.createTemp('kanban_');
  PathProviderPlatform.instance = _FakePathProvider(docs.path);
  final provider = TaskProvider();
  await provider.restoreFromJson(jsonEncode(<String, dynamic>{
    'version': 2,
    'tasks': tasks.map((t) => t.toJson()).toList(),
  }));
  return provider;
}

/// ⚠️ 必须走 [WidgetTester.runAsync]：`testWidgets` 测试体跑在 FakeAsync 时钟下，
/// `restoreFromJson` 尾部的真实文件 I/O 直接 await 会永不完成（进程挂死、无失败输出）。
Future<TaskProvider> _seed(WidgetTester tester, List<Task> tasks) async {
  final provider = await tester.runAsync(() => _providerWith(tasks));
  return provider!;
}

Widget _board(TaskProvider provider) => ChangeNotifierProvider<TaskProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: lightTheme,
        home: const Scaffold(body: SingleChildScrollView(child: KanbanBoard())),
      ),
    );

void main() {
  setUpAll(_installMocks);

  testWidgets('状态模式：双列等宽铺满且不再触发「宽度无界却含 flex 子项」断言',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = await _seed(tester, const [
      Task(
        id: 'k1',
        title: '待办卡片甲',
        priority: Priority.high,
        category: Category.work,
      ),
      Task(
        id: 'k2',
        title: '待办卡片乙',
        priority: Priority.medium,
        category: Category.life,
      ),
      Task(
        id: 'k3',
        title: '已完成卡片',
        priority: Priority.low,
        category: Category.study,
        status: TaskStatus.done,
      ),
    ]);

    await tester.pumpWidget(_board(provider));
    await tester.pumpAndSettle();

    // 1) 双列与卡片均正常渲染（宽度有界后 Expanded(Text) 才有落点），
    //    泳道计数取自「每任务恰好归入一列」的分组口径。
    expect(find.text('待办'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('待办卡片甲'), findsOneWidget);
    expect(find.text('待办卡片乙'), findsOneWidget);
    expect(find.text('已完成卡片'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // 待办列计数
    expect(find.text('1'), findsOneWidget); // 已完成列计数

    // 2) 核心：布局阶段不再抛断言（修复前此处必然非 null）。
    expect(tester.takeException(), isNull,
        reason: '泳道拿到无界宽度会让 Row+Spacer / Expanded 触发 debug 断言');

    // 3) 双列等宽铺满：Row 内仅两条 flex 子项 → 各占视口一半，合计等于整行宽度。
    final lanes = find.byType(DragTarget<Task>);
    expect(lanes, findsNWidgets(2));
    final lane0 = tester.getRect(lanes.at(0));
    final lane1 = tester.getRect(lanes.at(1));
    expect(lane0.width, closeTo(lane1.width, 0.01), reason: '两条泳道必须等宽');
    expect(lane0.width + lane1.width,
        closeTo(tester.view.physicalSize.width, 0.5),
        reason: '两列应铺满整行宽度（等宽铺满）');

    // 4) 泳道头 Spacer 真正吃到空间：计数落在泳道右半边（修复前 Spacer 塌为 0，
    //    计数会紧贴标题停在左半边）。
    expect(tester.getCenter(find.text('2')).dx,
        greaterThan(lane0.center.dx),
        reason: 'Spacer 塌为 0 时计数不会跑到右半区');
  });

  testWidgets('状态模式：单列为空时仍占一半宽度（两列位置不塌陷）', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = await _seed(tester, const [
      Task(
        id: 'k1',
        title: '只有待办',
        priority: Priority.high,
        category: Category.work,
      ),
    ]);

    await tester.pumpWidget(_board(provider));
    await tester.pumpAndSettle();

    expect(find.text('只有待办'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final lanes = find.byType(DragTarget<Task>);
    expect(lanes, findsNWidgets(2));
    expect(tester.getSize(lanes.at(0)).width,
        closeTo(tester.getSize(lanes.at(1)).width, 0.01),
        reason: '空列与有任务的列必须等宽（不能塌成 0）');
  });

  testWidgets('标签模式：泳道固定 220px（有界宽度）、横向滚动保留、无布局断言',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = await _seed(tester, const [
      Task(
        id: 'k1',
        title: '任务甲',
        priority: Priority.high,
        category: Category.work,
        tags: ['前端', '后端'],
      ),
      Task(
        id: 'k2',
        title: '任务乙',
        priority: Priority.medium,
        category: Category.life,
        tags: ['前端'],
      ),
      Task(
        id: 'k3',
        title: '任务丙',
        priority: Priority.low,
        category: Category.study,
      ),
    ]);

    await tester.pumpWidget(_board(provider));
    await tester.pumpAndSettle();

    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();

    // 前端=2 / 后端=1 → 后端泳道被「前端」吸空后隐藏，只剩「前端」+「其他」。
    expect(find.text('前端'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: '横向滚动视口内泳道宽度无界 → Row+Spacer / Expanded 会触发 debug 断言');

    final lanes = find.byType(DragTarget<Task>);
    expect(lanes, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
      expect(tester.getSize(lanes.at(i)).width, closeTo(220, 0.01),
          reason: '分类 / 标签泳道必须是固定宽度（`_scrollLaneWidth`，有界宽度前提）');
    }

    final horizontal = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((w) => w.scrollDirection == Axis.horizontal);
    expect(horizontal, isNotEmpty, reason: '分类 / 标签模式应保留横向滚动');
  });

  testWidgets('分类模式：三条泳道均为固定 220px 且无布局断言', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = await _seed(tester, const [
      Task(
        id: 'c1',
        title: '工作任务',
        priority: Priority.high,
        category: Category.work,
      ),
      Task(
        id: 'c2',
        title: '生活任务',
        priority: Priority.medium,
        category: Category.life,
      ),
      Task(
        id: 'c3',
        title: '学习任务',
        priority: Priority.low,
        category: Category.study,
      ),
    ]);

    await tester.pumpWidget(_board(provider));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分类'));
    await tester.pumpAndSettle();

    expect(find.text('工作'), findsOneWidget);
    expect(find.text('生活'), findsOneWidget);
    expect(find.text('学习'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final lanes = find.byType(DragTarget<Task>);
    expect(lanes, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(tester.getSize(lanes.at(i)).width, closeTo(220, 0.01));
    }
  });
}
