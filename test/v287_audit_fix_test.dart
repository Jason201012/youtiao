import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:todolist/models/task.dart';
import 'package:todolist/services/daily_briefing.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// v2.8.7 功能与操作审计报告（2026-09-12）修复回归测试。
///
/// 覆盖：
/// - P2-1（`reminder_timezone_override` 进备份白名单：collect → apply 往返；
///   恢复侧 `reloadTimezoneOverride` 重读偏好并应用到本地时区）；
/// - P2-2（`rescheduleFixedTimeReminders` 一并重排简报×2 / 回收站预告；
///   通知总开关关闭时全部转为取消、不调度）。
///
/// P3-2（armed 签名与落点内容缓存同生共死）为私有缓存绑定，无外部可观测态，
/// 由「所有失效统一收敛到 `_invalidateArmedCache` 单点」的结构保证 +
/// `dart analyze` 兜底；P3-1 / P3-3 / P3-4 为文案 / UI / 文档项，人工验收。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// P2-2 用例：把 getApplicationDocumentsPath 指到临时目录
/// （restoreFromJson 尾部的附件孤儿回收需要）。
class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// 记录 zonedSchedule 调度出的通知 id（P2-2 断言用）。
/// 插件参数为 Map 形态（{'id': int, ...}），按 key 取值。
List<int> _recordScheduledIds() {
  final ids = <int>[];
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async {
    if (call.method == 'zonedSchedule' && call.arguments is Map) {
      final id = (call.arguments as Map)['id'];
      if (id is int) ids.add(id);
    }
    return null;
  });
  return ids;
}

Task _trashTask(String id, DateTime deletedAt) => Task(
      id: id,
      title: '回收站任务$id',
      priority: Priority.medium,
      category: Category.work,
      deletedAt: deletedAt,
    );

void main() {
  _installMocks();

  group('P2-1 提醒时区纳入备份偏好白名单', () {
    test('collectAppPrefs 导出 reminder_timezone_override', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'reminder_timezone_override': 'Asia/Tokyo',
      });
      final collected = await collectAppPrefs();
      expect(collected['reminder_timezone_override'], 'Asia/Tokyo');
    });

    test('applyAppPrefs 写回 reminder_timezone_override（恢复侧）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await applyAppPrefs(<String, dynamic>{
        'reminder_timezone_override': 'Europe/Berlin',
      });
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('reminder_timezone_override'), 'Europe/Berlin');
    });

    test('reloadTimezoneOverride 重读偏好并应用到本地时区', () async {
      tz_data.initializeTimeZones();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'reminder_timezone_override': 'Asia/Kolkata',
      });
      await NotificationService.reloadTimezoneOverride();
      expect(tz.local.name, 'Asia/Kolkata');

      // 置空 = 跟随系统：原生通道在测试环境不可用，回退偏移扫描兜底，
      // 只要求不抛异常且 tz.local 仍可用（具体落点取决于运行环境偏移）。
      SharedPreferences.setMockInitialValues(const <String, Object>{
        'reminder_timezone_override': '',
      });
      await NotificationService.reloadTimezoneOverride();
      expect(tz.local, isNotNull);
    });
  });

  group('P2-2 固定时刻提醒全量重排', () {
    test('rescheduleFixedTimeReminders 一并重排简报×2 与回收站预告', () async {
      final scheduledIds = _recordScheduledIds();

      final docs = await Directory.systemTemp.createTemp('v287_p22_');
      PathProviderPlatform.instance = _FakePathProvider(docs.path);

      // 回收站保留期默认 30 天：删除于 29 天前 → 剩余 1 天 =
      // 明天 00:00 到期清理，rescheduleFixedTimeReminders 应触发预告。
      final today = DateTime.now();
      final task = TaskProvider();
      await task.restoreFromJson(jsonEncode(<String, dynamic>{
        'version': 2,
        'tasks': <Map<String, dynamic>>[],
        'trash': [
          _trashTask(
                  '901',
                  DateTime(today.year, today.month, today.day)
                      .subtract(const Duration(days: 29)))
              .toJson(),
        ],
      }));
      expect(task.trashExpiringTomorrow.map((t) => t.id), contains('901'));

      // 简报 / 挽留开关默认开启；挽留无漏卡会走取消分支（不产生 zonedSchedule）。
      await rescheduleFixedTimeReminders(task, FocusProvider(), HabitProvider());

      expect(scheduledIds, contains(NotificationService.trashExpireNotifyId),
          reason: '回收站过期预告应被重排（此前时区变更后不重排，按旧时区响）');
      expect(scheduledIds, contains(NotificationService.briefingEveningNotifyId),
          reason: '晚间简报应被重排');
      expect(scheduledIds, contains(NotificationService.briefingMorningNotifyId),
          reason: '晨间简报应被重排');
    });

    test('通知总开关关闭时全部转为取消、不产生任何调度', () async {
      final scheduledIds = _recordScheduledIds();

      final docs = await Directory.systemTemp.createTemp('v287_p22off_');
      PathProviderPlatform.instance = _FakePathProvider(docs.path);

      final task = TaskProvider();
      await task.restoreFromJson(jsonEncode(<String, dynamic>{
        'version': 2,
        'tasks': <Map<String, dynamic>>[],
        'notifications_enabled': false,
      }));

      await rescheduleFixedTimeReminders(task, FocusProvider(), HabitProvider());

      expect(scheduledIds, isEmpty, reason: '总开关关闭时只取消、不调度');
    });
  });
}
