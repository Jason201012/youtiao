import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/task_event.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/calendar_date.dart';
import 'package:todolist/services/daily_briefing.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/update_checker.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/models/focus_session.dart';

import 'test_helpers.dart';

/// v3.2.0 审计修复轮回归测试（《有条功能与操作审计报告（v3.2.0）》）。
///
/// 每条修复至少一个「能区分修与未修」的用例；纯 UI 项见文件尾说明。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(notifCh, (call) async => null);
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureCh, (call) async => null);

  late Directory docs;
  setUp(() async {
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    NotificationService.instance.enabled = true;
    docs = await Directory.systemTemp.createTemp('yt-audit-320-');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
  });

  tearDown(() {
    try {
      docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> drain() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

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
    DateTime? start,
    TaskStatus status = TaskStatus.todo,
    DateTime? completedAt,
    RepeatType repeat = RepeatType.none,
    List<String> skipDates = const [],
    int focusSecTotal = 0,
    bool pinned = false,
    List<AttachmentRef> attachments = const [],
  }) =>
      Task(
        id: id,
        title: title,
        priority: Priority.medium,
        category: Category.work,
        dueDate: due,
        startDate: start,
        status: status,
        completedAt: completedAt,
        repeat: repeat,
        skipDates: skipDates,
        focusSecTotal: focusSecTotal,
        pinned: pinned,
        attachments: attachments,
      );

  // ═══════════════════ P2-1 日历拖拽整体平移 ═══════════════════
  group('P2-1 时间段任务改期', () {
    test('shiftedToDay 同步平移 startDate 与 dueDate，时分不变', () {
      final base = DateTime(2026, 11, 27, 14);
      final t = mk('1', start: base, due: base.add(const Duration(hours: 1)));
      final moved = t.shiftedToDay(DateTime(2026, 11, 28, 0));
      expect(moved.dueDate, DateTime(2026, 11, 28, 15, 0));
      expect(moved.startDate, DateTime(2026, 11, 28, 14, 0));
      // 平移后仍是同日时间段，不再变成跨天区间。
      expect(
          moved.startDate!.day == moved.dueDate!.day &&
              moved.startDate!.month == moved.dueDate!.month,
          isTrue);
    });

    test('跨天区间整体平移保持日差，无 startDate 的任务不受影响', () {
      final t = mk('2',
          start: DateTime(2026, 11, 27, 9), due: DateTime(2026, 11, 29, 18, 30));
      final moved = t.shiftedToDay(DateTime(2026, 12, 2));
      expect(moved.startDate, DateTime(2026, 11, 30, 9));
      expect(moved.dueDate, DateTime(2026, 12, 2, 18, 30));
      final plain = mk('3', due: DateTime(2026, 11, 27, 9));
      expect(plain.shiftedToDay(DateTime(2026, 11, 28)).startDate, isNull);
    });
  });

  // ═══════════════════ P2-2 一次性副本 ═══════════════════
  group('P2-2 仅此一次改期副本', () {
    test('副本不继承悬空附件 / 专注累计 / 置顶，且 startDate 同步平移', () async {
      final today = DateTime(2026, 11, 27);
      final target = DateTime(2026, 11, 29);
      final ref = AttachmentRef(
        id: 'a1',
        type: AttachmentType.image,
        fileName: 'missing.png',
        sizeBytes: 10,
        createdAt: today,
      );
      final p = await buildWith([
        mk('1',
            due: today.add(const Duration(hours: 9)),
            start: today.add(const Duration(hours: 8)),
            repeat: RepeatType.daily,
            // 目标日显式跳过：repeatsOn(target)=false，保证走「建副本」分支。
            skipDates: [Task.ymdKey(target)],
            focusSecTotal: 3600,
            pinned: true,
            attachments: [ref]),
      ]);
      final src = p.byId('1')!;
      final r = await p.rescheduleOnceOccurrence('1', target, origDay: today);
      expect(r.coveredByLoop, isFalse);
      expect(r.copyFailed, isFalse);
      expect(r.copy, isNotNull);
      final copy = r.copy!;
      // 附件文件不存在 → 实体复制失败：元数据也必须清空，不能留悬空引用。
      expect(copy.attachments, isEmpty, reason: '副本不得继承打不开的附件引用');
      expect(r.attachmentsDropped, isTrue);
      expect(copy.focusSecTotal, 0);
      expect(copy.pinned, isFalse);
      expect(copy.startDate, DateTime(2026, 11, 29, 8));
      expect(copy.dueDate, DateTime(2026, 11, 29, 9));
      // 源任务未被改写。
      expect(p.byId('1')!.startDate, src.startDate);
      expect(p.byId('1')!.attachments.length, 1);
    });
  });

  // ═══════════════════ P2-3 批量改期 ═══════════════════
  group('P2-3 批量改期对重复任务不假成功', () {
    test('postponeToAs 跳过重复任务与无截止任务，计数只含真实变更', () async {
      final today = DateTime(2026, 11, 27);
      final p = await buildWith([
        mk('r', due: today.add(const Duration(hours: 7)), repeat: RepeatType.daily),
        mk('n', due: today.add(const Duration(hours: 9))),
        mk('none', title: '无截止'),
      ]);
      final r = await p.postponeToAs(['r', 'n', 'none'], DateTime(2026, 11, 30));
      expect(r.$2, 1, reason: '只有一条一次性有截止任务真正被改动');
      expect(p.byId('r')!.dueDate, today.add(const Duration(hours: 7)));
      expect(p.byId('n')!.dueDate, DateTime(2026, 11, 30, 9));
      expect(p.byId('none')!.dueDate, isNull);
    });

    test('batchUpdateAs 可显式排除指定任务且 no-op 不计入已更新', () async {
      final p = await buildWith([
        mk('1', due: DateTime(2026, 11, 27, 9)),
        mk('2', due: DateTime(2026, 11, 27, 9)),
        mk('none'),
      ]);
      final r = await p.batchUpdateAs(
        ['1', '2', 'none'],
        // 无截止任务原样返回（与批量编辑的 _shiftTo 同口径），不得计入 changed。
        (t) => t.dueDate == null
            ? t
            : t.copyWith(dueDate: DateTime(2026, 11, 28, 9)),
        excludeIds: {'2'},
      );
      expect(r.$2, 1);
      expect(p.byId('2')!.dueDate, DateTime(2026, 11, 27, 9));
    });
  });

  // ═══════════════════ P2-4 习惯目标快照 ═══════════════════
  group('P2-4 习惯历史达标保真', () {
    test('提高每日目标不追溯改写历史达标；新打卡按新目标判定', () async {
      final hp = HabitProvider();
      await hp.load();
      await hp.addHabit(
        title: '喝水',
        emoji: '💧',
        colorValue: 1,
        weekdays: const [],
        dailyTarget: 8,
      );
      final h = hp.habits.single;
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await hp.setCheckInValue(h, yesterday, 8);
      expect(hp.checkInCount(h), 1);
      expect(hp.currentStreak(h), 1);

      await hp.updateHabit(h, dailyTarget: 12);
      final changed = hp.habits.single;
      // 历史 8 杯按当时的 8 杯目标仍算达标，连续天数不崩塌。
      expect(hp.checkInCount(changed), 1, reason: '历史达标须按目标快照判定');
      expect(hp.currentStreak(changed), 1);

      await hp.setCheckInValue(changed, DateTime.now(), 8);
      expect(hp.isTargetMetToday(hp.habits.single), isFalse,
          reason: '新记录按 12 杯目标判定');
      expect(hp.checkInCount(hp.habits.single), 1);
    });
  });

  // ═══════════════════ P2-5 当日统计口径 ═══════════════════
  group('P2-5 当日事件单一真源', () {
    test('无截止已完成任务只在完成当天计入当日事件', () {
      final now = DateTime.now();
      final old = mk('old',
          status: TaskStatus.done,
          completedAt: now.subtract(const Duration(days: 4)));
      final fresh = mk('fresh',
          status: TaskStatus.done, completedAt: now);
      final pending = mk('pending');
      expect(isTaskEventOn(old, now), isFalse);
      expect(isTaskEventOn(fresh, now), isTrue);
      expect(isTaskEventOn(pending, now), isTrue);
    });

    test('todayEventTotal / todayCompleted 排除历史无截止完成', () async {
      final now = DateTime.now();
      final p = await buildWith([
        mk('1', status: TaskStatus.done,
            completedAt: now.subtract(const Duration(days: 4))),
        mk('2', status: TaskStatus.done, completedAt: now),
        mk('3', due: now),
      ]);
      expect(p.todayEventTotal, 2);
      expect(p.todayCompleted, 1);
      expect(p.todayCompletionRate, closeTo(0.5, 1e-9));
    });
  });

  // ═══════════════════ P3-1 今日三件撤销删除 ═══════════════════
  group('P3-1 今日三件悬空 id 保留', () {
    test('删除后补选再撤销删除，原选择自动回来', () async {
      final p = await buildWith([mk('A'), mk('B'), mk('C'), mk('D')]);
      await p.setTodayMit(['A', 'B', 'C']);
      await p.deleteTask('B');
      expect(p.todayMit, ['A', 'C']);
      // 补选 D：旧实现在这里把 B 的 id 从底层 map 洗掉。
      await p.toggleTodayMitDetailed('D');
      expect(p.todayMit, ['A', 'C', 'D']);
      await p.restoreFromTrash('B');
      expect(p.todayMit, contains('B'), reason: '撤销删除后原选择应自动回来');
      expect(p.todayMit.length, 3);
    });
  });

  // ═══════════════════ P3-2 跨午夜专注 ═══════════════════
  group('P3-2 跨午夜专注归日', () {
    test('20 分钟跨午夜会话按日各计 10 分钟，番茄数归开始日', () async {
      final fp = FocusProvider();
      await fp.load();
      final start = DateTime(2026, 11, 27, 23, 50);
      await fp.addSession(FocusSession(
        id: 'cross',
        plannedSec: 1200,
        durationSec: 1200,
        completed: true,
        startedAt: start,
        endedAt: DateTime(2026, 11, 28, 0, 10),
      ));
      expect(fp.focusSecOn(DateTime(2026, 11, 27)), 600);
      expect(fp.focusSecOn(DateTime(2026, 11, 28)), 600);
      expect(fp.focusSecOn(DateTime(2026, 11, 27)) +
          fp.focusSecOn(DateTime(2026, 11, 28)), 1200);
      expect(fp.completedOn(DateTime(2026, 11, 27)), 1);
      expect(fp.completedOn(DateTime(2026, 11, 28)), 0);
      expect(fp.sessionsOn(DateTime(2026, 11, 27)), hasLength(1));
      expect(fp.sessionsOn(DateTime(2026, 11, 28)), hasLength(1));
    });
  });

  // ═══════════════════ P3-3 DST 日历日差 ═══════════════════
  group('P3-3 日历日差单一真源', () {
    test('UTC 零点求差不受时分影响，日期加减跨月正确', () {
      expect(
          calendarDaysBetween(DateTime(2026, 11, 27, 23, 59),
              DateTime(2026, 11, 28, 0, 1)),
          1);
      expect(
          calendarDaysBetween(DateTime(2026, 11, 28), DateTime(2026, 11, 27)),
          -1);
      expect(addCalendarDays(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 1));
      expect(addCalendarDays(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
    });
  });

  // ═══════════════════ P3-4 自动更新开关 ═══════════════════
  group('P3-4 自动检查更新开关', () {
    test('默认开启；关闭后 shouldAutoPrompt 恒 false，手动检查不受影响', () async {
      expect(await UpdateChecker.autoCheckEnabled(), isTrue);
      expect(await UpdateChecker.shouldAutoPrompt(), isTrue);
      await UpdateChecker.setAutoCheckEnabled(false);
      expect(await UpdateChecker.autoCheckEnabled(), isFalse);
      expect(await UpdateChecker.shouldAutoPrompt(), isFalse);
      await UpdateChecker.setAutoCheckEnabled(true);
      expect(await UpdateChecker.shouldAutoPrompt(), isTrue);
    });
  });

  // ═══════════════════ P3-5 唯一文件名 ═══════════════════
  group('P3-5 备份 / 导出唯一文件名', () {
    test('时间戳含秒毫秒且连续两次不重复', () {
      final a = DataIo.uniqueFileStamp();
      final b = DataIo.uniqueFileStamp();
      expect(a, isNot(b));
      expect(RegExp(r'^\d{8}-\d{6}-\d{3}[0-9a-f]{5}$').hasMatch(a), isTrue);
      final fixed = DataIo.uniqueFileStamp(DateTime(2026, 11, 27, 15, 30, 45));
      expect(fixed, startsWith('20261127-153045-'));
    });
  });

  // ═══════════════════ P3-6 附件提升回执 ═══════════════════
  group('P3-6 附件实体一致性', () {
    test('existingRefs 只保留实体存在的引用；copyTaskAttachments 复制到新目录', () async {
      final srcDir = await AttachmentService.dirFor('src');
      final ref = AttachmentRef(
        id: 'a1',
        type: AttachmentType.file,
        fileName: 'a.txt',
        sizeBytes: 5,
        createdAt: DateTime(2026),
      );
      final gone = AttachmentRef(
        id: 'a2',
        type: AttachmentType.file,
        fileName: 'gone.txt',
        sizeBytes: 5,
        createdAt: DateTime(2026),
      );
      await File('${srcDir.path}/a.txt').writeAsString('hello');
      expect(await AttachmentService.existingRefs('src', [ref, gone]), [ref]);

      final copied = await AttachmentService.copyTaskAttachments(
          'src', 'dst', [ref]);
      expect(copied, [ref]);
      final dstDir = await AttachmentService.dirFor('dst');
      expect(await File('${dstDir.path}/a.txt').readAsString(), 'hello');
      await expectLater(
        AttachmentService.copyTaskAttachments('src', 'dst2', [gone]),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ═══════════════════ P3-7 起止时间校验 ═══════════════════
  group('P3-7 时间区间不变量', () {
    test('hasInvalidTimeRange 只认开始晚于截止', () {
      expect(
          mk('1',
                  start: DateTime(2026, 11, 28, 14),
                  due: DateTime(2026, 11, 27, 15))
              .hasInvalidTimeRange,
          isTrue);
      expect(
          mk('2',
                  start: DateTime(2026, 11, 27, 14),
                  due: DateTime(2026, 11, 27, 15))
              .hasInvalidTimeRange,
          isFalse);
      expect(
          mk('3', start: DateTime(2026, 11, 27, 14)).hasInvalidTimeRange,
          isFalse);
    });
  });

  // ═══════════════════ P3-8 晨报文案口径 ═══════════════════
  group('P3-8 晨报昨日未完成', () {
    test('只统计截止日为昨天的任务，不含更早逾期', () async {
      final today = DateTime(2026, 11, 27, 7, 30);
      final yesterday = DateTime(2026, 11, 26, 18);
      final p = await buildWith([
        mk('y', due: yesterday),
        mk('old', due: DateTime(2026, 11, 20, 18)),
      ]);
      final brief = buildMorningBriefFromState(
          p, FocusProvider(), HabitProvider(), forDay: today);
      expect(brief.lines.join('\n'), contains('昨日未完成任务：1 个'));
    });
  });

  // ═══════════════════ 打卡快照序列化 ═══════════════════
  group('打卡目标快照序列化', () {
    test('快照随 JSON 往返，脏值回退 null', () {
      final c = CheckIn.forDay('h', DateTime(2026, 11, 27),
          value: 12, target: 8);
      final restored = CheckIn.fromJson(c.toJson());
      expect(restored.targetAtWrite, 8);
      expect(restored.metBy(8), isTrue);
      expect(restored.metBy(13), isFalse, reason: '达标由调用方传入的目标裁决');
      expect(CheckIn.fromJson({'id': 'x', 'date': '2026-11-27T00:00:00',
        'value': 8, 'targetAtWrite': -1}).targetAtWrite, isNull);
    });
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
