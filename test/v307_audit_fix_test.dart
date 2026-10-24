import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/task_toggle_undo.dart';

import 'test_helpers.dart';

/// v3.0.7 审计修复轮（《有条功能与操作审计报告（v3.0.7）》9 项）回归测试。
/// 每条修复至少一个「能区分修与未修」的用例；不落用例的项见文件尾说明。
///
/// 覆盖清单：
/// - **P2-1** `restoreHabit` 落盘失败后快照**暂存进 provider**（`pendingRestore`），
///   `retryRestoreHabit` 提供真实可点的重试载体——旧实现快照只活在撤销横幅
///   闭包里，横幅一关重试入口随之销毁，数据实际不可恢复（而文案承诺「请重试」）；
///   同 id 已重建分支不暂存（真失效，重试无意义）；
/// - **P2-2①** 任务侧高频写入口透传落盘结果：addTask（失败 null + 内存回滚）、
///   updateTask / deleteTask / restoreFromTrash / discardTask / skipOccurrence /
///   endRepeat / pauseRepeatsUntil / batchUpdateAs / 标签族 → `Future<bool>`/
///   具名记录，失败如实回报；undoDelete / undoBatchEdit 返回 `(applied, saved)`
///   拆「缓冲失效」与「落盘失败但内存撤销已生效」双义；
/// - **P3-1** `showCompleteNotSaved` / `showHabitCheckInNotSaved` /
///   `showHabitUndoNotSaved` 三个覆盖式失败回执（service 层；main 的
///   _doComplete / _doHabitCheckIn / _doHabitUndo 接线库外不可达，同历轮口径）
///   与 `persistNow`（重试落盘的显式入口）；
/// - **P3-2 / U2-2** 失败提示按 `dbLoadFailed` 分化（安全模式不再复读「请重试」），
///   文案落到具体可执行动作（widget）；
/// - **P3-3** `showTaskMissingHint`——「任务不存在」与「落盘失败」的第二句文案；
/// - **P3-4** 新建习惯失败后按钮恢复可点（可重试，widget）；
/// - **惯例** `restoreHabit` 失败回滚完整性（习惯与打卡一并撤下，v3.0.6 基线
///   在 P2-1 用例中一并复钉）。
///
/// 不落用例：
/// - **P2-2② 的 3 处撤销迁移**（task_detail 暂停/恢复循环 ×2、calendar 拖拽
///   改期 ×1）——UI 闭包换实现（`restoreTaskSnapshot` → `taskUndoAction`），
///   `taskUndoAction` 三分支已由 v3.0.6 的 widget 用例钉死，迁移属等价替换；
/// - **P3-1 的 main 接线**（_doComplete 等三个 !ok 分支改弹回执）——顶层私有
///   回调库外不可达（v3.0.2 / v3.0.4 / v3.0.5 / v3.0.6 轮同判），其依赖的
///   provider / service 层信号已在本文件钉死；
/// - **P3-4 的双击防重入窗口**——addHabit 在内存库下微任务级完成，FakeAsync
///   下无法稳定构造「第一次 await 未 resolve 时第二次点击」的窗口期；以
///   `_saving` 守卫实现 + 「失败后按钮恢复可点」用例护住（与 P2-1 快照销毁
///   同判：代码推演 + 可稳定钉住的契约落测试）；
/// - **P3-5 的两段式短路**——习惯侧 habits / checkIns 两段共用同一 DB 实例
///   （testUseMemory 开关同源），无法只让首段失败来观测「次段未被写」；短路
///   为纯控制流（首段 false 即 return），失败回滚完整性已在本文件 P2-1 用例
///   复钉。仓库侧「restoreHabit 落盘失败后 habits/checkIns 均不在内存」断言
///   与 v3.0.6 的同名用例共同构成回滚契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  // 记录型通知插件 mock：除返回 null 外，把全部方法调用留档。
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
    // 🔴 内存库是同进程共享单例：每个用例前必须重置 DB + prefs 再 load()。
    LocalDatabase.resetMemoryForTest();
    // 🔴 testUseMemory 是进程级静态标志（v3.0.6 轮实证的泄漏教训）：setUp
    // 统一置真兜底，各用例内部仍须自负还原。
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    NotificationService.instance.enabled = true;
  });

  Future<void> drainMicrotasks() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  // ── 脚手架 ────────────────────────────────────────────────────────

  /// 用受控列表构造 TaskProvider（restoreFromJson 绕过 load()，不起午夜守护）。
  Future<TaskProvider> buildWith(
    List<Task> tasks, {
    List<Task>? trash,
  }) async {
    final p = TaskProvider();
    final json = jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': (trash ?? const <Task>[]).map((t) => t.toJson()).toList(),
      'notifications_enabled': false,
      'sound_enabled': false,
    });
    await p.restoreFromJson(json);
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return p;
  }

  /// 最小一次性任务工厂。
  Task mk({
    String id = '',
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

  /// 习惯 Provider 脚手架（setUp 已重置内存库 + prefs）：直接 load + add。
  Future<(HabitProvider, Habit)> habitWith() async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '喝水',
      emoji: '💧',
      colorValue: 1,
      weekdays: const [],
    );
    return (hp, hp.habits.single);
  }

  // ══════════════════════════════════════════════════════════════════
  // P2-1：restoreHabit 失败后的重试载体（provider 暂存 + retryRestoreHabit）
  // ══════════════════════════════════════════════════════════════════
  group('P2-1 习惯删除撤销的重试载体', () {
    test('落盘失败 → 快照暂存；retryRestoreHabit 真正恢复（载体可执行）',
        () async {
      final (hp, habit) = await habitWith();
      await hp.setCheckInValue(habit, DateTime.now(), 3);
      final snap = (await hp.deleteHabit(habit.id))!;
      expect(hp.byId(habit.id), isNull, reason: '前提：删除已落盘生效');

      // 第一次撤销：DB 异常 → null（回滚），快照必须被**暂存**。
      LocalDatabase.testUseMemory = false;
      final Habit? restored;
      try {
        restored = await hp.restoreHabit(snap);
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(restored, isNull, reason: '撤销未生效（v3.0.6 惯例基线保持）');
      expect(hp.byId(habit.id), isNull, reason: '内存回滚：习惯仍未恢复');
      expect(hp.checkIns.where((c) => c.habitId == habit.id), isEmpty,
          reason: 'P3-5：本次放回的打卡一并撤下（失败回滚完整性）');
      // ⭐ P2-1 核心断言：旧实现到此为止——快照只活在横幅闭包里，横幅一关
      // 「请重试」在物理上不存在入口；修复后 provider 暂存快照，重试可执行。
      expect(hp.pendingRestore, same(snap),
          reason: '落盘失败后快照暂存进 provider——habit_screen 的失败提示'
              '据此挂「再试一次」action（与通知侧 showTaskUndoNotSaved 对齐）');

      // 重试：正常库 → 恢复成功（习惯 + 打卡 + 原列表位置）。
      // U3-1（v3.0.8 审计）：retryRestoreHabit 改按快照校验（单槽位暂存会被
      // 后一次失败覆盖，无参版会恢复错对象）——调用方显式携带当次快照。
      final h = await hp.retryRestoreHabit(snap);
      expect(h, isNotNull, reason: '重试载体必须真实可执行——旧实现此路不存在');
      expect(h!.id, habit.id);
      expect(hp.byId(habit.id), isNotNull);
      expect(hp.todayValue(habit), 3, reason: '打卡记录一并恢复');
      expect(hp.pendingRestore, isNull, reason: '成功后清空暂存');
    });

    test('同 id 已重建 → null 且不暂存（真失效，重试无意义）', () async {
      final (hp, habit) = await habitWith();
      final snap = (await hp.deleteHabit(habit.id))!;
      // 用 restoreFromJson「重建」同 id 习惯（用户删后又恢复备份的场景）。
      await hp.restoreFromJson({
        'habits': [habit.toJson()],
        'check_ins': <dynamic>[],
      });
      expect(hp.byId(habit.id), isNotNull);

      final restored = await hp.restoreHabit(snap);
      expect(restored, isNull, reason: '幂等防重：同 id 已存在不得再插一份');
      expect(hp.pendingRestore, isNull,
          reason: '早退分支不暂存——此时挂「再试一次」只会二次骗人');
      expect(hp.habits, hasLength(1), reason: '不产生重复习惯');
    });

    test('retryRestoreHabit 无暂存 / 快照不匹配 → null（U3-1 对象校验）', () async {
      final hp = HabitProvider();
      await hp.load();
      // 另一套 provider + 习惯（内存库共享单例：先重置再建，避免 .single 撞车）。
      LocalDatabase.resetMemoryForTest();
      LocalDatabase.testUseMemory = true;
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      final (hp2, habit2) = await habitWith();
      final snap2 = (await hp2.deleteHabit(habit2.id))!;
      expect(await hp.retryRestoreHabit(snap2), isNull,
          reason: 'U3-1：暂存区为空 → 无从恢复（无参旧版同样 null，但无法'
              '区分「空」与「错对象」）');
      // 第三套：先成功删除，再让 restoreHabit 落盘失败 → 暂存 habit3 快照。
      LocalDatabase.resetMemoryForTest();
      LocalDatabase.testUseMemory = true;
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      final (hp3, habit3) = await habitWith();
      final snap3 = (await hp3.deleteHabit(habit3.id))!;
      LocalDatabase.testUseMemory = false;
      final r3 = await hp3.restoreHabit(snap3); // 落盘失败 → 暂存
      LocalDatabase.testUseMemory = true;
      expect(r3, isNull);
      expect(hp3.pendingRestore, isNotNull, reason: '暂存区现有 habit3 的快照');
      expect(await hp3.retryRestoreHabit(snap2), isNull,
          reason: 'U3-1：入参快照与暂存区不是同一个 → 按失效处理，'
              '禁止「第一次的横幅恢复第二个习惯」');
      expect(hp3.byId(habit3.id), isNull, reason: '未被误恢复');
      expect(await hp3.retryRestoreHabit(snap3), isNotNull,
          reason: '同一快照才真正恢复');
      expect(hp3.byId(habit3.id), isNotNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P2-2①：任务侧高频写入口透传落盘结果
  // ══════════════════════════════════════════════════════════════════
  group('P2-2 addTask / updateTask / 删除族 / 循环控制 / 标签族', () {
    test('addTask 成功：返回含新 id 的 Task 且在列表', () async {
      final p = await buildWith([]);
      final t = await p.addTask(mk(title: '新建'));
      expect(t, isNotNull);
      expect(p.byId(t!.id), isNotNull, reason: '落盘成功，任务在列表');
    });

    test('addTask 落盘失败：null + 内存回滚（列表不出现幽灵任务）', () async {
      final p = await buildWith([]);
      LocalDatabase.testUseMemory = false;
      final Task? created;
      try {
        created = await p.addTask(mk(title: '幽灵'));
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(created, isNull,
          reason: '旧实现返回 Task 且列表立刻出现——重启即丢且零提示（P2-2）');
      expect(p.tasks.where((t) => t.title == '幽灵'), isEmpty,
          reason: '回滚内存：与习惯侧 addHabit 失败口径一致（调用方停留输入层）');
    });

    test('updateTask 透传落盘结果：失败 false 且内存已改（任务侧不回滚口径）',
        () async {
      final p = await buildWith([mk(id: '7401', title: '原题')]);
      expect(await p.updateTask(p.byId('7401')!.copyWith(title: '新题')),
          isTrue, reason: '成功路径 true');
      LocalDatabase.testUseMemory = false;
      final bool ok;
      try {
        ok = await p.updateTask(p.byId('7401')!.copyWith(title: '新题2'));
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(ok, isFalse, reason: '旧实现 void + fire-and-forget：改完显示'
          '已生效、重启全部回退且零提示');
      expect(p.byId('7401')!.title, '新题2',
          reason: '内存不回滚（v3.0.5 核查备注 A 口径）：UI 显示即内存态，'
              '全量写自愈，调用方弹写入失败提示');
    });

    test('deleteTask 落盘失败：null + 任务仍在列表 + 回收站空（回滚）', () async {
      final p = await buildWith([mk(id: '7402')]);
      expect((await p.deleteTask('7402'))!.id, '7402',
          reason: '成功路径返回被删任务（供撤销/提示）');
      await p.undoDelete(); // 还原

      LocalDatabase.testUseMemory = false;
      final Task? removed;
      try {
        removed = await p.deleteTask('7402');
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(removed, isNull, reason: '删除未生效');
      expect(p.byId('7402'), isNotNull,
          reason: '回滚内存——旧实现列表已移除、DB 里还在，重启「复活」且零反馈'
              '（与习惯侧 deleteHabit 失败口径对齐）');
      expect(p.trashCount, 0, reason: '回收站副本一并撤掉');
    });

    test('restoreFromTrash 透传落盘结果：成功 true、失败 false（仍在回收站）',
        () async {
      final p = await buildWith([], trash: [mk(id: '7403')]);
      expect(await p.restoreFromTrash('7403'), isTrue);
      expect(p.byId('7403'), isNotNull);
      expect(p.trashCount, 0);

      // 再删回回收站，注入异常验证失败路径。
      await p.deleteTask('7403');
      expect(p.trashCount, 1);
      LocalDatabase.testUseMemory = false;
      final bool ok;
      try {
        ok = await p.restoreFromTrash('7403');
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(ok, isFalse, reason: '旧实现 fire-and-forget：DB 异常时列表已恢复、'
          '重启又回回收站且零反馈');
      expect(p.trashCount, 0, reason: '内存恢复已生效（任务侧不回滚，全量写自愈）');
    });

    test('discardTask：不存在幂等 true；落盘失败 false 且内存已删', () async {
      final p = await buildWith([mk(id: '7404')]);
      expect(await p.discardTask('不存在'), isTrue,
          reason: '幂等无操作 ≠ 失败（v3.0.5 固化口径）');
      LocalDatabase.testUseMemory = false;
      final bool ok;
      try {
        ok = await p.discardTask('7404');
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(ok, isFalse);
      expect(p.byId('7404'), isNull,
          reason: '内存移除已生效——复合撤销闭包按 byId(copy.id)==null 判定'
              '（回滚反而会破坏该判据，见 discardTask 注释）');
    });

    test('skipOccurrence：失败 false 且内存已跳过；幂等早退 true', () async {
      final p = await buildWith([
        mk(id: '7405').copyWith(repeat: RepeatType.daily, repeatMinute: 480),
      ]);
      expect(await p.skipOccurrence('7405'), isTrue);
      expect(await p.skipOccurrence('7405'), isTrue, reason: '已跳过：幂等');
      await p.unskipOccurrence('7405');

      LocalDatabase.testUseMemory = false;
      final bool ok;
      try {
        ok = await p.skipOccurrence('7405');
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(ok, isFalse, reason: '旧实现 void：DB 异常时弹层照显「已跳过」、'
          '重启回退且零反馈');
      expect(p.byId('7405')!.skipDates, isNotEmpty, reason: '内存已生效');
    });

    test('endRepeat 透传落盘结果：失败 false 且内存已结束', () async {
      final p = await buildWith([
        mk(id: '7406').copyWith(repeat: RepeatType.daily, repeatMinute: 480),
      ]);
      LocalDatabase.testUseMemory = false;
      final bool ok;
      try {
        ok = await p.endRepeat('7406');
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(ok, isFalse);
      expect(p.byId('7406')!.repeatEnded, isTrue, reason: '内存已生效');
    });

    test('pauseRepeatsUntil 返回 (until, saved)：失败 saved=false 且暂停已生效',
        () async {
      final p = await buildWith([
        mk(id: '7407').copyWith(repeat: RepeatType.daily, repeatMinute: 480),
      ]);
      LocalDatabase.testUseMemory = false;
      final r = await p.pauseRepeatsUntil(
          '7407', today().add(const Duration(days: 2)));
      LocalDatabase.testUseMemory = true;
      expect(r.until, isNotNull, reason: '内存暂停已生效（生效终点照常返回）');
      expect(r.saved, isFalse, reason: '旧实现丢弃 _persist 结果：DB 异常时'
          '「已暂停至 M/d」横幅照弹、重启回退且零反馈');
      expect(p.byId('7407')!.pausedToday, isTrue);
    });

    test('undoDelete 返回 (applied, saved)：成功双 true；缓冲已消费 applied=false',
        () async {
      final p = await buildWith([mk(id: '7408')]);
      final r = await p.deleteTaskAs('7408');
      final u = await p.undoDelete(r.$1);
      expect(u.applied, isTrue);
      expect(u.saved, isTrue);
      expect((await p.undoDelete(r.$1)).applied, isFalse,
          reason: '同一 batchId 已消费——旧实现 bool 双义（失效 vs 落盘失败）'
              '压进同一个 false，v3.0.7 起拆开');
    });

    test('batchUpdateAs / undoBatchEdit 透传落盘结果（saved=false 可区分）',
        () async {
      final p = await buildWith([mk(id: '7409'), mk(id: '7410')]);
      LocalDatabase.testUseMemory = false;
      final r = await p.batchUpdateAs(
          ['7409', '7410'], (t) => t.copyWith(pinned: true));
      expect(p.byId('7409')!.pinned, isTrue,
          reason: '内存编辑已生效（任务侧修改类不回滚口径）——此断言须在撤销前，'
              'undoBatchEdit 会把快照（pinned=false）写回内存');
      // 失败窗口须覆盖两次写入（批量 + 撤销），undoBatchEdit 的 saved 才是 false。
      final u = await p.undoBatchEdit(r.$1);
      LocalDatabase.testUseMemory = true;
      expect(r.$1, isNot(0), reason: 'batchId 照常分配（撤销缓冲已登记）');
      expect(r.$2, 2);
      expect(r.$3, isFalse, reason: 'saved=false——调用方先弹写入失败再给横幅');

      expect(u.applied, isTrue, reason: '内存撤销生效（快照已回写）');
      expect(p.byId('7409')!.pinned, isFalse,
          reason: '撤销把内存回滚到编辑前（pinned 复原）——applied 的语义印证');
      expect(u.saved, isFalse, reason: '落盘仍失败——调用方弹「写入失败」而'
          '非「撤销已失效」（与 taskUndoAction 三分支口径对齐）');
    });

    // P3-4（v3.0.8 审计）：断言口径修正。旧断言「archiveTag 失败 false」把
    // 「任务表写失败」当成归档失败——归档只写 SharedPreferences、不碰任务表，
    // 旧实现的无条件 _persist() 既写放大又制造反向误导（安全模式下误报
    // 「不会保存」，而归档其实已存 prefs）。现拆为两个语义分别钉死：
    // ① archiveTag：DB 异常下仍返回 true（prefs 写入成功即归档成功）；
    // ② renameTag：真改任务表，DB 异常下 saved=false 照旧透传。
    test('标签族落盘结果透传：archiveTag 只写 prefs（DB 异常不影响）；'
        'renameTag 失败 false', () async {
      final p = await buildWith([mk(id: '7411').copyWith(tags: ['工作'])]);
      // 前提：先把「工作」成功归档（幂等分支的对照——已归档再归档 = true 无操作）。
      // 旧写法 archiveTag('不存在') 会把「不存在」加进集合（add 非幂等命中），
      // 且 renameTag 会迁移归档态（工作→主业），旧断言 contains('工作') 必然翻车。
      await p.archiveTag('工作');
      expect(await p.archiveTag('工作'), isTrue, reason: '集合未变 = true 无操作');
      LocalDatabase.testUseMemory = false;
      final bool okArchive;
      final bool okRename;
      try {
        okArchive = await p.archiveTag('新标签');
        okRename = await p.renameTag('工作', '主业');
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(okArchive, isTrue,
          reason: 'P3-4：归档只写 prefs，任务表写失败不该连坐——旧实现此时误报'
              '「安全模式下更改不会保存」，而重启后标签仍是归档的（提示与事实相反）');
      expect(okRename, isFalse, reason: 'renameTag 真改任务表，DB 异常如实上报');
      expect(p.archivedTags, contains('新标签'),
          reason: '内存已生效（归档集合不回滚——与任务侧修改类口径一致）');
      expect(p.byId('7411')!.tags, contains('主业'),
          reason: '重命名内存已生效（归档态随 renameTag 迁移：工作→主业）');
    });

    test('persistNow：把当前内存态整体写库（通知「重试」action 的输入）', () async {
      final p = await buildWith([mk(id: '7412')]);
      expect(await p.setStatus('7412', TaskStatus.done), isTrue);
      LocalDatabase.testUseMemory = false;
      final bool fail;
      try {
        fail = await p.persistNow();
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      expect(fail, isFalse, reason: 'DB 异常 → false（_doRetrySave 据此保留回执）');
      expect(await p.persistNow(), isTrue, reason: '恢复正常库 → 重试落盘成功');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-1：通知侧三个失败回执（service 层）+ persistNow
  // ══════════════════════════════════════════════════════════════════
  group('P3-1 通知侧失败回执', () {
    test('showCompleteNotSaved：任务段覆盖位 + 「重试」action（persistNow 语义）',
        () async {
      await NotificationService.instance.showCompleteNotSaved('7501', '买牛奶');
      await drainMicrotasks();
      final shows = notifCalls.where((c) => c.method == 'show').toList();
      expect(shows, hasLength(1));
      final args = Map<String, dynamic>.from(shows.single.arguments as Map);
      expect(args['title'], '完成未保存',
          reason: '与「已完成 ✓」区分——落盘失败必须如实回报（旧实现只记日志：'
              '源提醒已撤、通知消失后零反馈，安全模式下 100% 触发）');
      expect(args['body'], contains('保存失败'));
      expect(args['payload'], '${NotificationService.payloadTaskPrefix}7501');
      final ps = Map<String, dynamic>.from(args['platformSpecifics'] as Map);
      final actions = (ps['actions'] as List).cast<Map>();
      expect(actions, hasLength(1));
      expect(actions.single['id'], NotificationService.taskRetrySaveActionId);
      expect(actions.single['title'], '重试',
          reason: '重试 = persistNow（setStatus 幂等早退不会再写盘，不能重调）');
    });

    test('showHabitCheckInNotSaved：9 号槽 + 习惯 action（失败已回滚，重试干净）',
        () async {
      final (hp, habit) = await habitWith();
      await NotificationService.instance.showHabitCheckInNotSaved(
        habit,
        value: hp.todayValue(habit),
        target: habit.effectiveTarget,
      );
      await drainMicrotasks();
      final shows = notifCalls.where((c) => c.method == 'show').toList();
      expect(shows, hasLength(1));
      final args = Map<String, dynamic>.from(shows.single.arguments as Map);
      expect(args['title'], '打卡未保存');
      expect(args['body'], contains('保存失败'));
      final ps = Map<String, dynamic>.from(args['platformSpecifics'] as Map);
      expect(args['id'], NotificationService.habitConfirmNotifyIdOf(habit.id),
          reason: '落 9 号槽覆盖——与打卡/撤销确认条同位替换，不刷屏');
      final actions = (ps['actions'] as List).cast<Map>();
      expect(actions.map((a) => a['id']),
          contains(NotificationService.habitCheckInActionId),
          reason: '挂习惯打卡 action：provider 失败已回滚内存，重试 = 干净的再次 +1');
    });

    test('showHabitUndoNotSaved：9 号槽 + 「重试」action + 带展示日 payload',
        () async {
      final (hp, habit) = await habitWith();
      await NotificationService.instance.showHabitUndoNotSaved(
        habit,
        value: hp.todayValue(habit),
        target: habit.effectiveTarget,
      );
      await drainMicrotasks();
      final args = Map<String, dynamic>.from(
          notifCalls.where((c) => c.method == 'show').single.arguments as Map);
      expect(args['title'], '撤销未保存');
      // U3-3（v3.0.8 审计）：正文改「撤销未保存，请重试」——旧文案「已回退但
      // 保存失败」与事实相反（setCheckInValue 失败会回滚内存，实际**没有回退**）。
      expect(args['body'], contains('撤销未保存，请重试'));
      expect(args['payload'],
          '${NotificationService.payloadHabitPrefix}${NotificationService.habitEntityWithDate(habit.id, NotificationService.habitConfirmDateKey(DateTime.now()))}',
          reason: '与确认条撤销同路由（带展示日校验）：重试 = 干净的再次 -1');
      final ps = Map<String, dynamic>.from(args['platformSpecifics'] as Map);
      final actions = (ps['actions'] as List).cast<Map>();
      expect(actions.single['id'], NotificationService.habitUndoActionId);
      expect(actions.single['title'], '重试');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // P3-2 / P3-3 / U2-2：失败提示的文案分化（widget）
  // ══════════════════════════════════════════════════════════════════
  group('P3-2/P3-3/U2-2 失败提示文案', () {
    Widget host(void Function(BuildContext) onTap) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: TextButton(onPressed: () => onTap(ctx), child: const Text('go')),
              ),
            ),
          ),
        );

    testWidgets('正常 DB 异常：文案落到具体动作，不再承诺不存在的「请重试」（U2-2）',
        (tester) async {
      // 🔴 v306 同款教训：testWidgets 跑在 FakeAsync 时钟下，而 buildWith
      // （restoreFromJson 尾部）有真实 I/O，直接 await 永远等不到完成——
      // 整条用例挂死 10 分钟被超时终止。必须包 tester.runAsync 播种。
      final p = (await tester.runAsync(() => buildWith([mk(id: '7601')])))!;
      await tester.pumpWidget(host((ctx) async {
        showTaskPersistFailedHint(ctx, provider: p);
      }));
      await tester.tap(find.text('go'));
      await tester.pump();
      final text = tester.widget<Text>(
          find.textContaining('写入失败：数据未保存')).data!;
      expect(text, isNot(contains('请重试')),
          reason: '撤销类一次性 action 场景没有重试载体（横幅点按即关），'
              '「请重试」是虚假承诺（U2-2）');
      expect(text, contains('自动一并保存'),
          reason: '全量 replaceTasks 写：后续任意成功写入即自愈——把「重试」'
              '落到事实上成立的动作');
      expect(text, isNot(contains('安全模式')));
    });

    testWidgets('安全模式：不再复读「写入失败请重试」，指向根因（P3-2）', (tester) async {
      // dbLoadFailed 置位的真实路径 = load 失败（testUseMemory=false 注入）。
      LocalDatabase.testUseMemory = false;
      final p = TaskProvider();
      try {
        await p.load();
      } catch (_) {
        // load 失败 rethrow——安全模式正是由此进入。
      }
      LocalDatabase.testUseMemory = true;
      expect(p.dbLoadFailed, isTrue, reason: '前提：已进入只读安全模式');

      await tester.pumpWidget(host((ctx) async {
        showTaskPersistFailedHint(ctx, provider: p);
      }));
      await tester.tap(find.text('go'));
      await tester.pump();
      final text = tester.widget<Text>(find.textContaining('安全模式')).data!;
      expect(text, isNot(contains('请重试')),
          reason: '安全模式下 _persist() 恒 false 是设计行为（保护坏库），'
              '顶部横幅已告知「不会保存」——再弹「请重试」是误导（重试必然再失败）');
    });

    testWidgets('任务不存在（false 双义之二）：专属文案，不误导重试（P3-3）',
        (tester) async {
      // 🔴 同上：buildWith 须包 runAsync（FakeAsync + 真实 I/O 死锁教训）。
      final p = (await tester.runAsync(() => buildWith([])))!;
      await tester.pumpWidget(host((ctx) async {
        consumeTaskWriteResult(ctx, p, 'ghost', Future.value(false));
      }));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(find.textContaining('任务已不存在'), findsOneWidget,
          reason: 'byId 判空拆双义——与 taskUndoAction / 通知侧 _doComplete '
              '的既有口径对齐（旧实现四消费点把「实体消失」与「落盘失败」'
              '压进同一句「写入失败请重试」）');
    });
  });
}
