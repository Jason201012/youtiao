import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:todolist/services/app_log.dart';
import 'package:todolist/models/task.dart' hide Priority;
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/habit_nudge.dart';

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

  /// L-06：锁屏上是否隐藏通知正文（默认 **隐藏**）。
  ///
  /// Android 默认 `PUBLIC`，锁屏会完整展示通知正文，而本 App 的正文就是任务
  /// 标题（可能含「复诊」「面试」等敏感语义）。用户开了应用锁却管不到锁屏，
  /// 与「别人看不到我的事」的预期不符，故默认取 [NotificationVisibility.private]：
  /// 锁屏只显示「有 N 条待办提醒」，解锁后才显示全文。
  ///
  /// 由 main() 在 Provider 加载后注入（跟 [dndDefer] 同模式，避免 service 反向依赖 UI）。
  static bool lockScreenPrivate = true;

  /// 统一的锁屏可见性取值（供全部 [AndroidNotificationDetails] 复用）。
  static NotificationVisibility get visibility => lockScreenPrivate
      ? NotificationVisibility.private
      : NotificationVisibility.public;

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

  /// P0-4：专注「被切出」挽留通知固定 id（与进度通知区分，避免互相覆盖）。
  static const int focusInterruptNotifyId = 777779;

  /// 专注完成通知的 Android 样式（复用有声渠道，确保完成时能引起注意）。
  AndroidNotificationDetails get _focusDoneAndroid => AndroidNotificationDetails(
        _chSound,
        '任务提醒',
        channelDescription: '任务截止时间提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        // L-06：锁屏隐藏任务标题（默认），解锁后才显示全文。
        visibility: visibility,
      );

  /// 定时测试用固定 id（不与任务 id 冲突）。
  ///
  /// 【通知 id 段分配表（固化，新增 id 必须避开以下区间；S10 已改为互不重叠的大区段）】
  /// - 任务一次性截止提醒：_notifyIdOf(id)            ≈ [0, ~2.1e9]（纯数字任务 id）
  /// - 任务重复提醒：      _repeatNotifyIdOf(id, d)   ≈ [2.0e9, ~2.1e9]（独立大连段）
  /// - 专注完成通知：      777777（固定）
  /// - 专注进行中常驻：    777778（固定）
  /// - 习惯提醒：          _habitNotifyIdOf(id, d)    ≈ [1.0e9, ~1.001e9]（独立大连段）
  /// - 定时测试系统闹钟：  _kTestTimerId = 999999（固定）
  /// - 定时测试应用内延迟：_kTestTimerId + 1 = 1000000（固定）
  /// - 即时测试通知：      1200000 + ms%100000     = [1200000, 1299999]（见 [showTest]）
  /// - 早晚简报：          briefingEveningNotifyId=1300001 / briefingMorningNotifyId=1300002（见 [scheduleBriefing]）
  /// - 回收站过期预告：    trashExpireNotifyId = 1400000（固定，见 [scheduleTrashExpireNotice]）
  ///
  /// 即时测试通知此前落在 800000 段，与习惯提醒段重叠，会以相同 id 顶掉用户当天
  /// 尚未触发的习惯打卡闹钟（约 10% 习惯被波及）。现整体移出习惯段到 1200000+。
  static const int _kTestTimerId = 999999;

  /// 即时测试通知 id 段起点（避开习惯提醒段 [800000,1800007] 与定时测试段 [999999,1000000]）。
  static const int _kTestInstantBase = 1200000;

  /// 早晚简报固定通知 id：独立于任务/重复/习惯/聚焦/测试各段，互不重叠。
  /// 晚间简报 [briefingEveningNotifyId]=1300001、晨间简报 [briefingMorningNotifyId]=1300002（见 [scheduleBriefing]）。
  static const int briefingEveningNotifyId = 1300001;
  static const int briefingMorningNotifyId = 1300002;

  /// 回收站过期预告固定通知 id（P1-12）：避开任务/重复/习惯/专注/测试/简报全部段位。
  /// 采用**单个固定 id**（1400000）每天覆盖式更新，把「将于明天被永久删除」的任务
  /// 聚合进同一条通知，避免每任务一条导致通知泛滥。见 [scheduleTrashExpireNotice]。
  static const int trashExpireNotifyId = 1400000;

  /// P1-7 习惯漏卡挽留固定通知 id（1500000）：避开任务/重复/习惯提醒/专注/测试/
  /// 简报/回收站预告全部段位。与简报同模式——单个固定 id，每次重排覆盖式更新，
  /// 把当天所有漏卡习惯聚合进同一条通知，避免 23:00 连弹多条。
  /// 见 [scheduleHabitNudge] 与 `HabitNudge`。
  static const int habitNudgeNotifyId = 1500000;

  /// 通知 payload 前缀：携带任务 id，点击通知时据此跳转到对应任务详情页。
  static const String payloadTaskPrefix = 'task:';
  /// 通知 payload 前缀：携带习惯 id，点击习惯提醒跳转到习惯页。
  static const String payloadHabitPrefix = 'habit:';
  /// 通知 payload 前缀：早晚简报。'brief:evening' → 今日回顾；'brief:morning' → 首页今日分区。
  static const String payloadBriefPrefix = 'brief:';

  /// 通知「稍后提醒」action 按钮的 actionId。
  static const String snoozeActionId = 'snooze';

  /// 通知「完成」action 按钮的 actionId：点击后直接在通知栏把任务标记为已完成，
  /// 无需进入 App（解决「看到提醒想完成却要进 App 找任务」的最后一公里断点）。
  /// 仅对携带 task: 前缀 payload 的任务提醒生效（习惯提醒不显示完成按钮）。
  static const String completeActionId = 'complete';

  /// 任务类提醒（截止 / 重复）统一的两个 action 按钮：稍后提醒 + 完成。
  /// 习惯提醒不显示「完成」（习惯是打卡语义，走各自 action），故单独维护。
  static List<AndroidNotificationAction> get _taskActions => [
        AndroidNotificationAction(snoozeActionId, '稍后提醒'),
        AndroidNotificationAction(completeActionId, '完成'),
      ];

  /// 点击通知的回调（由 main.dart 注入，负责根据 payload 导航）。
  /// 用实例字段而非直接 import 页面，避免 service 反向依赖 UI。
  static void Function(String? payload)? onNotificationTap;

  /// 点击通知 action 按钮的回调（由 main.dart 注入）。
  /// 普通点击（点通知体）走 [onNotificationTap]；点 action 按钮（如「稍后提醒」）
  /// 走这里，并带 actionId 与 payload 供调用方区分。
  static void Function(String? actionId, String? payload)? onNotificationAction;

  /// 勿扰时段顺延（由 main.dart 从 TaskProvider 注入）：传入「原定提醒时刻」，
  /// 返回「实际应弹时刻」；若无需顺延（不在勿扰区间或未启用）返回 null。
  /// 一次性截止提醒若落在勿扰区间，自动顺延到时段结束 + 5 分钟再弹，避免深夜打扰。
  /// 用函数字段注入，避免 service 反向依赖 TaskProvider（与 onNotificationTap 同模式）。
  static DateTime? Function(DateTime scheduled)? dndDefer;

  /// 把任务 id（字符串）映射成一个稳定的通知 id：优先用数字本身（本 App 的
  /// id 都是纯数字字符串），兜底用 hashCode。schedule / cancel 必须走同一函数，
  /// 否则编辑/删除时取消会错位。
  static int _notifyIdOf(String id) => int.tryParse(id) ?? id.hashCode;

  /// S4 修复：「幽灵提醒」根因是旧方案用会被重新调度清空的全局集合做取消标志，
  /// 导致改期到远期的旧兜底定时器在错误时间仍弹出。改为**单调代号（generation）**：
  /// 每次 [scheduleForTask] / [cancel] / [snoozeTaskReminder] 都让该任务的代号 +1，
  /// 兜底定时器触发时校验「自己是否仍是当前最新一代」，不是则静默作废。
  final Map<String, int> _deadlineGen = {};

  /// 重复提醒使用独立 id 段，与一次性「截止提醒」（0..N）、习惯提醒（1e9+）都互不重叠，
  /// 避免同一任务的两种提醒互相 cancel 掉。dayIndex：daily / interval 用 0；
  /// weekly / weekday 用 1..7（对应周一..周日），每个星期一个独立 id。
  ///
  /// S10 修复：原方案用 `id + 500000`，当任务自增 id 增长到 50 万后即与一次性提醒段
  /// 重叠、互相顶掉。现统一落到 20 亿起的独立大连段，彻底消除远期碰撞。
  static int _repeatNotifyIdOf(String id, int dayIndex) {
    final base = int.tryParse(id) ?? id.hashCode;
    return 2000000000 + (base % 100000000).abs() + (dayIndex % 8);
  }

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
      AppLog.d('[通知] 时区初始化失败，回退 UTC: $e');
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onTap,
    );
    // 显式创建两个渠道：避免首次调度时因渠道未注册被系统静默丢弃。
    await _createChannels();
    // S10：通知 id 段方案变更后，首次启动清掉旧方案遗留的通知，
    // 避免新旧 id 映射不一致导致的重复/陈旧通知。仅执行一次。
    await _purgeLegacyNotificationsIfNeeded();
    // Android 13+ 需授权通知权限（首次会自动弹窗）
    await _android?.requestNotificationsPermission();
    _initialized = true;
  }

  /// 通知 id 段方案版本（S10）。升级到新段分配后用于一次性清理旧通知，
  /// 避免旧 id 段遗留的提醒与新建提醒混淆。
  static const int _kNotifIdScheme = 1;
  static const String _kNotifIdSchemePref = 'notif_id_scheme';

  /// 仅首次（或跨版本）执行一次：清掉旧 id 段方案遗留的全部通知，随后正常重排
  /// 会按新段重建。失败不影响主流程。
  Future<void> _purgeLegacyNotificationsIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cur = prefs.getInt(_kNotifIdSchemePref) ?? 0;
      if (cur < _kNotifIdScheme) {
        await _plugin.cancelAll();
        await prefs.setInt(_kNotifIdSchemePref, _kNotifIdScheme);
      }
    } catch (e) {
      AppLog.d('[通知] 旧通知清理跳过：$e');
    }
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
      AppLog.d('[通知] 打开精确闹钟设置失败: $e');
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
      // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
      visibility: visibility,
    );
    final detail = NotificationDetails(android: androidDetail);

    // 0) 先查精确闹钟权限，用于诊断（ColorOS 上此值常为 false，导致定时被拦截）
    final exactOk = await canScheduleExactAlarms();

    // 1) 即时通知（绕过 enabled，验证通道/权限本身可用）
    // 置于 120 万段（_kTestInstantBase）：避开任务 id（0..N）、重复提醒（50 万+）、
    // 习惯提醒（80 万~180 万）、专注完成（777777）、定时测试（999999/1000000），
    // 避免以相同 id 顶掉用户当天尚未触发的习惯打卡闹钟（Bug2 修复）。
    final nowId = _kTestInstantBase + (DateTime.now().millisecondsSinceEpoch % 100000);
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
      AppLog.d('[通知] 未调度 id=${task.id}：通知总开关关闭');
      return false;
    }
    if (task.dueDate == null) {
      AppLog.d('[通知] 未调度 id=${task.id}：无截止时间');
      return false;
    }
    if (task.done) {
      // 已完成（含提前完成）的任务不再挂一次性「截止时间提醒」，避免完成后仍弹。
      // 作废在途兜底定时器（若有），使其触发时判定为过期一代而静默退出。
      _deadlineGen[task.id] = (_deadlineGen[task.id] ?? 0) + 1;
      AppLog.d('[通知] 未调度 id=${task.id}：任务已完成（不挂截止提醒）');
      return false;
    }
    // S4 修复：进入调度即让该任务代号 +1（作废任何在途兜底定时器）。
    // 旧方案在此 remove 掉「取消标记」正是"幽灵提醒"根因：改期到远期会把标记清空，
    // 使旧兜底定时器误以为自己仍有效。现仅靠代号判断，不再清除任何标记。
    final id = task.id;
    final g = (_deadlineGen[id] = (_deadlineGen[id] ?? 0) + 1);
    try {
      final loc = _loc ?? tz.UTC;
      final due = task.dueDate!;
      // 提醒提前量：在截止时间之前 reminderOffsetMin 分钟触发（0 = 准时）。
      var base = due.subtract(Duration(minutes: task.reminderOffsetMin));
      // 提醒时刻已过去（任务逾期）：不再补弹「迟到提醒」，避免从回收站恢复/重排逾期任务时立即骚扰。
      if (base.isBefore(DateTime.now())) {
        AppLog.d('[通知] 未调度 id=${task.id}：提醒时刻已过期（逾期任务不补弹）');
        return false;
      }
      // 勿扰时段顺延：一次性提醒若落在勿扰区间，自动顺延到时段结束 + 5 分钟再弹。
      if (dndDefer != null) {
        final deferred = dndDefer!(base);
        if (deferred != null) {
          AppLog.d('[通知] id=${task.id} 提醒落在勿扰时段，顺延到 $deferred');
          base = deferred;
        }
      }
      final tz.TZDateTime when = tz.TZDateTime(
          loc, base.year, base.month, base.day, base.hour, base.minute);
      // 打印实际调度时刻（含时区），便于在 debug 控制台核对是否准时。
      AppLog.d(
          '[通知] 调度 id=${task.id} "${task.title}" -> $when (playSound=$playSound, offset=${task.reminderOffsetMin}min)');
      final chId = playSound ? _chSound : _chSilent;
      final androidDetail = AndroidNotificationDetails(
        chId,
        '任务提醒',
        channelDescription: '任务截止时间提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: playSound,
        // 任务提醒：稍后提醒 + 完成（直接标记完成，无需进 App）。
        // 两个 action 各带 actionId，点击后由 main.dart 的 onNotificationAction 路由区分。
        actions: _taskActions,
        // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
        visibility: visibility,
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
      AppLog.d('[通知] 已提交 zonedSchedule id=${task.id} (mode=${mode.name})');
      // 应用内兜底：若 App 在到期时仍存活（前台/后台未杀），即使系统闹钟被
      // ColorOS 等 ROM 拦截，也能保证提醒弹出。使用同一通知 id，避免重复。
      // 仅对较短延时（≤1 天）启用，长期任务依赖上面的 setAlarmClock 即可。
      final delay = when.difference(tz.TZDateTime.now(loc));
      if (!delay.isNegative && delay <= const Duration(days: 1)) {
        Future.delayed(delay, () {
          // S4 修复：用单调代号判断自己是否仍是当前最新一代调度；
          // 任务改期/取消会让代号 +1，陈旧一代的定时器此处判定过期而静默退出，
          // 彻底消除"幽灵提醒"（旧方案用 _deadlineCancelled，改期时会被清空而失效）。
          if (_deadlineGen[id] != g) return;
          _plugin.show(_notifyIdOf(id), '任务提醒', task.title.isNotEmpty ? task.title : '无标题任务', detail, payload: payload);
        });
      }
      return true;
    } catch (e, s) {
      // 调度失败不应导致 App 崩溃，仅打印便于排查
      AppLog.d('[通知] 调度失败 id=${task.id}: $e');
      AppLog.d('$s');
      return false;
    }
  }

  /// 按任务 id 取消单条已调度的「截止提醒」通知。
  /// 同时作废在途的「应用内兜底定时器」（代号 +1，使其触发时判定为过期一代），
  /// 让提前完成/改期的任务不再弹出陈旧提醒（S4）。
  Future<void> cancel(String id) {
    // S4 修复：作废该任务在途的兜底定时器（代号 +1 使其判定为过期一代）。
    _deadlineGen[id] = (_deadlineGen[id] ?? 0) + 1;
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
      AppLog.d('[通知] 未调度重复提醒 id=${task.id}：通知总开关关闭');
      return false;
    }
    if (!task.isRepeating || task.repeatMinute == null) {
      AppLog.d('[通知] 未调度重复提醒 id=${task.id}：非重复任务或无提醒时间');
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
        actions: _taskActions,
        // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
        visibility: visibility,
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
          AppLog.d('[通知] 已调度重复提醒 id=${task.id} 每天 '
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
          AppLog.d('[通知] 已调度重复提醒 id=${task.id} ${task.repeatSummary} '
              '每周 $weeklyDays @ ${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} '
              '(skipToday=$skipToday)');
          return true;

        case RepeatType.interval:
          final next = _nextIntervalOccurrence(task, skipToday: skipToday);
          if (next == null) {
            AppLog.d('[通知] 未调度 interval 提醒 id=${task.id}：缺锚点');
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
          AppLog.d('[通知] 已调度重复提醒(interval) id=${task.id} 下次 '
              '${when.year}-${when.month}-${when.day} ${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} '
              '(skipToday=$skipToday)');
          return true;

        case RepeatType.monthly:
          final when = _nextMonthlyOccurrence(task, skipToday: skipToday);
          if (when == null) {
            AppLog.d('[通知] 未调度 monthly 提醒 id=${task.id}：缺提醒时间');
            return false;
          }
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
            matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime,
          );
          AppLog.d('[通知] 已调度重复提醒(monthly) id=${task.id} '
              '${task.repeatSummary} @ ${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} '
              '(skipToday=$skipToday)');
          return true;

        case RepeatType.none:
          return false;
      }
    } catch (e, s) {
      AppLog.d('[通知] 重复提醒调度失败 id=${task.id}: $e');
      AppLog.d('$s');
      return false;
    }
  }

  /// 计算 monthly 任务下一次 occurrence 的「日期+时刻」。
  /// 优先本月目标日；若已过（或 skipToday 且恰为今天）则顺延到下一月。
  /// 「每月 N 号」模式用 [Task.monthlyDay]（溢出夹到当月最后一天）；
  /// 「第 N 个周几 / 最后一个周几」模式用 [Task.monthlyWeekday]+[Task.monthlyWeekIndex]；
  /// 「每月最后一天 / 倒数第 N 天」用 [Task.monthlyFromEnd]（P1-9，优先级最高）。
  tz.TZDateTime? _nextMonthlyOccurrence(Task task, {bool skipToday = false}) {
    if (task.repeatMinute == null) return null;
    final loc = _loc ?? tz.UTC;
    final m = task.repeatMinute!;
    final hh = m ~/ 60;
    final mm = m % 60;
    final now = tz.TZDateTime.now(loc);

    int targetDay(int y, int mo) {
      // 倒数第 N 天（P1-9）语义最明确，优先于其余两种模式
      if (task.monthlyFromEnd > 0) {
        final dim = DateTime(y, mo + 1, 0).day;
        return (dim - task.monthlyFromEnd + 1).clamp(1, dim);
      }
      if (task.monthlyWeekday != null && task.monthlyWeekIndex != null) {
        var d = 1;
        while (DateTime(y, mo, d).weekday != task.monthlyWeekday) {
          d++;
          if (d > 31) return 1; // 安全兜底，理论不可达
        }
        d += (task.monthlyWeekIndex! - 1) * 7;
        final dim = DateTime(y, mo + 1, 0).day;
        if (d > dim) d -= 7; // 「最后一个」时第 5 个不存在则回退到第 4 个
        return d;
      }
      final dim = DateTime(y, mo + 1, 0).day;
      return task.monthlyDay.clamp(1, dim);
    }

    var y = now.year;
    var mo = now.month;
    for (var step = 0; step < 3; step++) {
      final d = targetDay(y, mo);
      final candidate = tz.TZDateTime(loc, y, mo, d, hh, mm);
      final isToday = _sameDay(
        DateTime(candidate.year, candidate.month, candidate.day),
        DateTime(now.year, now.month, now.day),
      );
      if (candidate.isAfter(now) && !(skipToday && isToday)) return candidate;
      mo += 1;
      if (mo > 12) {
        mo = 1;
        y += 1;
      }
    }
    // 极端兜底（正常 3 步内必命中）：返回两个月后的目标日。
    final d = targetDay(y, mo);
    return tz.TZDateTime(loc, y, mo, d, hh, mm);
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
    // 尊重 skipDates / repeatUntil：若算出的下次 occurrence 落在「跳过日」或「已超结束日」，
    // 顺延到下一个真正命中的循环日（上限 60 次防死循环，覆盖最极端间隔）。
    var guard = 0;
    var candidate = result;
    while (guard < 60 &&
        !task.repeatsOn(
            DateTime(candidate.year, candidate.month, candidate.day))) {
      final next = candidate.add(const Duration(days: 1));
      candidate = tz.TZDateTime(loc, next.year, next.month, next.day, m ~/ 60, m % 60);
      guard++;
    }
    // S11 修复：60 次仍未找到合法的循环日（跳过日密集 / 临近结束日期），
    // 不再返回一个不满足条件的候选日期去照常调度，而是本次不提醒（返回 null）。
    if (!task.repeatsOn(
        DateTime(candidate.year, candidate.month, candidate.day))) {
      return null;
    }
    return candidate;
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

  /// 习惯提醒使用独立的 id 段（10 亿起 + 槽位*10 + 星期索引），与任务的
  /// 「截止提醒 / 重复提醒」区分开，避免互相 cancel 掉。dayIndex：每天提醒用 0；
  /// 按星期提醒用 1..7。最大值 1e9 + 99999*10 + 7 ≈ 1.001e9，远小于 int32 上限。
  ///
  /// S10 修复：原方案落在 80 万段，虽与一次性段（0..N）实测不冲突，但与新迁到
  /// 20 亿段的重复提醒保持清晰的大段隔离，杜绝任何远期碰撞。
  /// schedule / cancel 必须走同一函数，否则删除习惯时取消会错位。
  static int _habitNotifyIdOf(String id, int dayIndex) {
    final s = _habitSlotOf(id);
    return 1000000000 + s * 10 + (dayIndex % 8);
  }

  /// 为习惯调度每日打卡提醒（setAlarmClock 模式，不被 ColorOS 等国产 ROM 拦截）。
  /// [checkedToday] 为 true（今天已打卡）且提醒时刻尚未到来时，跳过今日这一次，
  /// 挂到下一个循环日，避免「已完成仍弹提醒」。返回 true 表示已提交。
  ///
  /// - [weekdays] 为空：每天同一时刻（[DateTimeComponents.time]）。
  /// - [weekdays] 非空：按所选星期逐个挂 [DateTimeComponents.dayOfWeekAndTime]。
  Future<bool> scheduleHabitReminder(Habit habit, {bool checkedToday = false}) async {
    if (!enabled) {
      AppLog.d('[通知] 未调度习惯提醒 id=${habit.id}：通知总开关关闭');
      return false;
    }
    if (habit.reminderMinute == null) {
      AppLog.d('[通知] 未调度习惯提醒 id=${habit.id}：未设提醒时间');
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
        // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
        visibility: visibility,
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
        AppLog.d('[通知] 已调度习惯提醒 id=${habit.id} 每天 '
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
      AppLog.d('[通知] 已调度习惯提醒 id=${habit.id} 每周 ${habit.weekdays} '
          '@ ${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} '
          '(skipToday=$skipToday)');
      return true;
    } catch (e, s) {
      AppLog.d('[通知] 习惯提醒调度失败 id=${habit.id}: $e');
      AppLog.d('$s');
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
      AppLog.d('[通知] 取消习惯提醒失败 id=$id: $e');
    }
  }

  /// 稍后提醒（snooze）：用同一通知 id 在 [delay] 后重新弹出该任务提醒。
  /// 覆盖式调度（不新建通知），点「稍后提醒」后原通知消失、[delay] 后再弹一次；
  /// [delay] 默认 10 分钟。仅对「截止提醒」一次性任务有效（重复 / 习惯走各自方法）。
  Future<bool> snoozeTaskReminder(Task task,
      {Duration delay = const Duration(minutes: 10), bool playSound = true}) async {
    if (!enabled) {
      AppLog.d('[通知] 未 snooze id=${task.id}：通知总开关关闭');
      return false;
    }
    final loc = _loc ?? tz.UTC;
    final when = tz.TZDateTime.now(loc).add(delay);
    // S4 修复：作废在途兜底定时器（若有），使本次 snooze 的提醒能正常弹出。
    _deadlineGen[task.id] = (_deadlineGen[task.id] ?? 0) + 1;
    final chId = playSound ? _chSound : _chSilent;
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        chId,
        '任务提醒',
        channelDescription: '任务截止时间提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: playSound,
        // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
        visibility: visibility,
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
      AppLog.d('[通知] snooze id=${task.id} -> $when (${delay.inMinutes}min)');
      return true;
    } catch (e, s) {
      AppLog.d('[通知] snooze 失败 id=${task.id}: $e');
      AppLog.d('$s');
      return false;
    }
  }

  /// 习惯提醒的稍后提醒：用同一习惯通知 id 在 [delay] 后重新弹出打卡提醒。
  Future<bool> snoozeHabitReminder(Habit habit,
      {Duration delay = const Duration(minutes: 10)}) async {
    if (!enabled) {
      AppLog.d('[通知] 未 snooze 习惯 id=${habit.id}：通知总开关关闭');
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
        // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
        visibility: visibility,
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
      AppLog.d('[通知] snooze 习惯 id=${habit.id} -> $when (${delay.inMinutes}min)');
      return true;
    } catch (e, s) {
      AppLog.d('[通知] snooze 习惯失败 id=${habit.id}: $e');
      AppLog.d('$s');
      return false;
    }
  }

  /// 清空所有已调度的通知（关闭总开关时调用）。
  Future<void> cancelAll() {
    _deadlineGen.clear();
    return _plugin.cancelAll();
  }

  /// 计算下一次简报触发时刻：今日 [hour]:[minute] 若尚未过去则用今日，否则顺延到明日。
  ///
  /// P1-8 关键点：简报文案在**排程时**烘焙，所以调用方必须按**投递日**（即本方法的返回值）
  /// 而非「排程当下」来聚合数据，否则会出现「周一晚上排的周二晨报，说的是周一的口径」。
  /// 抽成公共方法是为了让 [scheduleBriefing] 与排程方（daily_briefing）共用同一口径，
  /// 避免两边各算一套、日后其中一处改动导致日期漂移。
  tz.TZDateTime nextBriefingTime(int hour, int minute) {
    final loc = _loc ?? tz.UTC;
    final hh = hour.clamp(0, 23);
    final mm = minute.clamp(0, 59);
    final now = tz.TZDateTime.now(loc);
    final when = tz.TZDateTime(loc, now.year, now.month, now.day, hh, mm);
    return when.isAfter(now) ? when : when.add(const Duration(days: 1));
  }

  /// P0-1 早晚简报调度：每日在 [hour]:[minute] 重复触发一条本地通知（setAlarmClock，
  /// 不被 ColorOS 等国产 ROM 拦截）。[evening]=true 为晚间「今日小结」，
  /// false 为晨间「今日待办」。文案由调用方在排程时烘焙进 [title]/[body]。
  /// 复用同一固定 id（[briefingEveningNotifyId]/[briefingMorningNotifyId]），
  /// 修改时间后重新调用即覆盖旧通知（与习惯每日提醒同模式）。
  Future<bool> scheduleBriefing(
    bool evening,
    int hour,
    int minute, {
    required String title,
    required String body,
  }) async {
    if (!enabled) {
      AppLog.d('[通知] 未调度简报：通知总开关关闭');
      return false;
    }
    try {
      final id = evening ? briefingEveningNotifyId : briefingMorningNotifyId;
      final when = nextBriefingTime(hour, minute);
      final mode = await _scheduleMode;
      final detail = NotificationDetails(
        android: AndroidNotificationDetails(
          _chSound,
          '任务提醒',
          channelDescription: '任务截止时间提醒',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
          visibility: visibility,
        ),
      );
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        when,
        detail,
        payload: '$payloadBriefPrefix${evening ? 'evening' : 'morning'}',
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
      AppLog.d('[通知] 已调度${evening ? "晚间" : "晨间"}简报 -> $when (id=$id)');
      return true;
    } catch (e, s) {
      AppLog.d('[通知] 简报调度失败(evening=$evening): $e');
      AppLog.d('$s');
      return false;
    }
  }

  /// 取消某条简报通知（关闭对应开关时调用）。
  Future<void> cancelBriefing(bool evening) =>
      _plugin.cancel(evening ? briefingEveningNotifyId : briefingMorningNotifyId);

  /// P1-7：调度「习惯漏卡挽留」通知——每天 [HabitNudge.nudgeMinute]（23:00）
  /// 重复触发一条本地通知（setAlarmClock 模式，不被 ColorOS 等国产 ROM 拦截）。
  ///
  /// 文案由调用方在**排程时**烘焙（[HabitNudge.text]），因为系统闹钟到点时 App
  /// 未必在内存、没有机会重算；因此 App 每次启动 / 习惯或打卡变动时都要重排。
  /// [payload] 默认指向习惯页，单个习惯漏卡时调用方会带上具体 id 以直达补卡。
  ///
  /// 用固定 id [habitNudgeNotifyId]，重复调用即覆盖旧通知（与简报同模式）。
  Future<bool> scheduleHabitNudge({
    required String title,
    required String body,
    String? payload,
    int nudgeMinute = 23 * 60,
  }) async {
    if (!enabled) {
      AppLog.d('[通知] 未调度习惯挽留：通知总开关关闭');
      return false;
    }
    if (title.isEmpty) {
      AppLog.d('[通知] 未调度习惯挽留：文案为空（今天没有漏卡）');
      return false;
    }
    try {
      final loc = _loc ?? tz.UTC;
      // F4：时刻可配置（自 00:00 起的分钟数，默认 23:00），不再硬编码。
      final hh = nudgeMinute ~/ 60;
      final mm = nudgeMinute % 60;
      final now = tz.TZDateTime.now(loc);
      // 今天这个时刻已过就顺延到明天——与简报同一套路，避免排一个过去的时间点。
      var when = tz.TZDateTime(loc, now.year, now.month, now.day, hh, mm);
      when = when.isAfter(now) ? when : when.add(const Duration(days: 1));
      // F4：排程前感知勿扰区间——若落点恰在勿扰时段内，按既有 dndDefer 顺延，
      // 避免挽留撞进勿扰被静默吞掉。
      if (dndDefer != null) {
        final deferred = dndDefer!(when);
        if (deferred != null) {
          // dndDefer 返回普通 DateTime，需按当前时区换算回 TZDateTime 才能用于 zonedSchedule。
          when = tz.TZDateTime(loc, deferred.year, deferred.month, deferred.day,
              deferred.hour, deferred.minute);
        }
      }
      final mode = await _scheduleMode;
      final detail = NotificationDetails(
        android: AndroidNotificationDetails(
          _chSound,
          '习惯提醒',
          channelDescription: '每日习惯打卡提醒',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          playSound: true,
          // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
          visibility: visibility,
        ),
      );
      await _plugin.zonedSchedule(
        habitNudgeNotifyId,
        title,
        body,
        when,
        detail,
        payload: payload ?? payloadHabitPrefix,
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
      AppLog.d('[通知] 已调度习惯挽留 -> $when (id=$habitNudgeNotifyId)');
      return true;
    } catch (e, s) {
      AppLog.d('[通知] 习惯挽留调度失败: $e');
      AppLog.d('$s');
      return false;
    }
  }

  /// 取消习惯漏卡挽留通知（通知总开关关闭，或今天已无漏卡时调用）。
  Future<void> cancelHabitNudge() => _plugin.cancel(habitNudgeNotifyId);

  /// P1-12：调度「回收站过期预告」通知——把将于明天 00:00 被永久删除的任务
  /// 聚合成一条通知，调度到「明天 00:00」触发。用固定 id [trashExpireNotifyId]
  /// 覆盖式更新：每天重排时旧通知自动被替换，不会堆积多条。
  ///
  /// [expiringTomorrow] 为将于明天 00:00 被清理的回收站任务（剩余天数 == 1）。
  /// 为空则取消该固定 id 的通知（无预告可发时不留残留）。离线、纯本地调度。
  Future<void> scheduleTrashExpireNotice(List<Task> expiringTomorrow) async {
    if (!enabled) {
      // 通知总开关关闭：不调度任何预告，同时清掉可能残留的旧预告。
      await _plugin.cancel(trashExpireNotifyId);
      return;
    }
    if (expiringTomorrow.isEmpty) {
      await _plugin.cancel(trashExpireNotifyId);
      return;
    }
    try {
      final loc = _loc ?? tz.UTC;
      final now = tz.TZDateTime.now(loc);
      // 明天 00:00（与原生 MidnightResetReceiver 清理同一时刻，口径一致）。
      final when = tz.TZDateTime(loc, now.year, now.month, now.day + 1);
      final mode = await _scheduleMode;
      // 标题/正文：聚合最多展示前几条任务名，避免通知体过长。
      final titles = expiringTomorrow.take(5).map((t) => t.title.trim()).toList();
      final more = expiringTomorrow.length - titles.length;
      final body = more > 0
          ? '${titles.join('、')} 等 ${expiringTomorrow.length} 条任务将于明天被永久删除'
          : '${titles.join('、')} 将于明天被永久删除';
      final detail = NotificationDetails(
        android: AndroidNotificationDetails(
          _chSound,
          '任务提醒',
          channelDescription: '任务截止时间提醒',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          autoCancel: true,
          // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
          visibility: visibility,
        ),
      );
      await _plugin.zonedSchedule(
        trashExpireNotifyId,
        '回收站即将清空',
        body,
        when,
        detail,
        payload: '',
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      AppLog.d('[通知] 回收站过期预告已调度 -> $when（${expiringTomorrow.length} 条）');
    } catch (e, s) {
      AppLog.d('[通知] 回收站过期预告调度失败: $e\n$s');
    }
  }

  /// P1-12：取消回收站过期预告通知（清空回收站 / 恢复全部时调用）。
  Future<void> cancelTrashExpireNotice() => _plugin.cancel(trashExpireNotifyId);

  /// 通知「完成」action 后的覆盖式确认通知：用任务通知 id 在原通知位弹出
  /// 「已完成 ✓」，既不刷屏、也不叠加新通知。用户点开无跳转（payload 置空）。
  Future<void> showCompletedConfirm(String taskId, String title) async {
    if (!enabled) return;
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        _chSound,
        '任务提醒',
        channelDescription: '任务截止时间提醒',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        autoCancel: true,
        // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        _notifyIdOf(taskId),
        '已完成 ✓',
        title.isNotEmpty ? title : '无标题任务',
        detail,
      );
    } catch (e) {
      AppLog.d('[通知] 完成确认通知失败 id=$taskId: $e');
    }
  }

  /// 在 [completeAt]（墙钟时刻）调度「专注完成」系统闹钟通知。
  /// 采用与任务提醒一致的 setAlarmClock 模式，即使 App 被划掉后台也能准点弹出；
  /// 固定 id=[focusDoneNotifyId]，与 [showFocusDoneNow]/[cancelFocusDone] 共用，
  /// 避免重复成两条。通知总开关关闭时不调度。
  /// [body] 可自定义文案（番茄循环用于提示"该休息 / 开始下一个番茄"）。
  Future<void> scheduleFocusDone(DateTime completeAt, {String? body}) async {
    if (!enabled) {
      AppLog.d('[通知] 未调度专注完成提醒：通知总开关关闭');
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
      AppLog.d('[通知] 已调度专注完成提醒 -> $when (mode=${mode.name})');
    } catch (e) {
      AppLog.d('[通知] 专注完成定时失败: $e');
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
      // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
      visibility: visibility,
    );
    try {
      await _plugin.show(
        focusProgressNotifyId,
        title,
        bodyText,
        NotificationDetails(android: android),
      );
    } catch (e) {
      AppLog.d('[通知] 专注进度通知失败: $e');
    }
  }

  /// 取消专注进行中的常驻进度通知（暂停 / 停止 / 自然完成 / 启动时清理残留）。
  Future<void> cancelFocusProgress() => _plugin.cancel(focusProgressNotifyId);

  /// P0-4：专注「被切出」挽留通知——切回 App 时告知本次专注已中断过几次，
  /// 让「实际专注质量」可感知（L1 只做次数统计，不识别来源 App，无需任何权限）。
  /// 固定 id，多次打断互相覆盖，不会堆成一排。
  Future<void> showFocusInterruptNotice(int count) => _plugin.show(
        focusInterruptNotifyId,
        '专注被中断过',
        '本次专注已切出 $count 次，回来继续吧',
        NotificationDetails(android: _focusDoneAndroid),
      );

  /// 取消「专注被切出」挽留通知（专注停止 / 完成时清理）。
  Future<void> cancelFocusInterruptNotice() =>
      _plugin.cancel(focusInterruptNotifyId);

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
