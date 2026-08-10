import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/habit_heatmap.dart';

void main() {
  testWidgets('HabitHeatmap 二值渲染无溢出', (tester) async {
    final days = {
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 2),
      DateTime(2026, 8, 3),
    };
    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: Scaffold(body: HabitHeatmap(checkedDays: days, weeks: 10)),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(HabitHeatmap), findsOneWidget);
  });

  testWidgets('HabitHeatmap 分级渲染无溢出', (tester) async {
    final days = {DateTime(2026, 8, 1), DateTime(2026, 8, 5)};
    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: Scaffold(
        body: HabitHeatmap(
          checkedDays: days,
          levelOf: (_) => 3,
          weeks: 12,
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('StreakBadge 显示当前与最长连续', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: Scaffold(
        body: StreakBadge(current: 7, longest: 20, showLongest: true),
      ),
    ));
    expect(find.text('7 天'), findsOneWidget);
    expect(find.text('最长 20'), findsOneWidget);
  });
}
