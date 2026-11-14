import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/backup_crypto.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/backup_sheet.dart'
    show confirmPartialRestore, confirmSafeModeExport;
import 'package:todolist/widgets/quick_entry_sheet.dart';

import 'test_helpers.dart';

/// v3.1.5 审计修复轮回归测试（《有条功能与操作审计报告（v3.1.5）》）。
///
/// 覆盖清单：
/// - **P1-1 / U-1** 应用锁可用性只认 `isDeviceSupported`（现在能验证），
///   「有硬件未录入 + 无锁屏密码」不得判为可用、解锁页必须有出口；文案三态。
/// - **P2-1** 安全模式导出需二次确认；恢复端识别 `safeMode` 标记再拦一次。
/// - **P2-2** 外部重写 prefs + `load()` 后设置签名失效（改回旧值必须落盘）。
/// - **P2-3** 关「同时恢复设置」时顶层通知 / 声音开关不被备份覆盖。
/// - **P3-1** `retryLoad` 期间每日重置必须落库。
/// - **P3-2** 设置读取失败期间 setter 不落盘，且留下可被感知的脏标记。
/// - **P3-3** 0 字节 / 损坏的当日快照不得锁死当天，必须可重写。
/// - **P3-5** 「加密但缺口令」在组装前直接失败，不重跑重活、不回退主 isolate。
/// - **P3-6** 首启示例落盘失败不置 `seeded`，下次启动仍会预置。
/// - **P3-7** 自动备份的附件剥离警告跨重启保留（设置页副标题带「不含附件」）。
/// - **U-3** 粘贴按字素簇计额度，与 TextField 的 maxLength 同口径。
/// - **U-4** 今日三件用完整集合覆盖（弹层内取消 + 替换一次提交）。
///
/// 不落用例（如实）：**P3-4** 是「重活移出主线程」的性能项，除
/// `buildSnapshotBodyOffMainThread` 的成功路径外无可断言的行为差异，以代码审查交付。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  final docs = Directory.systemTemp.createTempSync('yt_v315_').path;
  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  const widgetCh = MethodChannel('com.example.todolist/widget_refresh');
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const authCh = MethodChannel('plugins.flutter.io/local_auth');

  // 应用锁三态探测值：硬件能力 / 已录入生物识别 / 有锁屏密码。
  // P1-1（v3.1.5 审计）：三者必须能分叉，否则复现不出自锁死路。
  var bioHardware = false;
  var bioEnrolled = false;
  var deviceCredential = false;
  // authenticate 的行为：{'ok': true}=成功 / 默认取消 / {'notAvailable': true}=本机无凭据。
  var authResult = <String, dynamic>{'ok': false};
  var caseSeq = 0;
  late String caseDocs;
  late _ThrowingStore store;

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(notifCh, (call) async => null);
    messenger.setMockMethodCallHandler(widgetCh, (call) async => null);
    messenger.setMockMethodCallHandler(secureCh, (call) async => null);
    messenger.setMockMethodCallHandler(authCh, (call) async {
      switch (call.method) {
        // P1-1（v3.1.5 审计）：测试环境里 `LocalAuthPlatform.instance` 是
        // `DefaultLocalAuthPlatform`，`canCheckBiometrics`
        // （= `deviceSupportsBiometrics()`）并不是独立的方法调用，而是由
        // `getAvailableBiometrics` **推导**出来的：非空即有硬件。它还会把
        // `'undefined'` 这个「有硬件但未录入」的哨兵值过滤掉（见
        // `getEnrolledBiometrics`），正好是我们要的三态之一。因此这里不 mock
        // `canCheckBiometrics`（那条分支永远不会被命中），改由下面的哨兵值表达。
        case 'isDeviceSupported':
          return bioEnrolled || deviceCredential;
        case 'getAvailableBiometrics':
          if (bioEnrolled) return <String>['fingerprint'];
          if (bioHardware) return <String>['undefined'];
          return <String>[];
        case 'authenticate':
          if (authResult['notAvailable'] == true) {
            throw PlatformException(
                code: 'NotAvailable', message: 'No authentication available');
          }
          return authResult['ok'] == true;
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
    bioHardware = false;
    bioEnrolled = false;
    deviceCredential = false;
    authResult = <String, dynamic>{'ok': false};
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

  String todayKey() {
    final now = DateTime.now();
    String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
    return '${p(now.year, 4)}-${p(now.month)}-${p(now.day)}';
  }

  // ══════════════════════════════════════════════════════════════════
  // P1-1 / U-1：应用锁可用性 = 「现在能验证」，不是「有硬件」
  // ══════════════════════════════════════════════════════════════════

  group('P1-1 应用锁可用性判定', () {
    test('有硬件但未录入 + 无锁屏密码 → 不可开启，且解锁页出口可见', () async {
      bioHardware = true; // canCheckBiometrics=true（旧实现据此判「可用」）
      bioEnrolled = false;
      deviceCredential = false; // isDeviceSupported=false
      final lock = AppLockProvider();
      await lock.load();

      expect(lock.hasBiometricHardware, isTrue);
      expect(lock.canAuthenticate, isFalse, reason: 'P1-1 根因：硬件能力 ≠ 可验证凭据');
      expect(lock.biometricAvailable, isFalse, reason: '旧字段语义已修正');
      expect(lock.hasEnrolledBiometrics, isFalse);
      expect(lock.credentialLabel, '无可用验证方式');
      expect(await lock.setEnabled(true), isFalse,
          reason: '门槛必须拦住「开了就锁死」的设备');
      expect(lock.appLockEnabled, isFalse);
      expect(lock.unlockEscapeVisible, isTrue,
          reason: '无任何凭据时解锁页必须留出口（否则唯一出路是清数据）');
    });

    test('仅有锁屏密码 → 可开启，文案为锁屏密码而不是生物识别', () async {
      bioHardware = true;
      bioEnrolled = false;
      deviceCredential = true;
      final lock = AppLockProvider();
      await lock.load();

      expect(lock.canAuthenticate, isTrue);
      expect(lock.hasEnrolledBiometrics, isFalse);
      expect(lock.credentialLabel, '锁屏密码');
      expect(await lock.setEnabled(true), isTrue);
      expect(lock.unlockEscapeVisible, isFalse,
          reason: '有可用凭据时不得给出「关闭应用锁」入口（否则两键即绕过）');
    });

    // P2-1（v3.1.6 审计）口径修正：旧用例断言「一次 NotAvailable 异常就
    // 粘滞置位 authUnavailable + 放出出口」，正是报告点名的绕过面来源。
    // 现在 authenticateDetailed 会重新探测：探测仍判可验证时按「瞬时故障」
    // 处理，不放宽出口；探测确认无凭据的死路由 v316 审计用例覆盖。
    test('瞬时 NotAvailable 但重新探测仍可验证 → 不得放出关闭出口', () async {
      bioHardware = true;
      bioEnrolled = false;
      deviceCredential = true; // isDeviceSupported=true：只是传感器瞬时故障
      authResult = <String, dynamic>{'notAvailable': true};
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('app_lock_enabled', true);
      final lock = AppLockProvider();
      await lock.load();
      expect(lock.unlockEscapeVisible, isFalse);

      final r = await lock.authenticateDetailed(reason: '测试');
      expect(r.verified, isFalse);
      expect(r.unavailableConfirmed, isFalse,
          reason: '取消 / 瞬时异常不得被当成「本机无凭据」');
      expect(lock.authUnavailable, isFalse);
      expect(lock.unlockEscapeVisible, isFalse,
          reason: 'P2-1：探测仍可用时出口必须隐藏，避免「取消验证」绕过');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-1：安全模式导出的「双向」护栏
  // ══════════════════════════════════════════════════════════════════

  group('P2-1 安全模式导出护栏', () {
    testWidgets('导出前必须显式确认；默认取消不产出文件', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ));
      final future = confirmSafeModeExport(ctx, ['任务', '习惯']);
      await tester.pumpAndSettle();
      expect(find.text('当前处于只读安全模式'), findsOneWidget);
      expect(find.textContaining('任务、习惯'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await future, isFalse, reason: '默认不得把示例数据当成备份导出');
    });

    testWidgets('恢复端识别 safeMode 标记 → 再拦一次', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ));

      final flagged = confirmPartialRestore(ctx, {
        'safeMode': true,
        'partial': ['任务'],
      });
      await tester.pumpAndSettle();
      expect(find.text('这份备份可能不含真实数据'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await flagged, isFalse);

      // 普通备份不弹（否则每次恢复都多一层噪音）。
      final normal = confirmPartialRestore(ctx, {'tasks': <dynamic>[]});
      await tester.pumpAndSettle();
      expect(find.text('这份备份可能不含真实数据'), findsNothing);
      expect(await normal, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-2：外部重写 prefs 后设置签名必须失效
  // ══════════════════════════════════════════════════════════════════

  group('P2-2 设置签名失效', () {
    test('外部改写 prefs + load() + 把设置改回旧值 → 必须落盘', () async {
      final sp = await seedPrefs();
      final p = TaskProvider();
      await p.load();
      expect(p.notificationsEnabled, isFalse);

      // 第 1 步：正常打开通知（写盘成功，签名 = 「true 快照」）。
      await p.setNotificationsEnabled(true);
      expect(sp.getBool('notifications_enabled'), isTrue);

      // 第 2 步：模拟 applyAppPrefs（恢复备份）直接写 prefs，再 load()。
      await sp.setBool('notifications_enabled', false);
      await p.load();
      expect(p.notificationsEnabled, isFalse);

      // 第 3 步：用户改回 true——旧实现签名仍命中「true 快照」而整轮跳过。
      await p.setNotificationsEnabled(true);
      expect(sp.getBool('notifications_enabled'), isTrue,
          reason: 'P2-2：load() 必须刷新签名，否则改动只在内存里，重启回弹');
    });

    test('反向：load() 之后未变更的偏好仍被整轮跳过（不白写 28 个键）', () async {
      await seedPrefs();
      final p = TaskProvider();
      await p.load();
      // 前提：磁盘值与构造器默认值不同（false / 30 vs true / 10），
      // 所以签名若仍是「构造器默认快照」，下面这次 setter 必然误判为有变更。
      expect(p.notificationsEnabled, isFalse);
      expect(p.snoozeMinutes, 30);

      // 任何一次写盘都会打在会抛错的 store 上，从而把「误判」放大成失败。
      store.throwOnSet = true;
      await p.setBriefingEvening(enabled: true, hour: 22, minute: 0);
      expect(p.briefingEveningHour, 22);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-3：关「同时恢复设置」时 legacy 开关不得被覆盖
  // ══════════════════════════════════════════════════════════════════

  group('P2-3 恢复范围', () {
    test('applyLegacyToggles=false → 通知 / 声音保持本机值', () async {
      const payload = '{"version":3,"app":"有条","tasks":[],'
          '"notifications_enabled":false,"sound_enabled":false}';
      final p = TaskProvider();
      await p.restoreFromJson(payload, applyLegacyToggles: false);
      expect(p.notificationsEnabled, isTrue,
          reason: '本机未关通知，备份里的 false 不得生效（旧实现无条件覆盖）');
      expect(p.soundEnabled, isTrue);

      final q = TaskProvider();
      await q.restoreFromJson(payload, applyLegacyToggles: true);
      expect(q.notificationsEnabled, isFalse, reason: '显式选择恢复设置时才迁移');
      expect(q.soundEnabled, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-1：retryLoad 期间每日重置必须落库
  // ══════════════════════════════════════════════════════════════════

  group('P3-1 retryLoad 与每日重置', () {
    test('昨日完成的每天重复任务，retryLoad 后 DB 里必须已重置', () async {
      await seedPrefs();
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final t = Task(
        id: '1',
        title: '喝水',
        priority: Priority.medium,
        category: Category.life,
        repeat: RepeatType.daily,
        status: TaskStatus.done,
        completedAt: yesterday,
      );
      await LocalDatabase.instance.replaceTasks([t], []);

      final p = TaskProvider();
      p.markDbLoadFailedForTest();
      expect(await p.retryLoad(), isTrue);

      final rows = await LocalDatabase.instance.loadTasks();
      expect(rows.single.done, isFalse,
          reason: 'P3-1：重置走 _persistTasksOnly，不能再被「加载期拒写」闸拦下');
      expect(p.tasks.single.done, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-2：设置读取失败期间的「假成功」
  // ══════════════════════════════════════════════════════════════════

  group('P3-2 设置假成功回执', () {
    test('设置读取失败期间 setter 不落盘，但留下脏标记供确认框提示', () async {
      final sp = await seedPrefs();
      // 过期静音键会让 _loadSettings 走 await prefs.remove(...)，用可抛错的
      // store 模拟「设置读取中途平台通道异常」。
      await sp.setString('reminders_muted_until',
          DateTime.now().subtract(const Duration(days: 1)).toIso8601String());
      store.throwOnRemove = true;
      final p = TaskProvider();
      await expectLater(p.load(), throwsA(anything));
      expect(p.settingsLoadFailed, isTrue);
      expect(p.hasUnsavedSettingsEdits, isFalse);

      await p.setNotificationsEnabled(true);
      expect(sp.getBool('notifications_enabled'), isFalse,
          reason: '读取失败期间绝不能把内存值写回 prefs');
      expect(p.hasUnsavedSettingsEdits, isTrue,
          reason: 'P3-2：拒绝写回必须留痕，否则重试加载会静默丢弃这些修改');
      expect(p.hasUnsavedSafeModeEdits, isTrue,
          reason: '重试前的确认框要能覆盖「只改了设置」的情况');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-3：当日快照完整性（0 字节不得锁死当天）
  // ══════════════════════════════════════════════════════════════════

  group('P3-3 当日快照完整性', () {
    test('0 字节的当日快照 → 标记 .stale 并重写', () async {
      final sp = await seedPrefs();
      final key = todayKey();
      await sp.setString('last_auto_backup_date', key);
      await LocalDatabase.instance.replaceTasks([mk('1')], []);
      final dir = Directory('$caseDocs/backup/auto')
        ..createSync(recursive: true);
      final bad = File('${dir.path}/$key.json')..writeAsStringSync('');

      final p = TaskProvider();
      await p.load();
      await p.triggerAutoBackup();

      expect(File('${bad.path}.stale').existsSync(), isTrue,
          reason: '废快照要改名，不能再出现在恢复列表里');
      final good = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json') && !f.path.endsWith('.stale'))
          .toList();
      expect(good, hasLength(1));
      expect(good.single.lengthSync(), greaterThan(512),
          reason: 'P3-3：旧实现只按文件名判「今天已备」，当天再也不会补备');
      expect(jsonDecode(good.single.readAsStringSync())['tasks'], isA<List>());
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-5：加密缺口令时不得重跑重活
  // ══════════════════════════════════════════════════════════════════

  group('P3-5 isolate 回退收窄', () {
    test('加密但缺口令 → 直接抛业务异常，不回退主 isolate 重跑', () async {
      final before = buildSnapshotMainIsolateFallbacks;
      await expectLater(
        buildSnapshotBodyOffMainThread(
            <String, dynamic>{'version': 3, 'app': '有条'}, const [], 0, true,
            null, 1 << 20),
        throwsA(isA<BackupEncryptException>()),
      );
      expect(buildSnapshotMainIsolateFallbacks, before,
          reason: 'P3-5：业务异常不得触发「重跑全部附件读取」的回退');
      // 同步单一真源本身也必须抛（旧实现回退时正是重跑它才二次踩坑）。
      expect(
        () => buildSnapshotBodySync(
            <String, dynamic>{'version': 3}, const [], 0, true, '', 1 << 20),
        throwsA(isA<BackupEncryptException>()),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-6：首启示例落盘失败不置 seeded
  // ══════════════════════════════════════════════════════════════════

  group('P3-6 首启示例预置', () {
    test('落盘失败不置 seeded，下次启动仍会预置', () async {
      final sp = await SharedPreferences.getInstance();
      // SharedPreferences 是进程内单例，缓存不随 store 替换而清空；前序用例
      // 写过 samples_seeded_v1=true，这里必须显式抹掉才是「全新安装」。
      await sp.remove('samples_seeded_v1');
      LocalDatabase.failNextReplaceTasks = true;
      final p = TaskProvider();
      await p.load();
      expect(p.tasks, hasLength(7), reason: '本会话仍能看到示例');
      expect(sp.getBool('samples_seeded_v1'), isNull,
          reason: 'P3-6：写库失败却置位 → 示例永久消失且无安全模式提示');

      final p2 = TaskProvider();
      await p2.load();
      expect(await LocalDatabase.instance.loadTasks(), hasLength(7),
          reason: '第二次启动必须重新尝试预置并落库');
      expect(sp.getBool('samples_seeded_v1'), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-7：自动备份警告跨重启保留
  // ══════════════════════════════════════════════════════════════════

  group('P3-7 自动备份警告持久化', () {
    // P3-2（v3.1.6 审计）口径修正：旧用例只往 prefs 写一条含「剥离附件」
    // 的错误串就断言副标题带「不含附件」，把「靠错误串猜形态」这个缺陷
    // 编码成了正确行为。现在标注由**真实文件名**推导，且日期不被错误盖掉。
    test('旧 .noattach 快照（无错误串）重启后仍标注「不含附件」+ 日期', () async {
      final sp = await seedPrefs();
      final key = todayKey();
      await sp.setString('last_auto_backup_date', key);
      // 刻意不写 last_auto_backup_error：模拟旧版本写的快照 / 错误键丢失。
      final dir = Directory('$caseDocs/backup/auto')
        ..createSync(recursive: true);
      File('${dir.path}/$key.noattach.json').writeAsStringSync(jsonEncode({
        'version': 3,
        'tasks': <dynamic>[],
        'pad': 'x' * 400, // 越过 _kMinSnapshotBytes 下限
      }));

      final p = TaskProvider();
      await p.load();
      expect(p.lastAutoBackupNoAttach, isTrue);
      expect(p.lastAutoBackupLabel, contains('不含附件'),
          reason: 'P3-2：不能只靠错误串推断附件形态');
      expect(p.lastAutoBackupLabel, contains('最近快照：'),
          reason: 'P3-2：日期必须与状态同列，不能被错误分支盖掉');
      expect(p.autoBackupSubtitle, contains(key));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // U-3 / U-4：录入截断口径与今日三件
  // ══════════════════════════════════════════════════════════════════

  group('U-3 快速录入截断口径', () {
    test('中间插入按字素簇计额度（与 TextField maxLength 同口径）', () {
      final six = '😀' * 6;
      final r = QuickEntrySheet.mergeClipboardText(
        'abcdef',
        const TextSelection(baseOffset: 2, extentOffset: 4),
        six,
        maxLength: 10,
      );
      expect(r.truncated, isFalse);
      expect(r.text, 'ab$six' 'ef');
      expect(r.text.characters.length, 10);

      final r2 = QuickEntrySheet.mergeClipboardText(
        'abcdef',
        const TextSelection(baseOffset: 2, extentOffset: 4),
        '😀' * 10,
        maxLength: 10,
      );
      expect(r2.truncated, isTrue);
      expect(r2.text.characters.length, 10,
          reason: 'U-3：旧实现按 UTF-16 截，500 字额度下粘贴只能放 250 个 emoji');
      expect(r2.text.startsWith('ab'), isTrue);
    });
  });

  group('U-4 今日三件', () {
    test('完整集合覆盖：弹层内取消一件并换选另一件，一次提交成功', () async {
      final p = await buildWith([mk('a'), mk('b'), mk('c')]);
      expect(await p.setTodayMit(['a', 'b']), isTrue);
      expect(p.todayMit, ['a', 'b']);

      // 弹层提交的就是「完整集合」：保留 a、取消 b、换选 c。
      expect(await p.setTodayMit(['a', 'c']), isTrue);
      expect(p.todayMit, ['a', 'c']);
      expect(p.isTodayMit('b'), isFalse);
      expect(p.selectableMitTasks().map((t) => t.id),
          containsAll(<String>['a', 'b', 'c']),
          reason: '候选池必须包含已选项，否则弹层里无法取消它');
    });
  });
}

class _ThrowingStore extends InMemorySharedPreferencesStore {
  _ThrowingStore() : super.empty();
  bool throwOnRemove = false;
  bool throwOnSet = false;

  @override
  Future<bool> remove(String key) async {
    if (throwOnRemove) throw PlatformException(code: 'prefs_io_error');
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (throwOnSet) throw PlatformException(code: 'prefs_write_error');
    return super.setValue(valueType, key, value);
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
