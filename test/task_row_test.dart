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

  testWidgets('U2-1：重排场景（constrainTitleWidth）下标题不再被锁 80px', (tester) async {
    // 首页拖拽重排默认常开 → 每行都传 constrainTitleWidth: true。v2.4.1 起该标记
    // 会把标题固定成 80px（长标题只剩 ~8 字、备注/标签 chips 竖排堆叠）。
    // v2.9.1 审计后改为「用 LayoutBuilder 探可用宽」：有界即放开 Expanded，
    // 仅无界/过窄才 80px 兜底。这里用 400dp 有界容器钉死新行为。
    final task = Task(
      id: 'r3',
      title: '一个相当长的任务标题用于验证标题区宽度不再被固定为八十像素',
      priority: Priority.medium,
      category: Category.work,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, extensions: [ext]),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: TaskRow(task: task, constrainTitleWidth: true),
            ),
          ),
        ),
      ),
    );
    final width = tester.getSize(find.text(task.title)).width;
    expect(width, greaterThan(120),
        reason: '可用宽有界时必须放开标题（旧实现恒为 80px）');
  });
}
