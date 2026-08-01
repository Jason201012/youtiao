import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:todolist/models/task.dart' hide Priority;

/// 本地通知服务（flutter_local_notifications）。
/// 按任务 dueDate 在本地调度一次性提醒；受 enabled 开关控制。
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// 总开关（设置页控制）。关闭时不再调度，且清空已调度项。
  bool enabled = true;

  /// 是否已初始化（避免重复初始化）
  bool _initialized = false;

  /// 显式本地时区（中国时区）。不依赖 tz.local 的隐式状态，避免被静默回退到
  /// UTC 导致所有提醒延后 8 小时。
  tz.Location? _loc;

  /// 通知渠道 id：有声 / 静音（用两个渠道让「声音」开关真正生效，
  /// 因为 Android 一旦建好渠道，其声音属性不可再改）。
  static const String _chSound = 'todo_reminder';
  static const String _chSilent = 'todo_reminder_silent';

  /// 定时测试用固定 id（不与任务 id 冲突）。
  static const int _kTestTimerId = 999999;

  /// 把任务 id（字符串）映射成一个稳定的通知 id：优先用数字本身（本 App 的
  /// id 都是纯数字字符串），兜底用 hashCode。schedule / cancel 必须走同一函数，
  /// 否则编辑/删除时取消会错位。
  static int _notifyIdOf(String id) => int.tryParse(id) ?? id.hashCode;

  /// 与 MainActivity.kt 中的 MethodChannel 对应，用于查询/跳转「精确闹钟」权限。
  static const MethodChannel _exactAlarmChannel =
      MethodChannel('com.example.todolist/exact_alarm');

  /// 在 App 启动时调用一次：初始化通道、时区与权限。
  Future<void> init() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    try {
      _loc = tz.getLocation('Asia/Shanghai');
      tz.setLocalLocation(_loc!);
    } catch (e) {
      // 极端情况下拿不到时区数据也不应让 App 崩溃，回退 UTC 并打日志。
      _loc = tz.UTC;
      debugPrint('[通知] 时区初始化失败，回退 UTC: $e');
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onTap,
    );
    // 显式创建两个渠道：避免首次调度时因渠道未注册被系统静默丢弃。
    await _createChannels();
    // Android 13+ 需授权通知权限（首次会自动弹窗）
    await _android?.requestNotificationsPermission();
    _initialized = true;
  }

  /// 显式创建有声 / 静音两个通知渠道。
  Future<void> _createChannels() async {
    final plugin = _android;
    if (plugin == null) return;
    await plugin.createNotificationChannel(const AndroidNotificationChannel(
      _chSound,
      '任务提醒',
      description: '任务截止时间提醒（带声音）',
      importance: Importance.high,
      playSound: true,
    ));
    await plugin.createNotificationChannel(const AndroidNotificationChannel(
      _chSilent,
      '任务提醒（静音）',
      description: '任务截止时间提醒（无声音）',
      importance: Importance.high,
      playSound: false,
    ));
  }

  /// 点击通知时的回调（App 在前台/后台回到前台时触发）
  static void _onTap(NotificationResponse r) {
    // 当前无特定跳转目标，留作扩展
  }

  /// 读取当前通知权限状态（Android 13+ 才有效；旧版本恒为 true）。
  /// 返回 null = 平台不支持该查询。
  Future<bool?> checkPermission() async => _android?.areNotificationsEnabled();

  /// 请求通知权限；返回是否授予（null = 平台不支持）。
  Future<bool?> requestPermission() async =>
      _android?.requestNotificationsPermission();

  /// 查询本机是否拥有「精确闹钟」权限（SCHEDULE_EXACT_ALARM）。
  /// Android 12+ 需要用户授予；12 以下无需，恒为 true。
  Future<bool> canScheduleExactAlarms() async {
    try {
      final r =
          await _exactAlarmChannel.invokeMethod<bool>('canScheduleExactAlarms');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳转到系统「精确闹钟」授权页（Android 12+）。用户手动开启后返回 App 即可生效。
  Future<void> openExactAlarmSettings() async {
    try {
      await _exactAlarmChannel.invokeMethod<void>('openExactAlarmSettings');
    } catch (e) {
      debugPrint('[通知] 打开精确闹钟设置失败: $e');
    }
  }

  /// 选择实际调度模式：
  /// 采用 AlarmManager.setAlarmClock（alarmClock）。它是 Android 上唯一不受
  /// Doze 与各大 OEM（含 ColorOS / Realme / 小米等国产 ROM）电池优化拦截的
  /// 调度方式，且不需要 SCHEDULE_EXACT_ALARM 权限（状态栏会显示闹钟图标，属正常）。
  /// 注：exactAllowWhileIdle 在本机 ColorOS 上被系统拦截，故不使用。
  Future<AndroidScheduleMode> get _scheduleMode async =>
      AndroidScheduleMode.alarmClock;

  /// 发送测试通知：即时一条 + 5 秒后两条（AlarmManager 调度 + 应用内延迟兜底）。
  /// 返回诊断文本，供 UI 展示，用于区分「通道/权限是否通」与「系统 AlarmManager 是否被 ColorOS 拦截」。
  Future<String> showTest() async {
    final androidDetail = AndroidNotificationDetails(
      _chSound,
      '任务提醒',
      channelDescription: '任务截止时间提醒',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );
    final detail = NotificationDetails(android: androidDetail);

    // 0) 先查精确闹钟权限，用于诊断（ColorOS 上此值常为 false，导致定时被拦截）
    final exactOk = await canScheduleExactAlarms();

    // 1) 即时通知（绕过 enabled，验证通道/权限本身可用）
    final nowId = DateTime.now().millisecondsSinceEpoch % 100000;
    await _plugin.show(
      nowId,
      '测试通知（即时）',
      '如果你看到这条，说明通知通道正常 ✅',
      detail,
    );

    final loc = _loc ?? tz.UTC;
    final when = tz.TZDateTime.now(loc).add(const Duration(seconds: 5));
    final mode = await _scheduleMode;
    String result =
        '已发送即时通知；精确闹钟权限=${exactOk ? "已授予" : "未授予"}。\n';

    // 2) 系统闹钟定时（5 秒后）：验证系统调度是否工作（alarmClock = setAlarmClock）
    try {
      await _plugin.zonedSchedule(
        _kTestTimerId,
        '定时测试·系统闹钟（5秒后）',
        '调度模式=$mode（setAlarmClock，理论不被 ColorOS 拦截）',
        when,
        detail,
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      result += '已提交系统闹钟 5 秒定时（模式=$mode）。\n';
    } catch (e) {
      result += '系统闹钟定时提交失败：$e\n';
    }

    // 3) 应用内延迟兜底：只要 App 还在前台/内存中，5 秒后必弹，
    //    用来证明通知通道本身没问题，从而把问题隔离到「系统 AlarmManager 被拦截」。
    Future.delayed(const Duration(seconds: 5), () {
      _plugin.show(
        _kTestTimerId + 1,
        '定时测试·应用内延迟（5秒后）',
        'AlarmManager 被拦截时，这条仍能证明通道可用',
        detail,
      );
    });
    result += '另安排了「应用内延迟」5 秒通知（App 未退到后台即可见）。\n';

    if (!exactOk) {
      result += '⚠️ 未获精确闹钟权限：ColorOS 很可能会拦截上面的 AlarmManager 定时。'
          '请去系统设置开启本应用「精确闹钟 / 允许闹钟」与「电池→不受限制 / 自启动」后重试。';
    } else {
      result += '若 5 秒后只有「应用内延迟」弹出而「AlarmManager」那条没有，'
          '说明系统仍未放行定时闹钟，需检查 ColorOS 电池/自启动设置。';
    }
    return result;
  }

  /// 为任务调度到期提醒（按 dueDate 精确触发）。
  /// 返回 true 表示已成功提交 zonedSchedule（不代表系统一定触发）。
  Future<bool> scheduleForTask(Task task, {bool playSound = true}) async {
    if (!enabled) {
      debugPrint('[通知] 未调度 id=${task.id}：通知总开关关闭');
      return false;
    }
    if (task.dueDate == null) {
      debugPrint('[通知] 未调度 id=${task.id}：无截止时间');
      return false;
    }
    try {
      final loc = _loc ?? tz.UTC;
      final due = task.dueDate!;
      final tz.TZDateTime when = due.isBefore(DateTime.now())
          ? tz.TZDateTime.now(loc).add(const Duration(seconds: 1))
          : tz.TZDateTime(
              loc, due.year, due.month, due.day, due.hour, due.minute);
      // 打印实际调度时刻（含时区），便于在 debug 控制台核对是否准时。
      debugPrint(
          '[通知] 调度 id=${task.id} "${task.title}" -> $when (playSound=$playSound)');
      final chId = playSound ? _chSound : _chSilent;
      final androidDetail = AndroidNotificationDetails(
        chId,
        '任务提醒',
        channelDescription: '任务截止时间提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: playSound,
      );
      final detail = NotificationDetails(android: androidDetail);
      final mode = await _scheduleMode;
      await _plugin.zonedSchedule(
        _notifyIdOf(task.id),
        '任务提醒',
        task.title,
        when,
        detail,
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint('[通知] 已提交 zonedSchedule id=${task.id} (mode=${mode.name})');
      // 应用内兜底：若 App 在到期时仍存活（前台/后台未杀），即使系统闹钟被
      // ColorOS 等 ROM 拦截，也能保证提醒弹出。使用同一通知 id，避免重复。
      // 仅对较短延时（≤1 天）启用，长期任务依赖上面的 setAlarmClock 即可。
      final delay = when.difference(tz.TZDateTime.now(loc));
      if (!delay.isNegative && delay <= const Duration(days: 1)) {
        Future.delayed(delay, () {
          _plugin.show(_notifyIdOf(task.id), '任务提醒', task.title, detail);
        });
      }
      return true;
    } catch (e, s) {
      // 调度失败不应导致 App 崩溃，仅打印便于排查
      debugPrint('[通知] 调度失败 id=${task.id}: $e');
      debugPrint('$s');
      return false;
    }
  }

  /// 按任务 id 取消单条已调度的通知。
  Future<void> cancel(String id) => _plugin.cancel(_notifyIdOf(id));

  /// 清空所有已调度的通知（关闭总开关时调用）。
  Future<void> cancelAll() => _plugin.cancelAll();
}
