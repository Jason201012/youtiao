import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// 在 headless 测试里把 flutter_local_notifications 的 method channel 置为 no-op，
/// 并给 shared_preferences 一个内存实现，避免删除类操作触碰真实插件而抛 MissingPluginException。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控的 Task 列表构造 Provider（绕过 load()，避免启动午夜守护定时器）。
/// notifications_enabled=false 使 scheduleForTask 提前返回，避开时区路径。
Future<TaskProvider> buildWith(
  List<Task> tasks, {
  List<Task> trash = const [],
}) async {
  final p = TaskProvider();
  final json = jsonEncode({
    'version': 2,
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'trash': trash.map((t) => t.toJson()).toList(),
    'notifications_enabled': false,
    'sound_enabled': false,
  });
  await p.restoreFromJson(json);
  return p;
}

Task mk(
  String id, {
  String? title,
  DateTime? due,
  TaskStatus status = TaskStatus.todo,
  bool repeating = false,
  DateTime? completedAt,
  Priority priority = Priority.medium,
  Category category = Category.work,
}) =>
    Task(
      id: id,
      title: title ?? 'T$id',
      priority: priority,
      category: category,
      dueDate: due,
      status: status,
      completedAt: completedAt,
      repeat: repeating ? RepeatType.daily : RepeatType.none,
      repeatMinute: repeating ? 450 : null,
    );

void main() {
  setUpAll(_installMocks);

  final now = () => DateTime.now();
  final todayNoon = () =>
      DateTime(now().year, now().month, now().day, 10);

  group('sectionCounts 首页分区计数', () {
    test('按截止日 vs 重复 vs 已完成 正确分组', () async {
      final p = await buildWith([
        mk('1', due: now().subtract(const Duration(days: 1))), // 逾期
        mk('2', due: todayNoon()), // 今天
        mk('3', due: now().add(const Duration(days: 2))), // 未来
        mk('4', due: null), // 未来（无截止）
        mk('5', repeating: true), // 每天
        mk('6', status: TaskStatus.done), // 已完成
      ]);
      final s = p.sectionCounts;
      expect(s['overdue'], 1);
      expect(s['today'], 1);
      expect(s['future'], 2); // id3 + id4(null)
      expect(s['repeat'], 1);
      expect(s['done'], 1);
      // 五段互不重叠且覆盖全部 6 条
      expect(s['overdue']! + s['today']! + s['future']! + s['repeat']! + s['done']!,
          6);
    });
  });

  group('homeTasks 首页分区列表', () {
    test('逾期按截止时间升序；无截止排未来末尾', () async {
      final p = await buildWith([
        mk('1', due: now().subtract(const Duration(days: 2))),
        mk('2', due: now().subtract(const Duration(days: 1))),
        mk('3', due: null),
      ]);
      final overdue = p.homeTasks['overdue']!;
      expect(overdue.first.id, '1'); // 更早到期排前
      expect(overdue.last.id, '2');
      final future = p.homeTasks['future']!;
      expect(future.single.id, '3');
    });
    test('重复任务独占 repeat 段', () async {
      final p = await buildWith([mk('7', repeating: true)]);
      expect(p.homeTasks['repeat']!.single.id, '7');
      expect(p.homeTasks['overdue'], isEmpty);
    });
  });

  group('聚合统计', () {
    test('categoryProgress 完成比例', () async {
      final p = await buildWith([
        mk('1', status: TaskStatus.done), // work 完成
        mk('2'), // work 未完成
        mk('3', category: Category.life, status: TaskStatus.done),
      ]);
      final cp = p.categoryProgress();
      expect(cp[Category.work], 0.5); // 1/2
      expect(cp[Category.life], 1.0); // 1/1
    });
    test('priorityCounts 仅统计未完成', () async {
      final p = await buildWith([
        mk('1', priority: Priority.high),
        mk('2', priority: Priority.high, status: TaskStatus.done),
        mk('3', priority: Priority.low),
      ]);
      final pc = p.priorityCounts;
      expect(pc[Priority.high], 1); // 只算未完成的高
      expect(pc[Priority.low], 1);
    });
    test('kanbanGroups 拆待办/已完成并保留顺序', () async {
      final p = await buildWith([
        mk('1'),
        mk('2', status: TaskStatus.done),
        mk('3'),
      ]);
      final g = p.kanbanGroups;
      expect(g[TaskStatus.todo]!.map((t) => t.id), ['1', '3']);
      expect(g[TaskStatus.done]!.map((t) => t.id), ['2']);
    });
    test('overdue / completionRate', () async {
      final p = await buildWith([
        mk('1', due: now().subtract(const Duration(days: 1))),
        mk('2', status: TaskStatus.done),
        mk('3'),
      ]);
      expect(p.overdue, 1);
      expect(p.completionRate, closeTo(1 / 3, 1e-9));
    });
  });

  group('连续打卡 currentStreak / longestStreak', () {
    test('连续三天 -> 当前 3、最长 3', () async {
      final t = DateTime(now().year, now().month, now().day);
      final mkDone = (int back) => mk('d$back',
          status: TaskStatus.done,
          completedAt: t.subtract(Duration(days: back)));
      final p = await buildWith([mkDone(0), mkDone(1), mkDone(2)]);
      expect(p.currentStreak, 3);
      expect(p.longestStreak, 3);
    });
    test('中间断开 -> 当前 0、最长 3', () async {
      final t = DateTime(now().year, now().month, now().day);
      final mkDone = (int back) => mk('d$back',
          status: TaskStatus.done,
          completedAt: t.subtract(Duration(days: back)));
      // 完成于 3/4/5 天前：距今天 3 天（gap>1）-> 当前中断
      final p = await buildWith([mkDone(3), mkDone(4), mkDone(5)]);
      expect(p.currentStreak, 0);
      expect(p.longestStreak, 3);
    });
  });

  group('日期查询 tasksDueOn / tasksCompletedOn / completionsInMonthCount', () {
    test('按天查询到期与完成', () async {
      final day = DateTime(2026, 8, 10);
      final p = await buildWith([
        mk('1', due: day),
        mk('2',
            due: day,
            status: TaskStatus.done,
            completedAt: DateTime(2026, 8, 10, 18)),
        mk('3', due: DateTime(2026, 8, 11)),
      ]);
      expect(p.tasksDueOn(day).map((t) => t.id), ['1', '2']);
      expect(p.tasksCompletedOn(day).map((t) => t.id), ['2']);
    });
    test('当月完成计数', () async {
      final p = await buildWith([
        mk('1',
            status: TaskStatus.done, completedAt: DateTime(2026, 8, 5)),
        mk('2',
            status: TaskStatus.done, completedAt: DateTime(2026, 7, 5)),
      ]);
      expect(p.completionsInMonthCount(DateTime(2026, 8, 1)), 1);
    });
  });

  group('增删改 + 撤销', () {
    test('addTask 头插并分配唯一 id', () async {
      final p = await buildWith([]);
      p.addTask(mk('x'));
      expect(p.total, 1);
      expect(p.tasks.first.title, 'Tx');
      // id 由内部 _idSeq 重新分配（空库基于 7 起算 -> 8）
      expect(int.parse(p.tasks.first.id), greaterThanOrEqualTo(8));
    });
    test('deleteTask 移入回收站，undoDelete 原样恢复', () async {
      final p = await buildWith([mk('1'), mk('2')]);
      final removed = p.deleteTask('1');
      expect(removed?.id, '1');
      expect(p.total, 1);
      expect(p.trashCount, 1);
      p.undoDelete();
      expect(p.total, 2);
      expect(p.trashCount, 0);
      expect(p.tasks.any((t) => t.id == '1'), isTrue);
    });
    test('批量删除 + 整体撤销', () async {
      final p = await buildWith([mk('1'), mk('2'), mk('3')]);
      p.deleteTasks(['1', '3']);
      expect(p.total, 1);
      expect(p.trashCount, 2);
      p.undoDelete();
      expect(p.total, 3);
      expect(p.trashCount, 0);
    });
    test('toggleDone 翻转并置/清 completedAt', () async {
      final p = await buildWith([mk('1')]);
      p.toggleDone('1');
      expect(p.tasks.first.done, isTrue);
      expect(p.tasks.first.completedAt, isNotNull);
      p.toggleDone('1');
      expect(p.tasks.first.done, isFalse);
      expect(p.tasks.first.completedAt, isNull);
    });
    test('setStatus 直接置为完成', () async {
      final p = await buildWith([mk('1')]);
      p.setStatus('1', TaskStatus.done);
      expect(p.tasks.first.done, isTrue);
    });
    test('updateTask 清空截止时间生效（不再误保留旧值）', () async {
      final p = await buildWith([mk('1', due: DateTime(2026, 8, 10))]);
      p.updateTask(mk('1', due: null));
      expect(p.tasks.first.dueDate, isNull);
    });
  });

  group('回收站操作', () {
    test('restoreFromTrash 清除 deletedAt（恢复后在日历可见）', () async {
      final trashed = Task(
        id: '1',
        title: 'T1',
        priority: Priority.medium,
        category: Category.work,
        deletedAt: DateTime(2026, 8, 1),
      );
      final p = await buildWith([], trash: [trashed]);
      p.restoreFromTrash('1');
      expect(p.trashCount, 0);
      expect(p.total, 1);
      expect(p.tasks.first.deletedAt, isNull);
    });
    test('restoreFromTrash / permanentDelete / clearTrash', () async {
      final p = await buildWith([], trash: [mk('1')]);
      p.restoreFromTrash('1');
      expect(p.trashCount, 0);
      expect(p.total, 1);
      p.deleteTask('1'); // 退回回收站
      expect(p.trashCount, 1);
      p.permanentDelete('1');
      expect(p.trashCount, 0);
      // clearTrash
      p.addTask(mk('a'));
      p.deleteTask(p.tasks.first.id);
      expect(p.trashCount, 1);
      p.clearTrash();
      expect(p.trashCount, 0);
    });
  });

  group('备份 / 导出', () {
    test('backupJson 经 restoreFromJson 往返', () async {
      final p = await buildWith([mk('1'), mk('2', status: TaskStatus.done)]);
      final json = p.backupJson();
      expect(json, contains('"tasks"'));
      final p2 = TaskProvider();
      await p2.restoreFromJson(json);
      expect(p2.total, 2);
      expect(p2.completed, 1);
    });
    test('exportCsv 含表头与标题', () async {
      final p = await buildWith(
          [mk('1', title: '买菜'), mk('2', title: '跑步')]);
      final csv = p.exportCsv();
      expect(csv, contains('标题,优先级,分类'));
      expect(csv, contains('买菜'));
      expect(csv, contains('跑步'));
    });
    test('exportMarkdown 分未完成/已完成', () async {
      final p = await buildWith([
        mk('1', title: '买菜'),
        mk('2', status: TaskStatus.done, title: '睡觉'),
      ]);
      final md = p.exportMarkdown();
      expect(md, contains('## 未完成'));
      expect(md, contains('## 已完成'));
      expect(md, contains('买菜'));
    });
  });

  group('当日口径统计', () {
    test('todayEventTotal 仅统计截止今天或循环今日的任务', () async {
      final today = DateTime.now();
      final p = await buildWith([
        mk('1', due: today, title: '今天截止'),
        mk('2', due: today.subtract(const Duration(days: 1)), title: '昨天截止'),
        mk('3', repeating: true, title: '每天'),
        mk('4', title: '无截止'),
      ]);
      expect(p.todayEventTotal, 2); // 今天截止 + 每天循环
    });

    test('todayCompleted 仅统计当日事件中已完成', () async {
      final today = DateTime.now();
      final p = await buildWith([
        mk('1', due: today, status: TaskStatus.done, title: '今天已完成'),
        mk('2', due: today, title: '今天未完成'),
        mk('3', repeating: true, status: TaskStatus.done, title: '每天已完成'),
        mk('4', status: TaskStatus.done, title: '无截止已完成'),
      ]);
      expect(p.todayEventTotal, 3); // 今天截止(2) + 每天循环(1)
      expect(p.todayCompleted, 2); // 今天已完成 + 每天已完成
      expect(p.todayCompletionRate, closeTo(2 / 3, 1e-9));
    });

    test('todayEventTotal 排除已删除（deletedAt 非空）任务', () async {
      final today = DateTime.now();
      final deleted = Task(
        id: '2',
        title: '已删',
        priority: Priority.medium,
        category: Category.work,
        dueDate: today,
        deletedAt: DateTime.now(),
      );
      final p = await buildWith([mk('1', due: today, title: '今天'), deleted]);
      expect(p.todayEventTotal, 1);
    });
  });
}
