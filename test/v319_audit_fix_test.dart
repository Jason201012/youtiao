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
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/ui_durations.dart';
import 'package:todolist/widgets/sheet_message.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';

import 'test_helpers.dart';

/// v3.1.9 审计修复轮（《有条功能与操作审计报告（v3.1.9）》）回归测试。
///
/// 每条修复至少一个「能区分修与未修」的用例；不落用例的项见文件尾说明。
///
/// 覆盖清单：
/// - **P2-1** 进度层进出事件（自动锁暂停 / 恢复的唯一信号源）：计数翻转 +
///   监听方按次回调 + 退订后不再回调；
/// - **P2-2** 改名不再静默取消「稍后提醒」：服务层 `cancel(keepSnooze: true)`
///   不撤 snooze 段、`rebuildPendingSnooze` 按新标题同落点重排；provider 层
///   `updateTask` 仅改标题时端到端不产生 snooze 段 cancel；
/// - **P3-4** 弹层内撤销条 FIFO：连续两条各保留、点「撤销」立即消散且只执行一次；
/// - **P3-5** 原子写残片清理：过期 `.tmp.<hex>` 被清扫、在途（1 分钟内）不被误删、
///   本次写入不留残余；
/// - **P3-6** 今日三件候选池的已选项不受搜索词过滤；
/// - **P3-3** 应用锁开关落盘失败：不抛异常、仍通知、内存生效并标记「未保存」；
/// - **U-3** 口令强度：汉字长口令 / 16 位多符号口令通过，低多样性长串仍判弱。
///
/// 不落用例（如实）：
/// - **P2-1 自动锁 widget 行为**（开 1 分钟空闲锁 → 进度层期间推进 61 秒不锁 →
///   收起后推进 61 秒锁）——需要挂载完整 `MainScaffold`（七个 provider +
///   通知/安全窗口通道），与仓库既有「timer 型 widget 用例不落回归」口径一致；
///   这里钉死其唯一信号源（进度层监听 + `sheetProgressActive`），锁定判定本身
///   由 `_onIdleTimeout` 的显式守卫承担；
/// - **P2-1 软键盘探针**（焦点 + `textEditingValue` 轮询）——依赖真实 IME 与
///   焦点树，headless 环境无法复现「软键盘不算按键事件」的原始缺陷；
/// - **P3-1 首页分区内边距**——纯 sliver 布局，需要对 HomeScreen 做整页挂载；
/// - **P3-2 `_writeAutoBackup` 的 degraded/warning 分离**——入口为私有方法，
///   构造「isolate 回退」与「附件剥离」两种快照需要真实附件与路径桩，成本远高于
///   收益；判定点（`written.degraded`）与三处消费都已在代码里单点收口。
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
    // 内存库 / prefs 都是进程内共享单例，每个用例前必须重置。
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    NotificationService.instance.enabled = true;
    NotificationService.remindersMutedUntil = null;
  });

  // ── 脚手架 ────────────────────────────────────────────────────────

  Future<void> drain() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  int? argsIdOf(MethodCall c) =>
      c.arguments is Map ? (c.arguments as Map)['id'] as int? : null;

  int snoozeIdOf(String id) => 1900000000 + (int.parse(id) % 10000000);

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
    await drain();
    return p;
  }

  Task mk(
    String id, {
    String title = '任务',
    DateTime? due,
    TaskStatus status = TaskStatus.todo,
  }) =>
      Task(
        id: id,
        title: title,
        priority: Priority.medium,
        category: Category.work,
        dueDate: due,
        status: status,
      );

  // ═════════════════════ P2-1 进度层暂停自动锁 ═════════════════════

  group('P2-1 进度层进出事件', () {
    test('push/pop 翻转 sheetProgressActive 并按次通知监听方', () {
      var hits = 0;
      void listener() => hits++;
      addSheetProgressLayerListener(listener);
      expect(sheetProgressActive, isFalse);
      pushSheetProgressLayer();
      expect(sheetProgressActive, isTrue, reason: '进度层期间必须可判定');
      expect(hits, 1, reason: 'push 必须通知——自动锁据此撤销已挂定时器');
      popSheetProgressLayer();
      expect(sheetProgressActive, isFalse);
      expect(hits, 2, reason: 'pop 必须通知——自动锁据此按完整空闲时长重启');
      removeSheetProgressLayerListener(listener);
      pushSheetProgressLayer();
      popSheetProgressLayer();
      expect(hits, 2, reason: '退订后不得再收到回调（防跨页面悬浮引用）');
    });

    test('重复订阅只登记一次，pop 不会把计数打成负数', () {
      var hits = 0;
      void listener() => hits++;
      addSheetProgressLayerListener(listener);
      addSheetProgressLayerListener(listener);
      pushSheetProgressLayer();
      expect(hits, 1, reason: '同一监听方重复登记应只算一份');
      popSheetProgressLayer();
      popSheetProgressLayer(); // 多余的 pop 必须是安全的 no-op
      expect(sheetProgressActive, isFalse);
      expect(hits, 3, reason: '每次 pop 都通知，但计数已归零不再变负');
      removeSheetProgressLayerListener(listener);
    });
  });

  // ═════════════════════ P2-2 改名保留「稍后提醒」 ═════════════════════

  group('P2-2 改名不丢 snooze', () {
    test('cancel(keepSnooze: true) 不撤 snooze 段，默认 cancel 会撤', () async {
      final svc = NotificationService.instance;
      final t = mk('9201', title: '原名');
      expect(await svc.snoozeTaskReminder(t), isTrue);
      await drain();

      notifCalls.clear();
      await svc.cancel(t.id, keepSnooze: true);
      await drain();
      expect(
        notifCalls.any((c) =>
            c.method == 'cancel' && argsIdOf(c) == snoozeIdOf(t.id)),
        isFalse,
        reason: '保留 snooze 时绝不能撤该段（旧实现无条件撤且不重建）',
      );
      expect(
        notifCalls.any(
            (c) => c.method == 'cancel' && argsIdOf(c) == int.parse(t.id)),
        isTrue,
        reason: '截止提醒段仍要撤掉并重排',
      );

      notifCalls.clear();
      await svc.cancel(t.id);
      await drain();
      expect(
        notifCalls.any((c) =>
            c.method == 'cancel' && argsIdOf(c) == snoozeIdOf(t.id)),
        isTrue,
        reason: '默认语义不变：删除 / 完成等入口仍撤 snooze',
      );
    });

    test('rebuildPendingSnooze 按新标题在同一 snooze 段重排', () async {
      final svc = NotificationService.instance;
      final t = mk('9202', title: '旧标题');
      expect(await svc.snoozeTaskReminder(t), isTrue);
      await drain();
      await svc.cancel(t.id, keepSnooze: true);
      await drain();

      notifCalls.clear();
      final renamed = t.copyWith(title: '新标题');
      expect(await svc.rebuildPendingSnooze(renamed), isTrue);
      await drain();
      final zs = notifCalls.where((c) => c.method == 'zonedSchedule').toList();
      expect(zs.length, 1, reason: '同落点只重建一条');
      expect(argsIdOf(zs.single), snoozeIdOf(t.id), reason: '必须复用 snooze 独立段');
      expect(
        zs.single.arguments.toString().contains('新标题'),
        isTrue,
        reason: '通知文案必须烘焙新标题（旧实现保留的是旧标题）',
      );
    });

    test('无待发 snooze 时 rebuild 返回 false 且不产生任何调度', () async {
      final svc = NotificationService.instance;
      notifCalls.clear();
      expect(await svc.rebuildPendingSnooze(mk('9203')), isFalse);
      await drain();
      expect(notifCalls.where((c) => c.method == 'zonedSchedule'), isEmpty);
    });

    test('updateTask 仅改标题：端到端不撤 snooze 段', () async {
      final due = DateTime.now().add(const Duration(days: 2));
      final p = await buildWith([mk('9204', title: '旧标题', due: due)]);
      // restoreFromJson 会按备份里的 notifications_enabled=false 关掉通知总开关，
      // 后续 snooze 需要它开着（本条只测「改名是否撤 snooze」，与总开关无关）。
      NotificationService.instance.enabled = true;
      final t = p.byId('9204')!;
      expect(await NotificationService.instance.snoozeTaskReminder(t), isTrue);
      await drain();

      notifCalls.clear();
      expect(await p.updateTask(t.copyWith(title: '新标题')), isTrue);
      await drain();
      expect(
        notifCalls.any((c) =>
            c.method == 'cancel' && argsIdOf(c) == snoozeIdOf('9204')),
        isFalse,
        reason: '改名与提醒时刻无关，不得静默取消用户明确要求的 snooze',
      );
    });

    test('updateTask 改期 + 改名：仍按旧口径撤 snooze（用户重新定义了提醒）',
        () async {
      final due = DateTime.now().add(const Duration(days: 2));
      final p = await buildWith([mk('9205', title: '旧标题', due: due)]);
      NotificationService.instance.enabled = true;
      final t = p.byId('9205')!;
      expect(await NotificationService.instance.snoozeTaskReminder(t), isTrue);
      await drain();

      notifCalls.clear();
      await p.updateTask(t.copyWith(
          title: '新标题', dueDate: DateTime.now().add(const Duration(days: 5))));
      await drain();
      expect(
        notifCalls.any((c) =>
            c.method == 'cancel' && argsIdOf(c) == snoozeIdOf('9205')),
        isTrue,
        reason: '改期已重新定义提醒，撤销旧 snooze 属预期行为',
      );
    });
  });

  // ═════════════════════ P3-6 今日三件候选池 ═════════════════════

  group('P3-6 自选候选池', () {
    test('已选项（含已完成）不受搜索词过滤，仍出现在候选池', () async {
      final p = await buildWith([
        mk('9301', title: '写周报'),
        mk('9302', title: '买牛奶', status: TaskStatus.done),
      ]);
      final pool = p
          .selectableMitTasks(query: '周报', includeIds: {'9302'})
          .map((t) => t.id)
          .toList();
      expect(pool, contains('9301'));
      expect(pool, contains('9302'),
          reason: '满员提示承诺「均在下方列表」，已选项必须可见才能被取消');

      final none = p.selectableMitTasks(query: '周报');
      expect(none.map((t) => t.id).toList(), ['9301'],
          reason: '未选中的已完成任务仍应按 status + query 常规过滤');
    });
  });

  // ═════════════════════ P3-5 原子写残片清理 ═════════════════════

  group('P3-5 原子写残片', () {
    test('写入前清扫过期 .tmp 残片、不误删在途文件、成功后不留残余', () async {
      final dir = await Directory.systemTemp.createTemp('youtiao_v319_');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      PathProviderPlatform.instance = _FakePathProvider(dir.path);

      final stale = File('${dir.path}/old.json.tmp.deadbeef');
      await stale.writeAsString('可能是含附件的明文快照');
      await stale.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 10)));

      final inflight = File('${dir.path}/other.json.tmp.cafebabe');
      await inflight.writeAsString('本进程正在写');

      final file = await DataIo.saveToAppDocs('old.json', '{"ok":1}');
      expect(await file.readAsString(), '{"ok":1}');
      expect(await stale.exists(), isFalse,
          reason: '过期残片必须被清扫（旧实现只清 backup/auto）');
      expect(await inflight.exists(), isTrue,
          reason: '1 分钟内修改的 tmp 可能是并发写入的在途文件，不得误删');

      final leftovers = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.contains('.tmp.'))
          .toList();
      expect(leftovers, ['other.json.tmp.cafebabe'],
          reason: '本次写入的随机 tmp 必须已删除，不得累积');
    });
  });

  // ═════════════════════ P3-3 应用锁落盘失败 ═════════════════════

  group('P3-3 应用锁 fail-safe 出口', () {
    test('关闭应用锁时落盘失败：不抛异常、内存生效、通知并标记未保存', () async {
      // setMockInitialValues 会重置 SharedPreferences 单例；先重置再换坏 store，
      // 否则单例仍持有上一个用例的（可写）store，测不到失败路径。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SharedPreferencesStorePlatform.instance = _ThrowOnSetStore();

      final p = AppLockProvider();
      var notified = 0;
      p.addListener(() => notified++);

      final ok = await p.setEnabled(false); // 旧实现在这里抛异常
      expect(ok, isTrue, reason: '返回值语义仍是「是否允许该操作」');
      expect(p.appLockEnabled, isFalse);
      expect(p.locked, isFalse, reason: '本会话必须真的解锁，不能把用户困住');
      expect(p.lastSwitchPersistFailed, isTrue);
      expect(notified, greaterThan(0), reason: '失败路径同样要 notifyListeners');

      SharedPreferences.setMockInitialValues(<String, Object>{});
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
    });

    test('loadFailed 有可见说明文案（供解锁页 / 设置页消费）', () {
      final p = AppLockProvider();
      expect(p.loadFailed, isFalse);
      expect(p.loadFailedHint, contains('最保守'));
      expect(p.loadFailedHint, contains('下一次启动'));
    });
  });

  // ═════════════════════ P3-4 弹层撤销条 ═════════════════════

  group('P3-4 弹层内撤销条', () {
    testWidgets('连续两条各保留，点「撤销」立即消散且只执行一次', (tester) async {
      late BuildContext hostCtx;
      var undoCount = 0;
      Future<bool> onUndo() async {
        undoCount++;
        return true;
      }

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SheetMessageHost(
            child: Builder(builder: (c) {
              hostCtx = c;
              return const SizedBox.expand();
            }),
          ),
        ),
      ));

      const first = '已跳过 12-03';
      const second = '已跳过 12-10';
      showUndoSnackBar(hostCtx, content: undoContent(first), onUndo: onUndo);
      await tester.pump();
      expect(find.text(undoContent(first)), findsOneWidget);

      // 旧实现单槽覆盖：第二条会立刻顶掉第一条。
      showUndoSnackBar(hostCtx, content: undoContent(second), onUndo: onUndo);
      await tester.pump();
      expect(find.text(undoContent(first)), findsOneWidget,
          reason: '第一条仍在展示，第二条应排队而非覆盖');
      expect(find.text(undoContent(second)), findsNothing);

      await tester.pump(kUndoWindow); // 第一条自然超时
      await tester.pump();
      expect(find.text(undoContent(first)), findsNothing);
      expect(find.text(undoContent(second)), findsOneWidget,
          reason: '前一条收起后应推进到队列里的下一条');

      await tester.tap(find.text('撤销'));
      await tester.pump();
      expect(find.text(undoContent(second)), findsNothing,
          reason: '点过撤销后横幅必须立即消散（旧实现挂到 10 秒结束）');
      expect(undoCount, 1, reason: '撤销闭包只能执行一次');

      await tester.pump(kUndoWindow);
    });
  });

  // ═════════════════════ U-3 口令强度 ═════════════════════

  group('U-3 口令字符类别', () {
    test('汉字长口令与多符号长口令不再判弱', () {
      expect(backupPassphraseHasTwoClasses('一二三四五六七八九十十一'), isTrue,
          reason: '12 个汉字熵足够，旧实现按「0 类」判弱');
      expect(backupPassphraseHasTwoClasses(r'!@#$%^&*()-_=+[]{}'), isTrue,
          reason: '16 位多符号口令（单一类别）按长度 + 多样性放行');
      expect(backupPassphraseHasTwoClasses('密码abc123'), isTrue,
          reason: '汉字 + 小写 + 数字');
    });

    test('低多样性长串与纯数字短串仍判弱', () {
      expect(backupPassphraseHasTwoClasses('aaaaaaaaaaaaaaaa'), isFalse,
          reason: '单一字符重复 16 次不是高熵口令');
      expect(backupPassphraseHasTwoClasses('12345678'), isFalse,
          reason: '8 位纯数字长度不足 16，仍判弱');
      expect(backupPassphraseHasTwoClasses('1234567890123456'), isFalse,
          reason: '纯数字仅有 1 类，且无符号/字母多样性');
      expect(backupPassphraseHasTwoClasses(''), isFalse);
    });

    test('既有口径不回归', () {
      expect(backupPassphraseHasTwoClasses('Abcdefg1'), isTrue);
      expect(backupPassphraseHasTwoClasses('abcdefg1'), isTrue);
      expect(backupPassphraseHasTwoClasses('abcdefgh'), isFalse);
    });
  });
}

/// path_provider 假桩：把文档目录指到临时目录（P3-5 用例）。
class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// 偏好写入必失败的 store（P3-3：模拟存储损坏 / 磁盘满）。
class _ThrowOnSetStore extends InMemorySharedPreferencesStore {
  _ThrowOnSetStore() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    throw PlatformException(code: 'write_failed', message: '模拟偏好写入失败');
  }
}
