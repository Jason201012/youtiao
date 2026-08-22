import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:todolist/models/task.dart' hide Priority;
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/habit.dart';

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

  /// 专注进行中常驻通知渠道（锁屏可见、无声、无角标）。
  static const String _chFocusProgress = 'focus_progress';

  /// 专注（番茄钟）完成通知固定 id：schedule / cancel / show 必须共用同一 id，
  /// 这样「系统闹钟到点弹」与「应用内到点补弹」会互相覆盖而非重复成两条。
  static const int focusDoneNotifyId = 777777;

  /// 专注进行中常驻进度通知固定 id（与完成提醒 [focusDoneNotifyId] 区分，
  /// 避免互相取消）。锁屏可见剩余时间，暂停/停止/完成时取消。
  static const int focusProgressNotifyId = 777778;

  /// 专注完成通知的 Android 样式（复用有声渠道，确保完成时能引起注意）。
  AndroidNotificationDetails get _focusDoneAndroid => const AndroidNotificationDetails(
        _chSound,
        '任务提醒',
        channelDescription: '任务截止时间提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
      );

  /// 定时测试用固定 id（不与任务 id 冲突）。
  static const int _kTestTimerId = 999999;

  /// 通知 payload 前缀：携带任务 id，点击通知时据此跳转到对应任务详情页。
  static const String payloadTaskPrefix = 'task:';
  /// 通知 payload 前缀：携带习惯 id，点击习惯提醒跳转到习惯页。
  static const String payloadHabitPrefix = 'habit:';

  /// 通知「稍后提醒」action 按钮的 actionId。
  static const String snoozeActionId = 'snooze';

  /// 点击通知的回调（由 main.dart 注入，负责根据 payload 导航）。
  /// 用实例字段而非直接 import 页面，避免 service 反向依赖 UI。
  static void Function(String? payload)? onNotificationTap;

  /// 点击通知 action 按钮的回调（由 main.dart 注入）。
  /// 普通点击（点通知体）走 [onNotificationTap]；点 action 按钮（如「稍后提醒」）
  /// 走这里，并带 actionId 与 payload 供调用方区分。
  static void Function(String? actionId, String? payload)? onNotificationAction;

  /// 把任务 id（字符串）映射成一个稳定的通知 id：优先用数字本身（本 App 的
  /// id 都是纯数字字符串），兜底用 hashCode。schedule / cancel 必须走同一函数，
  /// 否则编辑/删除时取消会错位。
  static int _notifyIdOf(String id) => int.tryParse(id) ?? id.hashCode;

  /// 记录「已取消的一次性截止提醒」任务 id。任务提前完成后我们会 [cancel] 一次性
  /// 截止提醒，但 [scheduleForTask] 内部还有一条「应用内兜底」延迟定时器（到期 ≤1 天
  /// 时启用），它不依赖系统 AlarmManager，[cancel] 拦不住。用此集合在兜底定时器触发时
  /// 二次校验，确保提前完成的任务不会再弹出提醒。重新调度时会清除对应标记。
  final Set<String> _deadlineCancelled = {};

  /// 重复提醒使用独立 id 段（基础 id + 固定偏移 + 星期索引），与一次性「截止提醒」区分开，
  /// 避免同一任务的两种提醒互相 cancel 掉。dayIndex：daily / interval 用 0；
  /// weekly / weekday 用 1..7（对应周一..周日），每个星期一个独立 id。
  /// 偏移量远小于 int32 上限，且本 App 任务 id 为较小的纯数字，不会越界。
  static int _repeatNotifyIdOf(String id, int dayIndex) =>
      _notifyIdOf(id) + 500000 + dayIndex * 13;

  /// 仅比较「年月日」，忽略时分秒（用于判断 completedAt 是否为今天）。
  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

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
    await plugin.createNotificationChannel(const AndroidNotificationChannel(
      _chFocusProgress,
      '专注进行中',
      description: '专注计时常驻通知（锁屏显示剩余时间）',
      importance: Importance.defaultImportance,
      playSound: false,
      showBadge: false,
    ));
  }

  /// 点击通知时的回调（App 在前台/后台回到前台时触发，冷启动点开也走这里）。
  /// - 普通点击（actionId 为空）：payload 透传给 [onNotificationTap] 做导航。
  /// - 点 action 按钮（如「稍后提醒」，actionId 非空）：转 [onNotificationAction]。
  static void _onTap(NotificationResponse r) {
    if (r.actionId != null) {
      onNotificationAction?.call(r.actionId, r.payload);
    } else {
      onNotificationTap?.call(r.payload);
    }
  }

  /// 从 payload 解析任务 id；非任务类通知（无前缀 / 空）返回 null。
  static String? parseTaskId(String? payload) {
    if (payload == null || !payload.startsWith(payloadTaskPrefix)) return null;
    return payload.substring(payloadTaskPrefix.length);
  }

  /// 从 payload 解析习惯 id；非习惯类通知返回 null。
  static String? parseHabitId(String? payload) {
    if (payload == null || !payload.startsWith(payloadHabitPrefix)) return null;
    return payload.substring(payloadHabitPrefix.length);
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
    // 置于 80 万段：避开任务 id（0..N）、重复提醒（50 万+）、专注完成（777777）、定时测试（999999）。
    final nowId = 800000 + (DateTime.now().millisecondsSinceEpoch % 100000);
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
    if (task.done) {
      // 已完成（含提前完成）的任务不再挂一次性「截止时间提醒」，避免完成后仍弹。
      _deadlineCancelled.add(task.id);
      debugPrint('[通知] 未调度 id=${task.id}：任务已完成（不挂截止提醒）');
      return false;
    }
    // 重新调度：清除该任务的「已取消」标记（若曾因完成被取消），使后续取消能再次生效。
    _deadlineCancelled.remove(task.id);
    try {
      final loc = _loc ?? tz.UTC;
      final due = task.dueDate!;
      // 提醒提前量：在截止时间之前 reminderOffsetMin 分钟触发（0 = 准时）。
      final base = due.subtract(Duration(minutes: task.reminderOffsetMin));
      // 提醒时刻已过去（任务逾期）：不再补弹「迟到提醒」，避免从回收站恢复/重排逾期任务时立即骚扰。
      if (base.isBefore(DateTime.now())) {
        debugPrint('[通知] 未调度 id=${task.id}：提醒时刻已过期（逾期任务不补弹）');
        return false;
      }
      final tz.TZDateTime when = tz.TZDateTime(
          loc, base.year, base.month, base.day, base.hour, base.minute);
      // 打印实际调度时刻（含时区），便于在 debug 控制台核对是否准时。
      debugPrint(
          '[通知] 调度 id=${task.id} "${task.title}" -> $when (playSound=$playSound, offset=${task.reminderOffsetMin}min)');
      final chId = playSound ? _chSound : _chSilent;
      final androidDetail = AndroidNotificationDetails(
        chId,
        '任务提醒',
        channelDescription: '任务截止时间提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: playSound,
        actions: [AndroidNotificationAction(snoozeActionId, '稍后提醒')],
      );
      final detail = NotificationDetails(android: androidDetail);
      final mode = await _scheduleMode;
      final payload = '$payloadTaskPrefix${task.id}';
      await _plugin.zonedSchedule(
        _notifyIdOf(task.id),
        '任务提醒',
        task.title.isNotEmpty ? task.title : '无标题任务',
        when,
        detail,
        payload: payload,
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
        final id = task.id;
        Future.delayed(delay, () {
          // 任务在到期前已完成/被取消则不再弹：应用内兜底定时器不受系统 AlarmManager
          // cancel 影响，必须用 _deadlineCancelled 二次校验拦截。
          if (_deadlineCancelled.contains(id)) return;
          _plugin.show(_notifyIdOf(id), '任务提醒', task.title.isNotEmpty ? task.title : '无标题任务', detail, payload: payload);
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

  /// 按任务 id 取消单条已调度的「截止提醒」通知。
  /// 同时记入 [_deadlineCancelled]，让应用内兜底定时器也能正确拦截（提前完成场景）。
  Future<void> cancel(String id) {
    _deadlineCancelled.add(id);
    return _plugin.cancel(_notifyIdOf(id));
  }

  /// 为「重复任务」调度本地提醒：按 [Task.repeat] 规则在设定时刻重复触发
  /// （setAlarmClock 模式，不被 ColorOS 等国产 ROM 拦截）。返回 true 表示已提交。
  ///
  /// - daily：每天同一时刻（[DateTimeComponents.time]）。
  /// - weekly / weekday：按所选星期逐个挂 [DateTimeComponents.dayOfWeekAndTime]
  ///   （每个星期用独立 notifyId 区分）。
  /// - interval：flutter 没有「每隔 N 天」原语，降级为「下一次 occurrence 的一次性
  ///   setAlarmClock」；App 每次启动 / 回到前台（_rescheduleAllActive +
  ///   checkDailyReset）会重算并重新挂上，覆盖绝大多数使用场景。
  ///
  /// **当天已完成则跳过今日**：若 [Task.done] 且 [Task.completedAt] 为今天（即用户已
  /// 提前完成），则把下一次触发挂到「今天之后的第一个循环日」，避免「提前完成仍弹提醒」。
  /// 用同一 notifyId 重新 zonedSchedule 会覆盖掉今天尚未触发的闹钟。
  Future<bool> scheduleRepeatReminder(Task task, {bool playSound = true}) async {
    if (!enabled) {
      debugPrint('[通知] 未调度重复提醒 id=${task.id}：通知总开关关闭');
      return false;
    }
    if (!task.isRepeating || task.repeatMinute == null) {
      debugPrint('[通知] 未调度重复提醒 id=${task.id}：非重复任务或无提醒时间');
      return false;
    }
    try {
      final loc = _loc ?? tz.UTC;
      final m = task.repeatMinute!;
      final hh = m ~/ 60;
      final mm = m % 60;
      final now = tz.TZDateTime.now(loc);
      // 当天已完成（completedAt 为今日）→ 跳过今日这次，挂到下一个循环日。
      final skipToday =
          task.done && task.completedAt != null && _sameDay(task.completedAt!, DateTime.now());
      final chId = playSound ? _chSound : _chSilent;
      final androidDetail = AndroidNotificationDetails(
        chId,
        '任务提醒',
        channelDescription: '重复任务定时提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: playSound,
        actions: [AndroidNotificationAction(snoozeActionId, '稍后提醒')],
      );
      final detail = NotificationDetails(android: androidDetail);
      final mode = await _scheduleMode;

      // 计算「下一个该星期 @ hh:mm」的真实时刻。skipToday 时要求严格晚于今天。
      tz.TZDateTime nextWeekday(int wd) {
        final limit = skipToday ? now.add(const Duration(days: 1)) : now;
        var candidate = tz.TZDateTime(loc, now.year, now.month, now.day, hh, mm);
        while (candidate.weekday != wd || !candidate.isAfter(limit)) {
          candidate = candidate.add(const Duration(days: 1));
        }
        return candidate;
      }

      switch (task.repeat) {
        case RepeatType.daily:
          var when = tz.TZDateTime(loc, now.year, now.month, now.day, hh, mm);
          when = skipToday
              ? when.add(const Duration(days: 1))
              : (when.isAfter(now) ? when : when.add(const Duration(days: 1)));
          await _plugin.zonedSchedule(
            _repeatNotifyIdOf(task.id, 0),
            task.repeatSummary,
            task.title.isNotEmpty ? task.title : '无标题任务',
            when,
            detail,
            payload: '$payloadTaskPrefix${task.id}',
            androidScheduleMode: mode,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.time,
          );
          debugPrint('[通知] 已调度重复提醒 id=${task.id} 每天 '
              '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} '
              '(skipToday=$skipToday, 首次=$when)');
          return true;

        case RepeatType.weekday:
        case RepeatType.weekly:
          final weeklyDays = task.repeat == RepeatType.weekday
              ? const [1, 2, 3, 4, 5] // 周一至周五
              : task.repeatWeekdays.where((d) => d >= 1 && d <= 7).toList();
          if (weeklyDays.isEmpty) return false;
          for (final wd in weeklyDays) {
            final when = nextWeekday(wd);
            await _plugin.zonedSchedule(
              _repeatNotifyIdOf(task.id, wd),
              task.repeatSummary,
              task.title,
              when,
              detail,
              payload: '$payloadTaskPrefix${task.id}',
              androidScheduleMode: mode,
              uiLocalNotificationDateInterpretation:
                  UILocalNotificationDateInterpretation.absoluteTime,
              matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
            );
          }
          debugPrint('[通知] 已调度重复提醒 id=${task.id} ${task.repeatSummary} '
              '每周 $weeklyDays @ ${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} '
              '(skipToday=$skipToday)');
          return true;

        case RepeatType.interval:
          final next = _nextIntervalOccurrence(task, skipToday: skipToday);
          if (next == null) {
            debugPrint('[通知] 未调度 interval 提醒 id=${task.id}：缺锚点');
            return false;
          }
          final when = next.isAfter(now) ? next : next.add(const Duration(days: 1));
          await _plugin.zonedSchedule(
            _repeatNotifyIdOf(task.id, 0),
            task.repeatSummary,
            task.title.isNotEmpty ? task.title : '无标题任务',
            when,
            detail,
            payload: '$payloadTaskPrefix${task.id}',
            androidScheduleMode: mode,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
          );
          debugPrint('[通知] 已调度重复提醒(interval) id=${task.id} 下次 '
              '${when.year}-${when.month}-${when.day} ${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} '
              '(skipToday=$skipToday)');
          return true;

        case RepeatType.none:
          return false;
      }
    } catch (e, s) {
      debugPrint('[通知] 重复提醒调度失败 id=${task.id}: $e');
      debugPrint('$s');
      return false;
    }
  }

  /// 计算 interval 任务下一次 occurrence 的「日期+时刻」（date-only 锚点 + N 天步进）。
  /// [skipToday] 为 true 且下一次 occurrence 恰为今天时，再往后跳一个周期（跳过今天）。
  tz.TZDateTime? _nextIntervalOccurrence(Task task, {bool skipToday = false}) {
    final a = task.repeatAnchor;
    if (a == null || task.repeatMinute == null) return null;
    final loc = _loc ?? tz.UTC;
    final n = task.repeatInterval < 1 ? 1 : task.repeatInterval;
    final m = task.repeatMinute!;
    final now = tz.TZDateTime.now(loc);
    final today = DateTime(now.year, now.month, now.day);
    final ad = DateTime(a.year, a.month, a.day);
    final diff = today.difference(ad).inDays;
    // 已过去的天数里，最大的可整除步数 → 下一次 occurrence
    final k = diff < 0 ? 0 : (diff ~/ n);
    var occDate = ad.add(Duration(days: (k + 1) * n));
    var result =
        tz.TZDateTime(loc, occDate.year, occDate.month, occDate.day, m ~/ 60, m % 60);
    if (skipToday && _sameDay(DateTime(result.year, result.month, result.day), today)) {
      final nextDate = ad.add(Duration(days: (k + 2) * n));
      result = tz.TZDateTime(
          loc, nextDate.year, nextDate.month, nextDate.day, m ~/ 60, m % 60);
    }
    return result;
  }

  /// 按任务 id 取消全部「重复提醒」通知（daily 用 dayIndex=0；weekly/weekday 用 1..7）。
  Future<void> cancelRepeatReminder(String id) async {
    for (var d = 0; d <= 7; d++) {
      await _plugin.cancel(_repeatNotifyIdOf(id, d));
    }
  }

  /// 习惯 id 是毫秒时间戳字符串（13 位，约 1.7e12），**不能**像任务 id 那样直接
  /// int.tryParse——通知插件要求 id 落在 int32 范围内，否则抛
  /// `Invalid argument (id): must fit within the size of a 32-bit integer`。
  /// 这里把 id 折叠到 10 万个槽位（习惯数量为个位数，碰撞可忽略）。
  static int _habitSlotOf(String id) => (id.hashCode & 0x7fffffff) % 100000;

  /// 习惯提醒使用独立的 id 段（80 万起 + 槽位*10 + 星期索引），与任务的
  /// 「截止提醒 / 重复提醒」区分开，避免互相 cancel 掉。dayIndex：每天提醒用 0；
  /// 按星期提醒用 1..7。最大值 800000+99999*10+7 ≈ 180 万，远小于 int32 上限。
  /// schedule / cancel 必须走同一函数，否则删除习惯时取消会错位。
  static int _habitNotifyIdOf(String id, int dayIndex) =>
      800000 + _habitSlotOf(id) * 10 + dayIndex;

  /// 为习惯调度每日打卡提醒（setAlarmClock 模式，不被 ColorOS 等国产 ROM 拦截）。
  /// [checkedToday] 为 true（今天已打卡）且提醒时刻尚未到来时，跳过今日这一次，
  /// 挂到下一个循环日，避免「已完成仍弹提醒」。返回 true 表示已提交。
  ///
  /// - [weekdays] 为空：每天同一时刻（[DateTimeComponents.time]）。
  /// - [weekdays] 非空：按所选星期逐个挂 [DateTimeComponents.dayOfWeekAndTime]。
  Future<bool> scheduleHabitReminder(Habit habit, {bool checkedToday = false}) async {
    if (!enabled) {
      debugPrint('[通知] 未调度习惯提醒 id=${habit.id}：通知总开关关闭');
      return false;
    }
    if (habit.reminderMinute == null) {
      debugPrint('[通知] 未调度习惯提醒 id=${habit.id}：未设提醒时间');
      return false;
    }
    try {
      final loc = _loc ?? tz.UTC;
      final m = habit.reminderMinute!;
      final hh = m ~/ 60;
      final mm = m % 60;
      final now = tz.TZDateTime.now(loc);
      final chId = _chSound; // 习惯提醒统一用有声渠道，引起注意
      final androidDetail = AndroidNotificationDetails(
        chId,
        '习惯提醒',
        channelDescription: '每日习惯打卡提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        actions: [AndroidNotificationAction(snoozeActionId, '稍后提醒')],
      );
      final detail = NotificationDetails(android: androidDetail);
      final mode = await _scheduleMode;
      final body = '${habit.emoji} ${habit.title} · 该打卡啦';
      final skipToday = checkedToday;

      if (habit.weekdays.isEmpty) {
        var when = tz.TZDateTime(loc, now.year, now.month, now.day, hh, mm);
        when = skipToday
            ? when.add(const Duration(days: 1))
            : (when.isAfter(now) ? when : when.add(const Duration(days: 1)));
        await _plugin.zonedSchedule(
          _habitNotifyIdOf(habit.id, 0),
          '习惯打卡',
          body,
          when,
          detail,
          payload: '$payloadHabitPrefix${habit.id}',
          androidScheduleMode: mode,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time,
        );
        debugPrint('[通知] 已调度习惯提醒 id=${habit.id} 每天 '
            '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} '
            '(skipToday=$skipToday, 首次=$when)');
        return true;
      }

      for (final wd in habit.weekdays) {
        // 计算「下一个该星期 @ hh:mm」的真实时刻。
        // skipToday（今天已打卡）时从「明天」起找，避免今天恰为提醒星期且时刻未过时
        // 仍弹今日提醒（与 daily 分支、任务 weekly 分支的 limit 模式保持一致）。
        var candidate = tz.TZDateTime(loc, now.year, now.month, now.day, hh, mm);
        if (skipToday) candidate = candidate.add(const Duration(days: 1));
        while (candidate.weekday != wd || !candidate.isAfter(now)) {
          candidate = candidate.add(const Duration(days: 1));
        }
        await _plugin.zonedSchedule(
          _habitNotifyIdOf(habit.id, wd),
          '习惯打卡',
          body,
          candidate,
          detail,
          payload: '$payloadHabitPrefix${habit.id}',
          androidScheduleMode: mode,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        );
      }
      debugPrint('[通知] 已调度习惯提醒 id=${habit.id} 每周 ${habit.weekdays} '
          '@ ${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} '
          '(skipToday=$skipToday)');
      return true;
    } catch (e, s) {
      debugPrint('[通知] 习惯提醒调度失败 id=${habit.id}: $e');
      debugPrint('$s');
      return false;
    }
  }

  /// 取消某习惯的全部每日提醒通知（每天用 dayIndex=0；按星期用 1..7）。
  /// 取消失败（插件未初始化 / 平台不支持）不应阻断删除习惯等主流程，故整体吞异常。
  Future<void> cancelHabitReminder(String id) async {
    try {
      for (var d = 0; d <= 7; d++) {
        await _plugin.cancel(_habitNotifyIdOf(id, d));
      }
    } catch (e) {
      debugPrint('[通知] 取消习惯提醒失败 id=$id: $e');
    }
  }

  /// 稍后提醒（snooze）：用同一通知 id 在 [delay] 后重新弹出该任务提醒。
  /// 覆盖式调度（不新建通知），点「稍后提醒」后原通知消失、[delay] 后再弹一次；
  /// [delay] 默认 10 分钟。仅对「截止提醒」一次性任务有效（重复 / 习惯走各自方法）。
  Future<bool> snoozeTaskReminder(Task task,
      {Duration delay = const Duration(minutes: 10), bool playSound = true}) async {
    if (!enabled) {
      debugPrint('[通知] 未 snooze id=${task.id}：通知总开关关闭');
      return false;
    }
    final loc = _loc ?? tz.UTC;
    final when = tz.TZDateTime.now(loc).add(delay);
    // 清除「已取消」标记，保证 snooze 后的提醒能正常弹出。
    _deadlineCancelled.remove(task.id);
    final chId = playSound ? _chSound : _chSilent;
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        chId,
        '任务提醒',
        channelDescription: '任务截止时间提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: playSound,
      ),
    );
    try {
      await _plugin.zonedSchedule(
        _notifyIdOf(task.id),
        '任务提醒',
        task.title.isNotEmpty ? task.title : '无标题任务',
        when,
        detail,
        payload: '$payloadTaskPrefix${task.id}',
        androidScheduleMode: await _scheduleMode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint('[通知] snooze id=${task.id} -> $when (${delay.inMinutes}min)');
      return true;
    } catch (e, s) {
      debugPrint('[通知] snooze 失败 id=${task.id}: $e');
      debugPrint('$s');
      return false;
    }
  }

  /// 习惯提醒的稍后提醒：用同一习惯通知 id 在 [delay] 后重新弹出打卡提醒。
  Future<bool> snoozeHabitReminder(Habit habit,
      {Duration delay = const Duration(minutes: 10)}) async {
    if (!enabled) {
      debugPrint('[通知] 未 snooze 习惯 id=${habit.id}：通知总开关关闭');
      return false;
    }
    final loc = _loc ?? tz.UTC;
    final when = tz.TZDateTime.now(loc).add(delay);
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        _chSound,
        '习惯提醒',
        channelDescription: '每日习惯打卡提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
      ),
    );
    try {
      await _plugin.zonedSchedule(
        _habitNotifyIdOf(habit.id, 0),
        '习惯打卡',
        '${habit.emoji} ${habit.title} · 该打卡啦',
        when,
        detail,
        payload: '$payloadHabitPrefix${habit.id}',
        androidScheduleMode: await _scheduleMode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint('[通知] snooze 习惯 id=${habit.id} -> $when (${delay.inMinutes}min)');
      return true;
    } catch (e, s) {
      debugPrint('[通知] snooze 习惯失败 id=${habit.id}: $e');
      debugPrint('$s');
      return false;
    }
  }

  /// 清空所有已调度的通知（关闭总开关时调用）。
  Future<void> cancelAll() {
    _deadlineCancelled.clear();
    return _plugin.cancelAll();
  }

  /// 在 [completeAt]（墙钟时刻）调度「专注完成」系统闹钟通知。
  /// 采用与任务提醒一致的 setAlarmClock 模式，即使 App 被划掉后台也能准点弹出；
  /// 固定 id=[focusDoneNotifyId]，与 [showFocusDoneNow]/[cancelFocusDone] 共用，
  /// 避免重复成两条。通知总开关关闭时不调度。
  /// [body] 可自定义文案（番茄循环用于提示"该休息 / 开始下一个番茄"）。
  Future<void> scheduleFocusDone(DateTime completeAt, {String? body}) async {
    if (!enabled) {
      debugPrint('[通知] 未调度专注完成提醒：通知总开关关闭');
      return;
    }
    final loc = _loc ?? tz.UTC;
    final when = tz.TZDateTime.from(completeAt, loc);
    final mode = await _scheduleMode;
    try {
      await _plugin.zonedSchedule(
        focusDoneNotifyId,
        '专注完成 🍅',
        body ?? '你已完成一个番茄钟，记录已保存',
        when,
        NotificationDetails(android: _focusDoneAndroid),
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint('[通知] 已调度专注完成提醒 -> $when (mode=${mode.name})');
    } catch (e) {
      debugPrint('[通知] 专注完成定时失败: $e');
    }
  }

  /// 取消「专注完成」系统闹钟通知（暂停 / 提前停止 / 自然完成时调用）。
  Future<void> cancelFocusDone() => _plugin.cancel(focusDoneNotifyId);

  /// 立即弹出「专注完成」通知（应用内自然跑满时调用，与到点系统闹钟共用 id 互相覆盖）。
  /// [body] 可自定义文案（番茄循环用于提示"该休息 / 开始下一个番茄"）。
  Future<void> showFocusDoneNow({String? body}) => _plugin.show(
        focusDoneNotifyId,
        '专注完成 🍅',
        body ?? '你已完成一个番茄钟，记录已保存',
        NotificationDetails(android: _focusDoneAndroid),
      );

  /// 专注进行中的常驻进度通知：锁屏可见剩余时间，每秒刷新。
  /// [ongoing]=true 使其成为不会被自动划掉的前台式通知；完成/暂停/停止时由
  /// [cancelFocusProgress] 取消。与完成提醒（[focusDoneNotifyId]）互不干扰。
  /// [phase] 用于切换标题文案：专注阶段显示"专注中"，休息阶段显示"休息中"。
  Future<void> showFocusProgress({
    required int remainingSec,
    required int totalSec,
    String? taskTitle,
    FocusPhase phase = FocusPhase.focus,
  }) async {
    final r = remainingSec.clamp(0, 359999);
    final rh = r ~/ 3600;
    final rm = (r % 3600) ~/ 60;
    final rs = r % 60;
    final remStr = rh > 0
        ? '$rh:${rm.toString().padLeft(2, '0')}:${rs.toString().padLeft(2, '0')}'
        : '${rm.toString().padLeft(2, '0')}:${rs.toString().padLeft(2, '0')}';
    final verb = phase.isBreak ? '休息中' : '专注中';
    final title = taskTitle == null ? '$verb' : '$verb · $taskTitle';
    final bodyText = phase.isBreak ? '休息剩余 $remStr' : '剩余 $remStr';
    final percent = totalSec <= 0
        ? 0
        : ((1 - remainingSec / totalSec) * 100).round().clamp(0, 100);
    final android = AndroidNotificationDetails(
      _chFocusProgress,
      '专注进行中',
      channelDescription: '专注计时常驻通知（锁屏显示剩余时间）',
      importance: Importance.defaultImportance,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      playSound: false,
      channelShowBadge: false,
    );
    try {
      await _plugin.show(
        focusProgressNotifyId,
        title,
        bodyText,
        NotificationDetails(android: android),
      );
    } catch (e) {
      debugPrint('[通知] 专注进度通知失败: $e');
    }
  }

  /// 取消专注进行中的常驻进度通知（暂停 / 停止 / 自然完成 / 启动时清理残留）。
  Future<void> cancelFocusProgress() => _plugin.cancel(focusProgressNotifyId);

  /// 挂上「每日任务当天 00:00 自动重置」的午夜闹钟（setAlarmClock，ColorOS 可靠，
  /// 不依赖 App 是否打开）。由原生 MidnightResetReceiver 在午夜触发并自循环调度。
  /// 失败静默忽略（不影响其它功能）。
  static const MethodChannel _midnightChannel =
      MethodChannel('com.example.todolist/midnight_reset');
  Future<void> armMidnightReset() async {
    try {
      await _midnightChannel.invokeMethod<bool>('schedule');
    } catch (_) {
      // 通道未就绪或权限不足均不影响主流程
    }
  }

  /// 取消午夜重置闹钟（关闭每日重置总逻辑时调用）。
  Future<void> disarmMidnightReset() async {
    try {
      await _midnightChannel.invokeMethod<bool>('cancel');
    } catch (_) {
      // 忽略
    }
  }
}
