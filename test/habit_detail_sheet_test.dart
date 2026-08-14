import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/screens/habit_screen.dart';
import 'package:todolist/widgets/habit_heatmap.dart';
import 'test_helpers.dart';

void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

void main() {
  setUpAll(_installMocks);
  setUp(() => LocalDatabase.resetMemoryForTest());

  testWidgets('showHabitDetailSheet 打开含单习惯热力图与分享按钮',
      (tester) async {
    final hp = HabitProvider();
    await hp.load();
    await hp.addHabit(
      title: '阅读',
      emoji: '📚',
      colorValue: 1,
      weekdays: [],
    );
    final habit = hp.habits.first;
    await hp.toggleCheckInToday(habit); // 今日已打卡

    await tester.pumpWidget(
      ChangeNotifierProvider<HabitProvider>.value(
        value: hp,
        child: MaterialApp(
          theme: lightTheme,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showHabitDetailSheet(ctx, habit),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 单习惯专属热力图存在
    expect(find.byType(HabitHeatmap), findsWidgets);
    // 分享入口与习惯标题
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('阅读'), findsOneWidget);
    // 今日已打卡时按钮文案
    expect(find.text('今日已打卡'), findsOneWidget);
  });
}
