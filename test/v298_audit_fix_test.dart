import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/achievement.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';
import 'test_helpers.dart';

/// v2.9.7 审计修复轮回归测试（《有条功能与操作审计报告（v2.9.7）》新编号）。
///
/// 覆盖清单（可纯 Dart / 可稳定观测部分）：
/// - **新P3-1** 无 action 提示不参与活跃撤销计数（旧实现 `+1` 无配对 `−1`
///   → 计数泄漏 → 后续所有「窗口已结束」提示被永久跳过）；
/// - **新P3-2** `showUndoSnackBar` 的 `failureHint` 参数（习惯打卡撤销整体
///   委托唯一实现后，保留「这条记录之后已被再次修改」的细节文案）；
/// - **新P3-3** `trimForExport` 仅在**实际剥离** attachments 时返回 true
///   （旧实现超限但无 attachments 键也返回 true → 误报「附件已剥离」）；
/// - **新P3-4** 模板 `monthlyDay` 加载/套用侧夹取（0/99/字符串 → 1，不再
///   硬转型中断整份模板加载；套用侧兜底 `Task(monthlyDay: 0)` 不再可达）；
/// - **新P2-2** `HabitProvider.archivedHabits` 真源（取消归档入口的数据面）；
/// - **新P3-6** `habitConfirmNotifyIdOf` 独立 9 号槽（不与落点 0..7 / snooze
///   8 号槽相撞，int32 界内）——确认通知不再被落点重排顶掉；
/// - **新P3-9** 截止日差统一走 `dueCompareKey` 管道（sectionCounts / homeTasks
///   对纯日期 / 带时刻 / 昨日 / 未来四种形态的分区结果不变，等价性钉死）；
/// - **新P3-11** 成就 streak_3/7/30 取值 = 逐习惯 longestStreak 最大值
///   （用「两习惯交错达标」的判别用例区分并集自然日口径与单习惯口径）；
/// - **新U2-2** 通知撤销 = **-1** 对称（provider 侧 adjustCheckInValue(-1)：
///   3 → 2 → 1 → 0（删除记录），不再一键清零丢 7 个单位）。
///
/// 已知不可稳定钉死的残余（与实现注释共同保障，见各文件）：
/// - `_writeAutoBackup` 超限路径（私有 + 依赖 Documents 目录 IO，链路行为靠
///   task_provider 注释与 trimForExport 的单测共同覆盖）；
/// - 通知撤销的无记录早退 / 锁定态提示（main.dart 私有顶层函数）；
/// - 复合撤销 `byId == null → false` 的 UI 闭包（occurrence_sheet /
///   task_detail_screen 内联，无 widget 脚手架可复用）；
/// - 应用锁根类型恒定（U2-0）需真机/集成环境验证保活态，单元层无法观测。
void main() {
  _installMocks();

  // ── 新P3-1 / 新P3-2：撤销唯一实现的计数与失效文案 ───────────
  group('新P3-1/新P3-2 showUndoSnackBar 计数不变式与 failureHint', () {
    testWidgets('新P3-1：无 action 提示不参与活跃计数（旧实现 +1 泄漏）',
        (tester) async {
      ScaffoldMessengerState? messengerRef;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              messengerRef ??= ScaffoldMessenger.of(ctx);
              return Center(
                child: TextButton(
                  onPressed: () {
                    // ① 无 action 的提示（如习惯删除未发生时的反馈）——
                    //    旧实现在此无条件 +1 且永不 −1（泄漏源）。
                    showUndoSnackBar(ctx, content: '已保存');
                    // ② 紧随其后的正常撤销条。
                    showUndoSnackBar(
                      ctx,
                      content: undoContent('已删除「A」'),
                      onUndo: () async => true,
                    );
                  },
                  child: const Text('go'),
                ),
              );
            },
          ),
        ),
      ));
      final messenger = messengerRef!;
      await tester.tap(find.text('go'));
      await tester.pump(); // ① 入场中，② 已入队
      expect(debugActiveUndoSnackCount(messenger), 1,
          reason: '计数不变式 = 「在途撤销横幅数」——无 action 的提示不参与；'
              '旧实现此处为 2（泄漏），其后所有超时提示被 > 0 判据永久跳过');

      // 第一次 hide 收起的是队首（无 action 条）：它从未 +1、也没有 closed
      // 回调，计数不动——本用例第一版在这里误写「期望 0」，实际 1（正常条
      // 仍在队列未展示）。正确断言：计数仍 1。
      messenger.hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(debugActiveUndoSnackCount(messenger), 1,
          reason: '无 action 条收起不影响计数（旧实现会在此时把它从未入账的'
              '+1 留在账上，等价于泄漏）');

      // 第二次 hide 收起正常条：closed −1 → 归 0（此刻超时提示即代表
      // 「全部窗口已结束」，不会被 > 0 判据跳过）。
      messenger.hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(debugActiveUndoSnackCount(messenger), 0);
    });

    testWidgets('新P3-2：failureHint 生效（习惯侧失效文案经唯一实现展示）',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () {
                  showUndoSnackBar(
                    ctx,
                    content: undoContent('已清空今日记录（2）'),
                    failureHint: '撤销已失效：这条记录之后已被再次修改',
                    onUndo: () async => false,
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text('撤销已失效：这条记录之后已被再次修改'), findsOneWidget,
          reason: '习惯打卡撤销委托唯一实现后，细节失效文案经 failureHint 保留');
    });
  });

  // ── 新P3-3：trimForExport 返回值语义 ────────────────────────
  group('新P3-3 trimForExport 仅在实际剥离时返回 true', () {
    test('未超限 → 原样返回、false', () {
      final map = <String, dynamic>{
        'tasks': <dynamic>['a', 'b'],
      };
      final r = DataIo.trimForExport(map);
      expect(r.$2, isFalse);
      expect(identical(r.$1, map), isTrue, reason: '未超限不复制');
    });

    test('超限且无 attachments 键 → false（旧实现误报 true）', () {
      // 32MB + 64KB 的 ASCII 串（estimate 按 UTF-8 字节计）。
      final big = 'x' * (32 * 1024 * 1024 + 65536);
      final map = <String, dynamic>{'notes': big};
      final r = DataIo.trimForExport(map);
      expect(r.$2, isFalse,
          reason: '新P3-3：没有可剥离的 attachments 就不该报「附件已剥离」——'
              '旧实现此处返回 true，调用方据此误报，误导用户以为附件被安全处理');
      expect(r.$1.containsKey('attachments'), isFalse);
    });

    test('超限且含 attachments → true 且剥离后无 attachments 键', () {
      final big = 'x' * (32 * 1024 * 1024 + 65536);
      final map = <String, dynamic>{
        'tasks': <dynamic>[],
        'attachments': <String, dynamic>{
          'a1': <String, dynamic>{'base64': big},
        },
      };
      final r = DataIo.trimForExport(map);
      expect(r.$2, isTrue);
      expect(r.$1.containsKey('attachments'), isFalse);
      expect(map.containsKey('attachments'), isTrue,
          reason: '剥离作用于副本，不污染调用方原 map');
    });
  });

  // ── 新P3-4：模板 monthlyDay 加载 / 套用两侧夹取 ─────────────
  group('新P3-4 模板 monthlyDay 白名单夹取（1..31，缺省 1）', () {
    Map<String, dynamic> mj(dynamic monthlyDay) => <String, dynamic>{
          'title': '模板项',
          'category': 'work',
          'priority': 'medium',
          'repeat': 'monthly',
          if (monthlyDay != null) 'monthlyDay': monthlyDay,
        };

    test('fromJson：0 / 99 / 缺键 → 1；合法值原样保留', () {
      expect(TemplateItem.fromJson(mj(0)).monthlyDay, 1,
          reason: '旧模板 / 手改模板的 monthlyDay=0 此前会原样带出');
      expect(TemplateItem.fromJson(mj(99)).monthlyDay, 1);
      expect(TemplateItem.fromJson(mj(null)).monthlyDay, 1, reason: '缺键缺省 1');
      expect(TemplateItem.fromJson(mj(15)).monthlyDay, 15, reason: '合法值不动');
    });

    test('fromJson：字符串类型不再抛错中断整份模板加载', () {
      expect(TemplateItem.fromJson(mj('15')).monthlyDay, 1,
          reason: '旧实现 `as int?` 硬转型：字段为字符串时抛 TypeError，'
              '一份模板里其后的所有条目全部丢失');
    });

    test('applyTemplateItems：套用侧兜底夹取，不再产出「每月 0 号」任务', () async {
      final p = await buildWith(<Task>[]);
      final item = const TemplateItem(
        '月度体检',
        Category.work,
        Priority.medium,
        null,
        repeat: RepeatType.monthly,
        monthlyDay: 0, // 模拟编程构造 / 未来新增写入点的旁路（编辑器保存侧已夹）
      );
      // P2-2（v3.0.7 审计）：applyTemplateItems 随 addTask 异步化。
      final created = await applyTemplateItems(p, [item]);
      expect(created, 1);
      expect(p.tasks.single.monthlyDay, 1,
          reason: '构造器不夹取（Task.fromJson 之外的路径防不住），套用侧兜底');
    });
  });

  // ── 新P2-2：归档习惯数据面（取消归档入口可达）────────────────
  group('新P2-2 archivedHabits 真源', () {
    test('归档 → activeHabits 移出 / archivedHabits 收录；取消归档还原', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '目标习惯', emoji: '🌊', colorValue: 1, weekdays: const []);
      final h = hp.habits.single;

      await hp.updateHabit(h, archived: true);
      expect(hp.activeHabits, isEmpty, reason: '列表不渲染归档习惯（既有口径）');
      expect(hp.archivedHabits.single.title, '目标习惯',
          reason: '新真源：习惯页「已归档」折叠区的数据面——归档不再单向不可达');

      final archived = hp.archivedHabits.single;
      await hp.updateHabit(archived, archived: false);
      expect(hp.activeHabits.single.title, '目标习惯');
      expect(hp.archivedHabits, isEmpty);
    });
  });

  // ── 新P3-6：确认通知独立 9 号槽 ─────────────────────────────
  group('新P3-6 habitConfirmNotifyIdOf 独立槽位', () {
    test('不与落点 0..7 / snooze 8 号槽相撞；int32 界内且确定性', () {
      const id = '1727400000000';
      final confirm = NotificationService.habitConfirmNotifyIdOf(id);
      for (var d = 0; d < 8; d++) {
        expect(confirm, isNot(NotificationService.habitNotifyIdOf(id, d)),
            reason: '落点槽 $d：15 分钟守护周期内的重排不得顶掉带「撤销」按钮的确认通知');
      }
      expect(confirm, isNot(NotificationService.habitSnoozeNotifyIdOf(id)),
          reason: 'snooze（8 号槽）与确认（9 号槽）并存时互不覆盖');
      expect(confirm, inInclusiveRange(0, 0x7FFFFFFF),
          reason: '通知插件要求 id 落在 int32 范围');
      expect(NotificationService.habitConfirmNotifyIdOf(id), confirm,
          reason: '确定性（FNV-1a 折叠，与 habitNotifyIdOf 同一真源）');
    });
  });

  // ── 新P3-9：日差统一走 dueCompareKey（等价性钉死）────────────
  group('新P3-9 sectionCounts / homeTasks 分区口径（经比较键管道）', () {
    test('纯日期 / 带时刻 / 昨日 / 未来四种形态分区结果不变', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final p = await buildWith([
        _task('1', title: '纯日期今天', dueDate: today),
        _task('2', title: '带时刻今天', dueDate: DateTime(today.year, today.month, today.day, 10, 20)),
        _task('3', title: '昨天', dueDate: today.subtract(const Duration(days: 1))),
        _task('4', title: '后天', dueDate: today.add(const Duration(days: 2))),
      ]);
      final c = p.sectionCounts;
      expect(c['overdue'], 1, reason: '仅昨天逾期（重复不计逾期口径不变）');
      expect(c['today'], 2, reason: '纯日期与带时刻的「今天」都落在今天分区');
      expect(c['future'], 1);

      final h = p.homeTasks;
      expect(h['today']!.map((t) => t.id), containsAll(['1', '2']));
      expect(h['overdue']!.map((t) => t.id), ['3']);
      expect(h['future']!.map((t) => t.id), ['4']);
    });
  });

  // ── 新P3-11：成就 streak 取值 = 逐习惯最长连续 ──────────────
  group('新P3-11 成就 streak 取值链（单习惯 + 计划日口径）', () {
    test('两习惯交错达标：取逐习惯最大值，而非「并集自然日连续」', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '甲', emoji: '🌊', colorValue: 1, weekdays: const []);
      await hp.addHabit(
          title: '乙', emoji: '📖', colorValue: 2, weekdays: const []);
      final a = hp.habits.firstWhere((x) => x.title == '甲');
      final b = hp.habits.firstWhere((x) => x.title == '乙');
      // 交错达标：甲在 9/1、9/3；乙在 9/2、9/4。并集 {9/1..9/4} 按自然日
      // 连续 = 4（旧取值 overallLongestStreak 的结果）；逐习惯最长连续 = 1。
      await hp.setCheckInValue(a, DateTime(2026, 9, 1), 1);
      await hp.setCheckInValue(a, DateTime(2026, 9, 3), 1);
      await hp.setCheckInValue(b, DateTime(2026, 9, 2), 1);
      await hp.setCheckInValue(b, DateTime(2026, 9, 4), 1);

      expect(hp.overallLongestStreak, 4,
          reason: '对照钉死：并集自然日口径仍是 4（保留的旧 getter，仅供诊断）');
      expect(hp.longestStreak(a), 1);
      expect(hp.longestStreak(b), 1);

      final ctx = AchievementContext.fromProviders(
          await buildWith(<Task>[]), FocusProvider(), hp);
      expect(ctx.longestStreak, 1,
          reason: '新P3-11：成就 streak_3/7/30 取值改为逐习惯最大值——'
              '「连续达成 N 个计划日」的文案与取值同义（旧取值此处为 4，更失真）');
    });
  });

  // ── 新U2-2：通知撤销 = -1 对称（provider 侧语义）────────────
  group('新U2-2 通知撤销 -1 对称（adjustCheckInValue）', () {
    test('3 → 2 → 1 → 0（删除记录），不再一键清零', () async {
      final hp = await newHabitProvider();
      await hp.addHabit(
          title: '喝水',
          emoji: '💧',
          colorValue: 1,
          weekdays: const [],
          dailyTarget: 8);
      final h = hp.habits.single;
      final now = DateTime.now();

      await hp.setCheckInValue(h, now, 3);
      expect(hp.todayValue(h), 3);

      await hp.adjustCheckInValue(h, now, -1);
      expect(hp.todayValue(h), 2,
          reason: '新U2-2：通知「撤销」回退一步（旧实现 setCheckInValue(0) '
              '把 3 个单位一次清空，与「打卡 = +1」不对称）');

      await hp.adjustCheckInValue(h, now, -1);
      await hp.adjustCheckInValue(h, now, -1);
      expect(hp.todayValue(h), 0);
      expect(hp.checkIns.where((c) => c.habitId == h.id), isEmpty,
          reason: '归 0 → 删除记录（setCheckInValue 既有语义）');
    });
  });
}

void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控列表构造 TaskProvider（绕过 load()，避免启动午夜守护定时器）。
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
  return p;
}

/// 每个用例独立的习惯 Provider：**先重置内存库与 prefs 再 load**。
///
/// 首版漏掉 reset：`LocalDatabase` 内存后端是**同进程共享单例**（与
/// TaskProvider 共用一套记忆库），本文件内先跑的用例（新P2-2 / 新P3-11）
/// 已把习惯写入内存库，后跑的用例 `hp.habits.single` 直接
/// 「Bad state: Too many elements」（本机首轮 -2 的根因）。
/// 照抄 `kanban_lane_layout_test._providerWith` 的隔离做法。
Future<HabitProvider> newHabitProvider() async {
  LocalDatabase.resetMemoryForTest();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  final hp = HabitProvider();
  await hp.load();
  return hp;
}

Task _task(
  String id, {
  String title = '任务',
  DateTime? dueDate,
  RepeatType repeat = RepeatType.none,
  int? repeatMinute,
}) {
  final d = dueDate ?? DateTime(2026, 9, 1, 9, 0);
  return Task(
    id: id,
    title: title,
    priority: Priority.medium,
    category: Category.life,
    dueDate: d,
    repeat: repeat,
    repeatMinute: repeatMinute,
  );
}
