import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/quick_entry_sheet.dart';
import 'test_helpers.dart';

/// 快速录入弹层的渲染冒烟测试。
///
/// 该弹层依赖 [appColors]（需要 [AppColorsExt] 主题扩展），因此必须包在带
/// `lightTheme` / `darkTheme` 的 MaterialApp 里——裸 MaterialApp 会因找不到
/// 主题扩展直接 Null check 崩。这里浅/深两套都渲染一遍，并验证「输入即解析」
/// 的实时预览能正常展开，任何布局溢出或构建期抛错都会让用例失败。
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    useMemoryDatabase();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    const ch = MethodChannel('dexterous.com/flutter/local_notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async => null);
  });

  setUp(() {
    LocalDatabase.resetMemoryForTest();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  });

  /// 把弹层直接塞进 Scaffold 渲染（不依赖 showModalBottomSheet 的上下文）
  Future<void> _pump(WidgetTester tester, ThemeData theme) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<TaskProvider>(
        create: (_) => TaskProvider(),
        child: MaterialApp(
          theme: theme,
          home: Scaffold(body: const QuickEntrySheet()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('QuickEntrySheet 浅色渲染无溢出', (tester) async {
    await _pump(tester, lightTheme);
    expect(find.text('快速新建'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QuickEntrySheet 深色渲染无溢出', (tester) async {
    await _pump(tester, darkTheme);
    expect(find.text('快速新建'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入结构化语句后实时展开「已识别」预览', (tester) async {
    await _pump(tester, lightTheme);

    // 模拟用户输入一行自然语言
    await tester.enterText(
      find.byType(TextField),
      '明天下午3点 交周报 !高 #工作',
    );
    await tester.pump();

    // 解析预览区应展开
    expect(find.text('已识别'), findsOneWidget);
    // 优先级片段 chip 文案
    expect(find.text('高优先级'), findsOneWidget);
    // 剥离标记后的纯标题应被识别
    expect(find.text('交周报'), findsOneWidget);
    // 添加按钮此时应可用（标题非空）
    final addBtn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '添加任务'));
    expect(addBtn.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('纯标题输入不展开预览，「添加任务」可用', (tester) async {
    await _pump(tester, lightTheme);

    await tester.enterText(find.byType(TextField), '买牛奶');
    await tester.pump();

    // 没有任何结构化信息 → 预览区收起
    expect(find.text('已识别'), findsNothing);
    expect(find.text('买牛奶'), findsOneWidget);
    final addBtn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '添加任务'));
    expect(addBtn.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空输入时「添加任务」禁用', (tester) async {
    await _pump(tester, lightTheme);
    final addBtn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '添加任务'));
    expect(addBtn.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
