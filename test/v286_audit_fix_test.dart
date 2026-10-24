import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/update_policy.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// v2.8.6 功能与操作审计报告（2026-09-12）修复回归测试。
///
/// 覆盖：P1-1（首页排序基准统一：order 优先于日期 + reorderTasks 写回可感知）、
/// P2-2（改期一次性副本清空 doneDates，统计不再双算）、
/// P3-1（习惯通知 id 换 FNV-1a：确定性 + 分布）、
/// P3-2（重定向白名单补端口校验）、
/// P2-4（换口令后旧加密快照改名 stale且不再出现在恢复面板）。
///
/// P2-1（弹层 _isDirty 补提醒字段）与 P2-3（时区跟随设备 + 设置页覆盖）为
/// UI / 平台通道行为，单测代价高，由 `dart analyze` + 真机人工验收兜底。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
  // P2-4 用例需要 flutter_secure_storage 通道（读写口令）。测试内回 null 即可：
  // write/delete 无返回值，read 返回 null = 密钥库为空，不影响内存态断言。
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secure, (call) async => null);
}

/// P2-4 用例：把 getApplicationDocumentsDirectory 指到临时目录。
class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

Task _repeatTask(
  String id, {
  RepeatType repeat = RepeatType.daily,
  int? repeatMinute = 420,
  DateTime? due,
  List<int> weekdays = const [],
  List<String> doneDates = const [],
  double order = 0.0,
}) =>
    Task(
      id: id,
      title: 'T$id',
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
      repeat: repeat,
      repeatWeekdays: weekdays,
      repeatInterval: 1,
      repeatMinute: repeatMinute,
      doneDates: doneDates,
      order: order,
    );

DateTime _day0(DateTime d) => DateTime(d.year, d.month, d.day);

Future<TaskProvider> _providerWith(List<Task> tasks) async {
  final p = TaskProvider();
  await p.restoreFromJson(jsonEncode(jsonOf(tasks)));
  return p;
}

Map<String, dynamic> jsonOf(List<Task> tasks) => {
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': [],
      'notifications_enabled': false,
    };

void main() {
  setUpAll(_installMocks);
  setUp(() => LocalDatabase.resetMemoryForTest());

  group('P1-1 首页排序基准统一（pinned → order → 日期）', () {
    test('今天分区：order 优先于截止时间（此前 UI 只看日期导致拖拽成果被冲掉）', () async {
      final now = DateTime.now();
      final today = _day0(now);
      // X 手动顺序在前（order=1）但截止更晚；Y order=2 截止更早。
      final x = _repeatTask('11',
          repeat: RepeatType.none,
          repeatMinute: null,
          due: today.add(const Duration(hours: 20)),
          order: 1);
      final y = _repeatTask('12',
          repeat: RepeatType.none,
          repeatMinute: null,
          due: today.add(const Duration(hours: 9)),
          order: 2);
      final p = await _providerWith([x, y]);
      final todayList = p.homeTasks['today']!;
      expect(todayList.map((t) => t.id).toList(), ['11', '12'],
          reason: 'order 是第二排序键，必须优先于 dueDate');
    });

    test('reorderTasks 写回的 order 在 homeTasks 重建后仍生效（拖拽成果可感知）', () async {
      final now = DateTime.now();
      final today = _day0(now);
      // A(09:00)、B(20:00)：order 相同 → 按截止时间排 [A, B]。
      final a = _repeatTask('21',
          repeat: RepeatType.none,
          repeatMinute: null,
          due: today.add(const Duration(hours: 9)));
      final b = _repeatTask('22',
          repeat: RepeatType.none,
          repeatMinute: null,
          due: today.add(const Duration(hours: 20)));
      final p = await _providerWith([a, b]);
      expect(p.homeTasks['today']!.map((t) => t.id).toList(), ['21', '22']);

      // UI 上把 B（index 1）拖到最前（newIndex=0）。
      p.reorderTasks('today', 1, 0);
      expect(p.homeTasks['today']!.map((t) => t.id).toList(), ['22', '21'],
          reason: '拖拽后 order 重写，重建的 homeTasks 必须保持新顺序');
      expect(p.byId('22')!.order, 1);
      expect(p.byId('21')!.order, 2);
    });
  });

  group('P2-2 改期一次性副本清空完成历史（统计不双算）', () {
    test('副本 doneDates 为空；原任务完成记录只计 1 次', () async {
      final now = DateTime.now();
      final today = _day0(now);
      final lastWeek = today.subtract(const Duration(days: 7));
      // weekly-周一任务，doneDates 记两次完成（今天 + 上周同日）。
      final p = await _providerWith([
        _repeatTask(
          '31',
          repeat: RepeatType.weekly,
          weekdays: const [DateTime.monday],
          repeatMinute: 480,
          doneDates: [Task.ymdKey(today), Task.ymdKey(lastWeek)],
        ),
      ]);
      // 目标日取一个确定不是周一的日子 → 会建一次性副本。
      var target = today.add(const Duration(days: 1));
      while (target.weekday == DateTime.monday) {
        target = target.add(const Duration(days: 1));
      }
      // P2-2（v3.0.7 审计）：rescheduleOnceOccurrence 随 addTask 异步化。
      // P3-2（v3.0.8 审计）：返回值改具名记录，消费点取 .copy。
      final r =
          await p.rescheduleOnceOccurrence('31', target, origDay: today);
      final copy = r.copy;
      expect(copy, isNotNull);
      expect(copy!.doneDates, isEmpty,
          reason: '副本不得沿用原任务 doneDates，否则同一完成记录统计双算');
      expect(copy.completedAt, isNull);
      // P2-1（v2.9.1 审计）：改期把「今天这一次」整体挪到目标日，原日进 skipDates；
      // 而完成 / 跳过是互斥状态，故今天那条完成记录必须一并撤销——否则同一天同时
      // 「已完成」与「已跳过」（旧行为），撤销改期后当天仍被 isDoneOn 判为已完成、
      // 完成统计虚计。
      final src = p.byId('31')!;
      expect(src.skipDates, contains(Task.ymdKey(today)));
      expect(src.doneDates, contains(Task.ymdKey(lastWeek)));
      expect(src.doneDates, isNot(contains(Task.ymdKey(today))));
      // 统计口径：上周同日仍计 1 次；今天已随改期撤销，不再计入。
      expect(p.completionDayCounts[lastWeek], 1);
      expect(p.completionDayCounts[today] ?? 0, 0);
    });
  });

  group('P3-1 习惯通知 id：FNV-1a 确定性与分布', () {
    test('同一 id 结果确定；不同 id 不互相顶掉（段位不越界）', () {
      const ids = [
        '1726000000000',
        '1726000000001',
        '1726000100000',
        '1726000000000.1',
      ];
      for (final id in ids) {
        final a = NotificationService.habitNotifyIdOf(id, 0);
        final b = NotificationService.habitNotifyIdOf(id, 0);
        expect(a, b, reason: '同一 id 的通知 id 必须跨调用稳定（cancel 依赖）');
        expect(a, greaterThanOrEqualTo(1000000000));
        expect(a, lessThanOrEqualTo(1000999999),
            reason: '必须落在习惯独立段位 [1.0e9, ~1.001e9]');
      }
      // 不同 id 的同 dayIndex 通知 id 必须不同（此前 hashCode 折叠碰撞会互相覆盖）。
      final set = ids.map((i) => NotificationService.habitNotifyIdOf(i, 0)).toSet();
      expect(set.length, ids.length);
    });

    test('批量时间戳 id 分布健康（500 个样本几乎无碰撞）', () {
      final slots = <int>{};
      for (var i = 0; i < 500; i++) {
        final id = '1726${(100000000000 + i).toString()}';
        slots.add(NotificationService.habitNotifyIdOf(id, 0) ~/ 10);
      }
      expect(slots.length, greaterThanOrEqualTo(490),
          reason: 'FNV-1a 在 10 万槽位上的 500 样本碰撞应≤10');
    });
  });

  group('P3-2 重定向白名单校验端口（443 之外一律拒绝）', () {
    test('作者仓路径：缺省端口 / 显式 443 放行，非 443 端口拒绝', () {
      expect(
        UpdatePolicy.isAllowedRedirectTarget(
            'https://gitee.com/jason1012/youtiao/releases/download/v2.8.6/app.apk'),
        isTrue,
      );
      expect(
        UpdatePolicy.isAllowedRedirectTarget(
            'https://gitee.com:443/jason1012/youtiao/releases/download/v2.8.6/app.apk'),
        isTrue,
      );
      expect(
        UpdatePolicy.isAllowedRedirectTarget(
            'https://gitee.com:9999/jason1012/youtiao/releases/download/v2.8.6/app.apk'),
        isFalse,
        reason: '带非标准端口的主机此前会被 host 白名单误放行',
      );
    });

    test('附件对象存储：非 443 端口同样拒绝', () {
      expect(
        UpdatePolicy.isAllowedRedirectTarget(
            'https://foruda.gitee.com/attach_file/1/download/x'),
        isTrue,
      );
      expect(
        UpdatePolicy.isAllowedRedirectTarget(
            'https://foruda.gitee.com:8443/attach_file/1/download/x'),
        isFalse,
      );
    });

    test('APK 首跳前缀校验不受影响（缺省端口仍放行）', () {
      expect(
        UpdatePolicy.isAllowedApkUrl(
            'https://gitee.com/jason1012/youtiao-releases-3/releases/download/v2.8.6/app.apk'),
        isTrue,
      );
      expect(
        UpdatePolicy.isAllowedApkUrl(
            'https://gitee.com:8443/jason1012/youtiao-releases-3/releases/download/v2.8.6/app.apk'),
        isFalse,
      );
    });
  });

  group('P2-4 换口令后旧加密快照标记 stale', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('youtiao_v286_p24');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('changeAutoBackupPassphrase：旧 .enc.json 改名 stale，恢复面板不再展示', () async {
      final auto = Directory('${tmp.path}/backup/auto');
      await auto.create(recursive: true);
      File('${auto.path}/2026-09-01.enc.json').writeAsStringSync('{"v":1}');
      File('${auto.path}/2026-09-05.json').writeAsStringSync('{"v":1}');
      final p = await _providerWith(const []);

      final marked = await p.changeAutoBackupPassphrase('newpass123', force: true);
      expect(marked, 1, reason: '只有 1 份旧口令加密快照');
      expect(File('${auto.path}/2026-09-01.enc.json').existsSync(), isFalse);
      expect(File('${auto.path}/2026-09-01.stale.enc.json').existsSync(), isTrue,
          reason: '改名保留文件本体（滚动保留按日期自然淘汰）');
      expect(File('${auto.path}/2026-09-05.json').existsSync(), isTrue,
          reason: '明文快照不受影响');

      final listed = await p.listAutoBackups();
      expect(listed.length, 1, reason: 'stale 快照不得再出现在恢复面板');
      expect(listed.single.encrypted, isFalse);
    });
  });
}
