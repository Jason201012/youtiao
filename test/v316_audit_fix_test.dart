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
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart' show lightTheme;
import 'package:todolist/widgets/backup_sheet.dart'
    show confirmEmptyRestoreSections;
import 'package:todolist/widgets/quick_entry_sheet.dart';
import 'package:todolist/widgets/sheet_message.dart';
import 'package:todolist/widgets/task_toggle_undo.dart';

import 'test_helpers.dart';

/// v3.1.6 审计修复轮回归测试（《有条功能与操作审计报告（v3.1.6）》）。
///
/// 覆盖清单（13 项）：
/// - **P2-1 / P3-4** 应用锁三态验证、取消不得关闭、探测复位粘滞标记、
///   运行期凭据变更后开关 / 回前台重新探测。
/// - **P2-2** 弹层内消息可见 + 进度层期间的消息延后到收起后显示。
/// - **P2-3** 开启加密回溯存量明文快照（含 pre-restore 回滚点）。
/// - **P3-1** >1MB 快照头尾完整性、空 `ct` 信封不可用、截断文件补备。
/// - **P3-2** 日期 + 状态两段式副标题、noattach 由文件名推导、
///   错误跨日残留、关闭自动备份清键。
/// - **P3-3** 换口令后清日期并立即补写可用新快照。
/// - **P3-6** 死参数删除后确认文案与真实时序一致。
/// - **P3-7** daily_mit 列为本机短期状态，不随备份迁移。
/// - **U-2** 中间光标粘贴超限保留光标后原文。
/// - **U-3** 失败横幅判据（真失败告警 / warning 与跨日旧失败不误报）。
///
/// 不落用例（如实）：**P3-5**（横幅为 main.dart 私有 State，需构造三侧
/// Provider 故障 + 路由中途销毁）、**U-1**（进度层为 backup_sheet 私有方法，
/// 完整路径依赖平台通道写盘）以代码审查交付，见最终回复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  final docs = Directory.systemTemp.createTempSync('yt_v316_').path;
  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  const widgetCh = MethodChannel('com.example.todolist/widget_refresh');
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const authCh = MethodChannel('plugins.flutter.io/local_auth');

  // local_auth 三态：硬件 / 已录入 / 设备凭据；authenticate：成功 / 取消 /
  // 抛 NotAvailable（本机无凭据）。与 v315 脚手架同口径：
  // canCheckBiometrics 由 getAvailableBiometrics 推导，不单独 mock。
  var bioHardware = false;
  var bioEnrolled = false;
  var deviceCredential = false;
  var authOk = false;
  var authUnavailable = false;
  var caseSeq = 0;
  late String caseDocs;

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(notifCh, (call) async => null);
    messenger.setMockMethodCallHandler(widgetCh, (call) async => null);
    messenger.setMockMethodCallHandler(secureCh, (call) async => null);
    messenger.setMockMethodCallHandler(authCh, (call) async {
      switch (call.method) {
        case 'isDeviceSupported':
          return bioEnrolled || deviceCredential;
        case 'getAvailableBiometrics':
          if (bioEnrolled) return <String>['fingerprint'];
          if (bioHardware) return <String>['undefined'];
          return <String>[];
        case 'authenticate':
          if (authUnavailable) {
            throw PlatformException(
                code: 'NotAvailable', message: 'No authentication available');
          }
          return authOk;
        default:
          return null;
      }
    });
  });

  setUp(() async {
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    // 🔴 SharedPreferences 是进程内单例：换 store 不清缓存，必须显式抹掉
    // 上一个用例留下的所有键（尤其 app_lock_enabled / 快照日期 / 错误键）。
    final sp = await SharedPreferences.getInstance();
    for (final k in sp.getKeys().toList()) {
      await sp.remove(k);
    }
    NotificationService.instance.enabled = false;
    NotificationService.remindersMutedUntil = null;
    bioHardware = false;
    bioEnrolled = false;
    deviceCredential = false;
    authOk = false;
    authUnavailable = false;
    caseDocs = '$docs/case_${++caseSeq}';
    Directory(caseDocs).createSync(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(caseDocs);
  });

  String dateKey([DateTime? d]) {
    final n = d ?? DateTime.now();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(n.year, 4)}-${p(n.month)}-${p(n.day)}';
  }

  Task mk(String id, {String title = '任务'}) => Task(
        id: id,
        title: title,
        priority: Priority.medium,
        category: Category.work,
      );

  /// 与 v315 一致的「已播种、不生成示例」偏好集。
  Future<SharedPreferences> seedPrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('notifications_enabled', false);
    await sp.setBool('sound_enabled', false);
    await sp.setBool('auto_backup_encrypt', false);
    await sp.setBool('samples_seeded_v1', true);
    await sp.setInt('trash_retention_days', -1);
    return sp;
  }

  Directory autoDir() =>
      Directory('$caseDocs/backup/auto')..createSync(recursive: true);

  /// 一份 ≥256 字节、可被 _snapshotFileUsable 判为可用的明文快照。
  String validPlainSnapshot() => jsonEncode({
        'version': 3,
        'tasks': <dynamic>[],
        'pad': 'x' * 400,
      });

  Future<AppLockProvider> lockedProvider() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('app_lock_enabled', true);
    final lock = AppLockProvider();
    await lock.load();
    return lock;
  }

  Future<void> pumpGate(WidgetTester tester, AppLockProvider lock) async {
    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider<AppLockProvider>.value(value: lock)],
      child: MaterialApp(theme: lightTheme, home: const AppLockGate()),
    ));
    await tester.pumpAndSettle();
  }

  // ═══════════════════ P2-1 / P3-4 应用锁 ═══════════════════

  group('P2-1 应用锁取消验证不得关闭', () {
    testWidgets('出口可见 + 用户取消系统验证 → 无确认框、应用锁保持开启',
        (tester) async {
      final lock = await lockedProvider();
      expect(lock.unlockEscapeVisible, isTrue);
      await pumpGate(tester, lock);

      await tester.tap(find.text('无法验证？关闭应用锁'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('关闭应用锁'), findsNothing,
          reason: 'P2-1：取消验证绝不能进入「关闭应用锁」二次确认');
      expect(find.textContaining('已取消验证，应用锁保持开启'), findsOneWidget,
          reason: '用户必须看到明确回执，而不是「按钮没反应」');
      expect(lock.appLockEnabled, isTrue);
      expect(lock.locked, isTrue);
    });

    testWidgets('真实无凭据（不可用异常 + 探测确认）→ 仍保留死路出口',
        (tester) async {
      authUnavailable = true;
      final lock = await lockedProvider();
      await pumpGate(tester, lock);

      await tester.tap(find.text('无法验证？关闭应用锁'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '关闭应用锁'), findsOneWidget,
          reason: '不能把 P1-1 的真实死路兜底一起修掉');
      await tester.tap(find.widgetWithText(FilledButton, '关闭应用锁'));
      await tester.pumpAndSettle();
      expect(lock.appLockEnabled, isFalse);
      expect(lock.locked, isFalse);
    });

    test('瞬时不可用 + 探测仍可用 → 不置粘滞标记；补录凭据后出口隐藏', () async {
      deviceCredential = true;
      bioEnrolled = true;
      final lock = await lockedProvider();
      expect(lock.canAuthenticate, isTrue);

      // 系统凭据被移除 + 一次不可用异常 → 真实死路。
      deviceCredential = false;
      bioEnrolled = false;
      authUnavailable = true;
      final dead = await lock.authenticateDetailed();
      expect(dead.unavailableConfirmed, isTrue);
      expect(lock.authUnavailable, isTrue);
      expect(lock.unlockEscapeVisible, isTrue);

      // 系统重新补录 + 一次成功探测 → 粘滞标记必须复位。
      deviceCredential = true;
      bioEnrolled = true;
      authUnavailable = false;
      await lock.probeBiometric();
      expect(lock.canAuthenticate, isTrue);
      expect(lock.authUnavailable, isFalse,
          reason: '报告 P2-1 方向 3：探测成功必须复位粘滞标记');
      expect(lock.unlockEscapeVisible, isFalse);
    });

    test('P3-4：系统运行期补录凭据后 setEnabled(true) 无需重启', () async {
      final lock = AppLockProvider();
      await lock.load();
      expect(lock.canAuthenticate, isFalse);
      deviceCredential = true;
      expect(await lock.setEnabled(true), isTrue,
          reason: '旧实现读启动缓存，用户去系统设置补录后仍被拒');
      expect(lock.appLockEnabled, isTrue);
    });

    test('P3-4：onResumed 重新探测，设置页 / 解锁页状态即时更新', () async {
      final lock = await lockedProvider();
      expect(lock.canAuthenticate, isFalse);
      deviceCredential = true;
      lock.onResumed();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(lock.canAuthenticate, isTrue,
          reason: '凭据变更后不重启也要能看到最新可用性');
    });
  });

  // ═══════════════════ P2-2 弹层内消息可见 ═══════════════════

  group('P2-2 弹层内提示可见', () {
    testWidgets('showSheetSnackBar 在 host 内渲染消息条，不再挂主 Scaffold',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SheetMessageHost(
            child: Builder(builder: (c) {
              ctx = c;
              return const SizedBox.shrink();
            }),
          ),
        ),
      ));
      showSheetSnackBar(ctx, const SnackBar(content: Text('弹层内错误')));
      await tester.pump();

      expect(find.byKey(const Key('sheet-message')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SheetMessageHost),
          matching: find.text('弹层内错误'),
        ),
        findsOneWidget,
        reason: '提示必须落在弹层子树内且在弹层之上绘制',
      );
      expect(find.byType(SnackBar), findsNothing,
          reason: '旧实现把提示挂到主 Scaffold，被弹层整块遮住');
    });

    testWidgets('showTaskPersistFailedHint 在弹层内可见（新建失败回执）',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SheetMessageHost(
            child: Builder(builder: (c) {
              ctx = c;
              return const SizedBox.shrink();
            }),
          ),
        ),
      ));
      showTaskPersistFailedHint(ctx, rolledBack: true);
      await tester.pump();
      expect(find.text('新建未生效，请重试'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('sheet-message')),
          matching: find.text('新建未生效，请重试'),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('普通页面（无 host）仍退回原生 SnackBar，行为不回归',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          }),
        ),
      ));
      showSheetSnackBar(ctx, const SnackBar(content: Text('页面级提示')));
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byKey(const Key('sheet-message')), findsNothing);
    });

    testWidgets('进度层覆盖期间的消息排队，收起后才可见', (tester) async {
      late BuildContext hostCtx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            hostCtx = c;
            return const SizedBox.shrink();
          }),
        ),
      ));
      final dialog = showDialog<void>(
        context: hostCtx,
        builder: (_) => const AlertDialog(title: Text('进度中')),
      );
      await tester.pumpAndSettle();
      pushSheetProgressLayer();
      showSheetSnackBar(hostCtx, const SnackBar(content: Text('备份已完成')));
      await tester.pump();
      expect(find.text('备份已完成'), findsNothing,
          reason: '进度 AlertDialog 在前台时立即显示必被遮挡');

      Navigator.of(hostCtx, rootNavigator: true).pop();
      await dialog;
      await tester.pump();
      popSheetProgressLayer();
      flushPendingSheetMessages(hostCtx);
      await tester.pump();
      expect(find.text('备份已完成'), findsOneWidget);
    });
  });

  // ═══════════════════ U-2 快速录入截断 ═══════════════════

  group('U-2 中间光标粘贴只截粘贴内容', () {
    test('中间光标粘贴超限 → 光标后原文完整保留、光标在插入内容末尾', () {
      final head = 'A' * 10;
      final tail = '${'B' * 470}TAIL'; // 474 字素 → 剩余额度 = 500-10-474 = 16
      final current = head + tail; // 484 字素
      final r = QuickEntrySheet.mergeClipboardText(
        current,
        const TextSelection.collapsed(offset: 10),
        'X' * 40,
        maxLength: 500,
      );
      expect(r.truncated, isTrue);
      expect(r.text.endsWith('TAIL'), isTrue,
          reason: 'U-2：旧实现整段 take(500) 会吞掉原光标后的 TAIL');
      expect(r.text.characters.length, 500);
      expect(r.text.substring(10, 26), 'X' * 16);
      expect(r.cursor, 26,
          reason: '光标必须落在插入内容末尾，而不是保留段末尾');
    });

    test('原文已达上限时粘贴被拒，原文一字不动', () {
      final current = 'Q' * 500;
      final r = QuickEntrySheet.mergeClipboardText(
        current,
        const TextSelection.collapsed(offset: 200),
        'more',
      );
      expect(r.text, current);
      expect(r.truncated, isTrue);
      expect(r.cursor, 200);
    });
  });

  // ═══════════════════ P3-1 大快照完整性 ═══════════════════

  group('P3-1 大快照头尾完整性', () {
    test('明文：头含 tasks + 尾闭合 → true；尾部截断 → false', () {
      const head = '{"version":3,"tasks":[],"pad":"';
      expect(
        TaskProvider.snapshotLargeFileLooksComplete(
            head: head, tail: '${'x' * 64}"\n}', encrypted: false),
        isTrue,
      );
      expect(
        TaskProvider.snapshotLargeFileLooksComplete(
            head: head, tail: 'x' * 64, encrypted: false),
        isFalse,
        reason: '旧实现只读头 16KB，截断一半的大文件仍判可用',
      );
    });

    test('加密信封：空 ct / 缺 tag / 截断密文 → false；完整 ct → true', () {
      const head = '{\n  "format": "youtiao-backup",\n  "encrypted": true,\n'
          '  "kdf": {"salt": "abc"},\n  "aead": {"tag": "AAA"},\n'
          '  "ct": "';
      expect(
        TaskProvider.snapshotLargeFileLooksComplete(
            head: head, tail: '"\n}', encrypted: true),
        isFalse,
        reason: 'ct 为空的空壳信封旧实现会判可用',
      );
      expect(
        TaskProvider.snapshotLargeFileLooksComplete(
            head: head.replaceAll('"tag": "AAA"', '"iv": "AAA"'),
            tail: '${'A' * 64}"\n}',
            encrypted: true),
        isFalse,
      );
      expect(
        TaskProvider.snapshotLargeFileLooksComplete(
            head: head, tail: '${'A' * 64}"\n}', encrypted: true),
        isTrue,
      );
    });

    test('>1MB 被截断尾部的当日快照 → 改名 stale 并补写',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      final sp = await seedPrefs();
      final key = dateKey();
      await sp.setString('last_auto_backup_date', key);
      await LocalDatabase.instance.replaceTasks([mk('1')], []);
      final dir = autoDir();
      final bad = File('${dir.path}/$key.json')
        ..writeAsStringSync('{"version":3,"tasks":[],"pad":"'
            '${'x' * (1024 * 1024 + 512)}'); // 尾部永远不闭合
      expect(bad.lengthSync(), greaterThan(1024 * 1024));

      final p = TaskProvider();
      await p.load();
      await p.triggerAutoBackup();

      expect(File('${bad.path}.stale').existsSync(), isTrue,
          reason: 'P3-1：截尾大文件不得继续被当成「今天已备份」');
      final good = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json') && !f.path.endsWith('.stale'))
          .toList();
      expect(good, hasLength(1));
      expect(jsonDecode(good.single.readAsStringSync())['tasks'], isA<List>());
    });
  });

  // ═══════════════════ P2-3 / P3-2 / P3-3 快照状态 ═══════════════════

  group('P2-3 开启加密回溯存量明文', () {
    test('只统计明文快照（排除 .enc.json 与 .stale.）', () async {
      await seedPrefs();
      final p = TaskProvider();
      await p.load();
      final dir = autoDir();
      File('${dir.path}/2026-01-01.json')
          .writeAsStringSync(validPlainSnapshot());
      File('${dir.path}/2026-01-02.enc.json')
          .writeAsStringSync(validPlainSnapshot());
      File('${dir.path}/2026-01-03.stale.enc.json')
          .writeAsStringSync(validPlainSnapshot());
      expect(await p.countPlaintextSnapshots(), 1);
    });

    test('开启加密并选择清理 → auto/ 与 pre-restore/ 明文均被删除',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      final sp = await seedPrefs();
      await sp.setString('last_auto_backup_date', dateKey());
      await LocalDatabase.instance.replaceTasks([mk('1')], []);
      final auto = autoDir();
      final pre = Directory('$caseDocs/backup/pre-restore')
        ..createSync(recursive: true);
      final plain = File('${auto.path}/2026-01-01.json')
        ..writeAsStringSync(validPlainSnapshot());
      final rollback = File('${pre.path}/pre-restore-20260101-120000.json')
        ..writeAsStringSync(validPlainSnapshot());

      final p = TaskProvider();
      await p.load();
      await p.setAutoBackupPassphrase('pass12345');
      expect(await p.countPlaintextSnapshots(), 2);
      expect(await p.setAutoBackupEncrypt(true, purgePlaintext: true), isTrue);
      expect(plain.existsSync(), isFalse,
          reason: 'P2-3：开启加密后旧明文不能继续留在磁盘');
      expect(rollback.existsSync(), isFalse,
          reason: '报告方向 4：恢复前明文回滚点同步处理');
      expect(await p.countPlaintextSnapshots(), 0);
    });
  });

  group('P3-2 日期 + 状态两段式', () {
    test('错误存在时日期仍可见；noattach 由文件名推导', () async {
      final sp = await seedPrefs();
      final key = dateKey();
      await sp.setString('last_auto_backup_date', key);
      await sp.setString('last_auto_backup_error', '自动备份失败：磁盘满');
      await sp.setString('last_auto_backup_error_date', key);
      File('${autoDir().path}/$key.noattach.json')
          .writeAsStringSync(validPlainSnapshot());

      final p = TaskProvider();
      await p.load();
      expect(p.lastAutoBackupNoAttach, isTrue);
      expect(p.autoBackupSubtitle, contains('最近快照：'),
          reason: '旧副标题用错误分支把日期整段盖掉');
      expect(p.autoBackupSubtitle, contains(key));
      expect(p.autoBackupSubtitle, contains('不含附件'));
      expect(p.autoBackupSubtitle, contains('自动备份异常'));
      expect(p.autoBackupHasFailure, isTrue);
    });

    test('昨天的失败 + 今天已有有效快照 → 标「上次」且不触发首页告警', () async {
      final sp = await seedPrefs();
      await sp.setString('last_auto_backup_date', dateKey());
      await sp.setString('last_auto_backup_error', '自动备份失败：缺口令');
      await sp.setString('last_auto_backup_error_date',
          dateKey(DateTime.now().subtract(const Duration(days: 1))));
      File('${autoDir().path}/${dateKey()}.json')
          .writeAsStringSync(validPlainSnapshot());

      final p = TaskProvider();
      await p.load();
      expect(p.lastAutoBackupErrorIsStale, isTrue);
      expect(p.autoBackupHasFailure, isFalse,
          reason: 'U-3：跨日残留的旧失败不应让首页横幅反复误报');
      expect(p.autoBackupSubtitle, contains('上次自动备份异常'));
      expect(p.autoBackupSubtitle, contains('最近快照：'));
    });

    test('降级 warning 不算失败，但仍在副标题如实展示', () async {
      final sp = await seedPrefs();
      await sp.setString('last_auto_backup_date', dateKey());
      await sp.setString('last_auto_backup_error_date', dateKey());
      await sp.setString('last_auto_backup_error',
          '自动备份已剥离附件（数据体积超限），任务/习惯/专注数据完整');
      File('${autoDir().path}/${dateKey()}.json')
          .writeAsStringSync(validPlainSnapshot());

      final p = TaskProvider();
      await p.load();
      expect(p.autoBackupHasFailure, isFalse);
      expect(p.autoBackupStatusNote, contains('剥离附件'));
      expect(p.autoBackupSubtitle, contains('剥离附件'));
    });

    test('关闭自动备份时清掉失败留痕（内存 + prefs）', () async {
      final sp = await seedPrefs();
      await sp.setString('last_auto_backup_error', '自动备份失败：磁盘满');
      await sp.setString('last_auto_backup_error_date', dateKey());
      final p = TaskProvider();
      await p.load();
      expect(p.lastAutoBackupError, isNotNull);

      await p.setAutoBackupEnabled(false);
      expect(p.lastAutoBackupError, isNull);
      expect(sp.getString('last_auto_backup_error'), isNull);
      expect(sp.getString('last_auto_backup_error_date'), isNull);
    });
  });

  group('P3-3 换口令后立即补写新快照', () {
    test('当日加密快照被 stale → 清日期 + 补一份可用新口令快照',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      final sp = await seedPrefs();
      await sp.setBool('auto_backup_encrypt', true);
      await sp.setString('last_auto_backup_date', dateKey());
      await LocalDatabase.instance.replaceTasks([mk('1')], []);
      final dir = autoDir();
      final old = File('${dir.path}/${dateKey()}.enc.json')
        ..writeAsStringSync(validPlainSnapshot());

      final p = TaskProvider();
      await p.load();
      final marked =
          await p.changeAutoBackupPassphrase('newpass123', force: true);
      expect(marked, 1, reason: '当日的旧口令加密快照被标记失效');
      // 补写的新快照与旧文件同名（当日键）→ 原路径已被**新口令加密信封**覆盖，
      // 旧内容则留在 .stale.enc.json 里，二者必须能区分。
      expect(old.existsSync(), isTrue,
          reason: 'P3-3：换口令后应立即补写一份当日可用快照');
      expect(old.readAsStringSync(), contains('"encrypted"'),
          reason: '补写的是新口令加密信封，不是原来的明文测试桩');
      expect(File('${dir.path}/${dateKey()}.stale.enc.json').existsSync(),
          isTrue);
      expect(
          File('${dir.path}/${dateKey()}.stale.enc.json').readAsStringSync(),
          validPlainSnapshot());

      final listed = await p.listAutoBackups();
      expect(listed, hasLength(1),
          reason: 'P3-3：stale 不展示 + 立即补写一份可用新快照');
      expect(listed.single.encrypted, isTrue);
      expect(p.lastAutoBackupDate, isNotNull,
          reason: '设置页日期必须与恢复面板一致');
    });
  });

  // ═══════════════════ P3-6 / P3-7 恢复链路 ═══════════════════

  group('P3-6 恢复确认文案与时序一致', () {
    testWidgets('固定文案说明「会尝试生成 + 失败另行提示」，不再有死参数',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ));
      final future = confirmEmptyRestoreSections(
        ctx,
        {'habits': <dynamic>[], 'focus_sessions': <dynamic>[]},
        currentHabitCount: 2,
        currentFocusCount: 3,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('恢复前会尝试生成一份可回滚的快照'),
          findsOneWidget);
      expect(find.textContaining('会在恢复结果中明确提示'), findsOneWidget);
      expect(find.textContaining('本次未能生成恢复前快照'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await future, isFalse);
    });
  });

  group('P3-7 今日三件不随备份迁移', () {
    test('导出 / 恢复 / 不迁移名单三处一致', () async {
      final sp = await SharedPreferences.getInstance();
      const localMit = '{"2026-10-31":["keep"]}';
      await sp.setString('daily_mit', localMit);
      expect(neverBackedUpPrefKeys, contains('daily_mit'));

      final exported = await collectAppPrefs();
      expect(exported.containsKey('daily_mit'), isFalse,
          reason: '备份里不再携带按日期键的本机选择');

      // 模拟恢复一份昨天备份：备份中的旧 daily_mit 必须被二道闸丢弃。
      await applyAppPrefs(<String, dynamic>{
        'daily_mit': '{"2026-10-30":["from-backup"]}',
        'theme_mode': 'dark',
      });
      final sp2 = await SharedPreferences.getInstance();
      expect(sp2.getString('daily_mit'), localMit,
          reason: '恢复旧备份不得清空本机今天的「三件」');
      expect(sp2.getString('theme_mode'), 'dark');
    });
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
