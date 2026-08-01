// 基础冒烟测试：构建 App 并验证首页正常显示。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/main.dart';
import 'package:todolist/state/task_provider.dart';

void main() {
  testWidgets('App builds and shows home screen', (WidgetTester tester) async {
    await tester.pumpWidget(MyApp(provider: TaskProvider()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
