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
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart' show lightTheme;
import 'package:todolist/widgets/quick_entry_sheet.dart';
import 'package:todolist/widgets/sheet_message.dart';

import 'test_helpers.dart';

/// v3.1.7 审计修复轮回归测试（《有条功能与操作审计报告（v3.1.7）》）。
///
/// 覆盖清单（11 项）：
/// - **P1-1** 开启加密「先写后删 + 读回校验」：自动备份关闭 / 安全模式 /
///   缺口令时不删任何明文且如实回执；健康路径确实产出可解密的新快照后才删。
/// - **P2-1** 错误「过期」基准改为今天；设置页文案与首页横幅不再叠前缀。
/// - **P2-2** 弹层宿主横向推广的公共入口（失败文案自动判色 / 无 host 回退）。
/// - **P2-3** 自动备份状态单一真源不再把降级 warning 写成「上次失败」。
/// - **P3-2** `enqueue` 的排队消息在路由恢复 current 后自动 flush。
/// - **P3-3** 额度为 0 时区分「有选区 / 无选区」并回报 rejected。
/// - **U-2** 消息条贴底且非交互态点穿。
/// - **U-3** 未设 backgroundColor 的失败提示也用 error 色。
///
/// 不落用例（如实，靠代码审查）：**P3-1**（`_switchTab(5)` 在 main.dart
/// 私有 State 内）、**U-1**（`_confirmDisableLock` 私有静态方法 + 平台验证）、
/// **U-4**（`_loadVersion` 私有方法 + asset bundle 在宿主测试不可读）、
/// **P2-2 六个弹层的挂宿主**（需完整 Provider / 平台通道脚手架）、
/// **P3-3 的 UI 文案**（`_pasteFromClipboard` 私有方法）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  final docs = Directory.systemTemp.createTempSync('yt_v317_').path;
  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  const widgetCh = MethodChannel('com.example.todolist/widget_refresh');
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  var caseSeq = 0;
  late String caseDocs;

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(notifCh, (call) async => null);
    messenger.setMockMethodCallHandler(widgetCh, (call) async => null);
    messenger.setMockMethodCallHandler(secureCh, (call) async => null);
  });

  setUp(() async {
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    // 🔴 SharedPreferences 是进程内单例：换 store 不清缓存，必须显式抹键。
    final sp = await SharedPreferences.getInstance();
    for (final k in sp.getKeys().toList()) {
      await sp.remove(k);
    }
    NotificationService.instance.enabled = false;
    NotificationService.remindersMutedUntil = null;
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

  Directory preRestoreDir() => Directory('$caseDocs/backup/pre-restore')
    ..createSync(recursive: true);

  /// 一份 ≥256 字节、可被 _snapshotFileUsable 判为可用的明文快照。
  String validPlainSnapshot() => jsonEncode({
        'version': 3,
        'tasks': <dynamic>[],
        'pad': 'x' * 400,
      });

  File writePlain(String path) =>
      File(path)..writeAsStringSync(validPlainSnapshot());

  /// 挂一个固定尺寸的 host，供消息条几何 / 颜色断言使用。
  Future<BuildContext> pumpHost(
    WidgetTester tester, {
    GlobalKey<SheetMessageHostState>? key,
  }) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: SheetMessageHost(
              key: key,
              child: Builder(builder: (c) {
                ctx = c;
                return const SizedBox.expand();
              }),
            ),
          ),
        ),
      ),
    ));
    return ctx;
  }

  // ═══════════════════ P1-1 加密清理先写后删 ═══════════════════

  group('P1-1 开启加密不得删光最后一份副本', () {
    test('自动备份关闭时选「删除旧明文」→ 一份都不删、回执如实', () async {
      await seedPrefs();
      final plain = writePlain('${autoDir().path}/2026-01-01.json');
      final rollback = writePlain(
          '${preRestoreDir().path}/pre-restore-20260101-120000.json');

      final p = TaskProvider();
      await p.load();
      await p.setAutoBackupPassphrase('pass12345');
      await p.setAutoBackupEnabled(false);

      final r = await p.setAutoBackupEncrypt(true, purgePlaintext: true);
      expect(r.ok, isTrue);
      expect(r.snapshotWritten, isFalse,
          reason: '自动备份关闭时 _autoBackupIfNeeded 第一行即返回，写不出新快照');
      expect(r.purged, isFalse);
      expect(r.removed, 0);
      expect(r.note, contains('未清理'));
      expect(plain.existsSync(), isTrue,
          reason: '旧实现先删后写，此处会把唯一可恢复副本全部删光');
      expect(rollback.existsSync(), isTrue);
      expect(await p.countPlaintextSnapshots(), 2);
      expect(p.autoBackupEncrypt, isTrue,
          reason: '开关本身仍应生效，只是不执行不可逆清理');
    });

    test('数据源不健康（安全模式）时同样保留旧明文', () async {
      await seedPrefs();
      final plain = writePlain('${autoDir().path}/2026-01-01.json');
      final p = TaskProvider();
      await p.load();
      await p.setAutoBackupPassphrase('pass12345');
      p.markDbLoadFailedForTest();
      expect(p.snapshotSourcesHealthy, isFalse);

      final r = await p.setAutoBackupEncrypt(true, purgePlaintext: true);
      expect(r.snapshotWritten, isFalse);
      expect(r.purged, isFalse);
      expect(r.note, contains('未清理'));
      expect(plain.existsSync(), isTrue);
    });

    test('缺口令时直接拒绝开启，不触碰任何明文', () async {
      await seedPrefs();
      final plain = writePlain('${autoDir().path}/2026-01-01.json');
      final p = TaskProvider();
      await p.load();

      final r = await p.setAutoBackupEncrypt(true, purgePlaintext: true);
      expect(r.ok, isFalse);
      expect(r.purged, isFalse);
      expect(plain.existsSync(), isTrue);
    });

    test('健康路径：新加密快照可解密且含 tasks，之后才清理旧明文',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      final sp = await seedPrefs();
      await sp.setString('last_auto_backup_date', dateKey());
      await LocalDatabase.instance.replaceTasks([mk('1')], []);
      final auto = autoDir();
      final plain = writePlain('${auto.path}/2026-01-01.json');

      final p = TaskProvider();
      await p.load();
      await p.setAutoBackupPassphrase('pass12345');

      final r = await p.setAutoBackupEncrypt(true, purgePlaintext: true);
      expect(r.ok, isTrue);
      expect(r.snapshotWritten, isTrue,
          reason: '必须先写出并读回校验通过，才允许删除历史明文');
      expect(r.purged, isTrue);
      expect(r.removed, greaterThanOrEqualTo(1));
      expect(plain.existsSync(), isFalse);

      final enc = auto
          .listSync()
          .whereType<File>()
          .where((f) =>
              f.path.contains(dateKey()) && f.path.endsWith('.enc.json'))
          .toList();
      expect(enc, isNotEmpty, reason: '当日必须真的留下一份加密快照');
      final raw = enc.single.readAsStringSync();
      expect(isEncryptedEnvelope(raw), isTrue);
      final decoded = jsonDecode(decryptEnvelope(raw, 'pass12345'));
      expect(decoded['tasks'], isA<List>());
    });
  });

  // ═══════════════════ P2-1 / P2-3 自动备份状态真源 ═══════════════════

  group('P2-1 失败「过期」基准改为今天', () {
    test('今天失败 + 最近成功是昨天 → 判为现行异常、首页横幅可达', () async {
      final sp = await seedPrefs();
      await sp.setString(
          'last_auto_backup_date',
          dateKey(DateTime.now().subtract(const Duration(days: 1))));
      await sp.setString('last_auto_backup_error', '自动备份失败：磁盘满');
      await sp.setString('last_auto_backup_error_date', dateKey());

      final p = TaskProvider();
      await p.load();
      expect(p.lastAutoBackupErrorIsStale, isFalse,
          reason: '旧实现拿「最近成功日期」当基准，今天的失败被判 stale');
      expect(p.autoBackupHasFailure, isTrue,
          reason: 'P2-1：横幅在「今天失败」时必须渲染');
      expect(p.autoBackupStatusNote, contains('自动备份异常'));
      expect(p.autoBackupStatusNote, isNot(contains('上次')));
    });

    test('从未成功过 + 今天失败 → 横幅判据仍为 true', () async {
      final sp = await seedPrefs();
      await sp.setString('last_auto_backup_error', '自动备份失败：写入被拒绝');
      await sp.setString('last_auto_backup_error_date', dateKey());

      final p = TaskProvider();
      await p.load();
      expect(p.lastAutoBackupErrorIsStale, isFalse,
          reason: '旧实现 `d == null` 直接返回 true，横幅恒不可达');
      expect(p.autoBackupHasFailure, isTrue);
    });

    test('跨日残留的旧失败仍标「上次」且不触发告警', () async {
      final sp = await seedPrefs();
      await sp.setString('last_auto_backup_error', '自动备份失败：缺口令');
      await sp.setString('last_auto_backup_error_date',
          dateKey(DateTime.now().subtract(const Duration(days: 1))));

      final p = TaskProvider();
      await p.load();
      expect(p.lastAutoBackupErrorIsStale, isTrue);
      expect(p.autoBackupHasFailure, isFalse);
      expect(p.autoBackupStatusNote, contains('上次自动备份异常'));
      expect(p.autoBackupStatusNote, isNot(contains('每日自动备份失败：')),
          reason: 'P2-1：状态真源不得叠加横幅前缀，否则出现两层「失败」');
    });
  });

  group('P2-3 备份面板状态真源', () {
    test('降级 warning 的副标题自相矛盾已消除', () async {
      final sp = await seedPrefs();
      await sp.setString('last_auto_backup_date', dateKey());
      await sp.setString('last_auto_backup_error_date', dateKey());
      await sp.setString('last_auto_backup_error',
          '自动备份已剥离附件（数据体积超限），任务/习惯/专注数据完整');

      final p = TaskProvider();
      await p.load();
      final subtitle = p.autoBackupSubtitle;
      expect(subtitle, isNot(contains('上次失败')),
          reason: '旧备份面板硬加「上次失败：」会拼出「上次失败：…数据完整」');
      expect(subtitle, contains('数据完整'));
      expect(subtitle, contains('最近快照：'));
      expect(p.autoBackupHasFailure, isFalse);
    });
  });

  // ═══════════════════ P2-2 / P3-2 / U-2 / U-3 弹层消息 ═══════════════════

  group('P3-2 弹层消息队列有消费通道', () {
    testWidgets('普通对话框覆盖时 enqueue 的消息在路由恢复后自动显示',
        (tester) async {
      final key = GlobalKey<SheetMessageHostState>();
      await pumpHost(tester, key: key);
      expect(find.text('被遮住的校验失败'), findsNothing);

      // 模拟 _dispatch 在「无进度层 + 被更高路由覆盖」分支压入队列。
      key.currentState!.enqueue('被遮住的校验失败');
      await tester.pump();
      await tester.pump();

      expect(find.text('被遮住的校验失败'), findsOneWidget,
          reason: '旧实现唯一消费者是 backup_sheet 进度层 flush，其余消息滞留到 host 销毁');
    });
  });

  group('U-2 消息条不再压住弹层顶部控件', () {
    testWidgets('消息条贴底、且无操作按钮时点击可穿透', (tester) async {
      final ctx = await pumpHost(tester);
      showSheetSnackBar(ctx, const SnackBar(content: Text('仅展示的提示')));
      await tester.pump();

      final banner = find.byKey(const Key('sheet-message'));
      expect(banner, findsOneWidget);
      final hostRect = tester.getRect(find.byType(SheetMessageHost));
      final bannerRect = tester.getRect(banner);
      expect(bannerRect.top, greaterThan(hostRect.top + hostRect.height / 2),
          reason: '旧实现 Positioned(top: 0) 压住标题与拖拽手柄');
      expect(bannerRect.bottom, lessThanOrEqualTo(hostRect.bottom));
      expect(
        find.ancestor(
          of: banner,
          matching: find.byWidgetPredicate(
              (w) => w is IgnorePointer && w.ignoring),
        ),
        findsOneWidget,
        reason: '非交互消息条必须点穿，避免拦住下层点击',
      );
      expect(find.byType(GestureDetector), findsNothing,
          reason: '点穿态不应留下点不到的关闭按钮');
    });
  });

  group('U-3 失败色判定', () {
    test('失败 / 校验类文案自动判 error；成功文案保持中性', () {
      expect(sheetMessageLooksLikeError('套用失败：模板未保存'), isTrue);
      expect(sheetMessageLooksLikeError('请输入 0 - 3650 之间的天数'), isTrue);
      expect(sheetMessageLooksLikeError('模板保存失败：请检查存储空间后重试'),
          isTrue);
      expect(sheetMessageLooksLikeError('保存失败：磁盘已满'), isTrue);
      expect(sheetMessageLooksLikeError('已套用「清单」，新增 3 条任务'), isFalse);
      expect(sheetMessageLooksLikeError('已保存到相册 · Pictures/有条'), isFalse);
    });

    testWidgets('未设 backgroundColor 的失败提示也用 error 色', (tester) async {
      final ctx = await pumpHost(tester);
      showSheetSnackBar(ctx,
          const SnackBar(content: Text('模板保存失败：请检查存储空间后重试')));
      await tester.pump();

      final container =
          tester.widget<Container>(find.byKey(const Key('sheet-message')));
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, lightTheme.colorScheme.errorContainer,
          reason: '旧实现按 snackBar.backgroundColor != null 判定，恒为 inverseSurface');
    });

    testWidgets('显式 isError: false 仍可覆盖自动判定', (tester) async {
      final ctx = await pumpHost(tester);
      showSheetSnackBar(ctx,
          const SnackBar(content: Text('保存失败：磁盘已满')),
          isError: false);
      await tester.pump();
      final container =
          tester.widget<Container>(find.byKey(const Key('sheet-message')));
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, lightTheme.colorScheme.inverseSurface);
    });
  });

  group('P2-2 统一消息入口的兼容性', () {
    testWidgets('无 host 时仍退回原生 SnackBar（新增弹层忘挂宿主不丢消息）',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: lightTheme,
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          }),
        ),
      ));
      showSheetSnackBar(ctx, const SnackBar(content: Text('页面级失败提示')));
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byKey(const Key('sheet-message')), findsNothing);
    });
  });

  // ═══════════════════ P3-3 粘贴额度为 0 ═══════════════════

  group('P3-3 额度为 0 时如实回报', () {
    test('原文已达上限且无选区 → rejected，原文一字不动', () {
      final current = 'Q' * 500;
      final r = QuickEntrySheet.mergeClipboardText(
        current,
        const TextSelection.collapsed(offset: 200),
        'more',
      );
      expect(r.rejected, isTrue);
      expect(r.hadSelection, isFalse);
      expect(r.truncated, isTrue);
      expect(r.text, current);
    });

    test('原文已达上限但有选区 → 选区可替换，不算 rejected', () {
      final current = 'Q' * 500;
      final r = QuickEntrySheet.mergeClipboardText(
        current,
        const TextSelection(baseOffset: 100, extentOffset: 200),
        'more',
      );
      expect(r.hadSelection, isTrue);
      expect(r.rejected, isFalse,
          reason: '替换 100 字选区可腾出额度，粘贴内容应能插入');
      expect(r.text, '${'Q' * 100}more${'Q' * 300}');
    });

    test('超长原文 + 选区 → rejected 与 hadSelection 同时成立', () {
      final current = 'Q' * 520;
      final r = QuickEntrySheet.mergeClipboardText(
        current,
        const TextSelection(baseOffset: 5, extentOffset: 15),
        'more',
      );
      expect(r.rejected, isTrue);
      expect(r.hadSelection, isTrue);
      expect(r.text, current,
          reason: '此边界对应 UI 的「选中的文字也未被替换」回执');
    });

    test('有余量时选区被替换、且粘贴内容首尾空白不被吞掉', () {
      final r = QuickEntrySheet.mergeClipboardText(
        'AB',
        const TextSelection.collapsed(offset: 1),
        '\n  缩进内容  \n',
        maxLength: 500,
      );
      expect(r.text, 'A\n  缩进内容  \nB',
          reason: '锁定「正文不 trim」契约；UI 层不再对剪贴板整体 trim');
      expect(r.rejected, isFalse);
      expect(r.truncated, isFalse);
    });
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
