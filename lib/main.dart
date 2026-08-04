import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/background_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/bottom_nav.dart';
import 'package:todolist/widgets/new_task_fab.dart';
import 'package:todolist/widgets/new_task_sheet.dart';
import 'package:todolist/screens/home_screen.dart';
import 'package:todolist/screens/board_screen.dart';
import 'package:todolist/screens/calendar_screen.dart';
import 'package:todolist/screens/focus_screen.dart';
import 'package:todolist/screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  final provider = TaskProvider();
  await provider.load();
  final focus = FocusProvider();
  await focus.load();
  // 启动前台守护（若用户在设置里开启）：保证划掉后台后定时提醒仍准时送达
  if (provider.backgroundGuardEnabled) {
    await BackgroundService.instance.start();
  }
  runApp(MyApp(provider: provider, focus: focus));
}

class MyApp extends StatelessWidget {
  final TaskProvider provider;
  final FocusProvider focus;
  const MyApp({super.key, required this.provider, required this.focus});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: focus,
      child: ChangeNotifierProvider.value(
        value: provider,
        child: Consumer<TaskProvider>(
          builder: (context, provider, _) {
            return MaterialApp(
              title: '有条',
              themeMode: provider.effectiveThemeMode,
              theme: lightTheme,
              darkTheme: darkTheme,
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
          },
        ),
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
      const SettingsScreen(),
      const FocusScreen(),
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
