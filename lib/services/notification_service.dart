import 'dart:async';
import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// P3-13（v2.9.5 审计）：习惯类通知的**独立**渠道。
  ///
  /// 此前习惯打卡提醒 / 习惯稍后提醒 / 漏卡挽留全部复用任务渠道
  /// [todo_reminder]（其展示名是「任务提醒」），于是：
  /// - 在系统「通知设置」里，习惯提醒挂在**任务提醒**名下，用户无法单独关掉
  ///   习惯提醒（一个渠道只有一个开关）；
  /// - 关掉任务提醒会连带把习惯提醒一起静音，粒度不可分。
  ///
  /// Android 一旦建好渠道，其声音/重要性属性不可再改，所以要独立可关就必须
  /// **另开一个渠道 id**（不能改名复用）。保持与任务渠道相同的 Importance /
  /// playSound，让用户观感不变，只是多一个可分别管理的开关。
  static const String _chHabit = 'habit_reminder';

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
  /// - 任务重复提醒：      repeatNotifyIdOf(id, d)   ≈ [1.6e9, ~1.84e9]（独立大连段，每任务 8 槽）
  /// - 专注完成通知：      777777（固定）
  /// - 专注进行中常驻：    777778（固定）
  /// - 习惯提醒：          habitNotifyIdOf(id, d)    ≈ [1.0e9, ~1.001e9]（独立大连段）
  /// - 习惯稍后提醒：      habitSnoozeNotifyIdOf(id) 落在习惯段内每习惯的**第 8 号槽**
  ///                       （= 1000000000 + slot*10 + 8，落点只用 0..7，故永不被
  ///                       落点重排覆盖；详见 [habitSnoozeNotifyIdOf]）
  /// - 习惯打卡/撤销确认： habitConfirmNotifyIdOf(id) 落在习惯段内每习惯的**第 9 号槽**
  ///                       （= 1000000000 + slot*10 + 9，同样永不被落点重排覆盖；
  ///                       详见 [habitConfirmNotifyIdOf]；新P3-6，v2.9.7 审计）
  /// - 锁定态 action 提示： lockedActionNotifyId = 1600000（固定；新U3-1，v2.9.7 审计）
  /// - 习惯漏卡挽留：      habitNudgeNotifyId = 1500000（固定）
  /// - 定时测试系统闹钟：  _kTestTimerId = 999999（固定）
  /// - 定时测试应用内延迟：_kTestTimerId + 1 = 1000000（固定）
  /// - 即时测试通知：      1200000 + ms%100000     = [1200000, 1299999]（见 [showTest]）
  /// - 早晚简报：          briefingEveningNotifyId=1300001 / briefingMorningNotifyId=1300002（见 [scheduleBriefing]）
  /// - 回收站过期预告：    trashExpireNotifyId = 1400000（固定，见 [scheduleTrashExpireNotice]）
  ///
  /// 即时测试通知此前落在 800000 段，与习惯提醒段重叠，会以相同 id 顶掉用户当天
  /// 尚未触发的习惯打卡闹钟（约 10% 习惯被波及）。现整体移出习惯段到 1200000+。
  ///
  /// 【通知渠道分配表（P3-13）】
  /// - [todo_reminder] 「任务提醒」：任务一次性/重复提醒、专注完成、简报、回收站预告
  /// - [todo_reminder_silent] 「任务提醒（静音）」：任务类静音变体
  /// - [habit_reminder] 「习惯提醒」：习惯打卡落点、习惯稍后提醒、漏卡挽留
  /// - [focus_progress] 「专注进行中」：常驻进度条
  ///
  /// 习惯类此前复用 `todo_reminder`，在系统通知设置里与任务提醒混作一项、无法
  /// 单独关闭，故独立成段。
  static const int _kTestTimerId = 999999;

  /// 即时测试通知 id 段起点。
  ///
  /// P3-13（v2.9.6 审计）：本注释此前写「避开习惯提醒段 [800000,1800007]」，
  /// 与实际不符——习惯提醒段自 P3-13（v2.9.5）独立为 ~1e9 起，800000 旧段
  /// 已不存在（即时测试通知正是因当时落在 800000 与旧习惯段重叠才整体迁到
  /// 1200000+）。现按上方段位分配表如实更新：本段 [1200000, 1299999] 只需
  /// 避开定时测试段 [999999, 1000000] 与简报 / 回收站 / 挽留固定 id。
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

  /// 锁定态 action 提示固定通知 id（1600000）：避开任务/重复/习惯/专注/测试/
  /// 简报/回收站/挽留全部段位。见 [showLockedActionHint]（新U3-1，v2.9.7 审计）。
  static const int lockedActionNotifyId = 1600000;

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

  /// U3：习惯提醒的「打卡」action：点击后直接补打今天，不进 App、不打断当前场景。
  /// 只在习惯提醒（habit: 前缀）上挂；已打卡的提醒不会弹（调度层已 skipToday），
  /// 但保险起见消费端仍做幂等（checkInOnDay 已存在则忽略）。
  static const String habitCheckInActionId = 'habit_checkin';

  /// U2-4（v2.9.6 审计）：确认通知上的「撤销」action——通知打卡此前只能写入
  /// 不能回退，误触后必须进 App 手动纠正。点击后清空该习惯**今天**的记录
  /// （消费端走 setCheckInValue 唯一写入口）。
  static const String habitUndoActionId = 'habit_undo';

  /// P3-22（v2.9.9 审计）：任务「完成」确认通知上的「撤销」action——通知完成
  /// 此前只能写入不能回退（_doComplete 直接 setStatus(done)），与 App 内
  /// 「完成即撤销」承诺不统一。点击后由 main._doTaskUndo 用完成前快照整体回滚
  /// （restoreTaskSnapshot）。仅任务类确认通知（task: 前缀 payload）携带。
  static const String taskUndoActionId = 'task_undo';

  /// 任务类提醒（截止 / 重复）统一的两个 action 按钮：稍后提醒 + 完成。
  /// 习惯提醒不显示「完成」（习惯是打卡语义，走各自 action），故单独维护。
  ///
  /// U3-2（v3.0.3 审计）口径固化（防后续轮次按缺陷重复上报）：点「稍后提醒」
  /// 后原通知**会**随 action 点击自动消散——flutter_local_notifications 17.2.4
  /// 的 `AndroidNotificationAction.cancelNotification` **默认即 true**（Dart 侧
  /// 经 method_channel_mappers 序列化进 action 参数 → 原生
  /// ActionBroadcastReceiver.onReceive 按 CANCEL_NOTIFICATION extra 撤掉承载
  /// 该 action 的通知；showsUserInterface 路径由
  /// processForegroundNotificationAction 同样处理），无需显式设参。审计报告
  /// 「均未设 cancelNotification: true → 原通知仍留在通知栏」的前提与插件实际
  /// 默认不符，特此注释钉死。
  static List<AndroidNotificationAction> get _taskActions => [
        AndroidNotificationAction(snoozeActionId, '稍后提醒'),
        AndroidNotificationAction(completeActionId, '完成'),
      ];

  /// 习惯类提醒统一的两个 action 按钮：稍后提醒 + 打卡。
  ///
  /// P2-1（v2.9.4 审计）：抽出为单一真源——正式落点与 snooze 落点**共用**同一组
  /// action（此前 snooze 通知一个 action 都没有，顺延后既不能再顺延也不能打卡）。
  ///
  /// U2-4（v2.9.6 审计）：标签随量化语义变化——量化习惯的「打卡」动作实际是
  /// **+1**（U2-6 之后恒 +1，不再一键顶满），原标签「打卡」让用户分不清是
  /// 「+1」还是「达标」。量化习惯改显「记 1 个」；布尔习惯维持「打卡」。
  ///
  /// U3-2（v3.0.3 审计）：cancelNotification 口径同 [_taskActions] 注释
  /// （插件 17.2.4 默认 true，action 点击即撤原通知，无需显式设参）。
  static List<AndroidNotificationAction> habitActionsFor(Habit habit) => [
        AndroidNotificationAction(snoozeActionId, '稍后提醒'),
        AndroidNotificationAction(
            habitCheckInActionId, habit.isQuantified ? '记 1 个' : '打卡'),
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

  /// F-2：每个重复任务 / 习惯预挂的「未来 occurrence」个数。
  ///
  /// 重复提醒 id 段为每个任务预留了 8 个连续槽位（dayIndex 0..7），
  /// [cancelRepeatReminder] / [cancelHabitReminder] 也按 0..7 逐个取消——
  /// 这里正好用这 8 个槽位预挂「接下来的 8 次」，让进程被杀 / 长期未打开 App 时
  /// 仍有 8 个周期的续航（每天任务 ≈ 8 天、每周任务 ≈ 8 周、每月任务 ≈ 8 个月），
  /// 而不是「响一次就断」（F-2 改造前 daily/weekly 靠 OS 周期循环永生，
  /// 改造为一次性闹钟后必须自带这段续航，否则是可靠性倒退）。
  static const int _kScheduleSlots = 8;

  /// F-2：每个任务 / 习惯**当前已挂出**的落点签名，用于跳过多余重挂。
  ///
  /// `TaskProvider.checkDailyReset` 每 15 分钟就会为全部重复任务重挂一次；
  /// 若落点没变（绝大多数周期内都没变），重复的 zonedSchedule 只是白白消耗
  /// 平台通道 + 插件内部的 SharedPreferences 往返。签名一致即跳过。
  /// 进程重启 / 批量取消后缓存自然失效并重建（见 [cancelAll] /
  /// [_purgeLegacyNotificationsIfNeeded]）。
  final Map<String, String> _armedSignatures = {};

  /// 清空「已挂落点」缓存，强制下一次重排真正下发到系统。
  /// 批量取消（方案升级 / 恢复备份 / 关闭总开关）后必须调用。
  ///
  /// P3-2（v2.8.7 审计）：落点内容缓存 [_occurrenceMemo] 与 armed 签名**同生共死**，
  /// 统一在此一并失效——此前仅「勿扰变更 / 时区变更」两条路径清 memo，而
  /// 「方案升级 / 恢复备份 cancelAll」等路径只清 armed：同一天内 armed 已清、
  /// memo 未清时，scheduleRepeatReminder 会命中当日 memo，返回「首次计算之后
  /// 当前时刻已过」的落点，绕过 repeatOccurrenceTimes「落点必须严格晚于 now」
  /// 的契约，把过去时刻交给 zonedSchedule（Android 立即补弹或抛异常被吞）。
  /// 绑定后两条缓存同进同出，调用方无须（也不再需要）单独清 memo。
  void _invalidateArmedCache() {
    _armedSignatures.clear();
    _occurrenceMemo.clear();
  }

  /// P3-3（v2.8.6 审计）：落点**计算结果**的内容签名缓存。
  ///
  /// 15 分钟守护每轮都会为每个重复任务 / 习惯重算「接下来 8 次落点」
  /// （≤400 天逐日扫描）；而落点只随「规则内容 + 当日 + 勿扰顺延输入」变化。
  /// 缓存命中时直接复用上一轮结果，跳过整段扫描——千级任务可省每轮数万次
  /// 日期判断（电量 / CPU）。签名见 [_repeatContentSig] / 习惯处的内联签名。
  /// 失效路径（P3-2 起与 armed 签名绑定，同生共死）：跨天、内容变更、
  /// 勿扰设置变更（[clearOccurrenceMemo]）、批量取消 / 时区变更
  /// （[_invalidateArmedCache] / [setTimezoneOverride]）。
  final Map<String, (String, List<DateTime>)> _occurrenceMemo = {};

  /// P3-3：外部使落点内容缓存失效（勿扰时段设置变更时由 TaskProvider 调用）。
  void clearOccurrenceMemo() => _occurrenceMemo.clear();

  /// P3-3：重复任务落点的内容签名（只含会影响「未来落点序列」的字段）。
  /// 标题 / 颜色 / 置顶等展示字段变化**不应**触发重算，故刻意不纳入。
  static String _repeatContentSig(Task t) => [
        t.repeatMinute,
        t.repeat.index,
        t.repeatInterval,
        t.repeatWeekdays.join(','),
        t.repeatAnchor?.toIso8601String() ?? '',
        t.repeatUntil ?? '',
        t.skipDates.join(','),
        t.doneDates.join(','),
        t.done,
        t.completedAt?.toIso8601String() ?? '',
        t.monthlyDay,
        t.monthlyWeekday,
        t.monthlyWeekIndex,
        t.monthlyFromEnd,
      ].join('|');

  /// F-3：勿扰顺延在落点计算里的统一入口（见 [repeatOccurrenceTimes] /
  /// [habitOccurrenceTimes] 的 `defer` 参数）。
  ///
  /// 一次性闹钟的**每个**落点都独立过一遍勿扰是正确做法：不会像
  /// `matchDateTimeComponents` 那样把顺延后的时分 / 星期写进周期分量导致漂移。
  /// 「每天 07:00」在勿扰 23:00–08:00 下，等价于「每天 08:05 提醒」。
  /// 未注入 [dndDefer]（如单测 / 未启用勿扰）时返回原时刻。
  static DateTime? deferByDnd(DateTime when) {
    final defer = dndDefer;
    if (defer == null) return null;
    return defer(when);
  }

  /// F11：「稍后提醒（snooze）」独立 id 段。
  ///
  /// 此前 snooze 复用一次性「截止提醒」的 [_notifyIdOf]，而重复提醒的 payload
  /// 同为 `task:<id>`、_handleNotificationAction 只按前缀路由 →
  /// 在重复提醒上点「稍后提醒」会用**截止提醒的 id** 重新调度，
  /// 把该任务未来的截止闹钟覆盖删除（直到下次全量重排才恢复）。
  /// 这里给 snooze 一个独立段位，彻底杜绝顶掉其它提醒。
  static int _snoozeNotifyIdOf(String id) {
    final base = int.tryParse(id) ?? id.hashCode;
    return 1900000000 + (base % 10000000).abs();
  }

  /// 重复提醒使用独立 id 段，与一次性「截止提醒」（0..N）、习惯提醒（1e9+）都互不重叠，
  /// 避免同一任务的两种提醒互相 cancel 掉。dayIndex：daily / interval / monthly 用 0；
  /// weekly / weekday 用 1..7（对应周一..周日），每个星期一个独立 id。
  ///
  /// S10 修复：原方案用 `id + 500000`，当任务自增 id 增长到 50 万后即与一次性提醒段
  /// 重叠、互相顶掉。现统一落到独立大连段，彻底消除远期碰撞。
  ///
  /// F-02 修复：旧布局 `2000000000 + base%1e8 + dayIndex` 把星期槽**直接加在任务 id 低位**，
  /// 没有为它预留位宽——任务 id 连续自增时，只要 `A + dA == B + dB` 两个任务就会拿到
  /// 完全相同的通知 id（枚举 8..30 × 槽 0..7 有 28 组碰撞），Android 对同 id 的后一次
  /// zonedSchedule 会**覆盖**前一次，其中一条重复提醒就此静默消失（如「任务8 每周一」
  /// 与「任务9 每天」都算出 2000000009）。现为每个任务预留 8 个连续槽位（`slot * 8`），
  /// 与习惯提醒 [habitNotifyIdOf] 的 `* 10` 同思路：
  ///
  ///   1600000000 + (base % 30000000) * 8 + (dayIndex % 8)
  ///
  /// 取值区间 [1600000000, 1839999999]，既在 int32 上限（2147483647）内，
  /// 又避开 snooze 段 [1900000000, 1909999999] 与习惯段 [1000000000, 1000999907]。
  /// 升级后 [_purgeLegacyNotificationsIfNeeded] 会一次性清掉旧段位闹钟并全量重排。
  static int repeatNotifyIdOf(String id, int dayIndex) {
    final base = int.tryParse(id) ?? id.hashCode;
    final slot = (base % 30000000).abs();
    return 1600000000 + slot * 8 + (dayIndex % 8);
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
      _loc = await _resolveLocation();
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

  /// P2-3（v2.8.6 审计）：提醒时区覆盖偏好（SharedPreferences 键）。
  /// '' = 跟随设备（默认）；非空 = IANA 时区名（如 'Asia/Shanghai'，设置页选择）。
  static const String _kTzOverridePref = 'reminder_timezone_override';

  /// P2-3：解析提醒调度应使用的时区。
  ///
  /// 优先级：用户显式覆盖（设置页）> 设备时区（经原生通道取 IANA id）>
  /// 按设备当前 UTC 偏移在时区库中匹配（通道不可用时的离线兜底）> UTC。
  /// 此前硬编码 `Asia/Shanghai`：设备在其它时区（出差 / 旅行 / 海外常驻）时，
  /// 「每天 07:00」的提醒会早/晚数小时甚至被排到本地前一天。
  Future<tz.Location> _resolveLocation() async {
    String? override;
    try {
      final prefs = await SharedPreferences.getInstance();
      override = prefs.getString(_kTzOverridePref);
    } catch (_) {}
    if (override != null && override.isNotEmpty) {
      try {
        return tz.getLocation(override);
      } catch (_) {}
    }
    try {
      final id = await _exactAlarmChannel.invokeMethod<String>('getTimeZoneId');
      if (id != null && id.isNotEmpty) return tz.getLocation(id);
    } catch (_) {}
    // 离线兜底：与设备当前 UTC 偏移一致的首个时区。无 DST 信息可靠性稍弱，
    // 但只在新装设备拿不到通道 id 的极端场景出现；中国时区设备会命中
    // Asia/Shanghai 等同偏移时区，行为与旧版一致。
    try {
      final now = DateTime.now();
      final off = now.timeZoneOffset;
      for (final name in tz.timeZoneDatabase.locations.keys) {
        final l = tz.getLocation(name);
        if (tz.TZDateTime.from(now, l).timeZoneOffset == off) return l;
      }
    } catch (_) {}
    return tz.UTC;
  }

  /// P2-3：读取提醒时区覆盖（'' = 跟随系统）。设置页展示用。
  static Future<String> getTimezoneOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kTzOverridePref) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// P2-3：设置提醒时区覆盖并立即生效。
  /// 重解析时区、作废落点签名与内容缓存；调用方负责随后触发一次全量重排
  /// （[TaskProvider.rescheduleAllNotifications] + 简报/挽留/回收站预告，
  /// 见 daily_briefing.rescheduleFixedTimeReminders），否则已挂闹钟仍按旧时区响。
  static Future<void> setTimezoneOverride(String v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTzOverridePref, v);
    } catch (_) {}
    await _applyTimezoneOverride();
  }

  /// P2-1（v2.8.7 审计）：从 SharedPreferences **重读**时区覆盖并立即生效。
  /// 恢复备份 / 换机还原后调用——applyAppPrefs 只把键写回 SharedPreferences，
  /// 内存 [_loc] 不会自动刷新，不重解析则本轮会话仍按旧时区调度，
  /// 「提醒时区」偏好等于静默丢失（与 P2-12「新偏好未入白名单」同型的恢复侧配套）。
  /// 与 [setTimezoneOverride] 的区别：不回写偏好键，只做「重解析 + 缓存失效」；
  /// 调用方随后应触发一次全量重排。
  static Future<void> reloadTimezoneOverride() => _applyTimezoneOverride();

  /// P2-3 / P2-1 共用：按当前偏好重解析时区并作废落点相关缓存。
  static Future<void> _applyTimezoneOverride() async {
    final inst = instance;
    try {
      inst._loc = await inst._resolveLocation();
      tz.setLocalLocation(inst._loc!);
    } catch (_) {}
    // P3-2：armed 签名与落点内容缓存一并失效（见 _invalidateArmedCache 注释）。
    inst._invalidateArmedCache();
  }

  /// 通知 id 段方案版本（S10 = 1，F-02 = 2，F-2 = 3）。升级到新段分配后用于一次性清理旧通知，
  /// 避免旧 id 段遗留的提醒与新建提醒混淆。
  ///
  /// F-02：重复提醒 id 由「base + dayIndex」改为「base*8 + dayIndex」布局，
  /// 存量用户系统里已排的旧 id 闹钟若不清理，会与新 id 并存（旧闹钟无人取消、
  /// 永远按旧日期响）。这里把方案号 +1，init 时 cancelAll 一次，随后由
  /// TaskProvider 的全量重排按新布局重建。
  ///
  /// F-2：重复提醒（daily / weekly / weekday / 简单 monthly）由 OS 周期闹钟
  /// （`matchDateTimeComponents`）改为**一次性闹钟**。weekly 原先占用槽位 1..7
  /// （每周一个 id），现在统一只用槽位 0..7 承载「接下来 8 次」，若不清理，
  /// 存量用户系统里的 1..7 号周期闹钟会无人取消并**按周永久重复**，
  /// 与新排的提醒重复弹出。故再次把方案号 +1，init 时 cancelAll 清空重建。
  ///
  /// P3-1（v2.8.6 审计）：习惯槽位映射由 `String.hashCode` 换为自实现 FNV-1a
  /// （跨引擎版本稳定）。存量用户系统里已按旧映射排好的习惯闹钟，新映射下
  /// cancel 不到（id 不再对上），会按旧日期照响——与 F-02/F-2 同理，把方案号
  /// +1，init 时 cancelAll 清空，随后由启动全量重排按新映射重建。
  static const int _kNotifIdScheme = 4;
  static const String _kNotifIdSchemePref = 'notif_id_scheme';

  /// 仅首次（或跨版本）执行一次：清掉旧 id 段方案遗留的全部通知，随后正常重排
  /// 会按新段重建。失败不影响主流程。
  Future<void> _purgeLegacyNotificationsIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cur = prefs.getInt(_kNotifIdSchemePref) ?? 0;
      if (cur < _kNotifIdScheme) {
        // F-2：方案号升到 3 时，此处会连**已排的闹钟**一并取消（插件的
        // cancelAll 会遍历 scheduled_notifications 缓存逐个 AlarmManager.cancel），
        // 随后由全量重排按新布局重建；同时作废落点签名缓存。
        _invalidateArmedCache();
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
    // P3-13（v2.9.5 审计）：习惯类通知独立渠道（打卡提醒 / 稍后提醒 / 漏卡挽留）。
    // 意图与声音属性与任务渠道保持一致，只是让用户在系统设置里能单独关掉习惯。
    await plugin.createNotificationChannel(const AndroidNotificationChannel(
      _chHabit,
      '习惯提醒',
      description: '每日习惯打卡提醒与漏卡挽留',
      importance: Importance.high,
      playSound: true,
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
  ///
  /// U2-2（v3.0.4 审计）：确认条 payload 自本版起携带展示日（`<id>|<dateKey>`），
  /// 供「撤销」action 校验日期防错日写入；本方法剥离日期后缀，兼容无日期的
  /// 旧版 payload（习惯提醒 / snooze 通知 payload 恒为 `<id>`）。
  static String? parseHabitId(String? payload) {
    final entity = parseHabitEntity(payload);
    if (entity == null) return null;
    return habitEntityId(entity);
  }

  /// U2-2（v3.0.4 审计）：取 habit payload 的**实体部分**（去前缀）——
  /// `<id>` 或 `<id>|<dateKey>`；非习惯类通知返回 null。
  static String? parseHabitEntity(String? payload) {
    if (payload == null || !payload.startsWith(payloadHabitPrefix)) return null;
    return payload.substring(payloadHabitPrefix.length);
  }

  /// U2-2（v3.0.4 审计）：从实体部分解析习惯 id（剥离 `|<dateKey>` 后缀）。
  static String habitEntityId(String entity) {
    final i = entity.indexOf('|');
    return i == -1 ? entity : entity.substring(0, i);
  }

  /// U2-2（v3.0.4 审计）：从实体部分解析确认条展示日（dateKey；无后缀 /
  /// 空后缀 → null = 旧版 payload，调用方按「今日」宽容处理）。
  static String? habitEntityDate(String entity) {
    final i = entity.indexOf('|');
    if (i == -1) return null;
    final d = entity.substring(i + 1);
    return d.isEmpty ? null : d;
  }

  /// U2-2（v3.0.4 审计）：构造带展示日的实体部分（`<id>|<dateKey>`）。
  /// 冷启动暂存队列（_pendingHabitUndoIds）复用本格式携带日期。
  static String habitEntityWithDate(String habitId, String dateKey) =>
      '$habitId|$dateKey';

  /// U2-2（v3.0.4 审计）：确认条展示日的 dateKey（yyyy-MM-dd，与
  /// CheckIn.dateKey 同格式）。showHabitCheckedConfirm / showHabitUndoConfirm
  /// 的 payload 用它标记「这条回报属于哪一天」。
  static String habitConfirmDateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
        // P2-8：应用内兜底定时器与系统闹钟几乎同时 show 同一 id 的通知，
        // Android 对已在通知栏 alerting 的通知再次 notify 会**再响一次**（叮叮两声）。
        // onlyAlertOnce 让同一 id 的后续更新只刷新内容、不再触发响铃/震动。
        onlyAlertOnce: true,
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
  /// F11：snooze 已改用独立段位，这里一并取消，避免「任务已删除但 snooze 仍会弹」。
  Future<void> cancel(String id) {
    // S4 修复：作废该任务在途的兜底定时器（代号 +1 使其判定为过期一代）。
    _deadlineGen[id] = (_deadlineGen[id] ?? 0) + 1;
    unawaited(_plugin.cancel(_snoozeNotifyIdOf(id)));
    return _plugin.cancel(_notifyIdOf(id));
  }

  /// F11：单独取消某任务的「稍后提醒」通知（snooze 后任务被完成时调用）。
  Future<void> cancelSnooze(String id) => _plugin.cancel(_snoozeNotifyIdOf(id));

  /// 为「重复任务」调度本地提醒（setAlarmClock 模式，不被 ColorOS 等国产 ROM 拦截）。
  /// 返回 true 表示已提交。
  ///
  /// **F-2 起全部重复类型统一为「一次性闹钟 × 预挂 N 次」**，不再使用 OS 的
  /// `matchDateTimeComponents` 周期循环。原因是系统周期循环无法表达本 App 的两条
  /// 核心语义，形成三处可复现缺陷：
  /// 1) 落点不消费 [Task.skipDates]：「今天 07:00 还没到，先点『本次跳过』」重排后
  ///    落点仍是今天 07:00 → 今天照响；「今天周五跳过一次下周一」对 weekly 也无效；
  /// 2) 落点不消费 [Task.repeatUntil]：结束日到期后只要用户长期不开 App
  ///    （没有触发任何重排），系统周期闹钟会继续按天 / 周弹；
  /// 3) 与 interval / 复杂 monthly 已是两套机制，重复提醒一路两种实现、维护成本高。
  ///
  /// 现在统一走 [_nextRepeatOccurrences]：逐日前进取「未来 + 是循环日（[Task.repeatsOn]，
  /// 内含 repeatUntil 与 skipDates）+ 尚未完成（[Task.isDoneOn]，含 occurrence 级
  /// doneDates）」的落点，并按 [_kScheduleSlots] 预挂接下来的 8 次，
  /// 由 App 启动 / 回前台 / 午夜重置 / 15 分钟守护（[TaskProvider.checkDailyReset]）
  /// 持续补挂。
  ///
  /// **当天已完成 / 已跳过的这次不会响**：落在今天的 occurrence 只有当它既未完成
  /// 也未被跳过、且时刻尚未过去时才会被排上。
  Future<bool> scheduleRepeatReminder(Task task, {bool playSound = true}) async {
    if (!enabled) {
      AppLog.d('[通知] 未调度重复提醒 id=${task.id}：通知总开关关闭');
      return false;
    }
    if (!task.isRepeating || task.repeatMinute == null) {
      AppLog.d('[通知] 未调度重复提醒 id=${task.id}：非重复任务或无提醒时间');
      return false;
    }
    // F3：「结束重复」（repeatUntil）对**所有**重复类型生效。
    // 结束之日不再排任何落点，并显式取消已挂的 8 个槽位（否则旧闹钟会照旧响）。
    if (_repeatEnded(task)) {
      await cancelRepeatReminder(task.id);
      AppLog.d('[通知] 未调度重复提醒 id=${task.id}：重复已于 ${task.repeatUntil} 结束');
      return false;
    }
    try {
      final occurrences = _nextRepeatOccurrences(task);
      if (occurrences.isEmpty) {
        // 一个合法落点都没有（跳过日密集 / 已临近结束日）→ 清掉旧闹钟，宁可不响
        // 也不在错误的日期响（与 interval 的 S11 口径一致）。
        await cancelRepeatReminder(task.id);
        AppLog.d('[通知] 未调度重复提醒 id=${task.id}：近期无合法循环日');
        return false;
      }
      // 落点未变 → 系统里已挂的闹钟仍然正确，跳过重复的平台往返。
      final signature = occurrences
          .map((e) => '${e.year}-${e.month}-${e.day}T${e.hour}:${e.minute}')
          .join('|');
      if (_armedSignatures[task.id] == signature) return true;

      final playChId = playSound ? _chSound : _chSilent;
      final detail = NotificationDetails(
        android: AndroidNotificationDetails(
          playChId,
          '任务提醒',
          channelDescription: '重复任务定时提醒',
          importance: Importance.high,
          priority: Priority.high,
          playSound: playSound,
          actions: _taskActions,
          // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
          visibility: visibility,
        ),
      );
      final mode = await _scheduleMode;
      // 只取消「这次用不到」的多余槽位：落点数量变少时（新增跳过日 / 临近结束日）
      // 旧槽位必须被真正取消，否则会在过期日期照响；而仍在范围内的槽位不需要先取消
      // 再重排——同 id 的 zonedSchedule 会替换掉系统里既有的闹钟与插件缓存条目
      // （见插件 saveScheduledNotification 的去重逻辑），省下一半平台往返。
      for (var d = occurrences.length; d < _kScheduleSlots; d++) {
        await _plugin.cancel(repeatNotifyIdOf(task.id, d));
      }
      for (var i = 0; i < occurrences.length; i++) {
        await _plugin.zonedSchedule(
          repeatNotifyIdOf(task.id, i),
          task.repeatSummary,
          task.title.isNotEmpty ? task.title : '无标题任务',
          occurrences[i],
          detail,
          payload: '$payloadTaskPrefix${task.id}',
          androidScheduleMode: mode,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
      _armedSignatures[task.id] = signature;
      AppLog.d('[通知] 已调度重复提醒 id=${task.id} ${task.repeatSummary} '
          '共 ${occurrences.length} 次，首次=${occurrences.first}');
      return true;
    } catch (e, s) {
      AppLog.d('[通知] 重复提醒调度失败 id=${task.id}: $e');
      AppLog.d('$s');
      return false;
    }
  }

  /// F-2：计算重复任务接下来的 [count] 个投递时刻（已含勿扰顺延）。
  ///
  /// 逐日前进而非按周期跳：这样 [Task.repeatsOn]（repeatUntil + skipDates +
  /// 各重复类型的当日命中判定）与 [Task.isDoneOn]（occurrence 级完成历史）都能被
  /// 完整消费，`interval` / `monthly` 的各种边界也无需另写一套。
  /// 上限 400 天，既覆盖「每隔 N 天」的最大步进与密集跳过日，也杜绝死循环。
  List<tz.TZDateTime> _nextRepeatOccurrences(
    Task task, {
    int count = _kScheduleSlots,
  }) {
    final loc = _loc ?? tz.UTC;
    final nowTz = tz.TZDateTime.now(loc);
    // 全部计算在「墙钟」空间完成后再贴回 loc 时区：既让纯函数可单测，
    // 也避免设备时区 ≠ loc 时按 epoch 比较产生的错位（见 [repeatOccurrenceTimes]）。
    final nowWall = DateTime(nowTz.year, nowTz.month, nowTz.day, nowTz.hour,
        nowTz.minute, nowTz.second);
    // P3-3：内容签名（当日 + 规则字段）未变 → 复用上一轮扫描结果。
    final key = 'task:${task.id}';
    final sig = '${nowWall.year}-${nowWall.month}-${nowWall.day}'
        '|${_repeatContentSig(task)}';
    final cached = _occurrenceMemo[key];
    if (cached != null && cached.$1 == sig) {
      return cached.$2
          .map((d) =>
              tz.TZDateTime(loc, d.year, d.month, d.day, d.hour, d.minute))
          .toList();
    }
    final wall =
        repeatOccurrenceTimes(task, now: nowWall, count: count);
    if (_occurrenceMemo.length > 1024) _occurrenceMemo.clear(); // 防泄漏
    _occurrenceMemo[key] = (sig, wall);
    return wall
        .map((d) => tz.TZDateTime(loc, d.year, d.month, d.day, d.hour, d.minute))
        .toList();
  }

  /// F-2：重复任务「接下来该响的落点」的**纯计算**（墙钟语义，无时区依赖）。
  ///
  /// 与 [_nextRepeatOccurrences] 共用同一份逻辑，只是把时区与「现在」抽成参数，
  /// 供回归测试直接钉死以下契约（v2.8.4 审计报告 F-1 / F-2 的核心）：
  /// 1) 落点必须满足 [Task.repeatsOn] —— 因此 `skipDates`（本次跳过 / 提前跳过
  ///    未来某个星期）与 `repeatUntil`（结束日后不再响）都会被真正消费；
  /// 2) 落点必须不是 [Task.isDoneOn] 的那一天 —— 因此「今天已完成」与
  ///    「未来循环日被预标记完成」（F-10）都不会再响；
  /// 3) 落点必须严格晚于 [now]，不会补弹已经过去的时刻。
  ///
  /// [defer] 为勿扰顺延钩子（缺省取当前注入的 [dndDefer]），**逐落点独立施加**：
  /// 一次性闹钟不存在「把顺延后的时分写进周期分量」的漂移问题。
  ///
  /// F-11（v2.8.5 审计）：扫描窗按规则自适应——见函数体内 [scanLimit] 的说明。
  @visibleForTesting
  static List<DateTime> repeatOccurrenceTimes(
    Task task, {
    required DateTime now,
    int count = _kScheduleSlots,
    DateTime? Function(DateTime)? defer,
  }) {
    final out = <DateTime>[];
    final m = task.repeatMinute;
    if (m == null || count <= 0) return out;
    final hh = m ~/ 60;
    final mm = m % 60;
    final apply = defer ?? deferByDnd;
    var cursor = DateTime(now.year, now.month, now.day, hh, mm);
    // F-11（v2.8.5 审计）：扫描窗长度按规则自适应。固定 400 天窗在「每隔 365 天」
    // 这类大间隔任务下凑不齐 8 个预挂落点（400 / 365 ≈ 1 个），只能依赖
    // 15 分钟守护 / 启动 / 跨天重置补挂，长期不开 App 第 2 次提醒即缺失。
    // interval 时窗口下限抬到「count × 间隔 + 60 天余量」（余量留给密集
    // skipDates / repeatUntil 边界）；其余规则落点密度远高于 400 天窗
    // （daily≈8 天、weekly≈8 周、monthly≈8 个月），维持 400 不变。
    final step = task.repeat == RepeatType.interval
        ? (task.repeatInterval < 1 ? 1 : task.repeatInterval)
        : 1;
    final scanLimit = step > 1 ? (count * step + 60) : 400;
    for (var i = 0; i < scanLimit && out.length < count; i++) {
      if (cursor.isAfter(now)) {
        final day = DateTime(cursor.year, cursor.month, cursor.day);
        if (task.repeatsOn(day) && !task.isDoneOn(day)) {
          out.add(apply(cursor) ?? cursor);
        }
      }
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1, hh, mm);
    }
    if (out.length < count) {
      // 窗口内凑不满预挂槽位（临近结束日 / 跳过日密集 / 大间隔超窗），留一条
      // debug 日志便于排查「第 N 次提醒缺失」类问题；不影响正常调度。
      AppLog.d('[通知] 重复落点扫描窗（$scanLimit 天）内只找到 '
          '${out.length}/$count 个落点 id=${task.id}（临近结束日或跳过日密集）');
    }
    return out;
  }

  /// F3：重复是否已结束（[Task.repeatUntil] 严格早于今天）。
  /// 与 [Task.isRepeatEnded] 同一口径，此处独立实现以避免 service 反向依赖 Provider。
  static bool _repeatEnded(Task task) {
    final u = task.repeatUntil;
    if (u == null) return false;
    final until = DateTime.tryParse(u);
    if (until == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return today.isAfter(DateTime(until.year, until.month, until.day));
  }

  // F-9（v2.8.5 审计）：旧「逐落点递推」实现 `_nextMonthlyOccurrence` /
  // `_nextIntervalOccurrence`（约 120 行，以 `// ignore: unused_element` 压制
  // 告警的对照参考代码）已删除——v2.8.5 统一为 [repeatOccurrenceTimes] 的
  // 「扫描窗口内取前 8 个命中」后，生产路径零调用，留在生产文件里只会让后人
  // 误调用到与现实现不一致的旧路径。如需对照历史行为，git 历史中可查。

  /// 按任务 id 取消全部「重复提醒」通知。
  /// F-2 起 0..7 号槽位承载「接下来 8 次」一次性落点（不再按星期分槽），
  /// 故这里逐个取消 0..7 即可覆盖全部已挂落点；同时作废落点签名缓存，
  /// 使下一次 [scheduleRepeatReminder] 一定会重新下发。
  Future<void> cancelRepeatReminder(String id) async {
    _armedSignatures.remove(id);
    for (var d = 0; d < _kScheduleSlots; d++) {
      await _plugin.cancel(repeatNotifyIdOf(id, d));
    }
  }

  /// 习惯 id 是毫秒时间戳字符串（13 位，约 1.7e12），**不能**像任务 id 那样直接
  /// int.tryParse——通知插件要求 id 落在 int32 范围内，否则抛
  /// `Invalid argument (id): must fit within the size of a 32-bit integer`。
  /// 这里把 id 折叠到 10 万个槽位。
  ///
  /// P3-1（v2.8.6 审计）：不再依赖 [String.hashCode]——它跨 Dart 引擎版本
  /// **不保证稳定**（升级后映射漂移会让旧闹钟失去对应的 cancel 入口），且碰撞的
  /// 两个习惯会共享同一通知 id 段互相顶掉提醒。改用自实现 FNV-1a 32 位哈希：
  /// 结果跨版本 / 跨平台确定，分布质量与 hashCode 相当（习惯数量为个位数，
  /// 10 万槽位碰撞概率可忽略）。
  static int _habitSlotOf(String id) {
    var h = 0x811c9dc5; // FNV-1a offset basis
    for (final c in id.codeUnits) {
      // UTF-16 码元拆成两个 8 位输入，保持与逐字节 FNV 等价的分布。
      h ^= c & 0xff;
      h = (h * 0x01000193) & 0xffffffff;
      h ^= (c >> 8) & 0xff;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h % 100000;
  }

  /// 习惯提醒使用独立的 id 段（10 亿起 + 槽位*10 + 星期索引），与任务的
  /// 「截止提醒 / 重复提醒」区分开，避免互相 cancel 掉。dayIndex：每天提醒用 0；
  /// 按星期提醒用 1..7。最大值 1e9 + 99999*10 + 7 ≈ 1.001e9，远小于 int32 上限。
  ///
  /// S10 修复：原方案落在 80 万段，虽与一次性段（0..N）实测不冲突，但与新迁到
  /// 20 亿段的重复提醒保持清晰的大段隔离，杜绝任何远期碰撞。
  /// schedule / cancel 必须走同一函数，否则删除习惯时取消会错位。
  /// P3-1：转公开——与 [repeatNotifyIdOf] 对称，并供回归测试断言确定性。
  static int habitNotifyIdOf(String id, int dayIndex) {
    final s = _habitSlotOf(id);
    return 1000000000 + s * 10 + (dayIndex % 8);
  }

  /// 习惯提醒「稍后提醒（snooze）」的**独立** id（落点段之外的第 8 号槽位）。
  ///
  /// P2-1（v2.9.4 审计）：此前 `snoozeHabitReminder` 直接复用落点槽位 0
  /// （`habitNotifyIdOf(id, 0)`），而落点列表会在每次重排时整体位移——21:00 弹提醒
  /// → 点「稍后提醒」+10 分钟 → 15 分钟守护周期里落点签名变化，重排把 0..N 全部重挂，
  /// **同 id 覆盖掉刚排的 snooze**，用户当天再也收不到这条提醒。
  /// 这里给 snooze 独占 `s*10+8`：落点只用 0..7，下一习惯的段从 `(s+1)*10` 起，
  /// 故 8 号槽永不被落点重排覆盖（与任务侧 `[_snoozeNotifyIdOf]` 的独立段同理）。
  static int habitSnoozeNotifyIdOf(String id) {
    final s = _habitSlotOf(id);
    return 1000000000 + s * 10 + 8;
  }

  /// 习惯「打卡 / 撤销确认」通知的**独立** id（落点段之外的第 9 号槽位）。
  ///
  /// 新P3-6（v2.9.7 审计）：确认通知此前固定用落点槽 0（`habitNotifyIdOf(id, 0)`），
  /// 而 [scheduleHabitReminder] 每次重排都会 cancel + 重挂 0..7——15 分钟守护
  /// 周期内一旦重排，带「撤销」按钮的确认通知就被同 id 覆盖，撤销入口从通知栏
  /// 消失。改占 9 号槽（落点只用 0..7、snooze 占 8，下一习惯的段从 `(s+1)*10`
  /// 起）：永不被落点重排覆盖。打卡确认与撤销确认**共用**本 id——同一时刻
  /// 只应有一条最新回报，互相覆盖即覆盖式更新语义。
  static int habitConfirmNotifyIdOf(String id) {
    final s = _habitSlotOf(id);
    return 1000000000 + s * 10 + 9;
  }

  /// 为习惯调度每日打卡提醒（setAlarmClock 模式，不被 ColorOS 等国产 ROM 拦截）。
  /// [checkedToday] 为 true 则跳过今日这一次，挂到下一个循环日，
  /// 避免「已完成仍弹提醒」。返回 true 表示已提交。
  ///
  /// P2-1（v2.9.3 审计）：参数语义自本轮起统一为「今天是否已**达标**」
  /// （量化习惯当日累计量 ≥ [Habit.dailyTarget]；布尔习惯等价于已打卡）。
  /// 调用方（HabitProvider 五个调度点）已全部切换，通知侧跳过逻辑不变——
  /// 量化习惯「做了 1/8」不再吞掉当天提醒。
  ///
  /// F-2 / F-3：与 [scheduleRepeatReminder] 统一为「一次性闹钟 × 预挂 N 次」，
  /// 并逐落点过一次勿扰顺延。此前习惯用 OS 周期闹钟（`DateTimeComponents.time` /
  /// `dayOfWeekAndTime`），勿扰顺延根本没接入（F-3：用户设了 23:00–08:00 勿扰，
  /// 「每天 7:00 起床打卡」照常在勿扰窗口内响，且每天复现）；而不接入的原因正是
  /// 顺延会把「顺延后的时分 / 星期」写进周期分量，导致后续每天漂移
  /// （周习惯 23:30 顺延到次日 08:05 时，星期分量都会跑偏）。
  /// 改成一次性落点后，每个落点各自独立顺延，语义与一次性提醒完全一致。
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
      final occurrences = _nextHabitOccurrences(habit, checkedToday: checkedToday);
      if (occurrences.isEmpty) {
        // 一个合法落点都没有（理论不可达：reminderMinute 已非空）→ 清掉已挂闹钟，
        // 避免残留旧槽位在错误日期继续响。
        await cancelHabitReminder(habit.id);
        AppLog.d('[通知] 未调度习惯提醒 id=${habit.id}：近期无合法打卡日');
        return false;
      }
      final signature = occurrences
          .map((e) => '${e.year}-${e.month}-${e.day}T${e.hour}:${e.minute}')
          .join('|');
      if (_armedSignatures['habit:${habit.id}'] == signature) return true;

      final mode = await _scheduleMode;
      final body = '${habit.emoji} ${habit.title} · 该打卡啦';
      final detail = NotificationDetails(
        android: AndroidNotificationDetails(
          _chHabit, // P3-13：习惯类独立渠道，用户可在系统设置里单独关闭
          '习惯提醒',
          channelDescription: '每日习惯打卡提醒',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          // P2-1（v2.9.4 审计）：与 snooze 落点共用同一组 action（单一真源）。
          // U2-4（v2.9.6 审计）：量化习惯标签改「记 1 个」。
          actions: habitActionsFor(habit),
          // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
          visibility: visibility,
        ),
      );
      // 只取消「这次用不到」的多余槽位（同 [scheduleRepeatReminder] 的理由）。
      for (var d = occurrences.length; d < _kScheduleSlots; d++) {
        await _plugin.cancel(habitNotifyIdOf(habit.id, d));
      }
      for (var i = 0; i < occurrences.length; i++) {
        await _plugin.zonedSchedule(
          habitNotifyIdOf(habit.id, i),
          '习惯打卡',
          body,
          occurrences[i],
          detail,
          payload: '$payloadHabitPrefix${habit.id}',
          androidScheduleMode: mode,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
      _armedSignatures['habit:${habit.id}'] = signature;
      AppLog.d('[通知] 已调度习惯提醒 id=${habit.id} '
          '共 ${occurrences.length} 次，首次=${occurrences.first}');
      return true;
    } catch (e, s) {
      AppLog.d('[通知] 习惯提醒调度失败 id=${habit.id}: $e');
      AppLog.d('$s');
      return false;
    }
  }

  /// F-2：计算习惯接下来的 [count] 个投递时刻（已含勿扰顺延与「今天已打卡」跳过）。
  /// [Habit.weekdays] 为空表示每天；非空表示按 1..7（周一..周日）筛选。
  List<tz.TZDateTime> _nextHabitOccurrences(
    Habit habit, {
    bool checkedToday = false,
    int count = _kScheduleSlots,
  }) {
    final loc = _loc ?? tz.UTC;
    final nowTz = tz.TZDateTime.now(loc);
    final nowWall = DateTime(nowTz.year, nowTz.month, nowTz.day, nowTz.hour,
        nowTz.minute, nowTz.second);
    // P3-3：与任务重复落点同思路的内容缓存（当日 + 打卡态 + 规则字段）。
    // 打卡 / 取消打卡会改变 checkedToday → 签名变化 → 重算，不会缓存到旧态。
    final key = 'habit:${habit.id}';
    final sig = [
      nowWall.year, nowWall.month, nowWall.day, checkedToday,
      habit.reminderMinute, habit.weekdays.join(','), habit.archived,
    ].join('|');
    final cached = _occurrenceMemo[key];
    if (cached != null && cached.$1 == sig) {
      return cached.$2
          .map((d) =>
              tz.TZDateTime(loc, d.year, d.month, d.day, d.hour, d.minute))
          .toList();
    }
    final wall = habitOccurrenceTimes(habit,
        now: nowWall, checkedToday: checkedToday, count: count);
    if (_occurrenceMemo.length > 1024) _occurrenceMemo.clear(); // 防泄漏
    _occurrenceMemo[key] = (sig, wall);
    return wall
        .map((d) => tz.TZDateTime(loc, d.year, d.month, d.day, d.hour, d.minute))
        .toList();
  }

  /// F-2：习惯打卡提醒落点的**纯计算**（与 [repeatOccurrenceTimes] 同思路，
  /// 墙钟语义、可单测）。[checkedToday] 为 true 时跳过今天这一次。
  @visibleForTesting
  static List<DateTime> habitOccurrenceTimes(
    Habit habit, {
    required DateTime now,
    bool checkedToday = false,
    int count = _kScheduleSlots,
    DateTime? Function(DateTime)? defer,
  }) {
    final out = <DateTime>[];
    final m = habit.reminderMinute;
    if (m == null || count <= 0) return out;
    final hh = m ~/ 60;
    final mm = m % 60;
    final weekdays = habit.weekdays.where((d) => d >= 1 && d <= 7).toSet();
    final apply = defer ?? deferByDnd;
    final today = DateTime(now.year, now.month, now.day);
    var cursor = DateTime(now.year, now.month, now.day, hh, mm);
    for (var i = 0; i < 400 && out.length < count; i++) {
      final day = DateTime(cursor.year, cursor.month, cursor.day);
      final weekdayHit = weekdays.isEmpty || weekdays.contains(cursor.weekday);
      final isToday = _sameDay(day, today);
      if (cursor.isAfter(now) && weekdayHit && !(checkedToday && isToday)) {
        out.add(apply(cursor) ?? cursor);
      }
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1, hh, mm);
    }
    return out;
  }

  /// 取消某习惯的全部每日提醒通知（F-2 起 0..7 号槽位承载「接下来 8 次」）。
  /// 取消失败（插件未初始化 / 平台不支持）不应阻断删除习惯等主流程，故整体吞异常。
  Future<void> cancelHabitReminder(String id) async {
    _armedSignatures.remove('habit:$id');
    try {
      for (var d = 0; d < _kScheduleSlots; d++) {
        await _plugin.cancel(habitNotifyIdOf(id, d));
      }
      // P2-1（v2.9.4 审计）：snooze 占用独立的 8 号槽，删习惯 / 重排时一并清掉，
      // 否则会留下一个「点进去找不到的习惯」的稍后提醒。
      await _plugin.cancel(habitSnoozeNotifyIdOf(id));
      // P3-4（v3.0.1 审计）：打卡 / 撤销确认通知占用独立的 9 号槽
      // （[habitConfirmNotifyIdOf]），此前从未被任何取消路径覆盖——删除 /
      // 归档习惯后，通知栏里指向已不存在习惯的「已打卡 ✓ / 撤销」确认条
      // 会永久残留。一并清掉。
      await _plugin.cancel(habitConfirmNotifyIdOf(id));
    } catch (e) {
      AppLog.d('[通知] 取消习惯提醒失败 id=$id: $e');
    }
  }

  /// P2-7（v2.9.5 审计）：**只**清掉某习惯挂起的「稍后提醒」（8 号槽）。
  ///
  /// 复现：21:00 弹习惯提醒 → 点「稍后提醒」（+10 分钟）→ 21:05 在 App 里记满
  /// 8/8 达标 → 21:10 仍弹出「该打卡啦」（只有点通知里的「打卡」才会早退）。
  /// 也就是说**已做完仍被打扰**，且与任务侧不对称：任务侧的稍后提醒会随
  /// 「完成」被撤掉，习惯侧此前完全没有反向动作。
  ///
  /// 这里刻意**不**复用 [cancelHabitReminder]：那会把 0..7 号落点全部取消，
  /// 而 [HabitProvider.setCheckInValue] 紧接着还会按「已达标 → 跳过今天」重排，
  /// 两者叠加会让每次打卡都白白做一次「全取消 + 全重挂」的平台往返抖动。
  /// 只清 8 号槽即可让「稍后提醒」失效，落点由重排逻辑自己接管。
  Future<void> cancelHabitSnooze(String id) async {
    try {
      await _plugin.cancel(habitSnoozeNotifyIdOf(id));
    } catch (e) {
      AppLog.d('[通知] 取消习惯稍后提醒失败 id=$id: $e');
    }
  }

  /// P3-3（v3.0.2 审计）：**只**清掉某习惯的 9 号槽确认通知（「已打卡 ✓ / 撤销」）。
  ///
  /// 复现：通知提醒点「打卡」→ 9 号槽确认条「已打卡 ✓ / 撤销」→ 在 App 内
  /// 取消打卡（当日值降 0）→ 确认条仍显示「已打卡 ✓」且带可点的「撤销」；
  /// 用户之后再次打卡后点旧确认条的「撤销」，会再把刚打的卡退掉。P3-4
  /// （v3.0.1 审计）只在删除 / 归档路径清了 9 号槽（[cancelHabitReminder]），
  /// App 内撤卡路径漏掉——本轮补齐。与 [cancelHabitSnooze] 同款「只清指定
  /// 槽位」的最小取消：0..8 号落点由重排逻辑自己接管，不做全清全挂的
  /// 平台往返抖动。
  Future<void> cancelHabitConfirm(String id) async {
    try {
      await _plugin.cancel(habitConfirmNotifyIdOf(id));
    } catch (e) {
      AppLog.d('[通知] 取消习惯确认通知失败 id=$id: $e');
    }
  }

  /// 稍后提醒（snooze）：在 [delay] 后重新弹出该任务提醒。
  ///
  /// F11：使用独立的 [_snoozeNotifyIdOf] 段位，不再复用一次性「截止提醒」的
  /// [_notifyIdOf]——否则在重复提醒上点「稍后提醒」会覆盖掉同任务未来的截止闹钟。
  /// P2-6'：落点过一次勿扰顺延，并补回「稍后提醒 / 完成」两个 action 按钮，
  /// 使 snooze 后的通知仍可二次 snooze、仍可在通知栏直接完成。
  Future<bool> snoozeTaskReminder(Task task,
      {Duration delay = const Duration(minutes: 10), bool playSound = true}) async {
    // P2-2（v3.0.3 审计）：完成态守卫——已完成 / 重复已结束的任务不再排
    // 「稍后提醒」。对照（全部已有清理）：非重复任务完成 `cancel(id)` 顺带撤
    // snooze 段（F11）；重复任务完成族自 v3.0.3 起经
    // TaskProvider._rescheduleRepeatOnCompletion「先撤后挂」收口；习惯达标侧
    // 有 cancelHabitSnooze（P2-7 v2.9.5）+ main._doSnooze 达标守卫（v3.0.3）。
    // 此处防的是**历史残留通知 / 在途展示**被点的场景（报告场景 C：昨天/更早
    // 的提醒挂在通知栏，任务此刻已完成或重复已结束）。守卫置于 enabled 之前，
    // 与 habit 侧「archived 先于 enabled」同序。
    if (task.done || task.repeatEnded) {
      AppLog.d('[通知] 未 snooze id=${task.id}：'
          '${task.done ? '任务已完成' : '重复已结束'}，不排「稍后提醒」');
      return false;
    }
    if (!enabled) {
      AppLog.d('[通知] 未 snooze id=${task.id}：通知总开关关闭');
      return false;
    }
    final loc = _loc ?? tz.UTC;
    var when = tz.TZDateTime.now(loc).add(delay);
    // P2-6'：snooze 落点同样感知勿扰（此前只有一次性截止提醒会顺延，
    // 勿扰内点「稍后提醒」照弹，与用户对勿扰的预期矛盾）。
    if (dndDefer != null) {
      final deferred = dndDefer!(when);
      if (deferred != null) {
        when = tz.TZDateTime(loc, deferred.year, deferred.month, deferred.day,
            deferred.hour, deferred.minute);
      }
    }
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
        // P2-6'：补回 action 按钮，让 snooze 后的通知也能继续 snooze / 直接完成。
        actions: _taskActions,
        // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
        visibility: visibility,
      ),
    );
    try {
      await _plugin.zonedSchedule(
        _snoozeNotifyIdOf(task.id),
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

  /// 习惯提醒的稍后提醒：在 [delay] 后重新弹出该习惯的打卡提醒。
  ///
  /// P2-1（v2.9.4 审计）三处收口，与任务侧 `snoozeTaskReminder` 对齐：
  /// 1. **独立 id 段**（[habitSnoozeNotifyIdOf] 的 8 号槽）——此前复用落点槽位 0，
  ///    会被下一轮守护周期的落点重排同 id 覆盖，提醒当天静默丢失；
  /// 2. **勿扰顺延**（消费 [dndDefer]）——勿扰时段内点「稍后提醒」不该照弹；
  /// 3. **补回 action 按钮**（稍后提醒 / 打卡）——snooze 后仍可二次顺延或直接打卡。
  Future<bool> snoozeHabitReminder(Habit habit,
      {Duration delay = const Duration(minutes: 10)}) async {
    // P3-2（v3.0.2 审计）：已归档习惯不再排「稍后提醒」（归档语义 = 退场，
    // 与 _doHabitCheckIn 的归档守卫同口径；防的是系统延迟投递的在途旧闹钟）。
    // 「今日已达标」守卫需要 HabitProvider 的当日打卡数据（通知层不持有
    // provider，不做反向依赖），由唯一调用点 main._doSnooze 把关并如实回报。
    if (habit.archived) {
      AppLog.d('[通知] 未 snooze 习惯 id=${habit.id}：已归档');
      return false;
    }
    if (!enabled) {
      AppLog.d('[通知] 未 snooze 习惯 id=${habit.id}：通知总开关关闭');
      return false;
    }
    final loc = _loc ?? tz.UTC;
    var when = tz.TZDateTime.now(loc).add(delay);
    // P2-1：与任务 snooze 同款——落点过一次勿扰顺延。
    if (dndDefer != null) {
      final deferred = dndDefer!(when);
      if (deferred != null) {
        when = tz.TZDateTime(loc, deferred.year, deferred.month, deferred.day,
            deferred.hour, deferred.minute);
      }
    }
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        _chHabit, // P3-13：与正式打卡落点同渠道（snooze 后仍归「习惯提醒」名下）
        '习惯提醒',
        channelDescription: '每日习惯打卡提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        // P2-1：snooze 后的通知补回两个 action，使它仍可二次顺延 / 直接打卡。
        // U2-4（v2.9.6 审计）：量化习惯标签改「记 1 个」。
        actions: habitActionsFor(habit),
        // L-06：锁屏隐藏通知正文（任务标题属敏感内容）。
        visibility: visibility,
      ),
    );
    try {
      await _plugin.zonedSchedule(
        habitSnoozeNotifyIdOf(habit.id),
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

  /// 清空所有已调度的通知（关闭总开关 / 恢复备份 / 方案升级时调用）。
  /// F-2：同时作废「已挂落点」签名缓存——系统里的闹钟已被清空，
  /// 若缓存还在，下一次重排会因「签名未变」而跳过，提醒就真丢了。
  Future<void> cancelAll() {
    _deadlineGen.clear();
    _invalidateArmedCache();
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
  ///
  /// F-07 修复：此前以 `matchDateTimeComponents=time` 让系统每天重复，而 title/body
  /// 是**排程那一刻烘焙**的（系统闹钟到点时 App 未必在内存、没机会重算）。用户连续
  /// 几天不打开 App 时，第二天起每天弹出的其实是「排程那天」的旧数据——
  /// 「今日完成任务 0 个」会连着念好几天。现改为**一次性闹钟**：只投递下一班，
  /// 内容必然对应投递日；下一次的简报由「启动 / 回到前台 / 数据变动」的重排重建
  /// （`rescheduleBriefings` 已挂在这些时机上）。代价是长期不开 App 时不再连续推送，
  /// 但「不推」永远优于「推错的口径」。
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
      var when = nextBriefingTime(hour, minute);
      // P2-7：简报此前完全不感知勿扰，而默认勿扰 22:00-07:00 恰好覆盖晚报整点
      // （22:00）与晨报常用时刻——用户开了勿扰仍被简报吵醒。现与其它定时通知统一。
      if (dndDefer != null) {
        final deferred = dndDefer!(when);
        if (deferred != null) {
          when = tz.TZDateTime.from(deferred, _loc ?? tz.UTC);
        }
      }
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
        // F-07：不再让系统按天重复（旧文案会连日重发），改为一次性投递下一班。
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

  /// P3-4：计算「习惯挽留」下一次**实际投递时刻**（已含跨天顺延与勿扰顺延）。
  ///
  /// 抽成静态纯函数的目的：挽留文案在**排程时**烘焙（系统闹钟到点时 App 未必在内存），
  /// 若顺延跨越了午夜（如 23:00 的落点撞进勿扰区间被推到次日 07:05），文案里的
  /// 「今天」在送达时就变成了谎言。文案层用本函数预知投递日，据此把「今天」改写成
  /// 明确日期；调度层复用同一函数，两处口径不会各算一遍而漂移。
  ///
  /// 实现口径：全程只做**墙钟字段**运算（与 [from] 同一时区视角），不跨时区换算。
  /// 这与原实现 `TZDateTime(loc, ...)` 的判定逐点等价（原本比较的也是同一天里的同一份
  /// 墙钟字段），但不会把「某时区的墙钟字段」误当成「设备本地时刻」而引入漂移。
  /// 返回值 = 目标投递时刻的墙钟字段，调度层照旧用 `TZDateTime(loc, ...)` 组装。
  ///
  /// [from] 便于单测注入固定时刻；默认取当前本地时间。
  static DateTime nextHabitNudgeTime(int nudgeMinute, {DateTime? from}) {
    final now = from ?? DateTime.now();
    // F4：时刻可配置（自 00:00 起的分钟数，默认 23:00），不再硬编码。
    final hh = nudgeMinute ~/ 60;
    final mm = nudgeMinute % 60;
    // 今天这个时刻已过就顺延到明天——与简报同一套路，避免排一个过去的时间点。
    var when = DateTime(now.year, now.month, now.day, hh, mm);
    final nowMinutes = now.hour * 60 + now.minute;
    if (nowMinutes >= nudgeMinute) when = when.add(const Duration(days: 1));
    // F4：排程前感知勿扰区间——若落点恰在勿扰时段内，按既有 dndDefer 顺延，
    // 避免挽留撞进勿扰被静默吞掉。
    final defer = dndDefer;
    if (defer != null) {
      final deferred = defer(when);
      if (deferred != null) when = deferred;
    }
    return when;
  }

  /// P1-7：调度「习惯漏卡挽留」通知——在下一个 [HabitNudge.nudgeMinute]（23:00）
  /// 触发一条本地通知（setAlarmClock 模式，不被 ColorOS 等国产 ROM 拦截）。
  /// F-07：改为**一次性**投递（不再按天重复），理由与 [scheduleBriefing] 相同——
  /// 「今天漏了哪几个习惯」是当天口径，系统按天重发会把过期名单反复推给用户。
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
      final now = tz.TZDateTime.now(loc);
      // P3-4：时刻口径统一走 [nextHabitNudgeTime]（跨天顺延 + 勿扰顺延），
      // 让文案层能用同一个函数预知投递日，两处不会各算一遍而漂移。
      final target = nextHabitNudgeTime(nudgeMinute, from: now);
      final when = tz.TZDateTime(
          loc, target.year, target.month, target.day, target.hour, target.minute);
      final mode = await _scheduleMode;
      final detail = NotificationDetails(
        android: AndroidNotificationDetails(
          _chHabit, // P3-13：漏卡挽留同属习惯，独立渠道
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
        // F-07：同简报——不再按天重复（漏卡名单会过期），只投递今晚这一班；
        // 次日的挽留由启动 / 回前台 / 打卡变动时的 rescheduleHabitNudge 重建。
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
      var when = tz.TZDateTime(loc, now.year, now.month, now.day + 1);
      // P2-7：回收站过期预告固定排 00:00，正好落在默认勿扰 22:00-07:00 内，
      // 此前完全不感知勿扰。现与简报 / 习惯挽留统一走 dndDefer 顺延。
      if (dndDefer != null) {
        final deferred = dndDefer!(when);
        if (deferred != null) {
          when = tz.TZDateTime(loc, deferred.year, deferred.month, deferred.day,
              deferred.hour, deferred.minute);
        }
      }
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
  /// 「已完成 ✓」，既不刷屏、也不叠加新通知。
  ///
  /// P3-22（v2.9.9 审计）：补「撤销」action + task: 前缀 payload——撤销处理端
  /// 靠 payload 解析任务 id（与习惯侧 U2-4 同构）。缺 payload 的 action 点击
  /// 会因解析失败被静默丢弃（习惯侧确认通知曾因漏 payload 有同款死按钮，
  /// 本轮一并补上）。
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
        // P3-22：通知完成的 10 秒窗口外仍可反悔——确认通知常驻「撤销」按钮。
        // U3-5 / P3-18（v3.0.0 审计）：`showsUserInterface: true`——点按 action
        // 先拉起 App 前台再走 Flutter 端回调。旧实现不带该标记，App 被杀死后
        // 点按是「死键」（后台隔离区无回调、无任何反馈）；拉起前台后即使快照
        // 已随进程丢失，也会由 [_doTaskUndo] 的失效分支回「撤销已失效」提示。
        actions: [
          AndroidNotificationAction(
            taskUndoActionId,
            '撤销',
            showsUserInterface: true,
          ),
        ],
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
        payload: '$payloadTaskPrefix$taskId',
      );
    } catch (e) {
      AppLog.d('[通知] 完成确认通知失败 id=$taskId: $e');
    }
  }

  /// P3-22（v2.9.9 审计）：通知「撤销」action 后的覆盖式确认——回滚成功后在
  /// 原通知位回「已撤销完成」，不再谎报任何完成态。不挂新 action（撤销后如需
  /// 重新完成，进 App 点勾选即可）。
  Future<void> showTaskUndoConfirm(String taskId, String title) async {
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
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        _notifyIdOf(taskId),
        '已撤销完成',
        title.isNotEmpty ? title : '无标题任务',
        detail,
        payload: '$payloadTaskPrefix$taskId',
      );
    } catch (e) {
      AppLog.d('[通知] 任务撤销确认通知失败 id=$taskId: $e');
    }
  }

  /// U2-4 / P3-18（v3.0.0 审计）：通知「撤销」不可执行时的**如实反馈**——
  /// 快照是进程内内存，杀进程/重启后丢失，旧实现静默早退（点按无任何反应，
  /// 通知仍显示「已完成 ✓」）。现在在原通知位覆盖一条失效提示，绝不谎报。
  Future<void> showTaskUndoInvalid(String taskId) async {
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
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        _notifyIdOf(taskId),
        '撤销已失效',
        '应用重启后撤销窗口已过期，请打开应用查看任务状态',
        detail,
        payload: '$payloadTaskPrefix$taskId',
      );
    } catch (e) {
      AppLog.d('[通知] 撤销失效提示通知失败 id=$taskId: $e');
    }
  }

  /// P3-1（v3.0.6 审计）：通知「撤销」**落盘失败但内存撤销已生效**时的如实
  /// 回执。旧实现此分支只记日志：通知栏仍显示「已完成 ✓」、点按后条目毫无
  /// 变化，用户不知道回滚到底发生没有；且快照已被 remove，再点「撤销」只会
  /// 得到「撤销已失效」——把实际已生效的内存撤销误报为失效（与 _doComplete
  /// 失败分支保留快照的口径自相矛盾）。现在 main._doTaskUndo 已归还快照，
  /// 本提示挂同款「撤销」action（重试语义）供直接再点一次：
  /// [TaskProvider.restoreTaskSnapshotPersisted] 的 identical 分支会真正
  /// 重试落盘。文案与「已撤销完成」「撤销已失效」都不同，三分支各表其事。
  Future<void> showTaskUndoNotSaved(String taskId, String title) async {
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
        // 与 showCompletedConfirm 同款 action：快照已归还，重试即再次撤销。
        actions: [
          AndroidNotificationAction(
            taskUndoActionId,
            '重试',
            showsUserInterface: true,
          ),
        ],
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        _notifyIdOf(taskId),
        '撤销未保存',
        '${title.isNotEmpty ? title : '无标题任务'} · 已在应用内撤销，但保存失败，请重试',
        detail,
        payload: '$payloadTaskPrefix$taskId',
      );
    } catch (e) {
      AppLog.d('[通知] 撤销未保存提示通知失败 id=$taskId: $e');
    }
  }

  /// U3：通知「打卡」action 后的覆盖式确认通知：用习惯提醒 id 段位（日 0）弹出
  /// 「已打卡 ✓」，不刷屏不叠加。payload 置空避免点开跳转。
  /// 习惯打卡确认通知（覆盖式，同 id 不刷屏）。
  ///
  /// P2-2（v2.9.3 审计）：量化习惯此前只可能回报「已打卡 ✓」——哪怕当天目标 8 杯
  /// 只记了 1 杯也在撒谎。现在调用方可传入 [value] / [target]（当日累计量 / 目标量），
  /// 未达标时标题改为「已记 x/y」，正文补充「未达标」，不再误报完成。
  /// 不传参数（布尔习惯 / 已达标路径）维持原「已打卡 ✓」文案。
  Future<void> showHabitCheckedConfirm(
    Habit habit, {
    int? value,
    int? target,
    // P3-7（v2.9.5 审计）：休息日分支。调用方（通知 action）发现今天不是计划的
    // 打卡日、**没有写入任何记录**，此时若沿用默认分支会显示「已打卡 ✓」——
    // 谎报。改为如实说明「今天不打卡」。
    bool restDay = false,
  }) async {
    if (!enabled) return;
    final String title;
    final String body;
    if (restDay) {
      title = '今天不打卡';
      body = '${habit.emoji} ${habit.title} · 今天不在计划的打卡日';
    } else {
      // 达标判定：无参数（布尔习惯路径）视为已打卡；有参数则严格按 value >= target
      // ——哪怕 value<=0 的异常态也如实显示「已记 0/x」，不再谎报「已打卡 ✓」。
      final met = value == null || target == null || value >= target;
      title = met ? '已打卡 ✓' : '已记 $value/$target';
      body = met
          ? '${habit.emoji} ${habit.title}'
          : '${habit.emoji} ${habit.title} · 未达标，继续加油';
    }
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        _chHabit, // P3-13：确认通知同属习惯类，归「习惯提醒」渠道
        '习惯提醒',
        channelDescription: '每日习惯打卡提醒',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        autoCancel: true,
        // U2-4（v2.9.6 审计）：补「撤销」action——通知打卡写入后此前只能进 App
        // 纠正。休息日分支没有写入任何记录，不挂撤销。
        actions: restDay
            ? null
            : [AndroidNotificationAction(habitUndoActionId, '撤销')],
        visibility: visibility,
      ),
    );
    try {
      // U3-5（v2.9.6 审计）→ 新P3-6/P3-7（v2.9.7 审计）：确认通知改用**独立 9 号
      // 槽**（[habitConfirmNotifyIdOf]）。旧注释曾声称「打卡写入已撤掉 snooze，
      // 并存窗口趋近于零」——该结论与 P2-6（v2.9.6 审计）落地的判据矛盾：
      // `setCheckInValue` 仅在「写入的是今天且今天达标」时才撤 snooze，故
      // ① 休息日分支不写入 → 不撤；② 量化习惯从 snooze 点「记 1 个」未达标
      // （如 3/8 → 4/8）→ 不撤。此场景下 snooze（8 号槽）与确认（9 号槽）
      // 确会并存，属如实语义：8 号槽仍带「记 1 个」可继续累计，确认条是
      // 最新一次操作的回报。原「0 号槽会被重排顶掉」的缺陷随独立槽位一并消除。
      await _plugin.show(
        habitConfirmNotifyIdOf(habit.id),
        title,
        body,
        detail,
        // P3-22（v2.9.9 审计）顺手修：确认通知挂着「撤销」action 却不带 payload
        // ——action 点击回传 payload 为空，parseHabitId 解析失败、撤销分支永远
        // 不可达（U2-4 落地时的同型漏配）。补上 habit: 前缀 payload 打通。
        // U2-2（v3.0.4 审计）：payload 追加展示日（`<id>|<dateKey>`）——跨天
        // 残留的确认条被点「撤销」时，处理端校验日期不符即拒绝错日写入。
        payload:
            '$payloadHabitPrefix${habitEntityWithDate(habit.id, habitConfirmDateKey(DateTime.now()))}',
      );
    } catch (e) {
      AppLog.d('[通知] 习惯打卡确认通知失败 id=${habit.id}: $e');
    }
  }

  /// U2-4（v2.9.6 审计）：通知「撤销」action 后的覆盖式确认。
  ///
  /// 新U2-2（v2.9.7 审计）：撤销语义由「清零」改为「-1」（与「打卡 = +1」
  /// 对称），确认文案不再谎称「记录已清空」——按回退后的真实进度回报
  /// 「今日 x/y」（量化）或「已取消今日打卡」（布尔归零）。
  /// 新P3-6（v2.9.7 审计）：同 [showHabitCheckedConfirm] 改用独立 9 号槽。
  Future<void> showHabitUndoConfirm(
    Habit habit, {
    int? value,
    int? target,
  }) async {
    if (!enabled) return;
    final String body;
    if (habit.isQuantified && value != null && target != null) {
      body = value >= target
          ? '${habit.emoji} ${habit.title} · 今日 $value/$target（仍达标）'
          : '${habit.emoji} ${habit.title} · 今日 $value/$target';
    } else if (value != null && value > 0) {
      body = '${habit.emoji} ${habit.title} · 今日记录已回退';
    } else {
      body = '${habit.emoji} ${habit.title} · 已取消今日打卡';
    }
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        _chHabit,
        '习惯提醒',
        channelDescription: '每日习惯打卡提醒',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        autoCancel: true,
        // 撤销后允许直接重新打卡（回到「记 1 个 / 打卡」）。
        actions: habitActionsFor(habit),
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        habitConfirmNotifyIdOf(habit.id),
        '已撤销 1 次打卡',
        body,
        detail,
        // U2-2（v3.0.4 审计）：payload 追加展示日（同 showHabitCheckedConfirm）。
        payload:
            '$payloadHabitPrefix${habitEntityWithDate(habit.id, habitConfirmDateKey(DateTime.now()))}',
      );
    } catch (e) {
      AppLog.d('[通知] 习惯撤销确认通知失败 id=${habit.id}: $e');
    }
  }

  /// U2-2（v3.0.4 审计）：确认条「撤销」action 的日期校验失败回执——payload
  /// 携带的展示日不是今天（跨天残留 / 重启后旧条），拒绝错日写入并**如实提示**
  /// 而非静默早退（旧实现「点了没用」）。同 9 号槽覆盖式刷新，内容过期的旧
  /// 确认条一并被本提示覆盖。
  ///
  /// U3-2（v3.0.5 审计）：[dateKey] 为 payload 携带的展示日（`yyyy-MM-dd`），
  /// 文案按实际日期回显——旧实现写死「昨天」，在 P3-1（v3.0.5 审计）描述的
  /// 冷启动残留场景下该条可能已是 3 天前的，文案失实；解析失败 / 缺省时退回
  /// 「之前」的中性表述。
  Future<void> showHabitConfirmExpired(String habitId, {String? dateKey}) async {
    if (!enabled) return;
    final shown = _formatDateKeyCn(dateKey);
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        _chHabit,
        '习惯提醒',
        channelDescription: '每日习惯打卡提醒',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        autoCancel: true,
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        habitConfirmNotifyIdOf(habitId),
        '该确认已过期',
        shown != null
            ? '这是 $shown 的打卡确认，撤销操作请在应用内进行'
            : '这是之前的打卡确认，撤销操作请在应用内进行',
        detail,
        payload: '$payloadHabitPrefix$habitId',
      );
    } catch (e) {
      AppLog.d('[通知] 确认过期提示通知失败 id=$habitId: $e');
    }
  }

  /// `yyyy-MM-dd` → 「M月d日」（U3-2，v3.0.5 审计：过期确认文案回显实际日期）。
  /// 非 `yyyy-MM-dd` 形态（旧 payload / 异常值）返回 null，由调用方退回中性文案。
  static String? _formatDateKeyCn(String? dateKey) {
    if (dateKey == null) return null;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(dateKey);
    if (m == null) return null;
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    return '$month月$day日';
  }

  /// U3-1（v3.0.5 审计）：习惯**已删除 / 已归档**时「打卡 / 撤销」action 的
  /// 覆盖式回执。正常路径删除 / 归档时已撤全部提醒，此防系统延迟投递的**在途
  /// 旧闹钟**（P2-3，v3.0.1 审计自述的防御场景）仍带着 action 落地被点——
  /// 旧实现静默 return，通知随 action 消散，「点了没用」正是 U3-1 口径要消灭
  /// 的体验（与 _doSnooze 已删分支的覆盖式回执同构）。同 9 号槽覆盖，残留的
  /// 旧确认条一并被本提示覆盖。
  Future<void> showHabitEndedConfirm(String habitId) async {
    if (!enabled) return;
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        _chHabit,
        '习惯提醒',
        channelDescription: '每日习惯打卡提醒',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        autoCancel: true,
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        habitConfirmNotifyIdOf(habitId),
        '习惯已结束',
        '该习惯已删除或已归档，不再记录打卡',
        detail,
        payload: '$payloadHabitPrefix$habitId',
      );
    } catch (e) {
      AppLog.d('[通知] 习惯已结束提示通知失败 id=$habitId: $e');
    }
  }

  /// U3-2（v3.0.6 审计）：习惯「撤销」action 今天**无记录可撤**时的覆盖式
  /// 回执。旧实现 `current <= 0` 静默早退（点了毫无反应），与打卡侧休息日
  /// 回执（[showHabitCheckedConfirm] 的 restDay: true「今天不打卡」）不对称。
  /// v2.9.7 P3-6「无写入即无回报」的本意是「不谎报已撤销」，而非「点了
  /// 没反应」——U3-1（v3.0.5 审计）已确立「通知 action 不可静默」，此处
  /// 补齐同口径。落 9 号槽覆盖；不挂撤销 action（无记录可撤）。
  Future<void> showHabitUndoNoRecordConfirm(String habitId) async {
    if (!enabled) return;
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        _chHabit,
        '习惯提醒',
        channelDescription: '每日习惯提醒',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        autoCancel: true,
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        habitConfirmNotifyIdOf(habitId),
        '今天没有可撤销的记录',
        '该习惯今日暂无打卡记录，无需撤销',
        detail,
        payload: '$payloadHabitPrefix$habitId',
      );
    } catch (e) {
      AppLog.d('[通知] 无记录可撤提示通知失败 id=$habitId: $e');
    }
  }

  /// U3-1（v3.0.4 审计）：「稍后提醒」action 不可执行时的**如实反馈**——
  /// 实体已删除 / 重复已结束 / 服务层守卫早退（返回 false）时，旧实现在
  /// 通知场景下静默 return，用户点「10 分钟后提醒」毫无反应。通知 action
  /// 无法弹 SnackBar，覆盖式确认条是通知场景唯一可用的反馈形态（本仓 U 系
  /// 多轮确立的口径）。
  ///
  /// [id] 为原始实体 id：任务侧挂任务段（[_notifyIdOf]），习惯侧挂 9 号槽
  /// （[habitConfirmNotifyIdOf]）——两段位互不重叠，已删实体也不冲突。
  /// [title] 可选（实体仍在时带标题）；已删实体缺省通用文案。
  ///
  /// U3-2（v3.0.5 审计）：[rescheduleFailed] 区分失败原因——「不会再响」只在
  /// 实体已删 / 重复已结束（确实无未来落点）分支成立；**调度异常**返回 false
  /// 时重复任务的未来落点仍挂在外（snooze 失败不影响既有 8 槽预挂），下个
  /// 周期照响，文案改「顺延失败」不谎报。调用方（main._doSnooze）已把
  /// done / repeatEnded / archived 预拦截，走到本回执的 false 属异常分支。
  Future<void> showSnoozeUnavailableConfirm(String id,
      {String? title, bool isHabit = false, bool rescheduleFailed = false}) async {
    if (!enabled) return;
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        isHabit ? _chHabit : _chSound,
        isHabit ? '习惯提醒' : '任务提醒',
        channelDescription:
            isHabit ? '每日习惯打卡提醒' : '任务截止时间提醒',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        autoCancel: true,
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        isHabit ? habitConfirmNotifyIdOf(id) : _notifyIdOf(id),
        '提醒已结束',
        title != null && title.isNotEmpty
            ? '$title · ${rescheduleFailed ? '顺延失败，请打开应用查看' : '不会再响，请打开应用查看'}'
            : '该提醒已不再有效，请打开应用查看',
        detail,
        payload: isHabit
            ? '$payloadHabitPrefix$id'
            : '$payloadTaskPrefix$id',
      );
    } catch (e) {
      AppLog.d('[通知] 稍后提醒不可用提示通知失败 id=$id: $e');
    }
  }

  /// 锁定态 action 提示（新U3-1，v2.9.7 审计）：锁定期间点通知「撤销」此前
  /// 完全静默（既不暂存也不回报，与「打卡」会入队解锁后补执行的回报不一致）。
  /// 撤销是破坏性回退，不跨锁暂存——回一条提示通知如实说明，指引用户解锁后
  /// 在 App 内操作。固定 id=[lockedActionNotifyId]（1600000，独立于全部段位）。
  ///
  /// P2-1（v3.0.1 审计）：文案按动作类型参数化——旧实现固定写「撤销打卡记录」，
  /// 任务「完成撤销」命中该提示时话术错位（用户被告知去撤销打卡记录）。
  Future<void> showLockedActionHint({bool taskUndo = false}) async {
    if (!enabled) return;
    final detail = NotificationDetails(
      android: AndroidNotificationDetails(
        _chHabit,
        '习惯提醒',
        channelDescription: '每日习惯打卡提醒',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        autoCancel: true,
        visibility: visibility,
      ),
    );
    try {
      await _plugin.show(
        lockedActionNotifyId,
        '已锁定，未执行撤销',
        taskUndo
            ? '应用处于锁定状态。请解锁后在 App 内撤销该任务的完成。'
            : '应用处于锁定状态。请解锁后在 App 内撤销打卡记录。',
        detail,
      );
    } catch (e) {
      AppLog.d('[通知] 锁定态提示通知失败: $e');
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
