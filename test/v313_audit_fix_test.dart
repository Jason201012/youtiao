import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/screens/home_screen.dart' show mitTitleFor;
import 'package:todolist/services/backup_crypto.dart' show BackupEncryptException;
import 'package:todolist/services/backup_summary.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/quick_entry_sheet.dart';

import 'test_helpers.dart';

/// v3.1.3 审计修复轮回归测试（《有条功能与操作审计报告（v3.1.3）》）。
/// 每条实现至少一个「能区分修与未修」的用例。
///
/// 覆盖清单：
/// - **P1-1 / P2-2** 升级首启 / 恢复设置不再被默认值覆盖，且拼音仍回填；
/// - **P1-2** 安全模式只读：不写默认设置、不产出当日快照；
/// - **P1-3** 回收站保留期先读后用（「永不」+ 40 天条目不被删）；
/// - **P2-1** 成功加载清零 dbLoadFailed + retryLoad 退出安全模式；
/// - **P3-1** 悬空 MIT id 不占名额、失败原因具名化；
/// - **P3-2** 自动快照 `.noattach` 解析为「不含附件」；
/// - **P3-3** 快照编码单一真源（含加密缺口令守卫）；
/// - **P3-4** 数量 + 单位单一真源；
/// - **P3-5** 回收站恢复即回填拼音；
/// - **P3-6** 摘要与 apply 共用不迁移键名单；
/// - **P3-7** 纯非中文标题不重复触发全表写盘；
/// - **P3-8** 自选任务池覆盖池外任务 + 搜索；
/// - **U-2** 静音 snooze 专用回执；**U-3** 粘贴总长上限；**U-4** 满员标题。
///
/// 不落用例（如实）：
/// - **U-1 空合并回执 / P3-8 自选弹层 / P1-2 横幅按钮**——均为页面级 UI 接线，
///   需完整 Provider 栈与弹层交互，本轮以静态代码审查交付；数据前提
///   （batchId==0、selectableMitTasks、retryLoad）已由本文件钉死；
/// - **P3-3 进度层帧调度**——帧级时序，逻辑侧只钉编码入口的 isolate 化真源；
/// - **P1-2 真实损坏 DB**——用 markDbLoadFailedForTest 等价注入，不破坏宿主库。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  final docs = Directory.systemTemp.createTempSync('yt_v313_').path;
  final notifCalls = <MethodCall>[];
  var refreshCalls = 0;
  var caseSeq = 0;
  late String caseDocs;
  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  const widgetCh = MethodChannel('com.example.todolist/widget_refresh');
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifCh, (call) async {
      notifCalls.add(call);
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(widgetCh, (call) async {
      refreshCalls++;
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureCh, (call) async => null);
  });

  setUp(() {
    // 🔴 内存库 / prefs 是同进程共享单例，每个用例前必须重置。
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    refreshCalls = 0;
    NotificationService.instance.enabled = false;
    NotificationService.remindersMutedUntil = null;
    // 每个用例独立文档目录：自动快照文件名按「日期」命名，共用目录会让
    // 前一个用例写下的文件串进后一个用例的 listAutoBackups() 结果。
    caseDocs = '$docs/case_${++caseSeq}';
    Directory(caseDocs).createSync(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(caseDocs);
  });

  // ── 脚手架 ────────────────────────────────────────────────────────
  Task mk(
    String id, {
    String title = '任务',
    DateTime? due,
    TaskStatus status = TaskStatus.todo,
    Priority priority = Priority.medium,
    List<String> tags = const [],
  }) =>
      Task(
        id: id,
        title: title,
        priority: priority,
        category: Category.work,
        dueDate: due,
        status: status,
        tags: tags,
      );

  /// 走 restoreFromJson（绕过 load() 的午夜定时器）构造受控列表。
  Future<TaskProvider> buildWith(List<Task> tasks,
      {List<Task>? trash}) async {
    final p = TaskProvider();
    await p.restoreFromJson(jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': (trash ?? const <Task>[]).map((t) => t.toJson()).toList(),
      'notifications_enabled': false,
      'sound_enabled': false,
    }));
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return p;
  }

  /// 预置一组「非默认值」的用户偏好（P1-1 探针同款）。
  Future<SharedPreferences> seedPrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('notifications_enabled', false);
    await sp.setBool('sound_enabled', false);
    await sp.setInt('snooze_minutes', 30);
    await sp.setBool('dnd_enabled', true);
    await sp.setInt('trash_retention_days', -1);
    await sp.setInt('focus_goal_minutes', 240);
    await sp.setBool('auto_backup_encrypt', true);
    // 预置首启标记：load() 的 else 分支本就会写这个键，提前落位后
    // 「load 内自愈不得新增偏好键」的断言才不会被它干扰。
    await sp.setBool('samples_seeded_v1', true);
    return sp;
  }

  Future<void> expectPrefsIntact(SharedPreferences sp) async {
    expect(sp.getBool('notifications_enabled'), isFalse,
        reason: 'P1-1：通知开关被默认值 true 覆盖');
    expect(sp.getInt('snooze_minutes'), 30);
    expect(sp.getBool('dnd_enabled'), isTrue);
    expect(sp.getInt('trash_retention_days'), -1);
    expect(sp.getInt('focus_goal_minutes'), 240);
    expect(sp.getBool('auto_backup_encrypt'), isTrue,
        reason: 'P1-1：自动备份加密被静默关闭（隐私降级）');
  }

  final epoch = DateTime(2020, 1, 1);

  Habit habit({String unit = '', int? dailyTarget = 8}) => Habit(
        id: 'h1',
        title: '喝水',
        createdAt: epoch,
        unit: unit,
        dailyTarget: dailyTarget,
      );

  // ══════════════════════════════════════════════════════════════════
  // P1：启动加载顺序与安全模式
  // ══════════════════════════════════════════════════════════════════

  group('P1 启动加载顺序', () {
    test('P1-1：升级首启（旧任务触发拼音回填）不再重置任何用户设置', () async {
      final sp = await seedPrefs();
      await LocalDatabase.instance
          .replaceTasks([mk('1', title: '周报')], []);
      final p = TaskProvider();
      await p.load();
      await expectPrefsIntact(sp);
      // 回填本身仍须生效，不能为了修设置而把功能回退掉。
      expect(p.tasks.single.pinyinFull, 'zhoubao');
      expect(p.tasks.single.pinyinInitials, 'zb');
    });

    test('P1-1b：设置读取门闩——load() 内自愈只写任务表', () async {
      final sp = await seedPrefs();
      await LocalDatabase.instance
          .replaceTasks([mk('1', title: '周报')], []);
      // 记录 prefs 的键集合：自愈不应新增 / 删除任何偏好键。
      final before = sp.getKeys().toSet();
      final p = TaskProvider();
      await p.load();
      expect(sp.getKeys().toSet(), before);
    });

    test('P1-2：安全模式不写默认设置、也不产出当日自动快照', () async {
      final sp = await seedPrefs();
      await LocalDatabase.instance
          .replaceTasks([mk('1', title: '周报')], []);
      final p = TaskProvider();
      await p.load();
      p.markDbLoadFailedForTest();
      expect(p.dbLoadFailed, isTrue);

      await p.triggerAutoBackup();
      expect(Directory('$caseDocs/backup/auto').existsSync(), isFalse,
          reason: '安全模式下不得以空任务集写当日滚动快照');

      // 任意一次任务写操作触发 _persist()：旧实现在此写回全部默认偏好。
      await p.deleteTask('1');
      await expectPrefsIntact(sp);
    });

    test('P1-3：「永不清理」+ 40 天前回收站条目 → load() 后条目仍在', () async {
      final sp = await seedPrefs(); // trash_retention_days = -1
      final old = mk('old', title: '旧任务').copyWith(
          deletedAt: DateTime.now().subtract(const Duration(days: 40)));
      await LocalDatabase.instance.replaceTasks([], [old]);
      final p = TaskProvider();
      await p.load();
      expect(p.trash.map((t) => t.id).toList(), ['old'],
          reason: '旧实现按构造器默认 30 天判定，条目会被静默销毁（含附件）');
      expect(sp.getInt('trash_retention_days'), -1);
      expect(p.trashRetentionLabel, '永不');
    });

    test('P1-3b：90 天保留期下 40 天条目同样保留', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('trash_retention_days', 90);
      final old = mk('old').copyWith(
          deletedAt: DateTime.now().subtract(const Duration(days: 40)));
      await LocalDatabase.instance.replaceTasks([], [old]);
      final p = TaskProvider();
      await p.load();
      expect(p.trash.length, 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2：安全模式退出 / 恢复设置
  // ══════════════════════════════════════════════════════════════════

  group('P2 安全模式与恢复设置', () {
    test('P2-1：成功加载清零 dbLoadFailed，retryLoad 可退出安全模式', () async {
      await seedPrefs();
      await LocalDatabase.instance.replaceTasks([mk('1')], []);
      final p = TaskProvider();
      await p.load();
      p.markDbLoadFailedForTest();
      expect(p.dbLoadFailed, isTrue);
      expect(await p.retryLoad(), isTrue);
      expect(p.dbLoadFailed, isFalse,
          reason: '旧实现成功加载从不清零，恢复备份永远落不了盘');
    });

    test('P2-2：备份恢复「同时恢复设置」+ 旧任务 → 设置等于备份值', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('snooze_minutes', 30);
      await sp.setInt('focus_goal_minutes', 240);
      await LocalDatabase.instance
          .replaceTasks([mk('1', title: '周报')], []);
      // 模拟 backup_sheet：applyAppPrefs(备份中的 prefs) → provider.load()
      await applyAppPrefs({
        'snooze_minutes': 5,
        'focus_goal_minutes': 60,
      });
      final p = TaskProvider();
      await p.load();
      expect(sp.getInt('snooze_minutes'), 5);
      expect(sp.getInt('focus_goal_minutes'), 60);
      expect(p.snoozeMinutes, 5);
      expect(p.focusGoalMinutes, 60);
      expect(p.tasks.single.pinyinFull, 'zhoubao');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3：今日三件 / 备份 / 单位 / 拼音 / 摘要
  // ══════════════════════════════════════════════════════════════════

  group('P3 功能缺口', () {
    test('P3-1：悬空 id 不占名额，且失败原因具名化', () async {
      final p = await buildWith([
        mk('1'),
        mk('2'),
        mk('3'),
        mk('4'),
        mk('5'),
      ]);
      for (final id in ['1', '2', '3']) {
        expect(await p.toggleTodayMit(id), isTrue);
      }
      await p.deleteTask('3'); // 移入回收站 → todayMit 惰性过滤为 2 件
      expect(p.todayMit.length, 2);
      // 旧实现按未过滤的 3 个 id 早退 false，UI 误报「保存失败」。
      expect(await p.toggleTodayMitDetailed('4'), MitToggleOutcome.ok);
      expect(p.todayMit, contains('4'));
      expect(p.todayMit.length, 3);
      expect(await p.toggleTodayMitDetailed('5'), MitToggleOutcome.full);
      expect(await p.toggleTodayMitDetailed('missing'),
          MitToggleOutcome.invalid);
    });

    test('P3-1b：setTodayMit 先滤悬空再截断（有效任务不被挤掉）', () async {
      final p = await buildWith([mk('1'), mk('2'), mk('3')]);
      expect(await p.setTodayMit(['gone', '1', '2', '3']), isTrue);
      expect(p.todayMit, ['1', '2', '3']);
    });

    test('P3-2：自动快照 .noattach 解析为「不含附件」', () async {
      final p = TaskProvider();
      final now = DateTime.now();
      final key =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final dir = Directory('$caseDocs/backup/auto')..createSync(recursive: true);
      File('${dir.path}/$key.noattach.json').writeAsStringSync('{}');
      final found = (await p.listAutoBackups())
          .where((e) => !e.preRestore && e.attachmentsStripped)
          .toList();
      expect(found, hasLength(1),
          reason: '旧实现 auto 分支不摘 .noattach，key.split("-") 长度 != 3 直接跳过');
      expect(found.single.statusLabel, '明文 · 不含附件');
      expect(found.single.encrypted, isFalse);
    });

    test('P3-2b：加密 + 剥离组合后缀仍被正确解析', () async {
      final p = TaskProvider();
      final now = DateTime.now();
      final key =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final dir = Directory('$caseDocs/backup/auto')..createSync(recursive: true);
      File('${dir.path}/$key.noattach.enc.json').writeAsStringSync('{}');
      final found = (await p.listAutoBackups())
          .where((e) => !e.preRestore && e.attachmentsStripped)
          .toList();
      expect(found, hasLength(1));
      expect(found.single.encrypted, isTrue);
      expect(found.single.statusLabel, '已加密 · 不含附件');
    });

    test('P3-3：快照编码单一真源（明文直出 / 加密缺口令中止）', () async {
      final payload = <String, dynamic>{'a': 1, 'tasks': <dynamic>[]};
      expect(encodeSnapshotSync(payload, false, null), contains('"a": 1'));
      expect(
        () => encodeSnapshotSync(payload, true, null),
        throwsA(isA<BackupEncryptException>()),
        reason: '要求加密却无口令必须中止，绝不静默降级明文',
      );
      // 后台入口与同步真源结果一致。
      expect(await encodeSnapshotOffMainThread(payload, false, null),
          encodeSnapshotSync(payload, false, null));
    });

    test('P3-4：数量 + 单位单一真源（无单位逐字节等于旧文案）', () {
      expect(Habit.quantityLabel(8, '杯'), '8 杯');
      expect(Habit.quantityLabel(8, ''), '8');
      expect(Habit.quantityLabel(8, '  '), '8');
      final h = habit(unit: '杯');
      expect(h.quantityLabelOf(h.effectiveTarget), '8 杯');
      expect(h.progressLabelOf(6), '6/8 杯');
      final noUnit = habit(unit: '');
      expect(noUnit.quantityLabelOf(noUnit.effectiveTarget), '8');
      expect(noUnit.progressLabelOf(6), '6/8');
    });

    test('P3-5：回收站恢复旧任务即回填全拼，不必等下次冷启动', () async {
      final old = mk('old', title: '周报'); // pinyinFull 默认空串
      final p = await buildWith([], trash: [old]);
      expect(p.trash.single.pinyinFull, isEmpty);
      expect(await p.restoreFromTrash('old'), isTrue);
      expect(p.tasks.single.pinyinFull, 'zhoubao');
      expect(p.tasks.single.pinyinInitials, 'zb');
      expect(p.tasks.single.deletedAt, isNull);
    });

    test('P3-6：恢复摘要不列「不随备份迁移」的本机状态键', () async {
      final summary = await BackupSummary.fromMap({
        'tasks': <dynamic>[],
        'trash': <dynamic>[],
        'prefs': {
          'reminders_muted_until': '2099-01-01T00:00:00.000',
          'auto_backup_encrypt': true,
          'theme_mode': 'dark',
        },
      }, currentTaskCount: 0, currentHabitCount: 0, currentFocusCount: 0);
      expect(summary.prefKeys, ['theme_mode']);
      expect(summary.changedPrefKeys, isNot(contains('reminders_muted_until')));
      expect(summary.changedPrefKeys, isNot(contains('auto_backup_encrypt')));
      expect(neverBackedUpPrefKeys,
          containsAll(<String>['reminders_muted_until', 'auto_backup_encrypt']));
    });

    test('P3-6b：applyAppPrefs 显式丢弃不迁移键（二道闸）', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('reminders_muted_until', '2099-01-01T00:00:00.000');
      await applyAppPrefs({
        'reminders_muted_until': '2020-01-01T00:00:00.000',
        'snooze_minutes': 60,
      });
      expect(sp.getString('reminders_muted_until'),
          '2099-01-01T00:00:00.000');
      expect(sp.getInt('snooze_minutes'), 60);
    });

    test('P3-7：纯非中文标题两次 load 不再重复全表写盘', () async {
      await seedPrefs();
      await LocalDatabase.instance
          .replaceTasks([mk('1', title: 'Buy milk')], []);
      final p1 = TaskProvider();
      await p1.load();
      // 第一次 load 允许自愈其它字段（repeatAnchor 等），此处只关心第二次。
      final before = refreshCalls;
      final p2 = TaskProvider();
      await p2.load();
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(refreshCalls, before,
          reason: '旧实现每次冷启动都 heal 成功 → _persist → 刷新小组件');
      expect(p2.tasks.single.pinyinFull, isEmpty);
      expect(p2.tasks.single.pinyinInitials, isEmpty);
    });

    test('P3-8：自选池覆盖建议池外任务，并支持标题/标签搜索', () async {
      final now = DateTime.now();
      final p = await buildWith([
        mk('future', title: '明天再说', due: now.add(const Duration(days: 3))),
        mk('nodue', title: '周报', tags: const ['汇报']),
      ]);
      expect(p.suggestMitCandidates().length, lessThan(3),
          reason: '候选池不足 3 条正是 P3-8 的场景');
      final all = p.selectableMitTasks();
      expect(all.map((t) => t.id).toList(), containsAll(['future', 'nodue']));
      expect(p.selectableMitTasks(query: '明天').map((t) => t.id), ['future']);
      expect(p.selectableMitTasks(query: '汇报').map((t) => t.id), ['nodue']);
      // 已完成任务不入自选池。
      await p.setStatus('nodue', TaskStatus.done);
      expect(p.selectableMitTasks().map((t) => t.id), ['future']);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // U：交互细节
  // ══════════════════════════════════════════════════════════════════

  group('U 交互细节', () {
    test('U-2：静音命中 snooze 时回执「静音中」而非「顺延失败」', () async {
      NotificationService.instance.enabled = true;
      NotificationService.remindersMutedUntil =
          DateTime.now().add(const Duration(hours: 1));
      const delay = Duration(minutes: 10);
      final landing = NotificationService.instance.snoozeLandingTime(delay);
      expect(NotificationService.isReminderMuted(landing), isTrue,
          reason: '上层与服务层必须共用同一落点判据');

      final ok = await NotificationService.instance
          .snoozeTaskReminder(mk('u2'), delay: delay);
      expect(ok, isFalse, reason: '静音窗口内不应再排提醒');

      await NotificationService.instance.showSnoozeUnavailableConfirm(
        'u2',
        title: '买菜',
        muted: NotificationService.isReminderMuted(landing),
        rescheduleFailed: false,
      );
      final show = notifCalls.lastWhere((c) => c.method == 'show');
      final args = Map<String, dynamic>.from(show.arguments as Map);
      expect(args['title'], '提醒已静音');
      expect(args['body'] as String, contains('静音中，本次不顺延'));
      expect(args['body'] as String, isNot(contains('顺延失败')));
    });

    test('U-2b：非静音的调度失败仍保留「顺延失败」文案', () async {
      NotificationService.instance.enabled = true;
      NotificationService.remindersMutedUntil = null;
      await NotificationService.instance.showSnoozeUnavailableConfirm(
        'u2b',
        title: '买菜',
        rescheduleFailed: true,
        muted: false,
      );
      final show = notifCalls.lastWhere((c) => c.method == 'show');
      final args = Map<String, dynamic>.from(show.arguments as Map);
      expect(args['title'], '提醒已结束');
      expect(args['body'] as String, contains('顺延失败，请打开应用查看'));
    });

    test('U-3：粘贴按「合并后总长」截断，且光标落在插入点后', () {
      final current = 'x' * 480;
      final sel = TextSelection.collapsed(offset: current.length);
      final r = QuickEntrySheet.mergeClipboardText(current, sel, 'y' * 500);
      expect(r.text.length, 500,
          reason: '旧实现只截剪贴板文本，480 + 500 = 980 字，上限形同虚设');
      expect(r.truncated, isTrue);
      expect(r.cursor, 500);
      expect(r.text.substring(480, 500), 'y' * 20);
    });

    test('U-3b：非法选区退化为末尾追加，短文本不误报截断', () {
      final r = QuickEntrySheet.mergeClipboardText(
          'abc', const TextSelection.collapsed(offset: -1), 'def');
      expect(r.text, 'abcdef');
      expect(r.cursor, 6);
      expect(r.truncated, isFalse);
    });

    test('U-3c：已有内容达上限时插入空串并如实截断', () {
      final current = 'x' * 500;
      final r = QuickEntrySheet.mergeClipboardText(
          current, TextSelection.collapsed(offset: 500), 'more');
      expect(r.text, current);
      expect(r.truncated, isTrue);
    });

    test('U-4：今日三件满员标题不再写「继续添加」', () {
      expect(mitTitleFor(0, 3), '从建议中挑选今天最重要的几件事：');
      expect(mitTitleFor(2, 3), '继续添加（最多 3 件）：');
      expect(mitTitleFor(3, 3), '已满 3 件，请先移出一件：');
    });
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
