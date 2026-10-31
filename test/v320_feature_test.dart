import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/backup_summary.dart';
import 'package:todolist/services/backup_validator.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/services/search_history.dart';
import 'package:todolist/services/search_index.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';

import 'test_helpers.dart';

/// v3.1.1 功能增强轮回归测试（《有条功能增强建议报告（v3.1.1）》P0 速赢
/// A1–A5 + 顺手发现低风险修正）。每条实现至少一个「能区分修与未修」的用例。
///
/// 覆盖清单：
/// - **A1** 恢复三件套：BackupSummary 摘要（数量 / 时间范围 / 附件豁免 /
///   设置差异键名 / 旧备份弱提示）+ 恢复前快照（落盘 / 同构可校验 /
///   滚动保留 3 份 / 恢复面板「恢复前」条目）；
/// - **A2** 全局提醒临时静音：调度窗口判定、六个入口中的两个代表
///   （一次性 scheduleForTask 拒排、重复预挂落点剔除）、provider 状态机
///   （未来时间生效落盘 / 过期归一未静音）、prefs 白名单；
/// - **A3** 习惯单位 + 排序：unit/order 旧数据缺省（零迁移）、进度文案
///   单一真源、单位夹取、JSON 往返、reorderHabits 重排 + 落库 + 落盘失败
///   回滚 + 新建追加末尾、导出「单位」列；
/// - **A4** 搜索全拼：computePinyinFull 与首字母并行、恢复路径回填、
///   GlobalSearch 全拼命中 / 长度阈值 / 空串跳过、习惯拼音命中、搜索历史
///   （去重 / 上限 / 清空）；
/// - **A5** 置顶 + 今日三件：togglePinned 落盘翻转、MIT 选择 / 上限 /
///   完成保留 / 删除过滤 / 建议口径（逾期→今天→高优）/ 持久化单键。
///
/// 不落用例（如实）：
/// - **A1 确认框 UI**（摘要 + 「同时恢复设置」开关 + 旧备份弱提示）——
///   纯 backup_sheet 对话框渲染，摘要内容由 [BackupSummary.describe]
///   单一真源覆盖；「关闭设置恢复 → rescheduleReminders 让位」的分支
///   语义与既有 P3-10 契约同构，由代码推演交付；
/// - **A2 静音到期自愈**（15 分钟守护触发 `_autoRestoreIfMuteExpired`）——
///   需时间旅行，挂接点在 checkDailyReset（既有用例覆盖其骨架）；
/// - **A2 其余四个调度入口**（简报 / 挽留 / 习惯落点 / 回收站预告）——
///   与已测的两个入口走同一 `isReminderMuted` 判定（单一真源）；
/// - **A3 习惯页拖拽 UI**（ReorderableListView 手势）——widget 手势模拟
///   价值低，provider 契约已钉死；
/// - **A4 剪贴板按钮**（Clipboard.getData 交互）与**首页历史 chips**——
///   UI 接线，[SearchHistory] 纯逻辑已覆盖；
/// - **A5 首页 MIT 卡 / 详情置顶按钮 / 命令面板 /pin**——UI 与 main 接线，
///   provider 契约与 palette 命令注册由代码推演交付；
/// - **TaskProvider.load() 的静音 / MIT 读取**——load() 携带午夜守护定时器，
///   既有测试基线刻意绕开（buildWith 走 restoreFromJson）；读取逻辑与
///   持久化对称（写侧已钉死），由代码推演交付。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  final notifCalls = <MethodCall>[];
  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(notifCh, (call) async {
    notifCalls.add(call);
    return null;
  });
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureCh, (call) async => null);

  setUp(() {
    // 🔴 内存库是同进程共享单例：每个用例前必须重置 DB + prefs。
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    NotificationService.instance.enabled = true;
    // A2：静态静音窗口跨用例复位（static 状态不随 provider 重建清零）。
    NotificationService.remindersMutedUntil = null;
    PathProviderPlatform.instance = _NullPathProvider();
  });

  // ── 脚手架 ────────────────────────────────────────────────────────

  /// 用受控列表构造 TaskProvider（restoreFromJson 绕过 load()，不起午夜守护）。
  Future<TaskProvider> buildWith(List<Task> tasks) async {
    final p = TaskProvider();
    final json = jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': <dynamic>[],
      'notifications_enabled': false,
      'sound_enabled': false,
    });
    await p.restoreFromJson(json);
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return p;
  }

  /// 新建一个已 load 的 HabitProvider（内存库由 setUp 重置）。
  Future<HabitProvider> newHabitProvider() async {
    final hp = HabitProvider();
    await hp.load();
    return hp;
  }

  Task mk(
    String id, {
    String title = '任务',
    DateTime? due,
    TaskStatus status = TaskStatus.todo,
    Priority priority = Priority.medium,
  }) =>
      Task(
        id: id,
        title: title,
        priority: priority,
        category: Category.work,
        dueDate: due,
        status: status,
      );

  Habit mkHabit(String id, String title, {String unit = '', double order = 0}) =>
      // Habit 含 DateTime，不能 const 构造。
      Habit(
        id: id,
        title: title,
        createdAt: DateTime(2026, 1, 1),
        dailyTarget: 8,
        unit: unit,
        order: order,
      );

  int zonedCount() =>
      notifCalls.where((c) => c.method == 'zonedSchedule').length;

  // ═════════════════════ A1 恢复安全三件套 ═════════════════════

  group('A1 BackupSummary 恢复差异预演', () {
    test('数量 / 时间范围 / 附件 __skipped 豁免 / 设置差异键名 / 旧备份弱提示',
        () async {
      final now = DateTime.now();
      final data = <String, dynamic>{
        'version': 3,
        'schemaVersion': 1,
        'appVersion': '3.1.1',
        'generatedAt': DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 2))
            .toIso8601String(),
        'tasks': [
          mk('1', due: now.add(const Duration(days: 1))).toJson(),
          mk('2', due: now.add(const Duration(days: 5))).toJson(),
        ],
        'trash': [],
        'habits': [mkHabit('h1', '喝水').toJson()],
        'check_ins': [],
        'focus_sessions': [
          {'startedAt': now.toIso8601String()},
        ],
        'attachments': {
          '1': [
            const {'ref': {'fileName': 'a.png'}, 'data': 'x'},
          ],
          // H1 契约：统计段不是附件列表，摘要计数必须豁免。
          '__skipped': {'count': 1},
        },
        'user_templates': [],
        'prefs': {'dnd_enabled': false, 'snooze_minutes': 10},
      };
      final s = await BackupSummary.fromMap(
        data,
        encrypted: true,
        currentTaskCount: 7,
        currentHabitCount: 0,
        currentFocusCount: 0,
      );
      expect(s.taskCount, 2);
      expect(s.habitCount, 1);
      expect(s.focusCount, 1);
      expect(s.attachmentCount, 1, reason: '__skipped 统计段不计入附件数');
      expect(s.ageDays, 2, reason: '生成于两天前（date-only 差）');
      expect(s.earliestDue, isNotNull);
      expect(s.latestDue!.isAfter(s.earliestDue!), isTrue);
      // 当前 prefs 为空（内存库未写入）→ 两个键都算差异；只列键名不列值。
      expect(s.changedPrefKeys, contains('dnd_enabled'));
      expect(s.changedPrefKeys, contains('snooze_minutes'));
      final text = s.describe();
      expect(text, contains('任务 2'));
      expect(text, contains('2 天前'), reason: '旧备份弱提示的数据源');
      expect(text, contains('加密'));
      expect(text, contains('备份中不存在的当前任务将不会被保留'));
    });
  });

  group('A1 恢复前自动快照', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('youtiao_pre_restore');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('落盘 / 同构可校验 / 滚动保留 3 份 / 面板「恢复前」条目', () async {
      final p = await buildWith([mk('1', title: '快照验证')]);
      // 伪造 5 份更早的快照（固定过去时间戳，避开「秒级同名覆盖」）。
      final dir = Directory('${tmp.path}/backup/pre-restore')
        ..createSync(recursive: true);
      for (var i = 1; i <= 5; i++) {
        File('${dir.path}/pre-restore-20200101-00000$i.json')
            .writeAsStringSync('{"version":3,"tasks":[]}');
      }
      expect(await p.writePreRestoreSnapshot(), isTrue);
      final files = dir.listSync().whereType<File>().toList();
      expect(files.length, 3, reason: '滚动保留 3 份');
      expect(files.any((f) => f.path.contains('20200101-000001')), isFalse,
          reason: '最旧的伪造快照被清理');

      // 恢复面板列出「恢复前」条目（label 带恢复前标记；伪造的 2 份幸存快照
      // 同样按「恢复前」类别列出，真实回滚点只数非 20200101 前缀的那份）。
      final entries = await p.listAutoBackups();
      final pre = entries.where((e) => e.preRestore).toList();
      expect(pre, hasLength(3));
      final realPre =
          pre.where((e) => !e.file.path.contains('20200101')).toList();
      expect(realPre, hasLength(1));
      expect(realPre.single.label, contains('恢复前'));

      // 快照与备份格式同构：校验器通过、任务内容完整。
      final real = files
          .firstWhere((f) => !f.path.contains('pre-restore-20200101'));
      final content = await real.readAsString();
      expect(BackupValidator.validate(content).ok, isTrue,
          reason: '恢复前快照必须能走与备份一致的校验/恢复流程');
      final map = jsonDecode(content) as Map<String, dynamic>;
      expect((map['tasks'] as List).length, 1);
    });
  });

  // ═════════════════════ A2 全局提醒临时静音 ═════════════════════

  group('A2 临时静音', () {
    test('isReminderMuted：未静音恒 false；窗口内 true、窗口外 false', () {
      final now = DateTime.now();
      expect(NotificationService.isReminderMuted(now), isFalse);
      NotificationService.remindersMutedUntil = now.add(const Duration(hours: 1));
      expect(NotificationService.isReminderMuted(now), isTrue);
      expect(NotificationService.isReminderMuted(now.add(const Duration(hours: 1))),
          isTrue, reason: '窗口终点时刻本身仍算命中（<= until）');
      expect(
          NotificationService.isReminderMuted(
              now.add(const Duration(hours: 1, minutes: 1))),
          isFalse);
      NotificationService.remindersMutedUntil = null;
    });

    test('scheduleForTask：窗口内落点拒排，窗口外照常排', () async {
      final now = DateTime.now();
      final t = mk('10', due: now.add(const Duration(hours: 1)));
      NotificationService.remindersMutedUntil =
          now.add(const Duration(hours: 2));
      expect(await NotificationService.instance.scheduleForTask(t), isFalse,
          reason: '落点（+1h）在静音窗口（+2h）内 → 不排、错过不补发');
      NotificationService.remindersMutedUntil = null;
      expect(await NotificationService.instance.scheduleForTask(t), isTrue);
    });

    test('scheduleRepeatReminder：静音窗口内的重复落点被剔除，窗口外照常预挂',
        () async {
      // ⚠️ 落点口径：服务内部按**提醒时区**（测试未设 override → UTC）墙钟扫描
      // 并映射为 TZDateTime(UTC)（epoch = 墙钟按 UTC 解释）。夹具因此全程用
      // UTC 墙钟，并用纯函数求出首个落点后，用 DateTime.utc 构造其 **epoch
      // 正确**时刻再 +12h 作静音终点——恰好剔除首个落点（第二个落点在 +24h
      // 外），与测试机器时区、当前时刻均无关（不受午夜进位影响）。
      final wallNow = DateTime.now().toUtc();
      final at = wallNow.add(const Duration(hours: 2));
      final task = mk('9', title: '每天重复').copyWith(
        repeat: RepeatType.daily,
        repeatAnchor: DateTime(wallNow.year, wallNow.month, wallNow.day),
        repeatMinute: at.hour * 60 + at.minute,
      );
      // 无静音：8 个落点全挂。
      await NotificationService.instance.scheduleRepeatReminder(task);
      expect(zonedCount(), 8);
      await NotificationService.instance.cancelRepeatReminder(task.id);
      NotificationService.instance.clearOccurrenceMemo();
      notifCalls.clear();
      // 静音窗口盖住首个落点（终点 = 首落点 epoch + 12h）：只挂 7 个。
      final occ1Wall = NotificationService.repeatOccurrenceTimes(
          task,
          now: DateTime(wallNow.year, wallNow.month, wallNow.day, wallNow.hour,
              wallNow.minute, wallNow.second))
          .first;
      NotificationService.remindersMutedUntil = DateTime.utc(
              occ1Wall.year, occ1Wall.month, occ1Wall.day, occ1Wall.hour,
              occ1Wall.minute)
          .add(const Duration(hours: 12));
      await NotificationService.instance.scheduleRepeatReminder(task);
      expect(zonedCount(), 7,
          reason: '窗口内落点直接不排（错过不补发），窗口外落点照常预挂'
              '（occ1=$occ1Wall until=${NotificationService.remindersMutedUntil}）');
      NotificationService.remindersMutedUntil = null;
    });

    test('setRemindersMutedUntil：未来时间生效并落盘；过期时间归一为未静音',
        () async {
      final p = await buildWith([]);
      await p.setRemindersMutedUntil(DateTime.now().add(const Duration(hours: 1)));
      expect(p.remindersMuted, isTrue);
      expect(NotificationService.remindersMutedUntil, isNotNull);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('reminders_muted_until'), isNotNull);
      // 过期时间戳 → 归一为未静音（键同步清除）。
      await p.setRemindersMutedUntil(
          DateTime.now().subtract(const Duration(hours: 1)));
      expect(p.remindersMuted, isFalse);
      expect(NotificationService.remindersMutedUntil, isNull);
      expect(sp.getString('reminders_muted_until'), isNull);
    });

    test('reminders_muted_until / daily_mit 进 prefs 备份白名单（往返）', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('reminders_muted_until', '2026-11-01T10:00:00.000');
      await sp.setString('daily_mit', '{"2026-10-31":["1"]}');
      final collected = await collectAppPrefs();
      expect(collected['reminders_muted_until'], '2026-11-01T10:00:00.000');
      expect(collected['daily_mit'], '{"2026-10-31":["1"]}');
      // applyAppPrefs 往返（先清后恢复）。
      await sp.remove('reminders_muted_until');
      await applyAppPrefs(collected);
      final sp2 = await SharedPreferences.getInstance();
      expect(sp2.getString('reminders_muted_until'), '2026-11-01T10:00:00.000');
      expect(sp2.getString('daily_mit'), '{"2026-10-31":["1"]}');
    });
  });

  // ═════════════════════ A3 习惯单位 + 拖拽排序 ═════════════════════

  group('A3 习惯单位', () {
    test('旧数据缺省（零迁移）+ 进度文案单一真源 + 夹取 + JSON 往返', () {
      final legacy = Habit.fromJson({
        'id': 'h1',
        'title': '喝水',
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'dailyTarget': 8,
      });
      expect(legacy.unit, '', reason: '旧数据无 unit 键 → 空串（旧行为）');
      expect(legacy.order, 0);
      expect(legacy.progressLabelOf(6), '6/8',
          reason: '无单位时与升级前文案逐字节一致');
      final withUnit = legacy.copyWith(unit: '杯');
      expect(withUnit.progressLabelOf(6), '6/8 杯');
      // 夹取：超界截断到 6 字符；非字符串回空串。
      expect(Habit.clampUnit('1234567'), '123456');
      expect(Habit.clampUnit(42), '');
      expect(Habit.clampUnit('  '), '');
      // 脏备份：非法类型回空串，不炸恢复。
      expect(Habit.fromJson({'id': 'x', 'unit': 1}).unit, '');
      // JSON 往返。
      final j = withUnit.toJson();
      expect(j['unit'], '杯');
      expect(Habit.fromJson(j).progressLabelOf(6), '6/8 杯');
      // copyWith(unit: '') 显式清除。
      expect(withUnit.copyWith(unit: '').unit, '');
    });

    test('导出列：表头含「单位」且与取值逐列对齐', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
        title: '喝水',
        emoji: '💧',
        colorValue: 1,
        weekdays: const [],
        dailyTarget: 8,
        unit: '杯',
      );
      final h = hp.habits.first;
      expect(HabitProvider.habitExportHeaders, contains('单位'));
      expect(hp.habitExportCells(h).length,
          HabitProvider.habitExportHeaders.length);
      final unitIdx = HabitProvider.habitExportHeaders.indexOf('单位');
      expect(hp.habitExportCells(h)[unitIdx], '杯');
    });
  });

  group('A3 习惯排序', () {
    test('旧数据全 0 → 展示顺序与插入一致；新建追加末尾；重排生效并落库', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(title: 'A', emoji: '💧', colorValue: 1, weekdays: const []);
      await hp.addHabit(title: 'B', emoji: '💧', colorValue: 1, weekdays: const []);
      await hp.addHabit(title: 'C', emoji: '💧', colorValue: 1, weekdays: const []);
      expect(hp.activeHabits.map((h) => h.title).toList(), ['A', 'B', 'C'],
          reason: 'order 全 0 时按创建顺序兜底（零迁移）');
      // 拖拽：第 1 项拖到「B 与 C 之间」的槽位（Flutter onReorder 惯例：
      // newIndex 为移除前的目标位，向后移动需 -1 归一 → A 落到下标 1）。
      expect(await hp.reorderHabits(0, 2), isTrue);
      expect(hp.activeHabits.map((h) => h.title).toList(), ['B', 'A', 'C']);
      // 落库验证：新实例 load 后顺序保持。
      final hp2 = HabitProvider();
      await hp2.load();
      expect(hp2.activeHabits.map((h) => h.title).toList(), ['B', 'A', 'C']);
      // 新建习惯追加到排序末尾。
      await hp2.addHabit(title: 'D', emoji: '💧', colorValue: 1, weekdays: const []);
      expect(hp2.activeHabits.last.title, 'D');
      // 再拖一次：C（下标 2）拖到列表头（向前移动不调整）。
      expect(await hp2.reorderHabits(2, 0), isTrue);
      expect(hp2.activeHabits.map((h) => h.title).toList(), ['C', 'B', 'A', 'D']);
    });

    test('reorderHabits 落盘失败回滚顺序（与 updateHabit 同口径）', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(title: 'A', emoji: '💧', colorValue: 1, weekdays: const []);
      await hp.addHabit(title: 'B', emoji: '💧', colorValue: 1, weekdays: const []);
      hp.markDbLoadFailedForTest();
      // 用真实换位（尾槽 newIndex=2 = 移到 B 之后），避开「原位拖拽早退」。
      final ok = await hp.reorderHabits(0, 2);
      expect(ok, isFalse);
      expect(hp.activeHabits.map((h) => h.title).toList(), ['A', 'B'],
          reason: '落盘失败回滚全部 order（不留「内存已重排、库未落盘」分歧）');
      // 非法索引：返回 false 且不动数据。
      expect(await hp.reorderHabits(-1, 0), isFalse);
      expect(await hp.reorderHabits(5, 0), isFalse);
    });
  });

  // ═════════════════════ A4 搜索全拼 + 历史 ═════════════════════

  group('A4 拼音全拼', () {
    test('computePinyinFull 与首字母并行、口径一致（CJK 过滤）', () {
      expect(Task.computePinyinFull('周报'), 'zhoubao');
      expect(Task.computePinyinInitials('周报'), 'zb');
      expect(Task.computePinyinFull('整理周会纪要'), 'zhenglizhouhuijiyao');
      expect(Task.computePinyinFull('abc周'), 'zhou',
          reason: '非汉字字符与首字母口径一致地忽略');
      expect(Task.computePinyinFull(''), '');
      expect(Task.computePinyinFull('English only'), '');
    });

    test('GlobalSearch：全拼命中 / 首字母仍命中 / 长度阈值 / 空串跳过 / 习惯拼音',
        () async {
      // 显式带拼音索引（模拟 provider 新建路径的落库产物；Task 构造器本身不计算）。
      const t = Task(
        id: '1',
        title: '周报汇总',
        priority: Priority.medium,
        category: Category.work,
        pinyinInitials: 'zbhz',
        pinyinFull: 'zhoubao',
      );
      expect(
          GlobalSearch.query('zhoubao', tasks: [t], habits: const []).tasks,
          hasLength(1),
          reason: '全拼路径：搜「zhoubao」命中「周报汇总」');
      expect(GlobalSearch.query('zb', tasks: [t], habits: const []).tasks,
          hasLength(1), reason: '首字母路径保持原状');
      expect(GlobalSearch.query('zzz', tasks: [t], habits: const []).tasks,
          isEmpty);
      // 旧数据全拼空串：跳过该路径（避免空串恒真），首字母路径仍可用。
      const legacy = Task(
        id: '2',
        title: '周报汇总',
        priority: Priority.medium,
        category: Category.work,
        pinyinInitials: 'zbhz',
        pinyinFull: '',
      );
      expect(
          GlobalSearch.query('zhoubao', tasks: [legacy], habits: const [])
              .tasks,
          isEmpty);
      expect(GlobalSearch.query('zb', tasks: [legacy], habits: const []).tasks,
          hasLength(1));
      // 习惯侧：拼音索引与任务同口径（fixture 显式带上 provider 落库的产物）。
      final h = mkHabit('h1', '每天阅读')
          .copyWith(pinyinInitials: 'mtyd', pinyinFull: 'meiyuedu');
      expect(GlobalSearch.query('meiyuedu', tasks: const [], habits: [h])
          .habits, hasLength(1));
      expect(GlobalSearch.query('yuedu', tasks: const [], habits: [h]).habits,
          hasLength(1), reason: '全拼包含匹配（非全串相等）');
      expect(GlobalSearch.query('mtyd', tasks: const [], habits: [h]).habits,
          hasLength(1), reason: '首字母路径');
      expect(GlobalSearch.query('zzz', tasks: const [], habits: [h]).habits,
          isEmpty);
    });

    test('恢复路径按标题回填 pinyinFull（旧备份零迁移即可全拼搜索）', () async {
      final p = await buildWith([mk('1', title: '周报汇总')]);
      expect(p.tasks.first.pinyinFull, Task.computePinyinFull('周报汇总'));
    });

    test('搜索历史：去重提前 / 上限 10 / 清空 / 空查询不记录', () async {
      for (var i = 0; i < 12; i++) {
        await SearchHistory.add('q$i');
      }
      var h = await SearchHistory.load();
      expect(h.length, 10);
      expect(h.first, 'q11');
      // 重复查询提前且去重。
      await SearchHistory.add('q5');
      h = await SearchHistory.load();
      expect(h.first, 'q5');
      expect(h.where((e) => e == 'q5').length, 1);
      // 空查询不记录。
      await SearchHistory.add('   ');
      expect((await SearchHistory.load()).first, 'q5');
      // 清空。
      await SearchHistory.clear();
      expect(await SearchHistory.load(), isEmpty);
    });
  });

  // ═════════════════════ A5 置顶 + 今日三件 ═════════════════════

  group('A5 置顶', () {
    test('togglePinned 翻转并落盘；任务不存在返回 false', () async {
      final p = await buildWith([mk('1')]);
      expect(p.tasks.first.pinned, isFalse);
      expect(await p.togglePinned('1'), isTrue);
      expect(p.tasks.first.pinned, isTrue);
      expect(p.tasks.first.toJson()['pinned'], isTrue,
          reason: '序列化含 pinned（置顶内容落库验证）');
      expect(await p.togglePinned('999'), isFalse, reason: '任务不存在 = 未生效');
      // 再翻回（取消置顶）。
      expect(await p.togglePinned('1'), isTrue);
      expect(p.tasks.first.pinned, isFalse);
    });
  });

  group('A5 今日三件（MIT）', () {
    test('建议口径：逾期 → 今天到期 → 高优先级，最多 3 条，不含未来', () async {
      final now = DateTime.now();
      final p = await buildWith([
        mk('f', title: '未来', due: now.add(const Duration(days: 3))),
        // 高优任务给一个远期截止，确保它只落入「高优先级」建议池，
        // 不被「无截止归入今天」的首页口径提前捞走。
        mk('h', title: '高优',
            due: now.add(const Duration(days: 10)), priority: Priority.high),
        mk('t', title: '今天到期',
            due: DateTime(now.year, now.month, now.day, 23, 59)),
        mk('o', title: '逾期',
            due: now.subtract(const Duration(days: 1))),
      ]);
      expect(p.suggestMitCandidates().map((t) => t.id).toList(),
          ['o', 't', 'h'],
          reason: '逾期 → 今天 → 高优三级次序，未来任务不入建议');
    });

    test('选择 / 上限 / 移出 / 完成保留 / 删除过滤 / 持久化只留今天键', () async {
      final now = DateTime.now();
      final p = await buildWith([
        mk('o', title: '逾期', due: now.subtract(const Duration(days: 1))),
        mk('t', title: '今天到期',
            due: DateTime(now.year, now.month, now.day, 23, 59)),
        mk('h', title: '高优', priority: Priority.high),
        mk('f', title: '未来', due: now.add(const Duration(days: 3))),
      ]);
      for (final id in ['o', 't', 'h']) {
        expect(await p.toggleTodayMit(id), isTrue);
      }
      expect(p.todayMit, ['o', 't', 'h']);
      // 已满：第 4 件拒绝。
      expect(await p.toggleTodayMit('f'), isFalse, reason: '最多 3 件');
      // 移出后可选新任务。
      expect(await p.toggleTodayMit('o'), isTrue);
      expect(await p.toggleTodayMit('f'), isTrue);
      expect(p.todayMit, ['t', 'h', 'f']);
      // 完成后保留在列表（行内反映完成态，日切前不消失）。
      expect(await p.setStatus('t', TaskStatus.done), isTrue);
      expect(p.todayMit.contains('t'), isTrue);
      // 删除后惰性消失（无悬空 id）。
      await p.deleteTask('f');
      expect(p.todayMit.contains('f'), isFalse);
      // 持久化只留今天一个键（旧日期自动清理）。
      final sp = await SharedPreferences.getInstance();
      final map = jsonDecode(sp.getString('daily_mit')!) as Map;
      expect(map.length, 1);
      expect((map.values.first as List).length, 3);
    });

    test('isTodayMit / kDailyMitMax 契约', () async {
      final p = await buildWith([mk('1')]);
      expect(TaskProvider.kDailyMitMax, 3);
      expect(p.isTodayMit('1'), isFalse);
      await p.toggleTodayMit('1');
      expect(p.isTodayMit('1'), isTrue);
      await p.toggleTodayMit('1');
      expect(p.isTodayMit('1'), isFalse);
    });
  });
}

/// path_provider 桩：默认返回空串（restoreFromJson 的附件孤儿回收路径会取
/// 文档目录；未安装假桩时抛 MissingPluginException 被吞，不影响断言）。
class _NullPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => null;
}

/// path_provider 假桩：把文档目录指到临时目录（恢复前快照用例）。
class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
