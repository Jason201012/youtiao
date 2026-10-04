import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/state/habit_provider.dart';
import 'test_helpers.dart';

/// v3.0.2 审计修复轮（《有条功能与操作审计报告（v3.0.2）》）回归测试。
/// 每条修复至少一个可区分用例；不落用例的项见文件尾说明。
///
/// 覆盖清单：
/// - **P3-1** 模板 JSON 同族残留：repeatWeekdays 过滤 / 去重 / 排序、
///   repeatUntil 净化（与 Task.fromJson 的 F-8 同口径）、字符串字段安全转型；
/// - **P3-1/U3-2** `loadAllWithBroken` 损坏文件计数（UI 据此给可见提示）；
/// - **P3-2** 已归档习惯 `snoozeHabitReminder` 入口早退（服务层兜底）；
/// - **P3-3** App 内撤销今日打卡（当日值降 0）后取消 9 号槽确认通知，
///   补昨天 / 前天的撤卡不误触；
/// - **P2-2** Dart 侧启动兜底 `deleteOrphanTaskDirs`：只清「整目录孤儿」，
///   活跃任务 / 回收站任务 / `_staging` / 非白名单目录一律不动。
///
/// 不落用例：**P2-1**（main.dart 顶层私有回调 `_handleNotificationAction` /
/// `_flushPendingIntents` 入队接线，库外不可达，与 v3.0.2 轮任务侧同判）；
/// **U3-3**（注释固化设计口径，无行为面）；**P2-2 Kotlin 接线**（无 Kotlin
/// 测试面，真机复现建议见报告 §九）；P3-2 的「已达标」守卫在 main._doSnooze
/// （同属 main.dart 顶层私有），服务层仅兜 archived 分支。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  // 记录型通知插件 mock：除返回 null 外，把全部方法调用留档，
  // 供 P3-3 断言 cancel 的通知 id（9 号槽确认）与 P3-2 断言未排新提醒。
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
    // 🔴 内存库是同进程共享单例：每个用例前必须重置 DB + prefs 再 load()，
    // 否则先跑的用例会往库里留数据（v2.9.7 轮实测教训）。
    LocalDatabase.resetMemoryForTest();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
  });

  // flutter_local_notifications 新版 cancel 的 MethodCall arguments 是 Map
  // （{'id': ...}），裸比较 `arguments == <int>` 恒不命中——与 v296 / v301
  // 既有断言同款的双形态防御提取。
  int? cancelIdOf(MethodCall c) {
    final a = c.arguments;
    if (a is int) return a;
    if (a is Map) return a['id'] as int?;
    return null;
  }

  // ── P3-1：模板 JSON 同族残留收口 ─────────────────────────────────
  test('P3-1：repeatWeekdays 与 Task.fromJson 完整同口径（1..7 过滤 + 去重 + 排序）',
      () {
    final t = TemplateItem.fromJson(const {
      'title': '周会',
      'repeat': 'weekly',
      'repeatWeekdays': [9, 3, 3, 1, 0, -2],
    });
    // 旧实现只 whereType<int>()：9 留存 → 套用后 repeatsOn 永不命中的哑任务；
    // 3 重复留存；顺序不保证。新口径过滤 + 去重 + 升序。
    expect(t.repeatWeekdays, [1, 3]);
    expect(t.repeat, RepeatType.weekly);

    // 非列表 / 缺省 → 空列表（不再抛错）。
    final t2 = TemplateItem.fromJson(const {
      'title': 'T2',
      'repeatWeekdays': 'weekly',
    });
    expect(t2.repeatWeekdays, isEmpty);

    // 合法值原样通过（不误伤正常模板）。
    final t3 = TemplateItem.fromJson(const {
      'title': 'T3',
      'repeatWeekdays': [5, 2],
    });
    expect(t3.repeatWeekdays, [2, 5]);
  });

  test('P3-1：repeatUntil 净化——非法串清空（视为无限循环），合法串原样', () {
    // 与备份路径 Task.fromJson 的 F-8 同口径：非法串若原样透传，会被
    // _parseYmd 回退 1970 → isRepeatEnded 恒真 → 任务被静默视为「已结束」。
    final bad = TemplateItem.fromJson(const {
      'title': 'B',
      'repeat': 'daily',
      'repeatUntil': 'abc',
    });
    expect(bad.repeatUntil, isNull);

    final bad2 = TemplateItem.fromJson(const {
      'title': 'B2',
      'repeatUntil': 123, // 非字符串 → null（旧实现抛 TypeError 中断整份模板）
    });
    expect(bad2.repeatUntil, isNull);

    final bad3 = TemplateItem.fromJson(const {
      'title': 'B3',
      'repeatUntil': '2027-1-31', // 形态非法（长度不对）→ null
    });
    expect(bad3.repeatUntil, isNull);

    final ok = TemplateItem.fromJson(const {
      'title': 'OK',
      'repeatUntil': '2027-01-31',
    });
    expect(ok.repeatUntil, '2027-01-31');

    // 缺省 / 显式 null → null（旧行为不变）。
    expect(
        TemplateItem.fromJson(const {'title': 'N'}).repeatUntil, isNull);
  });

  test('P3-1：字符串字段（title / repeat / note）安全转型——不再中断整份模板', () {
    // 旧实现三处裸 `as String?`：非字符串值抛 TypeError → 该模板从列表
    // 静默消失。新实现判型回退默认值。
    final t = TemplateItem.fromJson(const {
      'title': 123, // 非字符串 → ''（不再抛错）
      'repeat': 7, // 非字符串 → RepeatType.none
      'note': 456, // 非字符串 → ''
    });
    expect(t.title, '');
    expect(t.repeat, RepeatType.none);
    expect(t.note, '');

    // 正常值原样通过。
    final ok = TemplateItem.fromJson(const {
      'title': '正常标题',
      'repeat': 'interval',
      'note': '备注 A',
    });
    expect(ok.title, '正常标题');
    expect(ok.repeat, RepeatType.interval);
    expect(ok.note, '备注 A');
  });

  test('P3-1：UserTemplate.fromJson 单项字段损坏不再吞掉整份模板', () {
    // 项级字段异常时旧实现抛错 → loadAll 的 catch 把**整份模板**跳过；
    // 现在字段级容错后，仅该字段回退默认，模板与其余项正常加载。
    final t = UserTemplate.fromJson(const {
      'id': 'tpl1',
      'name': '混入坏字段',
      'items': [
        {'title': '好项', 'dueInDays': 1},
        {'title': 999, 'repeatWeekdays': [9, 2]},
      ],
    });
    expect(t.items.length, 2);
    expect(t.items[0].title, '好项');
    expect(t.items[1].title, ''); // 坏 title 回退空串
    expect(t.items[1].repeatWeekdays, [2]); // 9 被过滤
  });

  test('P3-1/U3-2：loadAllWithBroken 报告损坏文件数；loadAll 行为不变', () async {
    final tmp = await Directory.systemTemp.createTemp('v302_tpl_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final dir = Directory('${tmp.path}/templates/user');
    await dir.create(recursive: true);
    // 好模板 1 份。
    await File('${dir.path}/good.json').writeAsString('''
{"id":"good","name":"好模板","items":[{"title":"A","dueInDays":1}]}''');
    // 损坏模板 2 份（JSON 畸形 / 非 JSON）。
    await File('${dir.path}/broken1.json').writeAsString('{"id":');
    await File('${dir.path}/broken2.json').writeAsString('not json at all');

    final r = await UserTemplateStore.loadAllWithBroken();
    expect(r.templates.length, 1);
    expect(r.templates.single.name, '好模板');
    expect(r.broken, 2, reason: '损坏文件数必须可见（U3-2：不再静默消失）');

    // 旧入口行为逐位不变：仍返回纯列表。
    final list = await UserTemplateStore.loadAll();
    expect(list.length, 1);
  });

  // ── P3-2：已归档习惯的 snooze 服务层兜底 ─────────────────────────
  test('P3-2：已归档习惯 snoozeHabitReminder 早退——不排任何新提醒', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '已退场的习惯',
      emoji: '🏃',
      colorValue: 1,
      weekdays: const [],
    );
    final habit = hp.habits.single;
    await hp.updateHabit(habit, archived: true);
    final archived = hp.byId(habit.id)!;
    notifCalls.clear();

    final ok = await NotificationService.instance
        .snoozeHabitReminder(archived, delay: const Duration(minutes: 10));
    expect(ok, isFalse, reason: '归档 = 退场，不再排「稍后提醒」');
    expect(
      notifCalls.where((c) => c.method == 'zonedSchedule'),
      isEmpty,
      reason: '早退不得产生任何新落点（防在途旧闹钟的 snooze 复活）',
    );
  });

  // ── P3-3：App 内撤卡清 9 号槽确认通知 ───────────────────────────
  test('P3-3：今日打卡被撤到 0 时取消 9 号槽确认通知', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '喝水',
      emoji: '💧',
      colorValue: 1,
      weekdays: const [],
    );
    final habit = hp.habits.single;

    // 打卡（0 → 1）：布尔习惯此时已达标，P2-7 会撤 8 号槽 snooze——
    // 但绝不应撤 9 号槽（确认条刚刚由本次写入产生、内容为真）。
    await hp.setCheckInValue(habit, DateTime.now(), 1);
    expect(
      notifCalls.where((c) =>
          c.method == 'cancel' &&
          cancelIdOf(c) ==
              NotificationService.habitConfirmNotifyIdOf(habit.id)),
      isEmpty,
    );

    // 撤卡（1 → 0）：确认条「已打卡 ✓ / 撤销」内容失真 → 必须一并取消。
    // 修复前这里只会撤 8 号槽，9 号槽确认条永久残留（可被误点再退新卡）。
    await hp.setCheckInValue(habit, DateTime.now(), 0);
    expect(
      notifCalls.any((c) =>
          c.method == 'cancel' &&
          cancelIdOf(c) ==
              NotificationService.habitConfirmNotifyIdOf(habit.id)),
      isTrue,
      reason: '当日值降 0 后 9 号槽确认条已失真，必须取消',
    );
  });

  test('P3-3：补昨天 / 前天的撤卡不触发 9 号槽取消（只看今天）', () async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '阅读',
      emoji: '📚',
      colorValue: 1,
      weekdays: const [],
    );
    final habit = hp.habits.single;

    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    await hp.setCheckInValue(habit, yesterday, 1);
    await hp.setCheckInValue(habit, yesterday, 0);
    expect(
      notifCalls.any((c) =>
          c.method == 'cancel' &&
          cancelIdOf(c) ==
              NotificationService.habitConfirmNotifyIdOf(habit.id)),
      isFalse,
      reason: '展示中的确认条只与今天有关，补昨天的撤卡不该误清',
    );
  });

  // ── P2-2：Dart 侧启动兜底——只清整目录孤儿 ───────────────────────
  test('P2-2：deleteOrphanTaskDirs 只删「目录名不在 tasks ∪ trash」的整目录',
      () async {
    final tmp = await Directory.systemTemp.createTemp('v302_orphan_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    // 真实布局（P2-2 复核实证）：AttachmentService 全部访问器经 _base()
    // （<docs>/attachments）再拼一段 _attachmentsDirName —— 双层嵌套
    // attachments/attachments/<taskId>，与 dirFor/removeDir/scanAll 同一口径。
    final att = Directory('${tmp.path}/attachments/attachments');
    await Directory('${att.path}/2001').create(recursive: true);
    await File('${att.path}/2001/a.png').writeAsBytes([1, 2, 3]);
    await Directory('${att.path}/2002').create(recursive: true);
    await File('${att.path}/2002/b.png').writeAsBytes([4]);
    await Directory('${att.path}/9999').create(recursive: true);
    await File('${att.path}/9999/orphan.bin').writeAsBytes([9, 9]);
    await Directory('${att.path}/_staging/sess1').create(recursive: true);
    await File('${att.path}/_staging/sess1/x.tmp').writeAsBytes([7]);
    await Directory('${att.path}/bad name').create(recursive: true);

    // 直接构造「仍保有记录」的任务列表（活跃 + 回收站），不经 restoreFromJson
    // ——其尾部的元数据级 deleteOrphans 会先删掉无元数据目录，干扰本用例对
    // deleteOrphanTaskDirs 自身判定口径的断言。
    final tasks = <Task>[
      Task(
        id: '2001',
        title: '活跃任务',
        priority: Priority.medium,
        category: Category.work,
      ),
      Task(
        id: '2002',
        title: '回收站任务',
        priority: Priority.medium,
        category: Category.work,
        deletedAt: DateTime.now().subtract(const Duration(days: 1)),
      ),
    ];

    final removed = await AttachmentService.deleteOrphanTaskDirs(tasks);
    expect(removed, 1, reason: '只有 9999（无任何记录）是整目录孤儿');
    expect(await Directory('${att.path}/9999').exists(), isFalse);
    // 活跃任务 / 回收站任务目录保留。
    expect(await File('${att.path}/2001/a.png').exists(), isTrue);
    expect(await File('${att.path}/2002/b.png').exists(), isTrue);
    // staging 与非白名单目录不在本方法职责内，一律不动。
    expect(await File('${att.path}/_staging/sess1/x.tmp').exists(), isTrue);
    expect(await Directory('${att.path}/bad name').exists(), isTrue);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.docsPath);
  final String docsPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}
