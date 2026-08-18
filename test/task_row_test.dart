import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/task_row.dart';

void main() {
  // 模拟一套浅色 AppColorsExt（仅用于让 TaskRow 拿到 extension，不参与断言）。
  final ext = AppColorsExt.fromColors(accent: Colors.blue, isDark: false);

  Widget _wrap(Task task) => MaterialApp(
        theme: ThemeData(useMaterial3: true, extensions: [ext]),
        home: Scaffold(body: TaskRow(task: task)),
      );

  testWidgets('空标题重复任务渲染 (无标题)，不再完全空白', (tester) async {
    final task = Task(
      id: 'r1',
      title: '',
      priority: Priority.medium,
      category: Category.life,
      repeat: RepeatType.daily,
      repeatMinute: 7 * 60,
      dueDate: DateTime(2026, 8, 15, 23, 59),
    );
    await tester.pumpWidget(_wrap(task));
    // v2.4.0 起：空标题必须以占位文案出现，而非一行纯空白。
    expect(find.text('(无标题)'), findsOneWidget);
    // 重复规则信息（图标）仍正常渲染，标题占位不影响分区元信息。
    expect(find.byType(Icon), findsWidgets);
  });

  testWidgets('有标题重复任务渲染真实标题', (tester) async {
    final task = Task(
      id: 'r2',
      title: '晨间喝水',
      priority: Priority.medium,
      category: Category.life,
      repeat: RepeatType.daily,
      repeatMinute: 7 * 60,
    );
    await tester.pumpWidget(_wrap(task));
    expect(find.text('晨间喝水'), findsOneWidget);
    expect(find.text('(无标题)'), findsNothing);
  });
}
