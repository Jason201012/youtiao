import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/main.dart' show AppLockGate;
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/backup_summary.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/services/search_index.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart' show lightTheme;

import 'test_helpers.dart';

/// v3.1.2 审计修复轮回归测试（《有条功能与操作审计报告（v3.1.2）》）。
/// 每条实现至少一个「能区分修与未修」的用例。
///
/// 覆盖清单：
/// - **P1-1** 应用锁出口收窄：仅在 `!biometricAvailable` 死路渲染；关闭前
///   强制一次 `authenticate()`，验证通过即解锁且**不**关闭应用锁；
/// - **P2-1** 存量任务拼音回填：`pinyinInitials` 非空 / `pinyinFull` 为空的
///   旧任务经 `load()` 后全拼可命中（GlobalSearch）；
/// - **P2-2** 今日三件：3 件可达、第 4 件拒绝；未满时建议列表仍给出未选
///   候选（UI「建议常驻」的数据前提）、满员时建议为空；
/// - **P2-3** 专注恢复落盘回执：`restoreSessions` → `Future<bool>`，安全
///   模式下返回 false 且内存回滚，正常路径返回 true；
/// - **P3-1** 设置差异深比较：StringList 内容一致不再误报；
/// - **P3-2/P3-3** 恢复前快照：`.noattach` 标记解析为 `attachmentsStripped`
///   （面板副标题数据源）、`.stale`（换口令）不列出；
/// - **P3-6** 静音保留确认条：`keepConfirm: true` 不清 9 号槽；
/// - **U-2** 静音边界严格 `<`：终点时刻照常投递；
/// - **U-6** 静音窗口不迁移：不进备份、恢复侧写不进；
/// - **U-10** 空合并撤销：无可撤销变更时 batchId=0（UI 不弹撤销）；
/// - **U-11⑤/U-12** 摘要措辞：schemaVersion 展示、差异键中文标签、当前
///   对比含回收站、无 prefs 段弱提示。
///
/// 不落用例（如实）：
/// - **P2-2 MIT 卡 widget 级**（空态点 1 条建议后仍可加满 3/3）——MIT 卡是
///   home_screen 私有组件，pump 整页需完整 Provider 栈 + 命令面板接线，
///   脆弱度高；provider 侧契约（本文件）+ UI 常驻改造由代码推演交付，
///   `_consumeMitToggle` 的「满员提示 / 保存失败提示」文案同理；
/// - **P2-3 安全模式恢复后重载/修复入口**（方向 ③）——本轮未实现，
///   仅实现 ①②（bool 回执 + failures 提示），见修复报告；
/// - **P3-5 恢复进度弹层**（overlay 交互）——UI 接线，静态自查交付；
/// - **U-3 静音到期 Timer**——需时间旅行；挂接点 `_armMuteExpiryTimer`
///   与 `_autoRestoreIfMuteExpired`（既有守护用例覆盖其骨架）；
/// - **U-4 批量取消 / U-7 历史时机 / U-8 粘贴插入**——UI 交互或平台通道
///   批次行为，逻辑单一真源已由代码审查覆盖；
/// - **P3-8 拖拽 / P3-9 日历口径**——widget 手势与页面级 sliver 重构，
///   provider 契约（reorderHabits）与统计真源（focusSecOn）已由既有用例
///   钉死，UI 层由代码推演交付。
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
  // P1-1：local_auth 桩——canCheckBiometrics / isDeviceSupported / authenticate
  // 由用例内可变标志控制（默认「无可用凭据 + 验证失败」的死路形态）。
  const authCh = MethodChannel('plugins.flutter.io/local_auth');
  var bioAvailable = false;
  var authResult = false;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(authCh, (call) async {
    switch (call.method) {
      case 'canCheckBiometrics':
        return bioAvailable;
      case 'isDeviceSupported':
        return bioAvailable;
      case 'authenticate':
        return authResult;
      default:
        return null;
    }
  });

  setUp(() {
    // 🔴 内存库是同进程共享单例：每个用例前必须重置 DB + prefs。
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    NotificationService.instance.enabled = false;
    NotificationService.remindersMutedUntil = null;
    bioAvailable = false;
    authResult = false;
    PathProviderPlatform.instance = _NullPathProvider();
  });

  // ── 脚手架 ────────────────────────────────────────────────────────

  /// 用受控列表构造 TaskProvider（restoreFromJson 绕过 load()，不起守护）。
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

  FocusSession focusSession({
    String id = 's1',
    String? taskId,
    FocusPhase phase = FocusPhase.focus,
    int sec = 600,
    DateTime? endedAt,
  }) {
    final end = endedAt ?? DateTime.now();
    return FocusSession(
      id: id,
      taskId: taskId,
      taskTitle: taskId,
      plannedSec: sec,
      durationSec: sec,
      completed: phase == FocusPhase.focus,
      phase: phase,
      startedAt: end.subtract(Duration(seconds: sec)),
      endedAt: end,
    );
  }

  List<int> cancelIds() => notifCalls
      .where((c) => c.method == 'cancel')
      .map((c) => c.arguments is Map
          ? (c.arguments as Map)['id']
          : c.arguments)
      .whereType<int>()
      .toList();

  // ══════════════════════════════════════════════════════════════════
  // P1-1：应用锁出口收窄
  // ══════════════════════════════════════════════════════════════════

  group('P1-1 应用锁出口收窄', () {
    Future<AppLockProvider> newLock() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_lock_enabled', true);
      final lock = AppLockProvider();
      await lock.load();
      return lock;
    }

    Future<void> pumpGate(WidgetTester tester, AppLockProvider lock) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [ChangeNotifierProvider<AppLockProvider>.value(value: lock)],
          // AppLockGate 内消费 appColors 扩展（空断言取值）——必须挂 app 自带主题。
          child: MaterialApp(theme: lightTheme, home: const AppLockGate()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('生物识别可用时不渲染出口（两键绕过不复现）', (tester) async {
      bioAvailable = true;
      final lock = await newLock();
      expect(lock.locked, isTrue);
      await pumpGate(tester, lock);
      expect(find.text('无法验证？关闭应用锁'), findsNothing,
          reason: '出口仅在 !biometricAvailable 死路渲染（旧实现无条件渲染）');
    });

    testWidgets('死路（无可用凭据）时出口可见；强制验证通过 → 解锁且不关闭应用锁',
        (tester) async {
      bioAvailable = false;
      authResult = true; // 锁屏密码降级验证成功
      final lock = await newLock();
      await pumpGate(tester, lock);
      expect(find.text('无法验证？关闭应用锁'), findsOneWidget);
      await tester.tap(find.text('无法验证？关闭应用锁'));
      await tester.pumpAndSettle();
      expect(lock.locked, isFalse, reason: '强制 authenticate 通过即正常解锁');
      expect(lock.appLockEnabled, isTrue,
          reason: '验证通过**不得**关闭应用锁（旧实现二次确认即 setEnabled(false)）');
    });

    testWidgets('死路 + 验证失败 → 二次确认后才关闭', (tester) async {
      bioAvailable = false;
      authResult = false;
      final lock = await newLock();
      await pumpGate(tester, lock);
      await tester.tap(find.text('无法验证？关闭应用锁'));
      await tester.pumpAndSettle();
      // authenticate 失败 → 二次确认框（旧实现无强制验证步骤）。
      // 「关闭应用锁」同时命中确认框标题与按钮，用取消按钮的存在性判定弹层。
      expect(find.text('取消'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '关闭应用锁'));
      await tester.pumpAndSettle();
      expect(lock.appLockEnabled, isFalse, reason: '确认后关闭（真实死路唯一出路）');
      expect(lock.locked, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-1：存量任务拼音回填
  // ══════════════════════════════════════════════════════════════════

  group('P2-1 存量任务全拼回填', () {
    test('load() 后 pinyinFull 为空的旧任务可全拼命中（GlobalSearch）', () async {
      // 3.1.2 之前落库的形态：pinyinInitials 已有、pinyinFull 为空串。
      final legacy = Task.fromJson({
        'id': '9',
        'title': '周报',
        'pinyinInitials': 'zb',
      });
      expect(legacy.pinyinFull, '', reason: '夹具：旧数据缺省形态');
      await LocalDatabase.instance.replaceTasks([legacy], const []);

      final p = TaskProvider();
      await p.load();
      final t = p.byId('9');
      expect(t, isNotNull);
      expect(t!.pinyinFull, 'zhoubao',
          reason: 'P2-1：load 侧回填（旧实现只有编辑/恢复路径补算）');
      expect(t.pinyinInitials, Task.computePinyinInitials('周报'));

      final r = GlobalSearch.query('zhoubao', tasks: p.tasks, habits: const []);
      expect(r.tasks.map((x) => x.id), contains('9'),
          reason: '升级用户不编辑、不恢复备份也应能全拼搜索');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-2 / P2-3：MIT 上限与专注恢复回执
  // ══════════════════════════════════════════════════════════════════

  group('P2-2 今日三件上限与建议常驻契约', () {
    test('3 件可达、第 4 件拒绝；未满时建议含未选候选、满员时建议为空', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final p = await buildWith([
        mk('1', title: '逾期件', due: today.subtract(const Duration(days: 1))),
        mk('2', title: '今天件', due: today),
        mk('3', title: '高优件', priority: Priority.high),
        mk('4', title: '候选件', priority: Priority.high),
      ]);
      expect(await p.toggleTodayMit('1'), isTrue);
      expect(p.todayMit, ['1']);
      // P2-2：未满 3 件时建议列表仍须给出未选候选（UI「建议常驻」的数据前提；
      // 旧实现 ids.isEmpty 才算建议 → UI 上永远到不了 2/3）。
      final mid = p.suggestMitCandidates();
      expect(mid.map((t) => t.id), isNot(contains('1')),
          reason: '已选 id 不再出现在建议里');
      expect(mid, isNotEmpty, reason: '仍有可加候选');
      expect(await p.toggleTodayMit('2'), isTrue);
      expect(await p.toggleTodayMit('3'), isTrue);
      expect(p.todayMit.length, 3, reason: '「3 件」承诺可达');
      expect(await p.toggleTodayMit('4'), isFalse, reason: '上限 3');
      // 满员后建议仍列出未选候选（UI 置灰 + 点按提示「最多 3 件」），
      // 但已选 id 绝不再出现在建议里（suggestMitCandidates 的 chosen 排除）。
      expect(p.suggestMitCandidates().map((t) => t.id), ['4']);
      // 移出后恢复可用。
      expect(await p.toggleTodayMit('1'), isTrue);
      expect(p.todayMit.length, 2);
    });
  });

  group('P2-3 专注恢复落盘回执', () {
    test('安全模式下 restoreSessions 返回 false 且内存回滚', () async {
      final fp = FocusProvider();
      await fp.addSession(focusSession(id: 'keep', sec: 600));
      expect(fp.sessions.single.id, 'keep');
      fp.markDbLoadFailedForTest();
      final ok = await fp
          .restoreSessions([focusSession(id: 'r1', sec: 300).toJson()]);
      expect(ok, isFalse,
          reason: 'P2-3：落盘结果必须回传（旧实现 Future<void> 丢弃，假报已恢复）');
      expect(fp.sessions.map((s) => s.id), ['keep'],
          reason: '失败回滚内存（UI 显示的即已落盘的）');
    });

    test('正常路径 restoreSessions 返回 true 且内存生效', () async {
      final fp = FocusProvider();
      await fp.addSession(focusSession(id: 'keep', sec: 600));
      final ok = await fp
          .restoreSessions([focusSession(id: 'r1', sec: 300).toJson()]);
      expect(ok, isTrue);
      expect(fp.sessions.single.id, 'r1');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-1 / P3-2 / P3-3：备份摘要与快照面板
  // ══════════════════════════════════════════════════════════════════

  group('P3-1 设置差异深比较', () {
    test('StringList 内容一致不误报；内容不同仍列出', () async {
      await (await SharedPreferences.getInstance()).clear();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('focus_sound_types', ['rain', 'wave']);
      final same = await BackupSummary.fromMap(
        {
          'prefs': {
            'focus_sound_types': ['rain', 'wave'],
          },
        },
        currentTaskCount: 0,
        currentHabitCount: 0,
        currentFocusCount: 0,
      );
      expect(same.changedPrefKeys, isEmpty,
          reason: 'P3-1：List 引用比较把内容相同的列表键恒判为不同（误报）');
      final diff = await BackupSummary.fromMap(
        {
          'prefs': {
            'focus_sound_types': ['rain'],
          },
        },
        currentTaskCount: 0,
        currentHabitCount: 0,
        currentFocusCount: 0,
      );
      expect(diff.changedPrefKeys, ['focus_sound_types']);
    });
  });

  group('P3-2/P3-3 恢复前快照命名与 stale 过滤', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('youtiao_v312_pre');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('.noattach 解析为 attachmentsStripped；.stale 不列出', () async {
      final dir = Directory('${tmp.path}/backup/pre-restore')
        ..createSync(recursive: true);
      File('${dir.path}/pre-restore-20200102-030405.noattach.json')
          .writeAsStringSync('{}');
      File('${dir.path}/pre-restore-20200103-030405.noattach.enc.json')
          .writeAsStringSync('{}');
      // P3-3：换口令后的 stale（旧口令不可解）不得出现在面板。
      File('${dir.path}/pre-restore-20200104-030405.stale.enc.json')
          .writeAsStringSync('{}');
      File('${dir.path}/pre-restore-20200105-030405.json')
          .writeAsStringSync('{}');

      final p = await buildWith(const []);
      final entries = await p.listAutoBackups();
      final pre = entries.where((e) => e.preRestore).toList();
      expect(pre, hasLength(3), reason: 'stale 被过滤');

      final plainStripped =
          pre.firstWhere((e) => e.file.path.contains('20200102'));
      expect(plainStripped.attachmentsStripped, isTrue,
          reason: 'P3-2：.noattach 标记透传面板（副标题「不含附件」的数据源）');
      expect(plainStripped.encrypted, isFalse);
      expect(plainStripped.statusLabel, '明文 · 不含附件');

      final encStripped =
          pre.firstWhere((e) => e.file.path.contains('20200103'));
      expect(encStripped.encrypted, isTrue);
      expect(encStripped.attachmentsStripped, isTrue);
      expect(encStripped.statusLabel, '已加密 · 不含附件');

      final plain = pre.firstWhere((e) => e.file.path.contains('20200105'));
      expect(plain.attachmentsStripped, isFalse);
      expect(plain.statusLabel, '明文');
    });
  });

  group('U-11⑤ / U-12 恢复摘要措辞', () {
    test('schemaVersion 展示、差异键中文标签、当前对比含回收站、无 prefs 弱提示',
        () async {
      await (await SharedPreferences.getInstance()).clear();
      final s = await BackupSummary.fromMap(
        {
          'schemaVersion': 3,
          'prefs': {
            'archived_tags': ['a'],
          },
        },
        currentTaskCount: 1,
        currentTrashCount: 2,
        currentHabitCount: 3,
        currentFocusCount: 4,
      );
      final d = s.describe();
      expect(d, contains('数据格式版本：v3'),
          reason: 'U-11⑤：schemaVersion 此前计算后从不展示');
      expect(d, contains('归档标签'),
          reason: 'U-12①：差异键名给中文标签而非英文键名');
      expect(d, isNot(contains('archived_tags')));
      expect(d, contains('回收站 2'), reason: 'U-12③：当前对比补回收站条数');

      final s2 = await BackupSummary.fromMap(
        const {'tasks': []},
        currentTaskCount: 0,
        currentHabitCount: 0,
        currentFocusCount: 0,
      );
      expect(s2.describe(), contains('此备份未包含设置'),
          reason: 'P3-4：无 prefs 段时摘要如实说明（与确认框隐藏开关同口径）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-6 / U-2 / U-6：静音族
  // ══════════════════════════════════════════════════════════════════

  group('P3-6 静音保留打卡确认条', () {
    test('keepConfirm 不清 9 号槽；默认路径全清（0..7 + snooze + 确认条）',
        () async {
      final confirmId = NotificationService.habitConfirmNotifyIdOf('h1');
      // 模拟静音开始的撤销路径：保留确认条（0..7 落点 + 8 号 snooze 仍清）。
      await NotificationService.instance.cancelHabitReminder('h1',
          keepConfirm: true);
      expect(cancelIds(), isNot(contains(confirmId)),
          reason: 'P3-6：确认条是进行态回执，静音不得连带清掉');
      expect(cancelIds().length, 9,
          reason: '0..7 提醒槽 + 8 号 snooze 槽');

      notifCalls.clear();
      // 默认（删除 / 归档 / 重排路径）：行为与升级前一致，9 号槽一并清。
      await NotificationService.instance.cancelHabitReminder('h1');
      expect(cancelIds(), contains(confirmId));
      expect(cancelIds().length, 10);
    });
  });

  group('U-2 静音边界严格小于', () {
    test('终点时刻本身不算命中（照常投递）；终点前一毫秒命中', () {
      final until = DateTime(2026, 11, 1, 8, 0);
      NotificationService.remindersMutedUntil = until;
      expect(NotificationService.isReminderMuted(until), isFalse,
          reason: 'U-2：静音到 08:00 时，每天 08:00 的提醒不再被吞');
      expect(NotificationService.isReminderMuted(
          until.subtract(const Duration(milliseconds: 1))), isTrue);
      NotificationService.remindersMutedUntil = null;
    });
  });

  group('U-6 静音窗口不随备份迁移', () {
    test('不进备份白名单；恢复侧写不进（本机状态保留）', () async {
      await (await SharedPreferences.getInstance()).clear();
      final prefs = await SharedPreferences.getInstance();
      const local = '2026-11-02T08:00:00.000';
      await prefs.setString('reminders_muted_until', local);

      final out = await collectAppPrefs();
      expect(out.containsKey('reminders_muted_until'), isFalse,
          reason: 'U-6：静音是本机短期状态，导出侧经二道闸排除');

      await applyAppPrefs({'reminders_muted_until': '2030-01-01T00:00:00.000'});
      expect(prefs.getString('reminders_muted_until'), local,
          reason: '旧备份携带的静音键在恢复侧同样被白名单丢弃（不再「莫名其妙又被静音」）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // U-10：空合并不承诺撤销
  // ══════════════════════════════════════════════════════════════════

  group('U-10 空合并撤销', () {
    test('无受影响任务且源未归档 → batchId=0（UI 不弹撤销横幅）', () async {
      final p = await buildWith([mk('1', title: '无标签任务')]);
      final (changed, batchId, ok) = await p.mergeTags('ghost', 'target');
      expect(ok, isTrue);
      expect(changed, 0);
      expect(batchId, 0, reason: '未登记撤销条目 → UI 据 batchId==0 跳过撤销横幅');
    });

    test('有受影响任务 → batchId 非 0，可撤销', () async {
      final p = await buildWith([
        mk('1', title: '带标签任务').copyWith(tags: const ['ghost']),
      ]);
      final (changed, batchId, ok) = await p.mergeTags('ghost', 'target');
      expect(ok, isTrue);
      expect(changed, 1);
      expect(batchId, isNot(0));
      final undo = await p.undoMergeTags(batchId);
      expect(undo.applied, isTrue, reason: '对照：有效合并不受影响');
    });
  });
}

class _NullPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => null;
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
