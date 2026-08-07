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
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/bottom_nav.dart';
import 'package:todolist/widgets/new_task_fab.dart';
import 'package:todolist/widgets/new_task_sheet.dart';
import 'package:todolist/screens/home_screen.dart';
import 'package:todolist/screens/board_screen.dart';
import 'package:todolist/screens/calendar_screen.dart';
import 'package:todolist/screens/focus_screen.dart';
import 'package:todolist/screens/habit_screen.dart';
import 'package:todolist/screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();

  final task = TaskProvider();
  await _safeLoad(task, 'TaskProvider');
  final focus = FocusProvider();
  await _safeLoad(focus, 'FocusProvider');
  final theme = ThemeProvider();
  await _safeLoad(theme, 'ThemeProvider');
  final habit = HabitProvider();
  await _safeLoad(habit, 'HabitProvider');

  // 专注结束回填累计专注时长到关联任务（任务行展示「已专注 X 分钟」）。
  focus.onFocusRecorded = (taskId, sec) => task.addFocusSec(taskId, sec);
  // 启动前台守护（若用户在设置里开启）：保证划掉后台后定时提醒仍准时送达
  if (task.backgroundGuardEnabled) {
    await BackgroundService.instance.start();
  }
  runApp(MyApp(task: task, focus: focus, theme: theme, habit: habit));
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
  const MyApp({
    super.key,
    required this.task,
    required this.focus,
    required this.theme,
    required this.habit,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: task),
        ChangeNotifierProvider.value(value: focus),
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: habit),
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
                home: const MainScaffold(),
              );
              } catch (e) {
                // buildThemes 或 DynamicColorBuilder 异常时降级为默认主题。
                debugPrint('主题构建异常，降级为默认：$e');
                final fallback = theme.buildThemes(null, null);
                return MaterialApp(
                  title: '有条',
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
                  home: const MainScaffold(),
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

class _MainScaffoldState extends State<MainScaffold> {
  int _index = 0;
  bool _homeSearching = false;

  @override
  void initState() {
    super.initState();
    // 看板统计卡点击后，由 provider 回调切回首页并套用筛选。
    Provider.of<TaskProvider>(context, listen: false).onRequestHome =
        () => setState(() => _index = 0);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(
        onSearchingChanged: (v) => setState(() => _homeSearching = v),
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
              onPressed: () => TaskSheet.show(context),
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
