import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/background_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/theme_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/onboarding_provider.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 在 init() 前挂上点击回调（init 内部 initialize() 会在冷启动时直接触发）。
  NotificationService.onNotificationTap = _handleNotificationTap;
  await NotificationService.instance.init();

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
  runApp(MyApp(task: task, focus: focus, theme: theme, habit: habit, onboarding: onboarding));
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
  const MyApp({
    super.key,
    required this.task,
    required this.focus,
    required this.theme,
    required this.habit,
    required this.onboarding,
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 进程即将转入后台/被杀：把主题首选项重新落盘，规避 shared_preferences.apply()
    // 在激进 ROM 上杀进程时丢写（纯黑背景等唯一非默认项最易暴露）。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      try {
        Provider.of<ThemeProvider>(context, listen: false).persist();
      } catch (_) {
        // 持久化失败不影响退出。
      }
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
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(child: pages[_index]),
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
  }
}
