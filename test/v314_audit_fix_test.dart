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
import 'package:todolist/models/task.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart' show lightTheme;
import 'package:todolist/widgets/backup_sheet.dart' show confirmEmptyRestoreSections;
import 'package:todolist/widgets/quick_entry_sheet.dart';

import 'test_helpers.dart';

/// v3.1.4 审计修复轮回归测试（《有条功能与操作审计报告（v3.1.4）》）。
/// 每条修复至少一个「能区分修与未修」的用例。
///
/// 覆盖清单：
/// - **P1-1** 密钥库异常按无口令降级；设置读取阶段抛错 → 只读安全模式，
///   真实库 / 偏好不被 7 条示例覆盖，显式 setter 也不写回默认值；
/// - **P2-1** 习惯 / 专注侧 retryLoad 出口；
/// - **P2-2 / P2-3** 三侧健康检查：自动备份与恢复前回滚点都拒绝产出；
///   恢复前预演对空 habits / check_ins / focus 段给出二次确认；
/// - **P3-1 / P3-6** 读库成功即清零（retry 内自愈本轮落库）、重试防重入、
///   安全模式期间未保存编辑可被感知；
/// - **P3-2** prefs 说「今天已备」但文件不存在时补备；
/// - **P3-5** 偏好写失败不阻断任务落盘；设置未变化时跳过 27 次偏好写；
/// - **P3-7** 快照组装在后台 isolate 内完成，输出与同步真源同构；
/// - **U-1 / U-2 / U-3 / U-4** 多选一次提交、UTF-16 安全截断、应用锁降级
///   如实回执、解锁按钮文案随凭据可用性。
///
/// 不落用例（如实，见最终回复）：
/// - **P3-3** 跨天 / resumed 触发点为 main.dart 回调接线，需跑完整 App 生命周期；
/// - **P3-4 / P3-8** 前者是启动性能（无可观测行为差异），后者是私有 sheet 的
///   onChanged 接线（需完整习惯页 Provider 栈），均以代码审查交付；
/// - **P2-2 方向 2/3** 本轮采用「阻断生成」而非「partial 标记」，故无 partial
///   文件名可断言；同日补备由 P3-2 用例覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  final docs = Directory.systemTemp.createTempSync('yt_v314_').path;
  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  const widgetCh = MethodChannel('com.example.todolist/widget_refresh');
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const authCh = MethodChannel('plugins.flutter.io/local_auth');

  var secureThrows = false;
  // P1-1（v3.1.5 审计）：三个探测值必须分开 mock——真实设备上
  // `canCheckBiometrics`（硬件）与 `isDeviceSupported`（现有凭据）会分叉，
  // v3.1.4 的用例把两者绑成同一个变量，正好掩盖了「有硬件未录入」的自锁死路。
  var bioHardware = false;
  var bioEnrolled = false;
  var deviceCredential = false;
  var caseSeq = 0;
  late String caseDocs;
  late _ThrowingStore store;

  setUpAll(() {
    final messenger = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(notifCh, (call) async => null);
    messenger.setMockMethodCallHandler(widgetCh, (call) async => null);
    messenger.setMockMethodCallHandler(secureCh, (call) async {
      if (secureThrows) throw PlatformException(code: 'keystore_invalid');
      return null;
    });
    messenger.setMockMethodCallHandler(authCh, (call) async {
      switch (call.method) {
        case 'canCheckBiometrics':
          return bioHardware;
        case 'isDeviceSupported':
          return bioEnrolled || deviceCredential;
        case 'getAvailableBiometrics':
          return bioEnrolled ? <String>['fingerprint'] : <String>[];
        case 'authenticate':
          return false;
        default:
          return null;
      }
    });
  });

  setUp(() {
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    store = _ThrowingStore();
    SharedPreferencesStorePlatform.instance = store;
    NotificationService.instance.enabled = false;
    NotificationService.remindersMutedUntil = null;
    secureThrows = false;
    bioHardware = false;
    bioEnrolled = false;
    deviceCredential = false;
    caseDocs = '$docs/case_${++caseSeq}';
    Directory(caseDocs).createSync(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(caseDocs);
  });

  Task mk(String id, {String title = '任务'}) => Task(
        id: id,
        title: title,
        priority: Priority.medium,
        category: Category.work,
      );

  /// 走 restoreFromJson 构造受控列表（绕过 load() 的守护 / 午夜定时器）。
  Future<TaskProvider> buildWith(List<Task> tasks) async {
    final p = TaskProvider();
    await p.restoreFromJson(jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': <dynamic>[],
      'notifications_enabled': false,
      'sound_enabled': false,
    }));
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return p;
  }

  Future<SharedPreferences> seedPrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('notifications_enabled', false);
    await sp.setBool('sound_enabled', false);
    await sp.setInt('snooze_minutes', 30);
    await sp.setBool('dnd_enabled', true);
    await sp.setInt('trash_retention_days', -1);
    await sp.setInt('focus_goal_minutes', 240);
    await sp.setBool('auto_backup_encrypt', false);
    await sp.setBool('samples_seeded_v1', true);
    return sp;
  }

  // ══════════════════════════════════════════════════════════════════
  // P1：设置读取失败不得让示例任务覆盖真实库
  // ══════════════════════════════════════════════════════════════════

  group('P1-1 设置读取异常', () {
    test('密钥库抛错按「无口令」降级，不阻断启动也不重置偏好', () async {
      final sp = await seedPrefs();
      await LocalDatabase.instance
          .replaceTasks([mk('real', title: '真实任务')], []);
      secureThrows = true;
      final p = TaskProvider();
      // 旧实现：_loadAutoBackupPass 抛 PlatformException，load() 在读库前退出。
      await expectLater(p.load(), completes);
      expect(p.dbLoadFailed, isFalse);
      expect(p.settingsLoadFailed, isFalse);
      expect(p.tasks.map((t) => t.id), ['real'],
          reason: '密钥库异常不得让 7 条示例留在内存');
      expect(sp.getInt('snooze_minutes'), 30);
      expect(sp.getInt('focus_goal_minutes'), 240);
      expect(p.hasAutoBackupPassphrase, isFalse,
          reason: '缺口令时保持关闭态，自动备份会显式失败而非静默降级明文');
    });

    test('设置读取阶段抛错 → 只读安全模式；真实库与偏好都不被示例覆盖', () async {
      final sp = await seedPrefs();
      await LocalDatabase.instance
          .replaceTasks([mk('real', title: '真实任务')], []);
      // 过期的静音键会让 _loadSettings 走 await prefs.remove(...)，
      // 用可抛错的 store 模拟「设置读取中途平台通道异常」。
      await sp.setString('reminders_muted_until',
          DateTime.now().subtract(const Duration(days: 1)).toIso8601String());
      store.throwOnRemove = true;
      final p = TaskProvider();
      await expectLater(p.load(), throwsA(anything));
      expect(p.dbLoadFailed, isTrue, reason: '横幅必须出现，旧实现恒 false');
      expect(p.settingsLoadFailed, isTrue);
      expect(p.tasksLoadedFromDb, isFalse);
      expect(p.tasks.length, 7, reason: '内存仍是内置示例');

      // 任意一次任务写操作都不得把示例写回真实库。
      await p.toggleDone('1');
      final rows = await LocalDatabase.instance.loadTasks();
      expect(rows.map((t) => t.id), ['real'],
          reason: 'P1-1 根因：旧实现一次 toggleDone 就把真实任务库覆盖成 7 条示例');
      expect(rows.single.title, '真实任务');

      // 口令之后才读的设置项不得被默认值覆盖，且自动备份不产出。
      expect(sp.getInt('snooze_minutes'), 30);
      expect(sp.getInt('app_lock_idle_seconds'), isNull);
      expect(sp.getBool('briefing_morning_enabled'), isNull);
      await p.triggerAutoBackup();
      expect(Directory('$caseDocs/backup/auto').existsSync(), isFalse);

      // 显式 setter 同样被拒绝（_persistSettings 的二道闸）。
      await p.setAutoBackupEnabled(false);
      expect(sp.getBool('auto_backup_enabled'), isNull,
          reason: '设置读取失败期间不允许任何偏好写回');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-1 / P3-6：load / retryLoad 的正确性
  // ══════════════════════════════════════════════════════════════════

  group('P3-1 / P3-6 加载与重试', () {
    test('重试成功那一轮的自愈本轮就落库（清零不再拖到 load 末尾）', () async {
      await seedPrefs();
      await LocalDatabase.instance.replaceTasks([mk('1', title: '周报')], []);
      final p = TaskProvider();
      p.markDbLoadFailedForTest();
      expect(await p.retryLoad(), isTrue);
      final rows = await LocalDatabase.instance.loadTasks();
      expect(rows.single.pinyinFull, 'zhoubao',
          reason: '旧实现 _persistTasksOnly 被自身 _dbLoadFailed 拒绝，DB 里仍是空拼音');
      expect(p.dbLoadFailed, isFalse);
    });

    test('连点两次 retryLoad 只执行一次', () async {
      await seedPrefs();
      await LocalDatabase.instance.replaceTasks([mk('1')], []);
      final p = TaskProvider();
      p.markDbLoadFailedForTest();
      final first = p.retryLoad();
      final second = p.retryLoad();
      expect(await second, isFalse, reason: '并发重试必须被 _loadInFlight 拒绝');
      expect(await first, isTrue);
      expect(p.loadInFlight, isFalse);
    });

    test('安全模式期间的未保存编辑可被感知，成功后清零', () async {
      final p = await buildWith([mk('1')]);
      p.markDbLoadFailedForTest();
      await p.toggleDone('1');
      expect(p.hasUnsavedSafeModeEdits, isTrue);
      expect(await p.retryLoad(), isTrue);
      expect(p.hasUnsavedSafeModeEdits, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2：三侧安全模式与快照可信度
  // ══════════════════════════════════════════════════════════════════

  group('P2-1 / P2-2 / P2-3 三侧健康', () {
    test('习惯侧 retryLoad 可退出安全模式', () async {
      final hp = HabitProvider();
      await hp.load();
      hp.markDbLoadFailedForTest();
      expect(hp.dbLoadFailed, isTrue);
      expect(await hp.retryLoad(), isTrue);
      expect(hp.dbLoadFailed, isFalse);
    });

    test('专注侧 retryLoad 可退出安全模式', () async {
      final fp = FocusProvider();
      await fp.load();
      fp.markDbLoadFailedForTest();
      expect(fp.dbLoadFailed, isTrue);
      expect(await fp.retryLoad(), isTrue);
      expect(fp.dbLoadFailed, isFalse);
    });

    test('习惯侧安全模式 → 自动备份与恢复前回滚点都不产出', () async {
      await seedPrefs();
      await LocalDatabase.instance.replaceTasks([mk('1')], []);
      final hp = HabitProvider();
      await hp.load();
      hp.markDbLoadFailedForTest();
      final p = TaskProvider();
      await p.load();
      expect(p.snapshotSourcesHealthy, isFalse,
          reason: '旧实现只看任务侧，习惯为空照样写当日快照');
      await p.triggerAutoBackup();
      expect(Directory('$caseDocs/backup/auto').existsSync(), isFalse);
      expect(await p.writePreRestoreSnapshot(), isFalse,
          reason: '旧实现会用 7 条示例 / 空习惯生成假回滚点');
      // 复原单例状态，避免污染同进程后续用例。
      await hp.retryLoad();
    });

    test('P3-2：prefs 说今天已备但文件不存在 → 补备', () async {
      final sp = await seedPrefs();
      final now = DateTime.now();
      final key = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      await sp.setString('last_auto_backup_date', key);
      await LocalDatabase.instance.replaceTasks([mk('1')], []);
      final p = TaskProvider();
      await p.load();
      expect(p.lastAutoBackupDate, isNotNull);
      expect(Directory('$caseDocs/backup/auto').existsSync(), isFalse);
      await p.triggerAutoBackup();
      final files = Directory('$caseDocs/backup/auto').existsSync()
          ? Directory('$caseDocs/backup/auto')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
          : <File>[];
      expect(files, isNotEmpty,
          reason: '旧实现只信 prefs 日期早退，快照文件被删后当天不再补备');
    });

    testWidgets('恢复前预演：空 habits / focus 段给出二次确认', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ));
      // U-2（v3.1.5 审计）：只有「备份段为空 **且** 本机对应段非空」才警告；
      // 旧实现不看本机数据，只用任务的用户每次恢复都被吓一次。
      final future = confirmEmptyRestoreSections(ctx, {
        'habits': <dynamic>[],
        'focus_sessions': <dynamic>[],
      }, currentHabitCount: 2, currentFocusCount: 3);
      await tester.pumpAndSettle();
      expect(find.text('这份备份可能不完整'), findsOneWidget);
      expect(find.textContaining('习惯'), findsOneWidget);
      expect(find.textContaining('2 条习惯'), findsOneWidget,
          reason: '文案要给出真实条数，而不是复述段名');
      await tester.tap(find.text('仍要恢复'));
      await tester.pumpAndSettle();
      expect(await future, isTrue);

      // 本机对应段同样为空 → 不存在数据损失，不弹警告。
      final noWarn = confirmEmptyRestoreSections(ctx, {
        'habits': <dynamic>[],
        'check_ins': <dynamic>[],
        'focus_sessions': <dynamic>[],
      });
      await tester.pumpAndSettle();
      expect(find.text('这份备份可能不完整'), findsNothing,
          reason: '空覆盖空无损失；旧实现无条件警告');
      expect(await noWarn, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-5：任务落盘与偏好解耦
  // ══════════════════════════════════════════════════════════════════

  group('P3-5 偏好写 best-effort', () {
    test('偏好写失败不阻断任务落盘', () async {
      final p = await buildWith([mk('1')]);
      store.throwOnSet = true;
      await p.toggleDone('1');
      final rows = await LocalDatabase.instance.loadTasks();
      expect(rows.single.done, isTrue,
          reason: '旧实现 _persistSettings 抛错即 return false，任务库明明可写却不落盘');
    });

    test('设置未变化时任务写入跳过 27 次偏好写', () async {
      final p = await buildWith([mk('1'), mk('2')]);
      // buildWith 的 restoreFromJson 已写过一轮全量偏好；此后两次纯任务写入
      // 均不改变任何设置值，签名相同就应该整轮跳过。
      store.setCalls = 0;
      await p.toggleDone('1');
      final afterFirst = store.setCalls;
      await p.toggleDone('2');
      expect(store.setCalls, 0,
          reason: '旧实现每次任务写入都串行写 27 个偏好键');
      expect(store.setCalls, afterFirst);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-7：快照后台组装
  // ══════════════════════════════════════════════════════════════════

  group('P3-7 快照组装 isolate 化', () {
    test('同步真源真实读取附件字节，后台入口结果一致', () async {
      final f = File('$caseDocs/att.bin')..writeAsBytesSync([1, 2, 3]);
      final src = AttachmentBlobSource(
        taskId: 't1',
        refJson: const {'fileName': 'att.bin', 'displayName': 'att.bin'},
        path: f.path,
      );
      final base = <String, dynamic>{'version': 3, 'app': '有条', 'tasks': <dynamic>[]};
      final sync = buildSnapshotBodySync(
          base, [src], 0, false, null, DataIo.maxExportPayloadBytes);
      expect(sync.oversize, isFalse);
      expect(sync.stripped, isFalse);
      expect(sync.body, contains('AQID'), reason: 'base64(01 02 03)');
      expect(sync.body, contains('__skipped'),
          reason: '输出结构必须与 collectBlobs 逐字段一致');
      final async = await buildSnapshotBodyOffMainThread(
          base, [src], 0, false, null, DataIo.maxExportPayloadBytes);
      expect(async.body, sync.body);
      expect(async.oversize, sync.oversize);
    });

    test('预算超限时 oversize=true 且 body 为空（不写废快照）', () async {
      final r = buildSnapshotBodySync(
          {'version': 3, 'tasks': <dynamic>[]},
          const <AttachmentBlobSource>[],
          0,
          false,
          null,
          1);
      expect(r.oversize, isTrue);
      expect(r.body, isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // U：交互与如实回执
  // ══════════════════════════════════════════════════════════════════

  group('U 交互', () {
    test('U-1：自选三件一次提交 3 件，超额 / 悬空 id 具名拒绝', () async {
      final p = await buildWith([mk('1'), mk('2'), mk('3'), mk('4')]);
      expect(await p.addTodayMitBatch(['1', '2', '3']), MitToggleOutcome.ok);
      expect(p.todayMit, ['1', '2', '3']);
      expect(await p.addTodayMitBatch(['4']), MitToggleOutcome.full);
      expect(await p.addTodayMitBatch(['gone']), MitToggleOutcome.invalid);
    });

    test('U-2：500 字上限唯一真源 + 截断不切断 emoji 代理对', () {
      expect(QuickEntrySheet.maxInputLength, 500);
      final s = '😀😀😀'; // UTF-16 长度 6，切在 3 正好落在一个 emoji 中间
      expect(s.length, 6);
      final clipped = QuickEntrySheet.clipToUtf16Safe(s, 3);
      expect(clipped, '😀');
      expect(clipped.length, 2, reason: '旧 substring 会留下孤立高代理项');
      final merged = QuickEntrySheet.mergeClipboardText(
          '', const TextSelection.collapsed(offset: 0), s * 200);
      expect(merged.truncated, isTrue);
      // U-3（v3.1.5 审计）：口径改为**字素簇**——TextField 的 maxLength 就是
      // 按字素计数，旧实现按 UTF-16 截（500 码元 = 250 个 emoji），同样
      // 500 字额度下手输能放 500 个、粘贴只能放 250 个。
      expect(merged.text.characters.length, QuickEntrySheet.maxInputLength,
          reason: '与输入框同口径：500 个字素，而不是 500 个 UTF-16 码元');
      expect(merged.text.length, greaterThan(500),
          reason: 'emoji 按字素计数时 UTF-16 长度必然超过 500');
      expect(Uri.encodeComponent(merged.text), isNot(contains('%EF%BF%BD')),
          reason: '不得产生替换字符（非法 UTF-16）');
    });

    test('U-3：应用锁被强制关闭时可通过 getter 如实回执', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('app_lock_enabled', true);
      bioEnrolled = false;
      deviceCredential = false;
      final lock = AppLockProvider();
      await lock.refreshEnabled();
      expect(lock.lastRefreshForceDisabled, isTrue);
      expect(lock.appLockEnabled, isFalse);
      expect(sp.getBool('app_lock_enabled'), isFalse);

      await sp.setBool('app_lock_enabled', true);
      bioEnrolled = true;
      final okLock = AppLockProvider();
      await okLock.refreshEnabled();
      expect(okLock.lastRefreshForceDisabled, isFalse);
      expect(okLock.appLockEnabled, isTrue);
    });

    testWidgets('U-4：解锁主按钮文案随凭据可用性', (tester) async {
      Future<void> pumpGate(AppLockProvider lock) async {
        await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AppLockProvider>.value(value: lock),
          ],
          child: MaterialApp(theme: lightTheme, home: const AppLockGate()),
        ));
        await tester.pumpAndSettle();
      }

      // P1-1 / U-1（v3.1.5 审计）：文案改由「现在能验证的方式」派生，三态：
      // 仅锁屏密码 / 生物识别（可降级密码）/ 无任何凭据。
      bioHardware = true;
      bioEnrolled = false;
      deviceCredential = true;
      final pwdOnly = AppLockProvider();
      await pwdOnly.load();
      await pumpGate(pwdOnly);
      expect(find.text('使用锁屏密码解锁'), findsOneWidget,
          reason: '旧实现固定写「使用生物识别解锁」，仅锁屏密码设备上不实');
      expect(find.text('使用生物识别解锁'), findsNothing);
      expect(find.textContaining('锁屏密码'), findsWidgets);

      bioHardware = true;
      bioEnrolled = true;
      deviceCredential = true;
      final withBio = AppLockProvider();
      await withBio.load();
      await pumpGate(withBio);
      expect(find.text('使用生物识别解锁'), findsOneWidget);
      expect(find.text('使用锁屏密码解锁'), findsNothing);

      // P1-1（v3.1.5 审计）：**有硬件但未录入 + 无锁屏密码**的真实死路——
      // 旧实现 `bioOk = canCheckBiometrics = true` → 承诺「使用生物识别解锁」
      // 且隐藏关闭出口，用户被永久锁在应用外。现在：不再承诺任何凭据，
      // 且必须渲染「关闭应用锁」出口。
      bioHardware = true;
      bioEnrolled = false;
      deviceCredential = false;
      final deadEnd = AppLockProvider();
      await deadEnd.load();
      await pumpGate(deadEnd);
      expect(deadEnd.canAuthenticate, isFalse,
          reason: '硬件能力不等于可验证凭据（P1-1 根因）');
      expect(find.text('使用生物识别解锁'), findsNothing);
      expect(find.text('使用锁屏密码解锁'), findsNothing);
      expect(find.text('重新验证'), findsOneWidget);
      expect(find.text('无法验证？关闭应用锁'), findsOneWidget,
          reason: '真实死路必须留出口，否则唯一出路是清数据');
    });
  });
}

/// 可注入失败 / 计数的 SharedPreferences 后端。
class _ThrowingStore extends InMemorySharedPreferencesStore {
  _ThrowingStore() : super.empty();
  bool throwOnRemove = false;
  bool throwOnSet = false;
  int setCalls = 0;

  @override
  Future<bool> remove(String key) async {
    if (throwOnRemove) throw PlatformException(code: 'prefs_io_error');
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    setCalls++;
    if (throwOnSet) throw PlatformException(code: 'prefs_io_error');
    return super.setValue(valueType, key, value);
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
