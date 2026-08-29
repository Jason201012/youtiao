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
import 'package:todolist/widgets/command_palette.dart';

/// 全局根导航键：供通知点击回调在脱离 widget context 时仍能 push 路由。
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

/// 冷启动时通知点击先于 MaterialApp 就绪到达，暂存 payload，待 MainScaffold 首帧后消费。
String? _pendingNotificationPayload;

/// 冷启动时点击通知「稍后提醒」action 先于导航器就绪到达，暂存任务/习惯 id。
String? _pendingSnoozeTaskId;
String? _pendingSnoozeHabitId;

/// 冷启动时点击通知「完成」action 先于导航器就绪到达，暂存任务 id。
String? _pendingCompleteTaskId;

/// 冷启动时由「分享」入口转发过来的文本先于导航器就绪到达，暂存，待首帧后弹出预填录入层。
String? _pendingShareText;

/// 冷启动时由「分享」入口转发过来的来源包名（用于预填录入层展示「来自 XX」）。
String? _pendingShareSource;

/// P1-11：冷启动时由「系统分享接收附件」入口（ACTION_SEND + EXTRA_STREAM）先于导航器就绪到达，
/// 暂存已落盘暂存目录的附件引用与其会话 id，待 MainScaffold 首帧后弹出带附件的预填录入层。
AttachmentRef? _pendingSharedAttachment;
String? _pendingSharedSession;

/// 冷启动时由桌面小组件点击任务项拉起（MainActivity 带 EXTRA_TASK_ID），原生经 widget_nav
/// 通道请求直达详情页；导航器未就绪时暂存任务 id，待 MainScaffold 首帧后消费。
String? _pendingWidgetTaskId;

/// 分享建任务：原生侧经 com.example.todolist/share_intent 通道推送文本，在此弹出预填录入层。
/// 导航器未就绪（冷启动）时暂存，待 MainScaffold 首帧后消费。
///
/// P2-8：对「短时间多次相同分享」做节流（500ms 内忽略重复文本），避免恶意 App 反复弹窗骚扰。
/// [sourcePackage] 为分享来源包名（原生侧经 getCallingActivity 取得），用于预填层展示来源。
String? _lastShareText;
int _lastShareAtMs = 0;
void _openQuickEntry(String text, {String? sourcePackage}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (text == _lastShareText && now - _lastShareAtMs < 500) {
    return; // 500ms 内的重复分享直接忽略
  }
  _lastShareText = text;
  _lastShareAtMs = now;
  final state = _navigatorKey.currentState;
  if (state == null) {
    _pendingShareText = text;
    _pendingShareSource = sourcePackage;
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
    if (state == null) {
      // 导航器未就绪（极端冷启动）：暂存，待 MainScaffold 首帧后消费。
      _pendingSharedAttachment = ref;
      _pendingSharedSession = sessionId;
      return;
    }
    await QuickEntrySheet.show(
      state.context,
      initialAttachment: ref,
      attachmentSession: sessionId,
    );
  } catch (e) {
    // 导入失败（超大/非法）：静默忽略，不打扰用户；临时缓存文件由 importSharedFile 清理。
    debugPrint('分享附件导入失败：$e');
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

/// 通知点击回调：解析 task:/habit: 前缀并跳转；导航器未就绪时暂存。
void _handleNotificationTap(String? payload) {
  if (payload == null || payload.isEmpty) return;
  final state = _navigatorKey.currentState;
  if (state != null) {
    _navigateFromPayload(payload, state);
  } else {
    _pendingNotificationPayload = payload;
  }
}

/// 按前缀跳转：task: → 任务详情；habit: → 习惯页；brief: → 简报汇总页。其它忽略。
void _navigateFromPayload(String payload, NavigatorState nav) {
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
void _handleNotificationAction(String? actionId, String? payload) {
  if (actionId == NotificationService.snoozeActionId) {
    final taskId = NotificationService.parseTaskId(payload);
    final habitId = NotificationService.parseHabitId(payload);
    final state = _navigatorKey.currentState;
    if (state != null) {
      _doSnooze(state, taskId, habitId);
    } else if (taskId != null) {
      _pendingSnoozeTaskId = taskId;
    } else if (habitId != null) {
      _pendingSnoozeHabitId = habitId;
    }
    return;
  }
  if (actionId == NotificationService.completeActionId) {
    final taskId = NotificationService.parseTaskId(payload);
    if (taskId == null) return;
    final state = _navigatorKey.currentState;
    if (state != null) {
      _doComplete(state, taskId);
    } else {
      _pendingCompleteTaskId = taskId;
    }
  }
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
          _navigateFromPayload('task:$id', state);
        } else {
          _pendingWidgetTaskId = id;
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
  // 启动后调度全部已设提醒的习惯（失败单个静默，不影响其它功能）。
  try {
    await habit.scheduleAllReminders();
  } catch (e) {
    debugPrint('[HabitProvider] 调度习惯提醒失败：$e');
  }
  // P0-1：启动后按设置重排早晚简报（失败单个静默，不影响其它功能）。
  try {
    await rescheduleBriefings(task, focus, habit);
  } catch (e) {
    debugPrint('[DailyBriefing] 调度简报失败：$e');
  }
  // P1-7：启动后重排「习惯漏卡挽留」（内部已包 try/catch，这里再兜一层）。
  try {
    await rescheduleHabitNudge(habit);
  } catch (e) {
    debugPrint('[HabitNudge] 调度挽留失败：$e');
  }

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
    debugPrint('自动备份触发失败（忽略）：$e\n$s');
  }
  // P2-9：启动兜底清理——删除超过 24h 的附件暂存残留（编辑弹层中途被杀会留下）。
  try {
    await AttachmentService.cleanupStaleStaging();
  } catch (e, s) {
    debugPrint('附件暂存清理失败（忽略）：$e\n$s');
  }
  runApp(MyApp(task: task, focus: focus, theme: theme, habit: habit, onboarding: onboarding, appLock: appLock));
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
    debugPrint('[$name] 启动加载失败（已降级跳过）：$e\n$stack');
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
                debugPrint('主题构建异常，降级为默认：$e');
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 看板统计卡点击后，由 provider 回调切回首页并套用筛选。
    Provider.of<TaskProvider>(context, listen: false).onRequestHome =
        () => setState(() => _index = 0);
    // 任务行「专注」按钮请求跳到专注 Tab（index=3）；FocusProvider 静态回调。
    FocusProvider.jumpToFocusTab = () => setState(() => _index = 3);
    // 消费冷启动期间因点通知而暂存的 payload（导航器此时已就绪）。
    if (_pendingNotificationPayload != null) {
      final p = _pendingNotificationPayload!;
      _pendingNotificationPayload = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final state = _navigatorKey.currentState;
        if (mounted && state != null) _navigateFromPayload(p, state);
      });
    }
    // 消费冷启动期间因点通知「稍后提醒」而暂存的 id（导航器此时已就绪）。
    if (_pendingSnoozeTaskId != null || _pendingSnoozeHabitId != null) {
      final tId = _pendingSnoozeTaskId;
      final hId = _pendingSnoozeHabitId;
      _pendingSnoozeTaskId = null;
      _pendingSnoozeHabitId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final state = _navigatorKey.currentState;
        if (mounted && state != null) _doSnooze(state, tId, hId);
      });
    }
    // 消费冷启动期间因点通知「完成」而暂存的 id（导航器此时已就绪）。
    if (_pendingCompleteTaskId != null) {
      final cId = _pendingCompleteTaskId;
      _pendingCompleteTaskId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final state = _navigatorKey.currentState;
        if (mounted && state != null) _doComplete(state, cId);
      });
    }
    // 消费冷启动期间由「分享」入口转发、暂存的文本：首帧后弹出预填录入层。
    if (_pendingShareText != null) {
      final s = _pendingShareText;
      final src = _pendingShareSource;
      _pendingShareText = null;
      _pendingShareSource = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final state = _navigatorKey.currentState;
        if (mounted && state != null && s != null) {
          QuickEntrySheet.show(state.context, initialText: s, sourcePackage: src);
        }
      });
    }
    // 消费冷启动期间由「系统分享接收附件」入口、暂存的附件：首帧后弹出带附件的预填录入层（P1-11）。
    if (_pendingSharedAttachment != null) {
      final a = _pendingSharedAttachment;
      final sess = _pendingSharedSession;
      _pendingSharedAttachment = null;
      _pendingSharedSession = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final state = _navigatorKey.currentState;
        if (mounted && state != null && a != null) {
          QuickEntrySheet.show(
            state.context,
            initialAttachment: a,
            attachmentSession: sess,
          );
        }
      });
    }
    // 消费冷启动期间由桌面小组件点击任务项、经原生拉起并暂存的 id：首帧后直达详情页。
    if (_pendingWidgetTaskId != null) {
      final wId = _pendingWidgetTaskId;
      _pendingWidgetTaskId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final state = _navigatorKey.currentState;
        if (mounted && state != null && wId != null) {
          _navigateFromPayload('task:$wId', state);
        }
      });
    }
  }

  @override
  void dispose() {
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
              child: scaffold,
            ),
          );
        }
        return scaffold;
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
