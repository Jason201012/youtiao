import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/daily_briefing.dart';
import 'package:todolist/services/background_service.dart';
import 'package:todolist/services/app_log.dart';
import 'package:todolist/services/app_nav.dart';
import 'package:todolist/services/secure_window.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/theme_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/onboarding_provider.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/services/focus_audio_service.dart';
import 'package:todolist/screens/onboarding_screen.dart';
import 'package:todolist/widgets/bottom_nav.dart';
import 'package:todolist/widgets/new_task_fab.dart';
import 'package:todolist/widgets/quick_entry_sheet.dart';
import 'package:todolist/screens/home_screen.dart';
import 'package:todolist/screens/board_screen.dart';
import 'package:todolist/screens/calendar_screen.dart';
import 'package:todolist/screens/focus_screen.dart';
import 'package:todolist/screens/habit_screen.dart';
import 'package:todolist/screens/settings_screen.dart';
import 'package:todolist/screens/today_review_screen.dart';
import 'package:todolist/screens/task_detail_screen.dart';
import 'package:todolist/screens/trash_screen.dart';
import 'package:todolist/screens/tag_manage_screen.dart';
import 'package:todolist/widgets/command_palette.dart';
import 'package:todolist/widgets/export_sheet.dart';
import 'package:todolist/widgets/backup_sheet.dart';

/// 全局根导航键：供通知点击回调在脱离 widget context 时仍能 push 路由。
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

/// P2-2：冷启动期间到达的外部意图先暂存，待 MainScaffold 首帧后消费。
/// 旧实现用单值变量，锁定期间若连续到达多个意图会被后者覆盖、最早的有效意图永久丢失。
/// 现全部改为队列，逐个消费；各队列上限 [_pendingQueueCap]，超出丢弃最旧，防长期运行无界增长。
const int _pendingQueueCap = 20;

/// 统一入队 helper：追加并截断到上限（丢弃最旧）。
void _enqueue<T>(List<T> q, T item) {
  q.add(item);
  if (q.length > _pendingQueueCap) q.removeAt(0);
}

/// 冷启动时通知点击先于 MaterialApp 就绪到达，暂存 payload，待 MainScaffold 首帧后消费。
final List<String> _pendingNotificationPayloads = [];

/// 冷启动时由桌面小组件点击任务项拉起（MainActivity 带 EXTRA_TASK_ID），原生经 widget_nav
/// 通道请求直达详情页；导航器未就绪时暂存任务 id，待 MainScaffold 首帧后消费。
final List<String> _pendingWidgetTaskIds = [];

/// 冷启动时点击通知「稍后提醒」action 先于导航器就绪到达，暂存任务/习惯 id（并行两队列，成对消费）。
final List<String> _pendingSnoozeTaskIds = [];
final List<String> _pendingSnoozeHabitIds = [];

/// 冷启动时点击通知「完成」action 先于导航器就绪到达，暂存任务 id。
/// 解锁后消费需先弹确认对话框（P2-3），避免刚解锁就被静默改动数据并弹确认通知。
final List<String> _pendingCompleteTaskIds = [];

/// U3：冷启动时点击习惯通知「打卡」action 先于导航器就绪到达，暂存习惯 id。
/// 打卡是幂等正向操作，解锁后直接补打、无需确认（与「完成」任务的确认框不同）。
final List<String> _pendingHabitCheckInIds = [];

/// 冷启动时由「分享」入口转发过来的文本 + 来源包名，先于导航器就绪到达，待首帧后弹出预填录入层。
class _PendingShare {
  final String text;
  final String? source;
  const _PendingShare(this.text, this.source);
}
final List<_PendingShare> _pendingShares = [];

/// P1-11：冷启动时由「系统分享接收附件」入口（ACTION_SEND + EXTRA_STREAM）先于导航器就绪到达，
/// 暂存已落盘暂存目录的附件引用与其会话 id，待 MainScaffold 首帧后弹出带附件的预填录入层。
class _PendingSharedAttachment {
  final AttachmentRef ref;
  final String session;
  const _PendingSharedAttachment(this.ref, this.session);
}
final List<_PendingSharedAttachment> _pendingSharedAttachments = [];

/// 分享建任务：原生侧经 com.example.todolist/share_intent 通道推送文本，在此弹出预填录入层。
/// 导航器未就绪（冷启动）时暂存，待 MainScaffold 首帧后消费。
///
/// I-05：对「短时间多次分享」做双层节流。
/// - 同一**来源包名** 1 秒内最多接收 1 次（恶意 App 换个文本就能绕开「相同文本」判定，
///   因此节流键必须是来源而不是内容）；
/// - 保留原「500ms 内相同文本」判据，覆盖同一来源连发同文本的抖动。
/// [sourcePackage] 为分享来源包名（原生侧经 getCallingActivity 取得），用于预填层展示来源。
String? _lastShareText;
int _lastShareAtMs = 0;
/// 来源包名 → 上次接收时刻（毫秒）。条目数设上限，防长期运行后无界增长。
final Map<String, int> _lastShareAtBySource = <String, int>{};
/// 同一来源两次分享的最小间隔（I-05）。
const int _shareThrottleMs = 1000;

void _openQuickEntry(String text, {String? sourcePackage}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  // 第一层：按来源包名节流（主要防线）。
  final key = sourcePackage ?? '';
  final lastBySource = _lastShareAtBySource[key];
  if (lastBySource != null && now - lastBySource < _shareThrottleMs) {
    return;
  }
  _lastShareAtBySource[key] = now;
  if (_lastShareAtBySource.length > 64) _lastShareAtBySource.clear();
  // 第二层：相同文本 500ms 内去重。
  if (text == _lastShareText && now - _lastShareAtMs < 500) {
    return;
  }
  _lastShareText = text;
  _lastShareAtMs = now;
  final state = _navigatorKey.currentState;
  // M-01：锁定期间同样只暂存，解锁后再弹（录入层同样盖在解锁页之上）。
  // P2-2：改为入队，避免锁定期间多次分享互相覆盖丢失。
  if (state == null || _isAppLocked) {
    _enqueue(_pendingShares, _PendingShare(text, sourcePackage));
    return;
  }
  QuickEntrySheet.show(
    state.context,
    initialText: text,
    sourcePackage: sourcePackage,
  );
}

/// P1-11：系统分享接收图片/文件。原生侧已把 content URI 二进制复制进应用私有缓存并传回
/// 本地路径 + 类型/大小等元数据；此处把该临时文件二次导入到本次分享专用的暂存目录，
/// 再唤起带附件预填的快速录入层，由用户确认后保存（不做自动保存，防骚扰）。离线、不联网。
Future<void> _openQuickEntryUri(Map<String, dynamic> meta) async {
  try {
    final localPath = meta['localPath'] as String?;
    if (localPath == null || localPath.isEmpty) return;
    final typeStr = (meta['type'] as String?) ?? 'file';
    final type = typeStr == 'image'
        ? AttachmentType.image
        : typeStr == 'audio'
            ? AttachmentType.audio
            : AttachmentType.file;
    final rawMime = meta['mimeType'] as String?;
    final mimeType = (rawMime != null && rawMime.isNotEmpty) ? rawMime : null;
    // 生成独立暂存会话 id（与 TaskSheet 自身会话区分），保存后由 promoteStaging 提升。
    final sessionId =
        '${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecondsSinceEpoch % 100000}';
    final ref = await AttachmentService.importSharedFile(
      localPath: localPath,
      sessionId: sessionId,
      type: type,
      mimeType: mimeType,
    );
    final state = _navigatorKey.currentState;
    // M-01：导航器未就绪或应用锁锁定期间只暂存，解锁后再弹。
    // P2-2：改为入队，避免锁定期间多次分享附件互相覆盖丢失。
    if (state == null || _isAppLocked) {
      _pendingSharedAttachments
          .add(_PendingSharedAttachment(ref, sessionId));
      if (_pendingSharedAttachments.length > _pendingQueueCap) {
        _pendingSharedAttachments.removeAt(0);
      }
      return;
    }
    await QuickEntrySheet.show(
      state.context,
      initialAttachment: ref,
      attachmentSession: sessionId,
    );
  } catch (e) {
    // 导入失败（超大/非法）：静默忽略，不打扰用户；临时缓存文件由 importSharedFile 清理。
    AppLog.d('分享附件导入失败：$e');
  }
}

/// P1-9：桌面端全局快捷键开关。仅在桌面平台（Windows/Linux/macOS）启用，
/// 移动端（Android/iOS）与 Web 无物理键盘，保持原有触摸交互，不挂任何快捷键。
bool get _isDesktopShortcutsEnabled {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// P1-9 快捷键意图：复用既有的快速录入 / 首页搜索 / 命令面板路由。
class _OpenQuickEntryIntent extends Intent {
  const _OpenQuickEntryIntent();
}

class _NewTaskIntent extends Intent {
  const _NewTaskIntent();
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _OpenCommandPaletteIntent extends Intent {
  const _OpenCommandPaletteIntent();
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

/// P1-6：切换到第 [index] 个底部 Tab（0=首页 … 5=设置）。
class _SwitchTabIntent extends Intent {
  const _SwitchTabIntent(this.index);

  /// 目标 Tab 下标；越界由 Action 兜底忽略，不抛异常。
  final int index;
}

/// P1-6：`Cmd/Ctrl+Enter` 完成首页当前选中的任务。
class _CompleteSelectedIntent extends Intent {
  const _CompleteSelectedIntent();
}

/// 底部 Tab 数量（首页/看板/日历/专注/习惯/设置），同时是数字键的上限。
const int _tabCount = 6;

/// 数字键 1..6 的 key 常量，顺序与 Tab 下标严格一致。
const List<LogicalKeyboardKey> _digitKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
];

/// P1-9：Ctrl/Cmd 组合键映射（同时照顾 Windows/Linux 的 Ctrl 与 macOS 的 Cmd）。
/// Esc 单独成组，用于关闭最上层模态路由 / 退出首页搜索。
/// P1-6 追加数字键切 Tab 与 `Cmd/Ctrl+Enter` 完成选中项。
/// 注意：`LogicalKeySet` 构造非 const，故整个映射不可声明为 const（保持顶层 final）。
final Map<ShortcutActivator, Intent> _appShortcuts = _buildAppShortcuts();

/// 构造全局快捷键表。拆成函数是为了用循环批量登记数字键，避免 18 行手写重复。
Map<ShortcutActivator, Intent> _buildAppShortcuts() {
  final m = <ShortcutActivator, Intent>{
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyK):
        const _OpenQuickEntryIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyK):
        const _OpenQuickEntryIntent(),
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyN):
        const _NewTaskIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyN):
        const _NewTaskIntent(),
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyF):
        const _FocusSearchIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyF):
        const _FocusSearchIntent(),
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyP):
        const _OpenCommandPaletteIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyP):
        const _OpenCommandPaletteIntent(),
    LogicalKeySet(LogicalKeyboardKey.escape): const _EscapeIntent(),
  };

  // P1-6：数字键切 Tab。成对登记三种形态：
  // - `Cmd/Ctrl+数字`：零冲突主入口（同浏览器切标签页惯例），任何场景都生效；
  // - 裸数字键：更快的入口，但会与文本输入抢字符，故由 Action 内的焦点判定兜底放行。
  for (var i = 0; i < _tabCount && i < _digitKeys.length; i++) {
    final key = _digitKeys[i];
    m[LogicalKeySet(LogicalKeyboardKey.control, key)] = _SwitchTabIntent(i);
    m[LogicalKeySet(LogicalKeyboardKey.meta, key)] = _SwitchTabIntent(i);
    m[LogicalKeySet(key)] = _SwitchTabIntent(i);
  }

  // P1-6：完成首页选中项。只绑组合键——裸 Enter 要留给确认/换行等默认行为。
  m[LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.enter)] =
      const _CompleteSelectedIntent();
  m[LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.enter)] =
      const _CompleteSelectedIntent();
  return m;
}

/// P1-6 兜底：当前焦点是否落在文本输入框内。
///
/// 裸数字键是全局快捷键，若用户在搜索框、备注框里打字时被截获，会吞掉字符输入。
/// 因此先判焦：命中输入框就放行，让事件继续走系统默认行为（字符照常录入）。
/// 判定方式是从焦点节点的 context 向上找最近的 [EditableText]——`Focus` 由
/// `EditableText` 内部构建、是它的后代，故能命中。无焦点、未挂载或找不到一律
/// 按「非输入」处理，宁可切 Tab 也不吞掉功能键。
bool _isEditingText() {
  final node = FocusManager.instance.primaryFocus;
  final ctx = node?.context;
  if (ctx == null || !ctx.mounted) return false;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// M-01：当前是否处于「应用锁已上锁」状态。
///
/// 应用锁的实现是「home（MainScaffold）内部 locked 时渲染 AppLockGate」，
/// 而通知 / 小组件 / 分享的跳转走的是 MaterialApp 的**根 Navigator**，
/// push 上去的路由会整屏盖在解锁页之上——即完全绕过应用锁。
/// 因此所有外部意图在消费前都必须先过这道判定；判定失败（Provider 未注入 /
/// context 未挂载）时按「未锁定」处理，宁可放行也不吞掉正常跳转。
bool get _isAppLocked {
  final ctx = _navigatorKey.currentContext;
  if (ctx == null) return false;
  try {
    return ctx.read<AppLockProvider>().locked;
  } catch (_) {
    return false;
  }
}

/// 通知点击回调：解析 task:/habit: 前缀并跳转；导航器未就绪时暂存。
void _handleNotificationTap(String? payload) {
  if (payload == null || payload.isEmpty) return;
  final state = _navigatorKey.currentState;
  if (state != null) {
    _navigateFromPayload(payload, state);
  } else {
    _enqueue(_pendingNotificationPayloads, payload);
  }
}

/// 按前缀跳转：task: → 任务详情；habit: → 习惯页；brief: → 简报汇总页。其它忽略。
///
/// M-01：锁定期间只把意图塞回 [_pendingNotificationPayloads]（入队，不覆盖），
/// 解锁成功后由 MainScaffold 的 AppLockProvider 监听回调统一消费。
void _navigateFromPayload(String payload, NavigatorState nav) {
  if (_isAppLocked) {
    _enqueue(_pendingNotificationPayloads, payload);
    return;
  }
  _doNavigate(payload, nav);
}

/// 实际执行跳转（M-01 改造后由 [_navigateFromPayload] 与解锁回调共同调用）。
void _doNavigate(String payload, NavigatorState nav) {
  if (payload.startsWith(NotificationService.payloadTaskPrefix)) {
    final id = payload.substring(NotificationService.payloadTaskPrefix.length);
    nav.push(MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: id)));
  } else if (payload.startsWith(NotificationService.payloadHabitPrefix)) {
    nav.push(MaterialPageRoute(builder: (_) => const HabitScreen()));
  } else if (payload.startsWith(NotificationService.payloadBriefPrefix)) {
    final kind = payload.substring(NotificationService.payloadBriefPrefix.length);
    if (kind == 'evening') {
      nav.push(MaterialPageRoute(builder: (_) => const TodayReviewScreen()));
    } else {
      // 晨间待办：进入首页「今日」分区（首页默认即展示今日任务）。
      nav.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
    }
  }
}

/// 通知 action 按钮点击回调：处理「稍后提醒」与「完成」两类 action。
/// 导航器未就绪（冷启动）时暂存 id，待 MainScaffold 首帧后消费。
///
/// M-01：锁定期间同样只暂存不执行——「完成」会改动数据并弹一条带任务标题的
/// 确认通知，「稍后提醒」会重排提醒；两者都会泄露/改变锁定状态下的数据。
void _handleNotificationAction(String? actionId, String? payload) {
  if (actionId == NotificationService.snoozeActionId) {
    final taskId = NotificationService.parseTaskId(payload);
    final habitId = NotificationService.parseHabitId(payload);
    final state = _navigatorKey.currentState;
    if (state != null && !_isAppLocked) {
      _doSnooze(state, taskId, habitId);
    } else {
      // P2-2：分别入队，避免多个 action 互相覆盖丢失。
      if (taskId != null) _enqueue(_pendingSnoozeTaskIds, taskId);
      if (habitId != null) _enqueue(_pendingSnoozeHabitIds, habitId);
    }
    return;
  }
  if (actionId == NotificationService.completeActionId) {
    final taskId = NotificationService.parseTaskId(payload);
    if (taskId == null) return;
    final state = _navigatorKey.currentState;
    if (state != null && !_isAppLocked) {
      _doComplete(state, taskId);
    } else {
      // P2-2 + P2-3：入队，解锁后消费前先弹确认对话框。
      _enqueue(_pendingCompleteTaskIds, taskId);
    }
    return;
  }
  if (actionId == NotificationService.habitCheckInActionId) {
    // U3：习惯提醒「打卡」action——直接把该习惯今天标记为已打卡。
    // 与任务「完成」不同：打卡是幂等正向操作、无数据破坏风险，
    // 锁定期间入队、解锁后直接补打（无需确认框）。
    final habitId = NotificationService.parseHabitId(payload);
    if (habitId == null) return;
    final state = _navigatorKey.currentState;
    if (state != null && !_isAppLocked) {
      _doHabitCheckIn(state, habitId);
    } else {
      _enqueue(_pendingHabitCheckInIds, habitId);
    }
  }
}

/// U3：把习惯标记为今天已打卡。与补卡共用 [HabitProvider.checkInOnDay]（幂等：
/// 已打卡则忽略），打卡后弹覆盖式确认通知（同 id 不刷屏），用户无需进 App。
///
/// P2-2（v2.9.3 审计）：量化习惯此前走 `checkInOnDay` 只记 1 个单位却回报
/// 「已打卡 ✓」——目标 8 杯点一下只算 1/8 还谎称完成。
///
/// U2-1（v2.9.4 审计）：v2.9.3 把量化习惯的「打卡」改成 `completeTodayTarget`
/// （一键顶满）以对齐文案，**副作用却过强**：已记 3/8 时点一下通知按钮直接变
/// 8/8，误触即虚增 5 个单位，而通知里没有任何回退手段（要进 App 手动改数）。
/// 现在按**当日已有量**分档：
/// - 已记 0 → 顶满目标（通知场景下最省事，与「打卡」按钮语义一致）；
/// - 已记 >0（未达标）→ 只 **+1**，与 App 内「+1」按钮同语义，误触损失 1 个单位；
/// - 已达标 → 早退（通知确认提示今日已完成，不重复写入）。
void _doHabitCheckIn(NavigatorState nav, String habitId) {
  final hp = Provider.of<HabitProvider>(nav.context, listen: false);
  final habit = hp.byId(habitId);
  if (habit == null) return;
  final now = DateTime.now();
  if (habit.isQuantified) {
    final current = hp.todayValue(habit);
    if (current >= habit.effectiveTarget) {
      // U2-1：已达标时不再写入（此前 completeTodayTarget 自身会早退，
      // 这里显式早退是为了不再弹一次「已打卡」确认覆盖掉用户原有通知）。
      NotificationService.instance.showHabitCheckedConfirm(
        habit,
        value: current,
        target: habit.effectiveTarget,
      );
      return;
    }
    // U2-1：已有进度时只 +1，不再一键顶满。
    final op = current <= 0
        ? hp.completeTodayTarget(habit)
        : hp.adjustCheckInValue(habit, now, 1);
    // 异步写入：内部走 setCheckInValue（落盘 + 重排提醒/挽留）；失败静默。
    op.catchError((_) => false).then((_) {
      // 按完成后的真实进度回报（+1 后通常未达标 → 如实显示「已记 x/y」）。
      NotificationService.instance.showHabitCheckedConfirm(
        habit,
        value: hp.todayValue(habit),
        target: habit.effectiveTarget,
      );
    });
    return;
  }
  // 异步打卡：checkInOnDay 内部持久化 + 重排今日提醒/挽留；失败静默。
  hp.checkInOnDay(habit, now).catchError((_) => false);
  NotificationService.instance.showHabitCheckedConfirm(habit);
}

/// 用 task/habit id 从 Provider 取实体并触发稍后提醒调度。
/// 顺延时长取用户设置的 [TaskProvider.snoozeMinutes]（默认 10 分钟）。
void _doSnooze(NavigatorState nav, String? taskId, String? habitId) {
  final ctx = nav.context;
  final provider = Provider.of<TaskProvider>(ctx, listen: false);
  final delay = Duration(minutes: provider.snoozeMinutes);
  if (taskId != null) {
    final task = provider.byId(taskId);
    if (task != null) {
      NotificationService.instance.snoozeTaskReminder(task, delay: delay);
    }
  } else if (habitId != null) {
    final habit = Provider.of<HabitProvider>(ctx, listen: false).byId(habitId);
    if (habit != null) {
      NotificationService.instance.snoozeHabitReminder(habit, delay: delay);
    }
  }
}

/// 从通知「完成」action 直接把任务标记为已完成：调用 TaskProvider.setStatus，
/// 并弹一条「已完成 ✓」确认通知（覆盖式，同 id 不刷屏）。任务已处于完成态则跳过。
void _doComplete(NavigatorState nav, String? taskId) {
  if (taskId == null) return;
  final provider = Provider.of<TaskProvider>(nav.context, listen: false);
  final task = provider.byId(taskId);
  if (task == null || task.done) return;
  // 标记完成（内部会取消其一次性截止提醒，避免完成后仍弹；重复任务则跳过今日）。
  provider.setStatus(taskId, TaskStatus.done);
  // 覆盖式确认通知：用任务通知 id，用户一眼可见「已完成」，且不会叠加新通知。
  NotificationService.instance.showCompletedConfirm(taskId, task.title);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // L-11：release 包一律不再向 logcat 输出业务内容。Flutter 不会自动剥离
  // debugPrint/print，这里把 debugPrint 整体置空，覆盖存量 70 余处调用；
  // 新增代码统一走 [AppLog]（内部以 kReleaseMode 守卫）。
  _silenceDebugPrintInRelease();
  // 在 init() 前挂上点击回调（init 内部 initialize() 会在冷启动时直接触发）。
  NotificationService.onNotificationTap = _handleNotificationTap;
  NotificationService.onNotificationAction = _handleNotificationAction;
  await NotificationService.instance.init();

  // 分享建任务：注册原生 → Dart 文本通道（与通知点击通道同理）。
  const MethodChannel('com.example.todolist/share_intent')
      .setMethodCallHandler((call) async {
    if (call.method == 'onSharedText') {
      // P2-8：原生侧以 Map 形式推送 {text, source}，兼顾「来源提示」。
      final args = call.arguments;
      final text = args is Map ? (args['text'] as String?) : (args as String?);
      final source =
          args is Map ? (args['source'] as String?) : null;
      if (text is String && text.isNotEmpty) {
        _openQuickEntry(text, sourcePackage: source);
      }
    }
  });

  // 系统分享接收附件（图片/文件）：注册原生 → Dart 通道，把临时缓存路径 + 元数据交给 Dart 导入。
  const MethodChannel('com.example.todolist/share_uri')
      .setMethodCallHandler((call) async {
    if (call.method == 'onSharedUri') {
      final args = call.arguments;
      if (args is Map) {
        await _openQuickEntryUri(Map<String, dynamic>.from(args));
      }
    }
  });

  // 桌面小组件点击任务项：原生 → Dart 通道，直达任务详情页（与通知点击同构）。
  const MethodChannel('com.example.todolist/widget_nav')
      .setMethodCallHandler((call) async {
    if (call.method == 'openTask') {
      final id = call.arguments;
      if (id is String && id.isNotEmpty) {
        final state = _navigatorKey.currentState;
        if (state != null) {
          // M-01：内部已判定锁定态，锁定期间自动转为暂存。
          _navigateFromPayload('task:$id', state);
        } else {
          // P2-2：入队，避免冷启动期间多次小组件点击互相覆盖丢失。
          _enqueue(_pendingWidgetTaskIds, id);
        }
      }
    }
  });

  final task = TaskProvider();
  await _safeLoad(task, 'TaskProvider');
  final focus = FocusProvider();
  await _safeLoad(focus, 'FocusProvider');
  final theme = ThemeProvider();
  await _safeLoad(theme, 'ThemeProvider');
  final habit = HabitProvider();
  await _safeLoad(habit, 'HabitProvider');
  final onboarding = OnboardingProvider();
  await _safeLoad(onboarding, 'OnboardingProvider');
  final appLock = AppLockProvider();
  await _safeLoad(appLock, 'AppLockProvider');
  // L-06：锁屏是否隐藏通知内容（默认隐藏）。必须在首次调度通知前写入，
  // 否则本轮调度出来的通知仍会按 public 展示任务标题。
  NotificationService.lockScreenPrivate = task.lockScreenPrivate;
  // L-07：防截屏 / 防录屏。原生 onCreate 已按持久化值应用过一次，
  // 这里再同步一次，覆盖「偏好由备份恢复」等运行时变更。
  unawaited(SecureWindow.setFlagSecure(task.screenSecurityEnabled));
  // 启动后调度全部已设提醒的习惯（失败单个静默，不影响其它功能）。
  try {
    await habit.scheduleAllReminders();
  } catch (e) {
    AppLog.d('[HabitProvider] 调度习惯提醒失败：$e');
  }
  // P0-1：启动后按设置重排早晚简报（失败单个静默，不影响其它功能）。
  try {
    await rescheduleBriefings(task, focus, habit);
  } catch (e) {
    AppLog.d('[DailyBriefing] 调度简报失败：$e');
  }
  // P1-7：启动后重排「习惯漏卡挽留」（内部已包 try/catch，这里再兜一层）。
  try {
    await rescheduleHabitNudge(habit,
        enabled: task.habitNudgeEnabled, nudgeMinute: task.habitNudgeMinute);
  } catch (e) {
    AppLog.d('[HabitNudge] 调度挽留失败：$e');
  }
  // P2-2：打卡 / 增删习惯变动后自动重排挽留，避免「已补卡却收到陈旧挽留」。
  // F4：变动重排沿用当前可配置时刻与开关。
  // 注意：onHabitsChanged 是 HabitProvider 的静态回调（避免反向 import daily_briefing），
  // 必须用类访问，不能经实例访问。
  HabitProvider.onHabitsChanged = (h) {
    rescheduleHabitNudge(h,
        enabled: task.habitNudgeEnabled, nudgeMinute: task.habitNudgeMinute);
  };
  // F-07：简报 / 习惯挽留已改为**一次性**闹钟（不再由系统按天重发旧文案）。
  // 若 App 一直挂在前台跨过 00:00，不会触发 resumed 事件，这里借 TaskProvider
  // 的跨天守护回调补一次重排，保证次日仍有一班简报 / 挽留。
  TaskProvider.onDayChanged = () {
    if (!task.notificationsEnabled) return;
    unawaited(rescheduleBriefings(task, focus, habit));
    rescheduleHabitNudge(habit,
        enabled: task.habitNudgeEnabled, nudgeMinute: task.habitNudgeMinute);
  };
  // F-2：习惯打卡提醒与任务重复提醒统一改为**一次性**闹钟（预挂接下来 8 次），
  // 需在每次 15 分钟守护周期补挂，否则预挂的几次响完后会静默断档。
  // 通知服务内部有「落点签名」缓存，落点未变时不会真的重复下发。
  TaskProvider.onGuardTick = () {
    if (!task.notificationsEnabled) return;
    unawaited(habit.scheduleAllReminders());
  };

  // 专注结束回填累计专注时长到关联任务（任务行展示「已专注 X 分钟」）。
  focus.onFocusRecorded = (taskId, sec) => task.addFocusSec(taskId, sec);
  // 启动前台守护（若用户在设置里开启）：保证划掉后台后定时提醒仍准时送达
  if (task.backgroundGuardEnabled) {
    await BackgroundService.instance.start();
  }
  // 注入勿扰顺延逻辑：一次性提醒落在勿扰区间时，顺延到时段结束 + 5 分钟再弹。
  NotificationService.dndDefer = (DateTime scheduled) {
    if (!task.dndEnabled) return null;
    if (!task.isDndHour(scheduled.hour)) return null;
    // 顺延到「勿扰结束小时」当天（或次日，若结束小时已过）的 :05 分。
    var end = DateTime(
        scheduled.year, scheduled.month, scheduled.day, task.dndEndHour, 5);
    if (!end.isAfter(scheduled)) {
      end = end.add(const Duration(days: 1));
    }
    return end;
  };
  // S1：跨日首启自动生成当日滚动快照（纯本地，不上传）。
  // 必须在 FocusProvider / HabitProvider 全部 load() 之后触发（P0-2），
  // 否则快照会系统性缺失专注记录与习惯打卡。错误仅记日志，不阻断启动。
  try {
    await task.triggerAutoBackup();
  } catch (e, s) {
    AppLog.e('自动备份触发失败（忽略）', e, s);
  }
  // P2-9：启动兜底清理——删除超过 24h 的附件暂存残留（编辑弹层中途被杀会留下）。
  try {
    await AttachmentService.cleanupStaleStaging();
  } catch (e, s) {
    AppLog.e('附件暂存清理失败（忽略）', e, s);
  }
  runApp(MyApp(task: task, focus: focus, theme: theme, habit: habit, onboarding: onboarding, appLock: appLock));
}

/// L-11：release 构建下把 debugPrint 置空，避免任务标题 / 提醒调度细节等
/// 业务内容继续写进 logcat。
void _silenceDebugPrintInRelease() {
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
}

/// 安全加载 Provider：捕获所有异常避免 [runApp()] 永远不被调用（卡在 splash）。
Future<void> _safeLoad(ChangeNotifier provider, String name) async {
  try {
    if (provider is TaskProvider) {
      await provider.load();
    } else if (provider is FocusProvider) {
      await provider.load();
    } else if (provider is ThemeProvider) {
      await provider.load();
    } else if (provider is HabitProvider) {
      await provider.load();
    } else if (provider is OnboardingProvider) {
      await provider.load();
    } else if (provider is AppLockProvider) {
      await provider.load();
    }
  } catch (e, stack) {
    AppLog.e('[$name] 启动加载失败（已降级跳过）', e, stack);
    // 不 rethrow ——允许 app 继续启动，该功能暂时不可用但 UI 正常渲染。
  }
}

class MyApp extends StatelessWidget {
  final TaskProvider task;
  final FocusProvider focus;
  final ThemeProvider theme;
  final HabitProvider habit;
  final OnboardingProvider onboarding;
  final AppLockProvider appLock;
  const MyApp({
    super.key,
    required this.task,
    required this.focus,
    required this.theme,
    required this.habit,
    required this.onboarding,
    required this.appLock,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: task),
        ChangeNotifierProvider.value(value: focus),
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: habit),
        ChangeNotifierProvider.value(value: onboarding),
        ChangeNotifierProvider.value(value: appLock),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) {
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              // 防御：若 DynamicColorBuilder 回传 null（或后续 buildThemes 抛错），
              // 用空 fallback 保证 MaterialApp 正常渲染，不再卡白屏。
              try {
                final themes = theme.buildThemes(lightDynamic, darkDynamic);
                return MaterialApp(
                title: '有条',
                navigatorKey: _navigatorKey,
                themeMode: theme.effectiveThemeMode,
                theme: themes.$1,
                darkTheme: themes.$2,
                debugShowCheckedModeBanner: false,
                locale: const Locale('zh', 'CN'),
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: const [Locale('zh', 'CN')],
                home: onboarding.hasSeenIntro
                    ? const MainScaffold()
                    : const OnboardingScreen(),
              );
              } catch (e) {
                // buildThemes 或 DynamicColorBuilder 异常时降级为默认主题。
                AppLog.d('主题构建异常，降级为默认：$e');
                final fallback = theme.buildThemes(null, null);
                return MaterialApp(
                  title: '有条',
                  navigatorKey: _navigatorKey,
                  themeMode: theme.effectiveThemeMode,
                  theme: fallback.$1,
                  darkTheme: fallback.$2,
                  debugShowCheckedModeBanner: false,
                  locale: const Locale('zh', 'CN'),
                  localizationsDelegates: const [
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  supportedLocales: const [Locale('zh', 'CN')],
                  home: onboarding.hasSeenIntro
                    ? const MainScaffold()
                    : const OnboardingScreen(),
                );
              }
            },
          );
        },
      ),
    );
  }
}

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});
  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold>
    with WidgetsBindingObserver {
  int _index = 0;
  bool _homeSearching = false;

  /// P1-9：首页 State 句柄，供 Ctrl/Cmd+F 快捷键从宿主 Scaffold 聚焦首页搜索。
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();

  /// M-01：应用锁 Provider 引用。锁定期间外部意图只暂存，解锁后由监听回调消费。
  late final AppLockProvider _appLock;

  /// P1-2：无操作自动锁定定时器。解锁后用户无交互超过设定时长即强制上锁。
  /// 仅在应用锁开启且当前未锁定时启动；锁定态/未开启锁时不持有定时器。
  Timer? _idleTimer;

  /// P1-2：当前设置的空闲时长；<=0 表示「永不」。
  Duration? get _idleDuration {
    final secs =
        Provider.of<TaskProvider>(context, listen: false).appLockIdleSeconds;
    return secs <= 0 ? null : Duration(seconds: secs);
  }

  /// P1-2：重置空闲定时器——任何用户交互（见 build 中的 Listener）或生命周期回到前台时调用。
  /// 规则：已锁定时取消定时器（锁定态无需再锁）；未开启锁时取消；否则按 [_idleDuration] 重启。
  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_appLock.locked || !_appLock.appLockEnabled) return;
    final dur = _idleDuration;
    if (dur == null) return;
    _idleTimer = Timer(dur, _onIdleTimeout);
  }

  /// P1-2：空闲超时回调——强制上锁。定时器已触发，置空引用。
  void _onIdleTimeout() {
    _idleTimer = null;
    if (_appLock.appLockEnabled && !_appLock.locked) {
      _appLock.lock();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 看板统计卡点击后，由 provider 回调切回首页并套用筛选。
    Provider.of<TaskProvider>(context, listen: false).onRequestHome =
        () => setState(() => _index = 0);
    // 任务行「专注」按钮请求跳到专注 Tab（index=3）；FocusProvider 静态回调。
    FocusProvider.jumpToFocusTab = () => setState(() => _index = 3);
    // U4：命令面板移动端顶栏入口——各 Tab 页经 AppNav.jumpToTab 请求切 Tab。
    AppNav.onJumpToTab = (i) {
      if (i >= 0 && i < _tabCount && mounted) setState(() => _index = i);
    };
    // M-01：监听解锁事件——locked 由 true 变 false 时，把锁定期间暂存的
    // 通知跳转 / 通知 action / 分享 / 小组件意图一次性消费掉。
    _appLock = Provider.of<AppLockProvider>(context, listen: false);
    _appLock.addListener(_onAppLockChanged);
    // 消费冷启动期间暂存的全部外部意图（此时导航器已就绪）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushPendingIntents());
    // P1-2：启动即开始计时空闲自动锁定。
    _resetIdleTimer();
  }

  /// M-01：解锁成功后补消费锁定期间暂存的意图。
  /// 用 postFrame 包一层，避免在 notifyListeners（可能处于 build 阶段）里直接 push 路由。
  void _onAppLockChanged() {
    if (!_appLock.locked) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _flushPendingIntents());
      // P1-2：刚解锁即重置空闲计时，避免解锁瞬间立即又被超时锁定。
      _resetIdleTimer();
    }
  }

  /// 消费所有暂存的外部意图：通知点击 / 通知 action（稍后提醒、完成）/
  /// 分享文本 / 分享附件 / 桌面小组件。
  ///
  /// M-01：**锁定期间一律不消费**——这些动作都会经根 Navigator push 路由或改动数据，
  /// 会整屏盖在 AppLockGate 之上，使应用锁形同虚设。仍锁定时保持暂存，
  /// 待解锁后由 [_onAppLockChanged] 再次调用。
  Future<void> _flushPendingIntents() async {
    final state = _navigatorKey.currentState;
    if (!mounted || state == null) return;
    if (_isAppLocked) return;

    // P2-2：所有暂存意图改为队列逐个消费，避免任一意图覆盖丢失。
    // 通知点击（含冷启动时由 initialize 回调暂存的 payload）。
    while (_pendingNotificationPayloads.isNotEmpty) {
      _doNavigate(_pendingNotificationPayloads.removeAt(0), state);
    }
    // 桌面小组件点击任务项。
    while (_pendingWidgetTaskIds.isNotEmpty) {
      _doNavigate('task:${_pendingWidgetTaskIds.removeAt(0)}', state);
    }
    // 通知「稍后提醒」action（任务 / 习惯 id 成对消费）。
    while (
        _pendingSnoozeTaskIds.isNotEmpty || _pendingSnoozeHabitIds.isNotEmpty) {
      final tId = _pendingSnoozeTaskIds.isEmpty
          ? null
          : _pendingSnoozeTaskIds.removeAt(0);
      final hId = _pendingSnoozeHabitIds.isEmpty
          ? null
          : _pendingSnoozeHabitIds.removeAt(0);
      _doSnooze(state, tId, hId);
    }
    // 系统分享文本（含来源）。
    while (_pendingShares.isNotEmpty) {
      final s = _pendingShares.removeAt(0);
      QuickEntrySheet.show(state.context,
          initialText: s.text, sourcePackage: s.source);
    }
    // 系统分享附件（P1-11）。
    while (_pendingSharedAttachments.isNotEmpty) {
      final a = _pendingSharedAttachments.removeAt(0);
      await QuickEntrySheet.show(
        state.context,
        initialAttachment: a.ref,
        attachmentSession: a.session,
      );
    }
    // 通知「完成」action：解锁后消费前需用户确认（P2-3），避免刚解锁就被静默改数据
    // 并弹出一条「已完成」确认通知。先消费其它意图，最后再处理完成类（弹确认框）。
    if (_pendingCompleteTaskIds.isNotEmpty) {
      await _confirmPendingCompletes(state);
    }
    // U3：习惯「打卡」action——幂等正向，直接补打、无需确认框。
    while (_pendingHabitCheckInIds.isNotEmpty) {
      _doHabitCheckIn(state, _pendingHabitCheckInIds.removeAt(0));
    }
  }

  /// P2-3：解锁后消费暂存的「完成」action 前，先弹确认对话框，让用户确认是否真的完成。
  /// 任务在确认窗口期间被删除则跳过该项；用户取消则整体丢弃（不静默执行）。
  Future<void> _confirmPendingCompletes(NavigatorState state) async {
    final provider =
        Provider.of<TaskProvider>(state.context, listen: false);
    final ids = List<String>.from(_pendingCompleteTaskIds);
    _pendingCompleteTaskIds.clear();
    final titles = ids
        .map((id) => provider.byId(id)?.title)
        .where((t) => t != null)
        .cast<String>()
        .toList();
    if (titles.isEmpty) return; // 任务已不存在，直接丢弃
    final msg = titles.length == 1
        ? '是否完成「${titles.first}」？'
        : '是否完成以下 ${titles.length} 个任务？\n${titles.map((t) => '· $t').join('\n')}';
    final confirmed = await showDialog<bool>(
      context: state.context,
      builder: (dctx) => AlertDialog(
        title: const Text('完成通知任务'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('完成'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      for (final id in ids) {
        _doComplete(state, id);
      }
    }
  }

  @override
  void dispose() {
    try {
      _idleTimer?.cancel();
    } catch (_) {}
    _idleTimer = null;
    // U4：卸载时清掉 Tab 跳转钩子，避免悬浮引用。
    AppNav.onJumpToTab = null;
    try {
      _appLock.removeListener(_onAppLockChanged);
    } catch (_) {
      // Provider 可能已被销毁（极端路径），忽略。
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台：若启用了应用锁，重新上锁，下次交互前需验证（A4）。
    if (state == AppLifecycleState.resumed) {
      try {
        Provider.of<AppLockProvider>(context, listen: false).onResumed();
      } catch (_) {}
      // P1-2：回到前台后立即重置空闲计时（此时若已锁定则由 AppLockGate 接管，定时器不启动）。
      try {
        _resetIdleTimer();
      } catch (_) {}
      // P0-4：切回前台时结算「专注被打断」次数（离开超阈值才计数，并弹挽留通知）。
      try {
        Provider.of<FocusProvider>(context, listen: false).noteAppResumed();
      } catch (_) {}
      // P1-8（部分修复）：简报正文是「调度时烘焙」的，若当天一直没打开 App，
      // 到点弹出的会是启动那刻的旧数据。这里在每次回到前台时用最新 Provider
      // 状态重烘焙并重排，使简报反映「最后一次打开 App 时」的真实数据。
      // 局限：完全不开 App 的整天仍无法刷新——那需要在触发前用后台闹钟重烘焙，
      // 属更大改动，留待后续。scheduleBriefing 内部会把时刻推到下一次未来出现，
      // 故重排绝不会导致简报立即弹出。
      try {
        final task = Provider.of<TaskProvider>(context, listen: false);
        if (task.notificationsEnabled) {
          rescheduleBriefings(
            task,
            Provider.of<FocusProvider>(context, listen: false),
            Provider.of<HabitProvider>(context, listen: false),
          );
          // P1-7：挽留正文同样是「调度时烘焙」，回到前台时用最新打卡状态重排，
          // 否则白天打完卡后 23:00 仍会误报「还没打卡」。cancel/schedule 由函数
          // 内部按当前漏卡情况自行决定，无漏卡时会撤掉已排的通知。
          rescheduleHabitNudge(
            Provider.of<HabitProvider>(context, listen: false),
            enabled: task.habitNudgeEnabled,
            nudgeMinute: task.habitNudgeMinute,
          );
        }
      } catch (_) {}
    }
    // 进程即将转入后台/被杀：把主题首选项重新落盘，规避 shared_preferences.apply()
    // 在激进 ROM 上杀进程时丢写（纯黑背景等唯一非默认项最易暴露）。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // 进程即将转入后台/被杀：把所有 Provider / 服务的首选项重新落盘，
      // 规避 shared_preferences.apply() 在激进 ROM（ColorOS 等）上杀进程时丢写。
      try {
        Provider.of<ThemeProvider>(context, listen: false).persist();
      } catch (_) {}
      // P0-4：先记下切出时刻（供切回时判定是否构成一次打断），再落盘。
      try {
        Provider.of<FocusProvider>(context, listen: false).noteAppPaused();
      } catch (_) {}
      try {
        Provider.of<FocusProvider>(context, listen: false).persist();
      } catch (_) {}
      try {
        Provider.of<OnboardingProvider>(context, listen: false).persist();
      } catch (_) {}
      try {
        FocusAudioService.instance.persist();
      } catch (_) {}
    }
  }

  /// P1-9：Ctrl/Cmd+F —— 切回首页并聚焦搜索框。若当前不在首页，先切 Tab，
  /// 待首帧后首页挂载再从外部触发其搜索聚焦（首页状态需先重建）。
  void _focusHomeSearch() {
    if (_index != 0) setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _homeKey.currentState?.focusSearch();
    });
  }

  /// P1-9：Esc —— 优先关闭最上层模态路由（快速录入层 / 命令面板 / 任务详情页），
  /// 否则若首页处于搜索态则退出搜索。与 WidgetsApp 默认「Esc 关闭」行为保持一致。
  void _handleEscape() {
    final nav = _navigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    if (_homeSearching) {
      _homeKey.currentState?.exitSearch();
    }
  }

  /// P1-6：`Cmd/Ctrl+Enter` 与命令面板 `/done` **共用**的落地逻辑。
  /// 返回实际完成条数。
  ///
  /// 兜底：选中态只存在于首页，在其它 Tab 上触发时给出明确提示而非静默失败；
  /// 一条都没选中时也提示，避免用户以为命令执行了。
  int _completeSelectedAndNotify(BuildContext context) {
    if (_index != 0) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先回到首页勾选任务')),
        );
      }
      return 0;
    }
    final n = _homeKey.currentState?.completeSelected() ?? 0;
    if (!context.mounted) return n;
    ScaffoldMessenger.of(context).showSnackBar(
      n > 0
          ? SnackBar(content: Text('已完成 $n 条任务'))
          : const SnackBar(content: Text('还没有勾选任何任务')),
    );
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(
        key: _homeKey,
        onSearchingChanged: (v) => setState(() => _homeSearching = v),
        onOpenHabit: () => setState(() => _index = 4),
      ),
      const BoardScreen(),
      const CalendarScreen(),
      const FocusScreen(),
      const HabitScreen(),
      const SettingsScreen(),
    ];
    return Consumer<AppLockProvider>(
      builder: (context, appLock, _) {
        // A4 应用锁：未解锁时渲染独立解锁页，屏蔽主界面交互。
        if (appLock.locked) {
          // F9：应用锁触发瞬间，把根 Navigator 上之前 push 的所有路由（任务详情 /
          // 看板 / 设置等详情页）一次性弹回首页。否则那些详情页会停在栈顶，
          // AppLockGate 仅替换 MainScaffold 内的视图，那些详情页仍然盖在解锁门
          // 之上——侧滑手势 / 系统返回键都会先落到详情页再回到门，应用锁形同虚设。
          // popUntil 用 isFirst 而非 immediatePop，避免 root 路由被一并 pop 掉。
          final nav = _navigatorKey.currentState;
          if (nav != null && nav.canPop()) {
            nav.popUntil((r) => r.isFirst);
          }
          return const AppLockGate();
        }
        final task = context.watch<TaskProvider>();
        final safeMode = task.dbLoadFailed;
        final scaffold = Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: SafeArea(
            child: Column(
              children: [
                // S13 安全模式横幅：数据库加载失败时提示只读、不落盘，引导修复。
                if (safeMode) const _DbSafeModeBanner(),
                Expanded(child: pages[_index]),
              ],
            ),
          ),
          // FAB 仅首页，且搜索时隐藏（搜索页不需要新增任务的加号）
          floatingActionButton: _index == 0 && !_homeSearching
              ? NewTaskFab(
                  onPressed: () => QuickEntrySheet.show(context),
                )
              : null,
          // 搜索时隐藏底部导航（搜索页不需要切换 Tab）
          bottomNavigationBar: _homeSearching
              ? null
              : AppBottomNav(
                  currentIndex: _index,
                  onTap: (i) => setState(() => _index = i),
                ),
        );
        // P1-2：用 Listener 包裹，任何指针交互（点按 / 滚动 / 拖拽 / 悬停）都重置空闲自动锁定计时。
        // 仅在未锁定、应用锁开启时才有定时器，故锁定态下不会因本 Listener 误触解锁。
        final monitored = Listener(
          onPointerDown: (_) => _resetIdleTimer(),
          onPointerMove: (_) => _resetIdleTimer(),
          onPointerHover: (_) => _resetIdleTimer(),
          child: scaffold,
        );
        // P1-9：桌面端挂全局快捷键；移动端原样返回 Scaffold，保持触摸交互不变。
        if (_isDesktopShortcutsEnabled) {
          return Shortcuts(
            shortcuts: _appShortcuts,
            child: Actions(
              actions: {
                _OpenQuickEntryIntent: CallbackAction<_OpenQuickEntryIntent>(
                  onInvoke: (_) {
                    QuickEntrySheet.show(context);
                    return null;
                  },
                ),
                _NewTaskIntent: CallbackAction<_NewTaskIntent>(
                  onInvoke: (_) {
                    QuickEntrySheet.show(context);
                    return null;
                  },
                ),
                _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
                  onInvoke: (_) {
                    _focusHomeSearch();
                    return null;
                  },
                ),
                _OpenCommandPaletteIntent:
                    CallbackAction<_OpenCommandPaletteIntent>(
                  onInvoke: (_) {
                    CommandPalette.show(
                      context,
                      currentIndex: _index,
                      onPick: (i) => setState(() => _index = i),
                      // P1-6：面板内 `/done` 命令落地到同一套逻辑。
                      onCompleteSelected: () =>
                          _completeSelectedAndNotify(context),
                      // F7：动作命令 → 落地回调。未注入的键会被面板标记为
                      // 「当前不可用」并安全禁用，不会成为死链。
                      // 每条都落在宿主已存在的入口，不新增任何 UI/网络代码。
                      actions: {
                        // /new：唤起快速录入（与 FAB 同源，符合报告「唤起快速录入」语义）。
                        'new': () => QuickEntrySheet.show(context),
                        // /trash：跳转回收站。
                        'trash': () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const TrashScreen()),
                            ),
                        // /tags：跳转标签管理。
                        'tags': () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const TagManageScreen()),
                            ),
                        // /export：打开导出面板（本地 Excel/PDF，零联网）。
                        'export': () => ExportSheet.show(context),
                        // /backup：打开备份与恢复面板。
                        'backup': () => BackupSheet.show(context),
                        // P2-7：曾提供 /week（回首页），但命令名与行为不符且与导航类
                        // /home、/today 重复，已移除——避免用户误解为「周视图」。
                      },
                    );
                    return null;
                  },
                ),
                _EscapeIntent: CallbackAction<_EscapeIntent>(
                  onInvoke: (_) {
                    _handleEscape();
                    return null;
                  },
                ),
                _SwitchTabIntent: CallbackAction<_SwitchTabIntent>(
                  onInvoke: (intent) {
                    // 兜底 1：越界下标直接忽略，Tab 数量变动时不会崩。
                    if (intent.index < 0 || intent.index >= _tabCount) {
                      return null;
                    }
                    // 兜底 2：搜索态下底部导航是隐藏的，切 Tab 会让界面失去
                    // 退出搜索的入口，故一律忽略，由 Esc 退出。
                    if (_homeSearching) return null;
                    // 兜底 3：裸数字键在输入框聚焦时放行，避免吞掉字符。
                    // （Cmd/Ctrl+数字 不受此限，见 _buildAppShortcuts 说明。）
                    if (_isEditingText()) return null;
                    if (_index != intent.index) {
                      setState(() => _index = intent.index);
                    }
                    return null;
                  },
                ),
                _CompleteSelectedIntent:
                    CallbackAction<_CompleteSelectedIntent>(
                  onInvoke: (_) {
                    // 输入框聚焦时不拦截，保留 Enter 的换行语义。
                    if (_isEditingText()) return null;
                    _completeSelectedAndNotify(context);
                    return null;
                  },
                ),
              },
              child: monitored,
            ),
          );
        }
        return monitored;
      },
    );
  }
}

/// S13 安全模式横幅：数据库加载失败时显示在顶部，提示用户当前为只读、
/// 修改不会保存，并引导前往「设置 → 备份与恢复」导出/修复，避免误覆盖坏库。
class _DbSafeModeBanner extends StatelessWidget {
  const _DbSafeModeBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded,
                color: scheme.onErrorContainer, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '数据库加载失败，已进入只读安全模式：本次修改不会保存。'
                '请前往「设置 → 备份与恢复」导出或修复数据。',
                style: TextStyle(
                  color: scheme.onErrorContainer,
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A4 应用锁解锁门禁页：全屏居中，调起系统生物识别。
/// 验证成功后由 [AppLockProvider] 置 locked=false，MainScaffold 自动切回主界面。
class AppLockGate extends StatelessWidget {
  const AppLockGate({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    final onBg = scheme.onBackground;
    return Scaffold(
      backgroundColor: scheme.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Symbols.lock, size: 56, color: ext.meta),
                const SizedBox(height: 20),
                Text(
                  '有条',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: onBg,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '已开启应用锁，验证身份以进入',
                  style: TextStyle(fontSize: 14, color: ext.meta),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () => context
                      .read<AppLockProvider>()
                      .authenticate(reason: '验证身份以进入有条'),
                  icon: const Icon(Symbols.fingerprint),
                  label: const Text('使用生物识别解锁'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
