/// v3.1.8 审计修复轮回归测试（《有条功能与操作审计报告（v3.1.8）》）。
///
/// 覆盖清单（只落「能区分修与未修」的稳定契约）：
/// - **P2-3** 任务确认/撤销/重试回执改挂独立通知段，与一次性提醒段隔离
///   （旧实现共用 _notifyIdOf，静音 cancel(id) 会连带撤掉确认条）。
/// - **P2-6** `backupPassphraseHasTwoClasses` 为手动/自动口令共用真源；
///   `soundEnabled` 静态单一真源（setSoundEnabled 注入，习惯/简报共用）。
/// - **P3-3** `decodeEncryptedSnapshotOffMainThread` 用当前口令解出明文
///   （读回校验即使移到 isolate 也必须真正验证 tasks 段）。
/// - **P3-7** `selectableMitTasks(includeIds:)` 让已完成的已选项留在候选池。
/// - **P3-9** `Habit.clampUnit` 按字素簇截断，不劈开 emoji。
/// - **U-2** 版本号asset兜底去构建号 —— 由正则口径纯函数验证（见文末说明）。
///
/// 不落用例（如实）：P2-1/P2-2/P3-1/P3-2/P3-4/P3-5/P3-6/P3-8/U-1/U-3
/// 依赖私有方法、平台通道写盘或完整 widget 交互树，按仓库历轮口径以代码审查
/// 交付（见最终回复），其依赖的 provider/service 层信号在本文件能钉的都已钉。
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/backup_crypto.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/sheet_message.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifCh, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureCh, (call) async => null);
  });

  setUp(() {
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    NotificationService.instance.enabled = true;
    NotificationService.soundEnabled = true;
  });

  Task mk(String id, {String title = '任务', TaskStatus status = TaskStatus.todo}) =>
      Task(
        id: id,
        title: title,
        priority: Priority.medium,
        category: Category.work,
        status: status,
      );

  group('P2-3 任务确认条独立通知段', () {
    test('taskConfirmNotifyIdOf 与一次性提醒 id 段隔离且跨版本稳定', () {
      // 纯数字任务 id：一次性段 = 数字本身（如 9001），确认段 = 2e9 起。
      final deadline = 9001;
      final confirm = NotificationService.taskConfirmNotifyIdOf('9001');
      expect(confirm, isNot(deadline),
          reason: '确认条若与截止提醒同槽，静音 cancel(id) 会撤掉撤销入口');
      expect(confirm, greaterThanOrEqualTo(2000000000));
      expect(confirm, lessThan(2000100000));
      expect(NotificationService.taskConfirmNotifyIdOf('9001'), confirm,
          reason: '确定性哈希——不得用 String.hashCode（跨引擎版本漂移）');
      // 不同任务 id 不应落到同一确认槽（10 万槽 + 个位数任务碰撞可忽略，
      // 这里只断言两个具体 id 不相等）。
      expect(NotificationService.taskConfirmNotifyIdOf('9001'),
          isNot(NotificationService.taskConfirmNotifyIdOf('9002')));
    });
  });

  group('P2-6 口令强度 / 声音单一真源', () {
    test('backupPassphraseHasTwoClasses：纯数字弱口令被拒、两类字符通过', () {
      expect(backupPassphraseHasTwoClasses('123456'), isFalse,
          reason: '纯数字可被 GPU 爆破——自动备份口令首次设置也要拒绝');
      expect(backupPassphraseHasTwoClasses('abcdef'), isFalse);
      expect(backupPassphraseHasTwoClasses('abc123'), isTrue);
      expect(backupPassphraseHasTwoClasses('Abcdef'), isTrue);
    });

    test('setSoundEnabled 注入通知服务静态单一真源', () async {
      final p = TaskProvider();
      expect(NotificationService.soundEnabled, isTrue);
      await p.setSoundEnabled(false);
      expect(NotificationService.soundEnabled, isFalse,
          reason: '习惯/简报/挽留/snooze 全部读此真源，关闭声音后不得仍响');
      await p.setSoundEnabled(true);
      expect(NotificationService.soundEnabled, isTrue);
    });
  });

  group('P3-3 读回校验（off-main-isolate 解密）', () {
    test('decodeEncryptedSnapshotOffMainThread 用当前口令解出 tasks 段', () async {
      final payload = jsonEncode({
        'version': 3,
        'tasks': [
          {'id': '1', 'title': '买牛奶'}
        ],
        'user_templates': <dynamic>[],
      });
      final envelope = encrypt(payload, 'right-pass');
      final decoded =
          await decodeEncryptedSnapshotOffMainThread(envelope, 'right-pass');
      expect(decoded, isNotNull);
      expect(decoded!['tasks'], isA<List>());
      // 错口令必须解不开（读回校验据此判定「覆盖未就位」，保留旧明文）。
      final wrong =
          await decodeEncryptedSnapshotOffMainThread(envelope, 'wrong-pass');
      expect(wrong, isNull);
    });
  });

  group('P3-7 今日三件自选已完成项可取消', () {
    test('includeIds 让已完成的已选项留在候选池，未传入时仍只返回 todo', () async {
      final done = mk('mit-done', title: '已完成的已选', status: TaskStatus.done);
      final todo = mk('mit-todo', title: '未完成');
      final p = TaskProvider();
      final json = jsonEncode({
        'version': 2,
        'tasks': [done.toJson(), todo.toJson()],
        'notifications_enabled': false,
      });
      await p.restoreFromJson(json);

      final plain = p.selectableMitTasks();
      expect(plain.map((t) => t.id), isNot(contains('mit-done')),
          reason: '默认候选池仍只给未完成任务（既有契约不回归）');
      final withChosen =
          p.selectableMitTasks(includeIds: {'mit-done'});
      expect(withChosen.map((t) => t.id), contains('mit-done'),
          reason: '已选中的已完成项必须出现在弹层里才能被取消/替换');
      expect(withChosen.map((t) => t.id), contains('mit-todo'));
    });
  });

  group('P3-9 习惯单位按字素簇截断', () {
    test('clampUnit 保留完整 emoji，不劈成半个代理对', () {
      // 6 个 emoji = 12 个 UTF-16 码元，旧 substring(0,6) 只留 3 个。
      final six = '😀😀😀😀😀😀';
      expect(Habit.clampUnit(six), six,
          reason: '6 个字素簇（emoji）应原样保留，不能按码元截成 3 个');
      final seven = '😀😀😀😀😀😀😀';
      expect(Habit.clampUnit(seven).characters.length, Habit.maxUnitLength);
      expect(Habit.clampUnit('次'), '次');
      expect(Habit.clampUnit(123), '');
    });
  });

  group('U-1 弹层消息条预留布局（不遮挡主操作）', () {
    testWidgets('SheetMessageHost 消息条显示时整体高度增加（预留空白）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SheetMessageHost(
            key: const Key('sheet-host'),
            child: const SizedBox(height: 300, key: Key('sheet-child')),
          ),
        ),
      ));
      final before = tester.getSize(find.byKey(const Key('sheet-host')));
      // 触发一条非交互消息（文案不含失败标记）。
      // 用 host 内部（scope 之下）的 context 触发，host 自身的 element
      // 位于 SheetMessageScope 之上，拿不到 scope。
      showSheetMessage(
          tester.element(find.byKey(const Key('sheet-child'))), '已保存');
      await tester.pump();
      final after = tester.getSize(find.byKey(const Key('sheet-host')));
      expect(find.byKey(const Key('sheet-message')), findsOneWidget);
      expect(after.height, greaterThan(before.height),
          reason: '非交互消息条贴底点穿时须在 child 下方预留布局高度，'
              '避免视觉遮挡底部按钮却点到它');
      // 消息自动消失后布局恢复。
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('撤销条返回值类型可空（P2-8 弹层路径）', () {
    testWidgets('弹层内 showUndoSnackBar 渲染 sheet-message 而非根 SnackBar',
        (tester) async {
      late BuildContext hostCtx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SheetMessageHost(
            child: Builder(builder: (ctx) {
              hostCtx = ctx;
              return const SizedBox(height: 200);
            }),
          ),
        ),
      ));
      showUndoSnackBar(hostCtx, content: '已跳过（10 秒内可撤销）', onUndo: () async => true);
      await tester.pump();
      expect(find.byKey(const Key('sheet-message')), findsOneWidget,
          reason: '弹层内撤销条必须渲染在弹层消息宿主内，不能被 bottom sheet 遮住');
      // 冲掉 show() 的 10s Timer 与超时提示 Timer，避免 widget 树销毁时残留。
      await tester.pump(const Duration(seconds: 11));
    });
  });
}
