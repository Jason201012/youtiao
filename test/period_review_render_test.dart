import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/period_review.dart';
import 'package:todolist/screens/period_review_screen.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/period_review_card.dart';
import 'test_helpers.dart';

/// 月报 / 年报视图的渲染冒烟测试。
///
/// 分享长图是「固定宽度 + 强制主题 + 关闭字号缩放」的离屏渲染，最容易在真机上撞
/// RenderFlex overflow 却在开发机看不出来；这里把月报 / 年报 + 浅 / 深两套都渲染一遍，
/// 任何布局溢出 / 构建期抛错都会让用例直接失败。
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

  PeriodReview _fixture(ReviewPeriod period) {
    final task = TaskProvider();
    final focus = FocusProvider();
    final habit = HabitProvider();
    return PeriodReview.fromProviders(task, focus, habit, period: period);
  }

  testWidgets('PeriodReviewScreen 月报 能在真实 Provider 下渲染', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => TaskProvider()),
          ChangeNotifierProvider(create: (_) => FocusProvider()),
          ChangeNotifierProvider(create: (_) => HabitProvider()),
        ],
        child:
            MaterialApp(theme: lightTheme, home: const PeriodReviewScreen()),
      ),
    );
    await tester.pump();
    expect(find.byType(PeriodReviewScreen), findsOneWidget);
    expect(find.text('习惯达成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PeriodReviewScreen 切换到年报后重新渲染', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => TaskProvider()),
          ChangeNotifierProvider(create: (_) => FocusProvider()),
          ChangeNotifierProvider(create: (_) => HabitProvider()),
        ],
        child:
            MaterialApp(theme: lightTheme, home: const PeriodReviewScreen()),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('年报'));
    await tester.pump();
    expect(find.text('习惯达成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PeriodReviewShareCard 浅色渲染无溢出', (tester) async {
    final r = _fixture(ReviewPeriod.month);
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(child: PeriodReviewShareCard(review: r)),
      ),
    );
    await tester.pump();
    expect(find.text('习惯达成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PeriodReviewShareCard 深色渲染无溢出', (tester) async {
    final r = _fixture(ReviewPeriod.year);
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: PeriodReviewShareCard(review: r, dark: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('习惯达成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
