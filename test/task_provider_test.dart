import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  group('clearSampleTasks 后重启不复活示例（回归）', () {
    test('从零开始后再次 load 不应重新塞入 7 条 mock', () async {
      // 关闭通知，避免 load() 内 _rescheduleAllActive 走 tz 调度路径（测试环境无原生时区库）。
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notifications_enabled', false);

      // 首次启动：预置 7 条示例
      final p = TaskProvider();
      await p.load();
      expect(p.tasks.length, 7, reason: '全新安装应有 7 条示例');

      // 用户在引导页选择「从零开始」
      await p.clearSampleTasks();
      expect(p.tasks.length, 0, reason: '从零开始后应为空');
      // 清空须置位 samples_seeded 标志，使后续空库不再复活
      expect(prefs.getBool('samples_seeded_v1'), isTrue);

      // 模拟重启：重建 Provider 并再次 load
      final p2 = TaskProvider();
      await p2.load();
      expect(p2.tasks.length, 0, reason: '从零开始后重启不应复活示例');
    });

    test('全新安装首启仍预置 7 条示例且置位标志', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notifications_enabled', false);
      // 确保是全新状态
      await prefs.remove('samples_seeded_v1');

      final p = TaskProvider();
      await p.load();
      expect(p.tasks.length, 7, reason: '全新安装应预置 7 条示例');
      expect(prefs.getBool('samples_seeded_v1'), isTrue,
          reason: '预置后应置位标志，避免误判空库为全新安装');
    });
  });

  group('sectionCounts 首页分区计数', () {
    test('按截止日 vs 重复 vs 已完成 正确分组', () async {
      final p = await buildWith([
        mk('1', due: now().subtract(const Duration(days: 1))), // 逾期
        mk('2', due: todayNoon()), // 今天
        mk('3', due: now().add(const Duration(days: 2))), // 未来
        mk('4', due: null), // 今天（无截止）
        mk('5', repeating: true), // 每天
        mk('6', status: TaskStatus.done), // 已完成
      ]);
      final s = p.sectionCounts;
      expect(s['overdue'], 1);
      expect(s['today'], 2); // id2(今天) + id4(无截止)
      expect(s['future'], 1); // id3(未来)
      expect(s['repeat'], 1);
      expect(s['done'], 1);
      // 五段互不重叠且覆盖全部 6 条
      expect(s['overdue']! + s['today']! + s['future']! + s['repeat']! + s['done']!,
          6);
    });
  });

  group('homeTasks 首页分区列表', () {
    test('逾期按截止时间升序；无截止归今天段', () async {
      final p = await buildWith([
        mk('1', due: now().subtract(const Duration(days: 2))),
        mk('2', due: now().subtract(const Duration(days: 1))),
        mk('3', due: null),
      ]);
      final overdue = p.homeTasks['overdue']!;
      expect(overdue.first.id, '1'); // 更早到期排前
      expect(overdue.last.id, '2');
      // 无截止日期不再进「未来」，归入「今天」段
      final today = p.homeTasks['today']!;
      expect(today.single.id, '3');
      expect(p.homeTasks['future'], isEmpty);
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
    test('todayEventTotal 统计截止今天/循环今日/无截止的任务', () async {
      final today = DateTime.now();
      final p = await buildWith([
        mk('1', due: today, title: '今天截止'),
        mk('2', due: today.subtract(const Duration(days: 1)), title: '昨天截止'),
        mk('3', repeating: true, title: '每天'),
        mk('4', title: '无截止'),
      ]);
      expect(p.todayEventTotal, 3); // 今天截止 + 每天循环 + 无截止(视为当天)
    });

    test('todayCompleted 统计当日事件（含无截止）中已完成', () async {
      final today = DateTime.now();
      final p = await buildWith([
        mk('1', due: today, status: TaskStatus.done, title: '今天已完成'),
        mk('2', due: today, title: '今天未完成'),
        mk('3', repeating: true, status: TaskStatus.done, title: '每天已完成'),
        mk('4', status: TaskStatus.done, title: '无截止已完成'),
      ]);
      expect(p.todayEventTotal, 4); // 今天截止(2) + 每天循环(1) + 无截止(1)
      expect(p.todayCompleted, 3); // 今天已完成 + 每天已完成 + 无截止已完成
      expect(p.todayCompletionRate, closeTo(3 / 4, 1e-9));
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

    test('循环任务计入当日事件且不被标逾期（过去截止日也不算逾期）', () async {
      final today = DateTime.now();
      final p = await buildWith([
        // 每天重复、截止日设在 3 天前：应在「当日事件」中，但不算「逾期」
        mk('1', repeating: true, due: today.subtract(const Duration(days: 3)), title: '每天(过去截止)'),
        // 普通一次性任务、截止日 3 天前：既不在当日事件，也算逾期
        mk('2', due: today.subtract(const Duration(days: 3)), title: '普通逾期'),
      ]);
      expect(p.todayEventTotal, 1); // 只有每天循环任务计入当日
      expect(p.overdue, 1); // 只有普通逾期任务算逾期，循环任务不重复计入
    });

    test('之前设置的每日任务也计入当天（截止日早于今天仍算当日事件）', () async {
      final today = DateTime.now();
      // 模拟「几天前创建并设为每天」的任务：截止日设在 5 天前、repeat=daily
      final p = await buildWith([
        mk('1', repeating: true, due: today.subtract(const Duration(days: 5)), title: '几天前设的每天'),
        mk('2', repeating: true, title: '几天前设的无截止每天'),
      ]);
      // 两条都是每天重复，与创建/截止日期无关，都应计入当日事件
      expect(p.todayEventTotal, 2);
      expect(p.overdue, 0); // 每日任务不计入逾期
    });

    test('每日任务+未来截止日（如用户截图 2026-08-15）仍计入当天', () async {
      // 精确复现用户场景：repeat=daily, dueDate=未来9天后, 分类=生活, 有备注
      final today = DateTime.now();
      final futureDue = today.add(const Duration(days: 9));
      final p = await buildWith([
        Task(
          id: '1',
          title: '哈哈哈',
          priority: Priority.medium,
          category: Category.life,
          dueDate: futureDue,
          repeat: RepeatType.daily,
          repeatMinute: 420, // 07:00
          note: 'hg',
        ),
      ]);
      // 核心断言：每天重复的任务无论截止日是未来还是过去，都计入当天事件
      expect(p.todayEventTotal, 1, reason: '每天重复任务(含未来截止日)必须计入当日事件');
      expect(p.todayCompleted, 0); // 未完成
      // 不应被标为逾期
      expect(p.overdue, 0, reason: '每天重复任务不应计入逾期');
      // 验证看板全量分组中该任务在待办列
      final kanban = p.kanbanGroups;
      expect(kanban[TaskStatus.todo]!.length, 1);
      expect(kanban[TaskStatus.todo]!.first.title, '哈哈哈');
    });

    test('无截止日期任务视为当天，且跨天始终顺延（恒为今天）', () async {
      // 无截止日期的非循环任务，无论哪一天都计入「今日事件」，
      // 因此跨天时会自然顺延到第二天（无需任何重置，dueDate==null 恒等于「今天」）。
      final p = await buildWith([
        mk('1', due: null, title: '无截止待办'),
        mk('2', due: null, status: TaskStatus.done, title: '无截止已完成'),
      ]);
      // 看板当日统计：两条无截止都算今天（含已完成）
      expect(p.todayEventTotal, 2);
      expect(p.todayCompleted, 1);
      // 首页分组：无截止的未完成任务进「今天」段；已完成的归「已完成」段，不进「未来」
      expect(p.sectionCounts['today'], 1); // 仅未完成的 id1
      expect(p.sectionCounts['done'], 1); // 已完成的 id2
      expect(p.sectionCounts['future'], 0);
      final todayList = p.homeTasks['today']!;
      expect(todayList.map((t) => t.id), ['1']);
      expect(p.homeTasks['future'], isEmpty);
      // 且不会误标逾期（无截止 non-repeating 绝不逾期）
      expect(p.overdue, 0);
    });
  });

  group('标签 / 专注回填 / 拖拽排序（v2.3.4 新增）', () {
    test('allTags 去重并按出现顺序汇集', () async {
      final p = await buildWith([
        Task(id: '1', title: 't', priority: Priority.low, category: Category.work,
            tags: const ['工作', '紧急']),
        Task(id: '2', title: 't', priority: Priority.low, category: Category.work,
            tags: const ['紧急', '阅读']),
        Task(id: '3', title: 't', priority: Priority.low, category: Category.work,
            tags: const []),
      ]);
      expect(p.allTags, const ['工作', '紧急', '阅读']);
    });

    test('addFocusSec 累加专注秒数到关联任务并持久化', () async {
      final p = await buildWith([
        mk('1', due: todayNoon()),
      ]);
      p.addFocusSec('1', 600);
      expect(p.tasks.first.focusSecTotal, 600);
      p.addFocusSec('1', 300);
      expect(p.tasks.first.focusSecTotal, 900);
    });

    test('addFocusSec 对 sec<=0 或任务不存在时忽略', () async {
      final p = await buildWith([mk('1', due: todayNoon())]);
      p.addFocusSec('1', 0);
      p.addFocusSec('1', -5);
      expect(p.tasks.first.focusSecTotal, 0);
      p.addFocusSec('999', 600); // 不存在的任务
      expect(p.tasks.first.focusSecTotal, 0);
    });

    test('homeTasks 分区内按 order 优先排序', () async {
      final today = DateTime.now();
      final p = await buildWith([
        Task(id: 'a', title: 'a', priority: Priority.low, category: Category.work,
            dueDate: today, order: 2),
        Task(id: 'b', title: 'b', priority: Priority.low, category: Category.work,
            dueDate: today, order: 5),
        Task(id: 'c', title: 'c', priority: Priority.low, category: Category.work,
            dueDate: today, order: 1),
      ]);
      // order 1,2,5 → c, a, b（即便 b 的 id 在列表里更靠前）
      expect(p.homeTasks['today']!.map((t) => t.id), ['c', 'a', 'b']);
    });

    test('reorderTasks 重排后把 order 顺写为 1,2,3…', () async {
      final today = DateTime.now();
      final p = await buildWith([
        Task(id: 'a', title: 'a', priority: Priority.low, category: Category.work,
            dueDate: today, order: 1),
        Task(id: 'b', title: 'b', priority: Priority.low, category: Category.work,
            dueDate: today, order: 2),
        Task(id: 'c', title: 'c', priority: Priority.low, category: Category.work,
            dueDate: today, order: 3),
      ]);
      // a 从 0 移到末尾：对应 ReorderableListView 的 oldIndex=0, newIndex=3(移除后)
      p.reorderTasks('today', 0, 3);
      final ids = p.homeTasks['today']!.map((t) => t.id).toList();
      expect(ids, ['b', 'c', 'a']);
      // 落点 order 已重写为 1,2,3
      final orders = p.homeTasks['today']!.map((t) => t.order).toList();
      expect(orders, [1, 2, 3]);
    });

    test('reorderTasks 边界安全：越界索引直接返回', () async {
      final today = DateTime.now();
      final p = await buildWith([
        Task(id: 'a', title: 'a', priority: Priority.low, category: Category.work,
            dueDate: today, order: 1),
        Task(id: 'b', title: 'b', priority: Priority.low, category: Category.work,
            dueDate: today, order: 2),
      ]);
      p.reorderTasks('today', 9, 0); // oldIndex 越界
      p.reorderTasks('today', 0, 99); // newIndex 越界
      expect(p.homeTasks['today']!.map((t) => t.id), ['a', 'b']);
    });
  });

  group('子任务 byId / toggleSubTask（v2.3.8 新增）', () {
    test('byId 命中返回任务，未命中返回 null', () async {
      final p = await buildWith([mk('1'), mk('2')]);
      expect(p.byId('1')?.id, '1');
      expect(p.byId('9'), isNull);
    });

    test('toggleSubTask 只翻转目标子任务，并刷新派生聚合', () async {
      final task = Task(
        id: '1',
        title: 'T1',
        priority: Priority.medium,
        category: Category.work,
        subtasks: [
          SubTask(id: 's1', title: '步骤一', done: false),
          SubTask(id: 's2', title: '步骤二', done: false),
          SubTask(id: 's3', title: '步骤三', done: true),
        ],
      );
      final p = await buildWith([task]);
      expect(p.byId('1')!.subtaskTotal, 3);
      expect(p.byId('1')!.subtaskDone, 1); // s3 初始已勾
      p.toggleSubTask('1', 's1');
      final t2 = p.byId('1')!;
      expect(t2.subtaskDone, 2);
      expect(t2.subtasks.firstWhere((s) => s.id == 's1').done, isTrue);
      expect(t2.subtasks.firstWhere((s) => s.id == 's2').done, isFalse);
      // 再次翻转回到原状
      p.toggleSubTask('1', 's1');
      expect(p.byId('1')!.subtaskDone, 1);
    });

    test('toggleSubTask 不影响其它任务；任务不存在时安全返回', () async {
      final a = Task(
        id: 'a',
        title: 'A',
        priority: Priority.medium,
        category: Category.work,
        subtasks: [SubTask(id: 'x', title: 'x', done: false)],
      );
      final b = Task(
        id: 'b',
        title: 'B',
        priority: Priority.medium,
        category: Category.work,
        subtasks: [SubTask(id: 'y', title: 'y', done: false)],
      );
      final p = await buildWith([a, b]);
      p.toggleSubTask('a', 'x');
      expect(p.byId('a')!.subtaskDone, 1);
      expect(p.byId('b')!.subtaskDone, 0); // b 不受影响
      p.toggleSubTask('nope', 'x'); // 任务不存在，安全返回
      expect(p.byId('a')!.subtaskDone, 1);
    });

    test('toggleSubTask 经 backupJson 往返持久化一致', () async {
      final task = Task(
        id: '1',
        title: 'T1',
        priority: Priority.medium,
        category: Category.work,
        subtasks: [
          SubTask(id: 's1', title: 'x', done: false),
          SubTask(id: 's2', title: 'y', done: false),
        ],
      );
      final p = await buildWith([task]);
      p.toggleSubTask('1', 's2');
      final json = p.backupJson();
      final p2 = TaskProvider();
      await p2.restoreFromJson(json);
      expect(p2.byId('1')!.subtaskDone, 1);
      expect(p2.byId('1')!.subtasks.firstWhere((s) => s.id == 's2').done, isTrue);
    });
  });

  group('本周完成数 weeklyCompletedCount（B1 / P2-7 补测）', () {
    /// 复制 [TaskProvider._mondayOf] 口径，保证断言与当前星期几无关（周一也稳定）。
    DateTime mondayOf(DateTime d) {
      final today = DateTime(d.year, d.month, d.day);
      return today.subtract(Duration(days: today.weekday - DateTime.monday));
    }

    test('仅统计本周一~周日且已完成的任务', () async {
      final now = DateTime.now();
      final mon = mondayOf(now);
      final p = await buildWith([
        mk('1', status: TaskStatus.done, completedAt: mon), // 本周一
        mk('2', status: TaskStatus.done, completedAt: mon.add(const Duration(days: 3))), // 本周四
        mk('3', status: TaskStatus.done, completedAt: mon.subtract(const Duration(days: 7))), // 上周一，排除
        mk('4', status: TaskStatus.todo), // 未完成，排除
      ]);
      expect(p.weeklyCompletedCount, 2);
    });

    test('空库为 0', () async {
      final p = await buildWith([]);
      expect(p.weeklyCompletedCount, 0);
    });
  });
}
