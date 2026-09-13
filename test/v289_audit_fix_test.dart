import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/screens/calendar_screen.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/kanban_board.dart';
import 'package:todolist/widgets/occurrence_sheet.dart';
import 'test_helpers.dart';

/// v2.8.8 功能与操作审计报告（2026-09-13）修复回归测试。
///
/// 覆盖：
/// - P2-2「跳过一次」无撤销入口 —— 顺带修正了审计的隐含前提：审计认为「已跳过行仍在
///   弹层里显示」，但实测**不成立**。`Task.occurrencesBetween` 复用 `repeatsOn`，而
///   `repeatsOn` 会排除 `skipDates` → 弹层里 `_isSkipped` 恒为 false，「已跳过 /
///   撤销跳过」都是不可达死代码。修复 = 新增 `occurrencesBetweenIncludingSkipped`
///   作数据源 + 状态互斥菜单 + 详情页 SnackBar 撤销。此处覆盖数据源语义、provider
///   互逆、弹层菜单与撤销落库三处。
/// - P3-1 日历拖拽改期接入 `PastDueGuard`：拖到过去日期弹确认框，取消则不写库。
/// - P3-2 日历重复任务不可拖拽改期（无 `LongPressDraggable`）+ 长按给出正确路径提示。
/// - P3-3 看板「标签」分组互斥归入：多标签任务只出现一次，泳道计数之和 = 任务数。
///
/// P3-3 为何用纯函数单测而非 widget 测试：看板泳道位于**横向滚动视口**内，宽度约束
/// 无界，而泳道头 `Row + Spacer()` 与卡片 `Expanded` 在宽度无界时会触发 debug 断言
/// 「RenderFlex children have non-zero flex but incoming width constraints are
/// unbounded」（既有缺陷，与本轮改动无关；release 下无断言、flex 子项按非 flex
/// 处理，故真机未见异常）。该断言使 widget 级测试无法完成布局，因此把分组口径抽成
/// 纯函数 `buildKanbanLanes` 后直接单测，分组逻辑与渲染解耦、可稳定断言。
///
/// P2-1（手动恢复后偏好内存态不重读）为私有静态方法内的多 Provider 重载，无外部
/// 可观测单点；由与自动备份还原路径（`_restoreFromAutoBackup`）逐行同构 +
/// `dart analyze` 兜底，人工验收。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// `restoreFromJson` 尾部的附件孤儿回收会经 path_provider 取应用文档目录，
/// 测试环境须指向临时目录（与 v287 回归测试同口径）。
class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// 用「任务列表」构造一个已加载的 [TaskProvider]（走真实 restoreFromJson 链路）。
Future<TaskProvider> _providerWith(List<Task> tasks) async {
  LocalDatabase.resetMemoryForTest();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  final docs = await Directory.systemTemp.createTemp('v289_');
  PathProviderPlatform.instance = _FakePathProvider(docs.path);
  final provider = TaskProvider();
  await provider.restoreFromJson(jsonEncode(<String, dynamic>{
    'version': 2,
    'tasks': tasks.map((t) => t.toJson()).toList(),
  }));
  return provider;
}

/// widget 用例内的播种入口。
///
/// ⚠️ 必须走 [WidgetTester.runAsync]：`testWidgets` 的测试体跑在 FakeAsync 时钟下，
/// 而 [TaskProvider.restoreFromJson] 尾部会做**真实文件 I/O**（附件 blob 还原 /
/// 孤儿回收经 path_provider 落盘），直接 `await` 会永远等不到完成——表现为整条
/// `flutter test` 进程挂死并被外部超时终止（无任何失败输出，极难定位）。
Future<TaskProvider> _seed(WidgetTester tester, List<Task> tasks) async {
  final provider = await tester.runAsync(() => _providerWith(tasks));
  return provider!;
}

Task _simple(
  String id,
  String title, {
  List<String> tags = const [],
  DateTime? due,
  RepeatType repeat = RepeatType.none,
  int? repeatMinute,
  String? repeatUntil,
  List<String> skipDates = const [],
}) =>
    Task(
      id: id,
      title: title,
      priority: Priority.medium,
      category: Category.work,
      tags: tags,
      dueDate: due,
      repeat: repeat,
      repeatMinute: repeatMinute,
      repeatUntil: repeatUntil,
      skipDates: skipDates,
    );

/// 日历测试统一放大画布：月视图卡片较高，避免目标日期格落在视口外导致命中失败。
void _useLargeCanvas(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(_installMocks);

  group('P2-2 预览窗口必须包含已跳过日（撤销入口可达的前提）', () {
    test('occurrencesBetween 滤掉跳过日；IncludingSkipped 保留', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final task = _simple(
        'r1',
        '喝水',
        repeat: RepeatType.daily,
        repeatMinute: 7 * 60,
        skipDates: [Task.ymdKey(today)],
      );

      expect(task.repeatsOn(today), isFalse, reason: '跳过当天不算「循环命中」');
      expect(
        task.occurrencesBetween(today, days: 3),
        isNot(contains(today)),
        reason: '原数据源会滤掉跳过日 → 已跳过行永不渲染（审计前提不成立）',
      );

      final inc = task.occurrencesBetweenIncludingSkipped(today, days: 3);
      expect(inc, contains(today), reason: '预览必须能看到已跳过的日子，否则用户无从撤销');
      expect(inc.length, 3, reason: '仅放开跳过过滤，窗口长度不变');
    });

    test('IncludingSkipped 仍遵守 repeatUntil（不因放开跳过而越界）', () {
      final task = _simple(
        'r2',
        '限时循环',
        repeat: RepeatType.daily,
        repeatUntil: Task.ymdKey(DateTime(2026, 1, 3)),
      );
      final inc = task.occurrencesBetweenIncludingSkipped(
          DateTime(2026, 1, 1),
          days: 10);
      expect(inc.map(Task.ymdKey).toList(),
          ['2026-01-01', '2026-01-02', '2026-01-03']);
    });
  });

  group('P2-2 skipOccurrence / unskipOccurrence 严格互逆', () {
    test('跳过 → 撤销 回到未跳过态', () async {
      final todayKey = Task.ymdKey(DateTime.now());
      final provider = await _providerWith([
        _simple('r3', '晨间喝水',
            repeat: RepeatType.daily, repeatMinute: 7 * 60),
      ]);

      provider.skipOccurrence('r3');
      expect(provider.byId('r3')!.skipDates, contains(todayKey));

      provider.unskipOccurrence('r3');
      expect(provider.byId('r3')!.skipDates, isNot(contains(todayKey)));
      expect(provider.byId('r3')!.repeatsOn(DateTime.now()), isTrue,
          reason: '撤销后当天应重新成为循环命中日');
    });
  });

  group('P2-2 弹层撤销入口（widget）', () {
    testWidgets('已跳过的行显示「撤销跳过」，点按后 skipDates 移除', (tester) async {
      final todayKey = Task.ymdKey(DateTime.now());
      final provider = await _seed(tester, [
        _simple(
          'r4',
          '晨跑',
          repeat: RepeatType.daily,
          repeatMinute: 7 * 60,
          skipDates: [todayKey],
        ),
      ]);
      final task = provider.byId('r4')!;

      await tester.pumpWidget(MaterialApp(
        theme: lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => OccurrenceSheet.show(ctx, task, provider),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 已跳过的一天必须可见（修复前该行被 repeatsOn 过滤，根本渲染不出来）。
      expect(find.text('已跳过'), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();

      // 已跳过行只给「撤销跳过」——不再展示两个必然 no-op 的项。
      expect(find.text('撤销跳过'), findsOneWidget);
      expect(find.text('跳过一次'), findsNothing);
      expect(find.text('移到下一天'), findsNothing);

      await tester.tap(find.text('撤销跳过'));
      await tester.pumpAndSettle();

      expect(provider.byId('r4')!.skipDates, isNot(contains(todayKey)));
      expect(find.text('已跳过'), findsNothing, reason: '撤销后该行回到待处理态');
    });
  });

  group('P3-1 日历拖拽改期接入 PastDueGuard', () {
    testWidgets('拖到过去日期弹「截止时间已过」，选择返回则不写库', (tester) async {
      _useLargeCanvas(tester);

      final now = DateTime.now();
      // 一律退到上个月：本月 1 号时本月内不存在「过去日期」，而上个月则 1 号 / 2 号
      // 必然都已过去——测试完全确定，无日期边界分支。
      final prev = DateTime(now.year, now.month - 1, 1);
      final sourceDay = DateTime(prev.year, prev.month, 1, 23, 59);
      final targetDay = DateTime(prev.year, prev.month, 2);

      final provider = await _seed(tester, [
        _simple('m1', '买菜', due: sourceDay),
      ]);

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: provider),
          ChangeNotifierProvider<FocusProvider>(create: (_) => FocusProvider()),
        ],
        child: MaterialApp(
          theme: lightTheme,
          home: const Scaffold(body: CalendarScreen()),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('上个月'));
      await tester.pumpAndSettle();

      final source = find.text('买菜');
      expect(source, findsOneWidget);

      final cellKey = ValueKey(
          'cal-month-cell-${targetDay.year}-${targetDay.month}-${targetDay.day}');
      final gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(tester.getCenter(find.byKey(cellKey)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('截止时间已过'), findsOneWidget,
          reason: '拖到过去日期必须先弹统一守卫，不得静默改期');

      await tester.tap(find.text('返回修改'));
      await tester.pumpAndSettle();

      expect(provider.byId('m1')!.dueDate, sourceDay,
          reason: '用户选择返回修改 → 不得落库');
    });
  });

  group('P3-2 日历重复任务不可拖拽改期', () {
    testWidgets('重复任务不产生 LongPressDraggable，长按给出正确路径提示', (tester) async {
      _useLargeCanvas(tester);

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final due = DateTime(today.year, today.month, today.day, 23, 59);

      final provider = await _seed(tester, [
        _simple('c1', '每日打卡',
            due: due, repeat: RepeatType.daily, repeatMinute: 7 * 60),
      ]);

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: provider),
          ChangeNotifierProvider<FocusProvider>(create: (_) => FocusProvider()),
        ],
        child: MaterialApp(
          theme: lightTheme,
          home: const Scaffold(body: CalendarScreen()),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('每日打卡'), findsOneWidget);
      expect(find.byType(LongPressDraggable<Task>), findsNothing,
          reason: '重复任务的 dueDate 只是占位，拖拽改期是「假成功」，须禁用');

      await tester.longPress(find.text('每日打卡'));
      await tester.pumpAndSettle();

      expect(find.text('重复任务不支持拖拽改期，请在详情页使用「仅此一次改期」'),
          findsOneWidget);
      expect(provider.byId('c1')!.dueDate, due);
    });
  });

  group('P3-3 看板分组口径（互斥归入，每任务恰好出现一次）', () {
    /// 泳道标题 → 该泳道任务 id 列表。
    Map<String, List<String>> laneIds(List<KanbanLaneData> lanes) => {
          for (final l in lanes) l.title: l.tasks.map((t) => t.id).toList(),
        };

    test('标签分组：多标签任务只归入第一个命中的 top 标签，计数之和 = 任务数', () {
      final active = [
        // 前端=2 / 后端=1 → topTags 顺序 [前端, 后端]；任务甲命中两者，只归「前端」。
        _simple('k1', '任务甲', tags: const ['前端', '后端']),
        _simple('k2', '任务乙', tags: const ['前端']),
        _simple('k3', '任务丙'), // 无标签 → 「其他」
      ];
      final lanes = buildKanbanLanes(KanbanGroupMode.tag, active);
      final map = laneIds(lanes);

      expect(map.keys.toList(), ['前端', '其他'],
          reason: '「后端」泳道被更高频的「前端」吸空 → 自动隐藏（与分类模式一致）');
      expect(map['前端'], ['k1', 'k2']);
      expect(map['其他'], ['k3']);

      // 核心：每个任务在整个看板中恰好出现一次（修复前 k1 会在两条泳道各一份）。
      final all = lanes.expand((l) => l.tasks).map((t) => t.id).toList();
      expect(all.length, active.length, reason: '泳道计数之和必须等于实际任务数');
      expect(all.toSet(), {'k1', 'k2', 'k3'});
    });

    test('状态 / 分类分组同样是严格划分（不重不漏）', () {
      final active = [
        _simple('a', 'A', tags: const ['x']),
        _simple('b', 'B'),
      ];
      for (final mode in [KanbanGroupMode.status, KanbanGroupMode.category]) {
        final all =
            buildKanbanLanes(mode, active).expand((l) => l.tasks).toList();
        expect(all.length, active.length, reason: '$mode 应为严格划分');
        expect(all.map((t) => t.id).toSet(), {'a', 'b'});
      }
    });

    test('标签泳道数量受 maxTagLanes 限制，其余归「其他」', () {
      final active = [
        for (var i = 0; i < 5; i++) _simple('t$i', 'T$i', tags: ['tag$i']),
      ];
      final lanes =
          buildKanbanLanes(KanbanGroupMode.tag, active, maxTagLanes: 2);
      expect(lanes.length, 3, reason: '2 条标签泳道 + 1 条「其他」');
      expect(lanes.last.title, '其他');
      expect(lanes.last.tasks.length, 3);
    });
  });
}
