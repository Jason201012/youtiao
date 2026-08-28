import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/background_service.dart';
import 'package:todolist/state/task_provider.dart';
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
import 'package:todolist/screens/task_detail_screen.dart';

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

/// 冷启动时由桌面小组件点击任务项拉起（MainActivity 带 EXTRA_TASK_ID），原生经 widget_nav
/// 通道请求直达详情页；导航器未就绪时暂存任务 id，待 MainScaffold 首帧后消费。
String? _pendingWidgetTaskId;

/// 分享建任务：原生侧经 com.example.todolist/share_intent 通道推送文本，在此弹出预填录入层。
/// 导航器未就绪（冷启动）时暂存，待 MainScaffold 首帧后消费。
void _openQuickEntry(String text) {
  final state = _navigatorKey.currentState;
  if (state == null) {
    _pendingShareText = text;
    return;
  }
  QuickEntrySheet.show(state.context, initialText: text);
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

/// 按前缀跳转：task: → 任务详情；habit: → 习惯页。其它（专注完成/测试）忽略。
void _navigateFromPayload(String payload, NavigatorState nav) {
  if (payload.startsWith(NotificationService.payloadTaskPrefix)) {
    final id = payload.substring(NotificationService.payloadTaskPrefix.length);
    nav.push(MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: id)));
  } else if (payload.startsWith(NotificationService.payloadHabitPrefix)) {
    nav.push(MaterialPageRoute(builder: (_) => const HabitScreen()));
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
      final text = call.arguments;
      if (text is String && text.isNotEmpty) _openQuickEntry(text);
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
      _pendingShareText = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final state = _navigatorKey.currentState;
        if (mounted && state != null && s != null) {
          QuickEntrySheet.show(state.context, initialText: s);
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

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(
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
        return Scaffold(
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
