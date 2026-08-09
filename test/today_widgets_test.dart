import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/today.dart';
import 'package:todolist/screens/today_screen.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/today_card.dart';
import 'test_helpers.dart';

/// 今日聚合视图的渲染冒烟测试。
///
/// 分享长图是「固定宽度 + 强制主题 + 关闭字号缩放」的离屏渲染，最容易在真机
/// 上撞 RenderFlex overflow 却在开发机看不出来；这里把浅/深两套都渲染一遍，
/// 任何布局溢出/构建期抛错都会让用例直接失败。
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    useMemoryDatabase();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    const ch = MethodChannel('dexterous.com/flutter/local_notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async => null);
  });

  setUp(() {
    LocalDatabase.resetMemoryForTest();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
  });

  TodayAggregate fixture() {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    Task t(String id, String title, {DateTime? due, bool done = false}) => Task(
          id: id,
          title: title,
          priority: Priority.high,
          category: Category.work,
          dueDate: due,
          status: done ? TaskStatus.done : TaskStatus.todo,
        );
    final habit = Habit(id: 'h1', title: '晨跑', emoji: '🏃', createdAt: day);
    return TodayAggregate(
      date: day,
      pendingTasks: [
        t('1', '写完今日聚合视图的收尾测试', due: day.add(const Duration(hours: 10))),
        t('2', '无截止时间的长标题任务用来验证单行省略是否生效不会撑破卡片'),
      ],
      completedToday: 3,
      todoCount: 5,
      focusMinutes: 85,
      pomodoroCount: 4,
      focusGoalMinutes: 120,
      sessions: [
        FocusSession(
          id: 's1',
          plannedSec: 1500,
          durationSec: 1500,
          completed: true,
          phase: FocusPhase.focus,
          startedAt: day.add(const Duration(hours: 9)),
          endedAt: day.add(const Duration(hours: 9, minutes: 25)),
          taskTitle: '写代码',
        ),
      ],
      habits: [
        TodayHabitStatus(
          habit: habit,
          shouldCheckIn: true,
          checked: true,
          streak: 7,
        ),
      ],
    );
  }

  testWidgets('TodayShareCard 浅色渲染无溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(child: TodayShareCard(today: fixture())),
      ),
    );
    await tester.pump();
    expect(find.text('今日核心'), findsOneWidget);
    expect(find.text('今日待办'), findsWidgets); // 分区标题 + 核心指标标签
    expect(tester.takeException(), isNull);
  });

  testWidgets('TodayShareCard 深色渲染无溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: TodayShareCard(today: fixture(), dark: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('今日专注'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TodayCard 首页摘要卡渲染并可点击', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: lightTheme,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: TodayCard(today: fixture(), onTap: () => tapped++),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('今日'), findsOneWidget);
    await tester.tap(find.byType(TodayCard));
    expect(tapped, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TodayScreen 能在真实 Provider 下渲染', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => TaskProvider()),
          ChangeNotifierProvider(create: (_) => FocusProvider()),
          ChangeNotifierProvider(create: (_) => HabitProvider()),
        ],
        // 必须带上 App 主题：TodayScreen 依赖 AppColorsExt 主题扩展
        child: MaterialApp(theme: lightTheme, home: const TodayScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('今日'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
