import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/services/update_policy.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// v3.0.1 审计修复轮（《有条功能与操作审计报告（v3.0.1）》）回归测试。
/// 每条修复至少一个可区分用例；不落用例的项（P2-1 main.dart 顶层私有回调、
/// P2-4 Kotlin 桌件、UI 文案接线）见修复对照表说明。
///
/// 覆盖清单：
/// - **P1-1** 更新白名单补 releases-4（单元）+ **发版护栏**：仓库根 update.json
///   的 apkUrl / releaseUrl 必须落在客户端白名单内（换仓漏改 CI 直接红）；
/// - **P2-2** 新建导入路径应用 meta 状态 / 完成时间（含 id 撞库转新建分支）；
/// - **P2-3** 归档习惯 `setCheckInValue` 守卫（provider 层兜底）；
/// - **P3-1** 覆盖合并保留显式 `pausedUntil`；
/// - **P3-3** 模板 JSON 兄弟字段与 Task.fromJson 同口径夹取（不再抛错 / 产哑任务）；
/// - **P3-4** `cancelHabitReminder` 增清 9 号槽确认通知（经归档路径验证）；
/// - **P3-5** 覆盖路径批内去重以**最新**对象为合并基准 + 指纹索引同步刷新；
/// - **P3-2** `pausedUntilDate` 回退推导早退语义不变 + `pauseDisplay` 区分推导态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  LocalDatabase.resetMemoryForTest();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();

  // 记录型通知插件 mock：除返回 null 外，把全部方法调用留档，
  // 供 P3-4 断言 cancel 的通知 id（含 9 号槽）。
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
    LocalDatabase.resetMemoryForTest();
    notifCalls.clear();
  });

  DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  Future<TaskProvider> buildWith(List<Task> tasks) async {
    final p = TaskProvider();
    final json = jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': const <Map<String, dynamic>>[],
      'notifications_enabled': false,
      'sound_enabled': false,
    });
    await p.restoreFromJson(json);
    return p;
  }

  Task mk({
    String id = '',
    String title = '任务',
    DateTime? due,
    TaskStatus status = TaskStatus.todo,
    DateTime? completedAt,
    Priority priority = Priority.medium,
    Category category = Category.work,
    String note = '',
    RepeatType repeat = RepeatType.none,
    List<int> repeatWeekdays = const [],
    List<String> skipDates = const [],
    int monthlyFromEnd = 0,
    String? pausedUntil,
  }) =>
      Task(
        id: id,
        title: title,
        priority: priority,
        category: category,
        dueDate: due,
        status: status,
        completedAt: completedAt,
        note: note,
        repeat: repeat,
        repeatWeekdays: repeatWeekdays,
        skipDates: skipDates,
        monthlyFromEnd: monthlyFromEnd,
        pausedUntil: pausedUntil,
      );

  // ── P1-1：更新链路白名单 + 发版护栏 ──────────────────────────────
  test('P1-1 发版护栏：仓库根 update.json 必须整体落在客户端白名单内', () {
    final f = File('update.json');
    expect(f.existsSync(), isTrue,
        reason: 'update.json 应位于仓库根（flutter test 的工作目录）');
    final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    expect(UpdatePolicy.isValidVersion((data['version'] as String).trim()),
        isTrue);
    expect(
        UpdatePolicy.isAllowedApkUrl(data['apkUrl'] as String), isTrue,
        reason: 'apkUrl 换仓时必须同步 UpdatePolicy.apkUrlPrefixes——P1-1：'
            'v3.0.1 迁 releases-4 漏改白名单，所有已装版本应用内下载 100% 被拒');
    expect(UpdatePolicy.isAllowedReleaseUrl(data['releaseUrl'] as String),
        isTrue,
        reason: 'releaseUrl 换仓时必须同步 UpdatePolicy.releaseUrlPrefixes，'
            '否则被静默丢弃、「浏览器下载」兜底回落旧仓');
  });

  test('P1-1：releases-4 前缀放行，其余仓 / 非作者仓 / 非白名单主机仍拒绝', () {
    const apk4 =
        'https://gitee.com/jason1012/youtiao-releases-4/releases/download/v3.0.1/app-release-3.0.1-arm64.apk';
    const rel4 =
        'https://gitee.com/jason1012/youtiao-releases-4/releases/tag/v3.0.1';
    expect(UpdatePolicy.isAllowedApkUrl(apk4), isTrue);
    expect(UpdatePolicy.isAllowedReleaseUrl(rel4), isTrue);
    // 未来换仓（-5）必须显式加白名单，不能靠宽松匹配放行。
    expect(
        UpdatePolicy.isAllowedApkUrl(
            'https://gitee.com/jason1012/youtiao-releases-5/releases/download/v1.0.0/a.apk'),
        isFalse);
    // 前缀校验锚定 owner + repo + 路径：他人同名仓 / 非白名单主机不放行。
    expect(
        UpdatePolicy.isAllowedApkUrl(
            'https://gitee.com/other/youtiao-releases-4/releases/download/v1.0.0/a.apk'),
        isFalse);
    expect(
        UpdatePolicy.isAllowedApkUrl(
            'https://evil.example.com/jason1012/youtiao-releases-4/releases/download/v1.0.0/a.apk'),
        isFalse);
  });

  // ── P2-2：新建导入路径应用 meta 状态 / 完成时间 ──────────────────
  test('P2-2：新建导入不再静默丢弃状态与完成时间（空库迁移场景）', () async {
    final p = await buildWith(const <Task>[]);
    final completedAt = DateTime(2026, 9, 30, 10, 30);
    final r = await p.importDedup(
      <Task>[
        mk(title: '已完成任务'),
        mk(title: '待办任务'),
        mk(title: '源未提供状态'),
      ],
      const ['', '', ''],
      fingerprint: true,
      statuses: const [TaskStatus.done, TaskStatus.todo, null],
      completedAts: [completedAt, null, null],
    );
    expect(r.added, 3);
    expect(r.skipped, 0);
    expect(r.overwritten, 0);
    Task one(String title) => p.tasks.firstWhere((t) => t.title == title);
    // 显式 done → 状态与完成时间都落位（旧行为：全部静默变回待办）。
    expect(one('已完成任务').status, TaskStatus.done);
    expect(one('已完成任务').completedAt, completedAt);
    // 显式 todo → 完成时间清空（CSV「待办」行不携带残留完成时间）。
    expect(one('待办任务').status, TaskStatus.todo);
    expect(one('待办任务').completedAt, isNull);
    // 源未提供 → 草稿原样（仍是待办、无完成时间）。
    expect(one('源未提供状态').status, TaskStatus.todo);
    expect(one('源未提供状态').completedAt, isNull);
  });

  test('P2-2：id 撞库转「新建」分支同样应用 meta（可疑 id 被丢弃、内容保真）', () async {
    final due1 = DateTime(2026, 10, 10);
    final due2 = DateTime(2026, 10, 11);
    final p = await buildWith(<Task>[
      mk(id: '500', title: '真实任务', due: due1),
    ]);
    // 第三方 .ics 枚举出的小整数 id 撞上真实任务，但内容指纹不一致 →
    // 丢弃 id、按全新任务导入，且 meta 状态 / 完成时间一并应用。
    final r = await p.importDedup(
      <Task>[mk(id: '500', title: '外部任务', due: due2)],
      const [''],
      fingerprint: true,
      statuses: const [TaskStatus.done],
      completedAts: [DateTime(2026, 10, 1, 8, 0)],
    );
    expect(r.added, 1);
    final real = p.tasks.firstWhere((t) => t.title == '真实任务');
    expect(real.id, '500'); // 真实任务未被改写
    expect(real.status, TaskStatus.todo);
    final imported = p.tasks.firstWhere((t) => t.title == '外部任务');
    expect(imported.id, isNot('500')); // 可疑 id 已被丢弃重排
    expect(imported.status, TaskStatus.done);
    expect(imported.completedAt, DateTime(2026, 10, 1, 8, 0));
  });

  // ── P3-1：覆盖合并保留显式暂停窗口 ──────────────────────────────
  test('P3-1：覆盖导入不再清空显式 pausedUntil 窗口（与 skipDates 同族保护）',
      () async {
    final due = DateTime(2026, 10, 15);
    final p = await buildWith(<Task>[
      mk(
        id: 'w',
        title: '每周报告',
        due: due,
        repeat: RepeatType.weekly,
        repeatWeekdays: const [3],
        pausedUntil: '2099-01-01',
      ),
    ]);
    // CSV / iCal 草稿不携带 pausedUntil（恒 null）——覆盖后必须保留原窗口。
    // 走 CSV 的指纹匹配形态：草稿无 id、无 youtiao UID，按「标题 + 截止」命中。
    final draft = mk(
      title: '每周报告',
      due: due,
      repeat: RepeatType.weekly,
      repeatWeekdays: const [3],
      note: '来自外部来源',
    );
    final r = await p.importDedup(<Task>[draft], const [''],
        overwrite: true, fingerprint: true);
    expect(r.overwritten, 1);
    final after = p.byId('w')!;
    expect(after.pausedUntil, '2099-01-01');
    // 合并本身仍然生效：来源显式携带的备注正常写入。
    expect(after.note, '来自外部来源');
  });

  // ── P3-5：覆盖路径批内去重以最新对象为基准 ────────────────────────
  test('P3-5：同批两行命中同一任务时，后行不再吞掉前一行刚写入的字段', () async {
    final due = DateTime(2026, 10, 10);
    final p = await buildWith(<Task>[
      mk(id: '7', title: '重复条目', due: due),
    ]);
    // 行 1 带备注、行 2 不带：旧行为下行 2 以「构建索引时的旧快照」为基准，
    // 空 note 视为「源为空保留原值」→ 保留旧快照的空串，吞掉行 1 的备注。
    final r = await p.importDedup(
      <Task>[
        mk(title: '重复条目', due: due, note: '重要备注'),
        mk(title: '重复条目', due: due),
      ],
      const ['', ''],
      overwrite: true,
      fingerprint: true,
    );
    expect(r.overwritten, 2);
    expect(p.byId('7')!.note, '重要备注');
  });

  // ── P3-3：模板 JSON 兄弟字段夹取 ────────────────────────────────
  test('P3-3：模板字段为字符串 / 越界时不再抛错、不再产出非法月规则', () {
    final t = TemplateItem.fromJson(const {
      'title': 'T',
      'repeatInterval': '3', // 字符串 → 回退默认（不再抛 TypeError 中断整份模板）
      'repeatMinute': 'x', // 非数值 → null（未设）
      'monthlyWeekday': 9, // 越界 → null（不再产出「永不命中」的哑规则）
      'monthlyWeekIndex': 0, // 越界 → null
      'monthlyFromEnd': 99, // 越界 → 缺省 0
      'monthlyDay': 0, // 越界 → 缺省 1（v2.9.7 既有口径）
      'dueInDays': '5', // 字符串 → null
    });
    expect(t.repeatInterval, 2);
    expect(t.repeatMinute, isNull);
    expect(t.monthlyWeekday, isNull);
    expect(t.monthlyWeekIndex, isNull);
    expect(t.monthlyFromEnd, 0);
    expect(t.monthlyDay, 1);
    expect(t.dueInDays, isNull);

    // 合法值原样通过（不误伤正常模板）。
    final ok = TemplateItem.fromJson(const {
      'title': 'OK',
      'repeatInterval': 5,
      'repeatMinute': 540,
      'monthlyWeekday': 3,
      'monthlyWeekIndex': 5,
      'monthlyFromEnd': 2,
      'dueInDays': 3,
    });
    expect(ok.repeatInterval, 5);
    expect(ok.repeatMinute, 540);
    expect(ok.monthlyWeekday, 3);
    expect(ok.monthlyWeekIndex, 5);
    expect(ok.monthlyFromEnd, 2);
    expect(ok.dueInDays, 3);
  });

  // ── P2-3 / P3-4：归档守卫 + 9 号槽取消 ──────────────────────────
  test('P2-3：归档习惯的 setCheckInValue 守卫——任何入口都不再产生新打卡', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '跑步',
      emoji: '🏃',
      colorValue: 1,
      weekdays: const [],
    );
    final habit = hp.habits.single;
    await hp.updateHabit(habit, archived: true);
    final archived = hp.byId(habit.id)!;
    expect(archived.archived, isTrue);

    // 直写 / 增减 / 打卡 / 切换四个族入口全部被守卫拦截（详情页 UI 已禁用，
    // 这里验证 provider 层兜底所有程序化入口）。
    await hp.setCheckInValue(archived, DateTime.now(), 1);
    await hp.adjustCheckInValue(archived, DateTime.now(), 1);
    await hp.toggleCheckInToday(archived);
    await hp.checkInOnDay(archived, DateTime.now());
    expect(hp.todayValue(archived), 0);
    expect(hp.isCheckedToday(archived), isFalse);
    expect(hp.checkInCount(archived), 0);
  });

  test('P3-4：归档习惯时 cancelHabitReminder 一并清掉 9 号槽确认通知', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '阅读',
      emoji: '📚',
      colorValue: 1,
      weekdays: const [],
      reminderMinute: 8 * 60,
    );
    final habit = hp.habits.single;
    await hp.updateHabit(habit, archived: true);
    // updateHabit(archived:true) → cancelHabitReminder → 0..7 + 8(snooze)
    // + 9(确认) 全部取消。旧行为漏 9 号槽：确认通知永久残留且指向已归档习惯。
    // Android 平台通道把 cancel 参数包装成 {'id': id, 'tag': tag}（17.2.4）。
    int? cancelIdOf(MethodCall c) {
      final a = c.arguments;
      if (a is int) return a;
      if (a is Map) return a['id'] as int?;
      return null;
    }

    final cancelIds = notifCalls
        .where((c) => c.method == 'cancel')
        .map(cancelIdOf)
        .whereType<int>()
        .toList();
    expect(cancelIds, contains(NotificationService.habitConfirmNotifyIdOf(habit.id)),
        reason: '删除 / 归档习惯必须撤掉指向该习惯的「已打卡 ✓ / 撤销」确认通知');
  });

  // ── P3-2：回退推导早退语义不变 + pauseDisplay 区分推导态 ─────────
  test('P3-2：无跳过记录恒非暂停；推导态 pauseDisplay.derived=true；显式窗口 false',
      () {
    // 与「今天」的星期几无关：相差 3 天必为不同 weekday。
    final wd = today().add(const Duration(days: 3)).weekday;

    // (a) 无 skipDates、无显式窗口：恒非暂停（早退后语义与逐位等价）。
    final t1 = mk(
      id: 'a',
      title: '每周任务',
      repeat: RepeatType.weekly,
      repeatWeekdays: [wd],
    );
    expect(t1.pausedUntilDate, isNull);
    expect(t1.pauseDisplay, isNull);

    // (b) 旧数据形态（未来循环日被跳过、无显式字段）：推导窗口 = 该日，
    //     derived = true —— UI 据此显示「已跳过至」而非「已暂停至」。
    final skippedDay = today().add(const Duration(days: 3));
    final t2 = mk(
      id: 'b',
      title: '每周任务',
      repeat: RepeatType.weekly,
      repeatWeekdays: [wd],
      // skipDates 不为空但不含任何循环日：推导仍为 null（窗口终点只能
      // 来自被跳过的循环日），且此时无法早退、必须真扫——语义不变。
      skipDates: [Task.ymdKey(today().add(const Duration(days: 1)))],
    );
    expect(t2.pausedUntilDate, isNull);
    expect(t2.pauseDisplay, isNull);

    final t3 = mk(
      id: 'c',
      title: '每周任务',
      repeat: RepeatType.weekly,
      repeatWeekdays: [wd],
      skipDates: [Task.ymdKey(skippedDay)],
    );
    expect(t3.pausedUntilDate, isNotNull);
    final p3 = t3.pauseDisplay!;
    expect(p3.derived, isTrue);
    expect(p3.end.year, skippedDay.year);
    expect(p3.end.month, skippedDay.month);
    expect(p3.end.day, skippedDay.day);

    // (c) 显式窗口（v2.9.9+ 暂停）：derived = false，终点即窗口值。
    final t4 = mk(
      id: 'd',
      title: '每周任务',
      repeat: RepeatType.weekly,
      repeatWeekdays: [wd],
      pausedUntil: '2099-01-01',
    );
    final p4 = t4.pauseDisplay!;
    expect(p4.derived, isFalse);
    expect(p4.end, DateTime(2099, 1, 1));
  });
}
