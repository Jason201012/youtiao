import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/background_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/bottom_nav.dart';
import 'package:todolist/widgets/new_task_fab.dart';
import 'package:todolist/widgets/new_task_sheet.dart';
import 'package:todolist/screens/home_screen.dart';
import 'package:todolist/screens/board_screen.dart';
import 'package:todolist/screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  final provider = TaskProvider();
  await provider.load();
  // 启动前台守护（若用户在设置里开启）：保证划掉后台后定时提醒仍准时送达
  if (provider.backgroundGuardEnabled) {
    await BackgroundService.instance.start();
  }
  runApp(MyApp(provider: provider));
}

class MyApp extends StatelessWidget {
  final TaskProvider provider;
  const MyApp({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
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
  final _pages = const [HomeScreen(), BoardScreen(), SettingsScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(child: _pages[_index]),
      // FAB 仅首页
      floatingActionButton: _index == 0
          ? NewTaskFab(
              onPressed: () => TaskSheet.show(context),
            )
          : null,
      bottomNavigationBar: AppBottomNav(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}
