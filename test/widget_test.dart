import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/main.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/task_provider.dart';

/// 构建冒烟测试：确保 MyApp 能正常初始化并渲染 5 个底部 Tab，
/// 任何在 build 期抛错（依赖缺失、布局崩溃）都会被这里捕获。
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('MyApp 渲染 5 个底部导航 Tab', (tester) async {
    await tester.pumpWidget(
      MyApp(provider: TaskProvider(), focus: FocusProvider()),
    );
    await tester.pump();

    expect(find.text('首页'), findsWidgets);
    expect(find.text('看板'), findsWidgets);
    expect(find.text('日历'), findsWidgets);
    expect(find.text('专注'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
  });
}
