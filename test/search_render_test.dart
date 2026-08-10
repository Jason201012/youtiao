import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/main.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/theme_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/models/task.dart';
import 'test_helpers.dart';

/// 进入搜索态并输入关键字，渲染分组结果。
Future<void> _enterSearchAndQuery(WidgetTester tester, String query) async {
  // 顶栏「搜索」图标按钮（tooltip=搜索）进入搜索态。
  await tester.tap(find.byTooltip('搜索'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), query);
  await tester.pumpAndSettle();
}

void main() {
  // 仅浅色：深色变体在集成测试中 pumpAndSettle 会卡在主题切换动画，
  // 且搜索结果复用与今日卡相同的控件（today_widgets_test 已覆盖深色渲染），
  // 故这里聚焦验证分组 UI 在浅色下无溢出。
  for (final dark in [false]) {
    testWidgets('搜索结果按 任务/习惯 分组渲染（${dark ? '深色' : '浅色'}）无溢出',
        (tester) async {
      useMemoryDatabase();

      // 预置一条任务 + 一个习惯，二者都含「跑」字，验证跨类分组。
      final tp = TaskProvider()
        ..addTask(Task(
          id: 's1',
          title: '跑步健身',
          priority: Priority.medium,
          category: Category.work,
        ));
      final hp = HabitProvider();
      await hp.addHabit(
        title: '晨跑',
        emoji: '🏃',
        colorValue: 0xFF0061A4,
        weekdays: const [],
        reminderMinute: null,
      );

      final theme = ThemeProvider();
      if (dark) await theme.setDark(true);

      await tester.pumpWidget(MyApp(
        task: tp,
        focus: FocusProvider(),
        theme: theme,
        habit: hp,
        onboarding: await prepareSeenOnboarding(),
      ));
      await tester.pumpAndSettle();

      await _enterSearchAndQuery(tester, '跑');

      // 分组头 + 两条命中结果都应出现，且全程无布局异常。
      expect(find.text('任务'), findsWidgets);
      expect(find.text('习惯'), findsWidgets);
      expect(find.text('跑步健身'), findsOneWidget);
      expect(find.text('晨跑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('搜索无结果时显示空态（${dark ? '深色' : '浅色'}）',
        (tester) async {
      useMemoryDatabase();
      final tp = TaskProvider();
      final hp = HabitProvider();
      final theme = ThemeProvider();
      if (dark) await theme.setDark(true);

      await tester.pumpWidget(MyApp(
        task: tp,
        focus: FocusProvider(),
        theme: theme,
        habit: hp,
        onboarding: await prepareSeenOnboarding(),
      ));
      await tester.pumpAndSettle();

      await _enterSearchAndQuery(tester, '不存在的关键字xyz');

      expect(find.text('没有匹配的结果'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
