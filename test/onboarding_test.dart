import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/state/onboarding_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/screens/onboarding_screen.dart';
import 'package:todolist/theme/app_theme.dart';
import 'test_helpers.dart';

/// 引导页相关测试：OnboardingProvider 标志位 + 3 屏 UI 交互。
void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());

  setUp(() {
    useMemoryDatabase();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    // 屏蔽 flutter_local_notifications 的 method channel（headless 无原生实现）。
    const ch = MethodChannel('dexterous.com/flutter/local_notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async => null);
  });

  test('OnboardingProvider 默认未看过；complete 后已看且落盘', () async {
    final p = OnboardingProvider();
    expect(p.hasSeenIntro, isFalse);
    await p.complete();
    expect(p.hasSeenIntro, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarding_seen'), isTrue);
  });

  testWidgets('渲染跳过、页码与「下一步」按钮（屏1 文案）', (tester) async {
    await tester.pumpWidget(_app(OnboardingProvider(), TaskProvider(), onFinished: () {}));
    await tester.pumpAndSettle();
    expect(find.text('跳过 ›'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('有条'), findsOneWidget);
    // 屏1「数据只存在你手机上\n无需账号 · 不上传云端」是单个多行 Text，
    // find.text 为精确全串匹配，故用 textContaining 校验关键短语。
    expect(find.textContaining('数据只存在你手机上'), findsOneWidget);
  });

  testWidgets('下一步翻页：屏1→屏2→屏3，末页按钮变「开始使用」', (tester) async {
    await tester.pumpWidget(_app(OnboardingProvider(), TaskProvider(), onFinished: () {}));
    await tester.pumpAndSettle();

    // 屏1 → 屏2
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('这个 App 能帮你'), findsOneWidget);
    expect(find.text('速记建单'), findsOneWidget);
    expect(find.text('日历'), findsOneWidget);

    // 屏2 → 屏3
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('开启提醒'), findsOneWidget);
    // 末页主按钮文案为「开始使用」
    expect(find.text('开始使用'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
  });

  testWidgets('点击跳过 → 回调触发且标记已看过', (tester) async {
    var finished = false;
    final ob = OnboardingProvider();
    await tester.pumpWidget(_app(ob, TaskProvider(), onFinished: () => finished = true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('跳过 ›'));
    await tester.pumpAndSettle();

    expect(finished, isTrue);
    expect(ob.hasSeenIntro, isTrue);
  });

  testWidgets('屏3 选「从零开始」→ 开始使用 清空示例任务', (tester) async {
    var finished = false;
    final task = TaskProvider(); // 构造时含 7 条硬编码 mock
    expect(task.tasks.length, 7);
    final ob = OnboardingProvider();
    await tester.pumpWidget(_app(ob, task, onFinished: () => finished = true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 选「从零开始」再开始
    await tester.tap(find.text('从零开始'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    expect(finished, isTrue);
    expect(ob.hasSeenIntro, isTrue);
    expect(task.tasks.isEmpty, isTrue); // 示例已清空
  });

  testWidgets('屏3 选「保留示例」→ 开始使用 保留 7 条示例', (tester) async {
    var finished = false;
    final task = TaskProvider();
    final ob = OnboardingProvider();
    await tester.pumpWidget(_app(ob, task, onFinished: () => finished = true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 默认即为「保留示例」，直接开始
    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    expect(finished, isTrue);
    expect(task.tasks.length, 7); // 示例保留
  });
}

/// 用真实主题（含 AppColorsExt）包裹引导页，并注入 TaskProvider / OnboardingProvider。
/// [onFinished] 注入后，完成流程只回调、不真正导航到主页，便于断言。
Widget _app(OnboardingProvider onboarding, TaskProvider task, {VoidCallback? onFinished}) {
  return MaterialApp(
    theme: lightTheme,
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: task),
        ChangeNotifierProvider.value(value: onboarding),
      ],
      child: OnboardingScreen(onFinished: onFinished),
    ),
  );
}
