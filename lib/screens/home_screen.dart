import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/task_row.dart';
import 'package:todolist/widgets/new_task_sheet.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Consumer<TaskProvider>(
      builder: (context, provider, _) {
        final tasks = provider.tasks;
        final today = tasks.where((t) => !t.done).toList();
        final done = tasks.where((t) => t.done).toList();
        return Column(
          children: [
            const TopAppBar(title: '首页'),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppColors.pagePadX,
                  8,
                  AppColors.pagePadX,
                  20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 今天
                    _SectionHeader(
                      title: '今天',
                      count: today.length,
                      chipColor: ext.chip,
                      metaColor: ext.meta,
                    ),
                    ...today.map(
                      (t) => Padding(
                        padding: const EdgeInsets.only(bottom: AppColors.contentGap),
                        child: _DismissibleTask(
                          task: t,
                          onToggle: () => provider.toggleDone(t.id),
                          onLongPress: () => TaskSheet.show(context, task: t),
                          onEdit: () => TaskSheet.show(context, task: t),
                          onDeleted: (removed) => _showUndoSnackBar(context, provider, removed),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 已完成
                    _SectionHeader(
                      title: '已完成',
                      count: done.length,
                      chipColor: ext.chip,
                      metaColor: ext.meta,
                    ),
                    ...done.map(
                      (t) => Padding(
                        padding: const EdgeInsets.only(bottom: AppColors.contentGap),
                        child: _DismissibleTask(
                          task: t,
                          onToggle: () => provider.toggleDone(t.id),
                          onLongPress: () => TaskSheet.show(context, task: t),
                          onEdit: () => TaskSheet.show(context, task: t),
                          onDeleted: (removed) => _showUndoSnackBar(context, provider, removed),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color chipColor;
  final Color metaColor;
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.chipColor,
    required this.metaColor,
  });

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppColors.contentGap),
      child:           Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: onBg)),
              Container(
                height: 19,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: chipColor,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Text('$count',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: metaColor)),
              ),
            ],
          ),
    );
  }
}

/// 可滑动的任务行：
/// - 向右滑（startToEnd）删除任务，删除后回调 onDeleted(removed) 并支持撤销；
/// - 向左滑（endToStart）进入编辑，回调 onEdit（通常是打开编辑面板，不删除）；
/// 长按主体仍打开编辑面板。
class _DismissibleTask extends StatelessWidget {
  final Task task;
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;
  final VoidCallback? onEdit;
  final void Function(Task removed) onDeleted;
  const _DismissibleTask({
    required this.task,
    this.onToggle,
    this.onLongPress,
    this.onEdit,
    required this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final ext = appColors(context);
    return Dismissible(
      key: Key(task.id),
      direction: DismissDirection.horizontal,
      // 向右滑：左侧露出「删除」红色背景
      background: _deleteBg(error, Alignment.centerLeft),
      // 向左滑：右侧露出「编辑」蓝色背景
      secondaryBackground: _editBg(ext.accent, Alignment.centerRight),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          // 向左滑 = 编辑：不让 Dismissible 真正消失，先回弹再打开编辑面板。
          onEdit?.call();
          return false;
        }
        // 向右滑 = 删除：允许 dismiss。
        return true;
      },
      onDismissed: (_) {
        // 只有右滑（startToEnd）会走到这里。
        final removed = context.read<TaskProvider>().deleteTask(task.id);
        if (removed != null) onDeleted(removed);
      },
      child: TaskRow(task: task, onToggle: onToggle, onLongPress: onLongPress),
    );
  }

  Widget _deleteBg(Color error, Alignment align) => Container(
        decoration: BoxDecoration(
          color: error,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
        alignment: align,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Symbols.delete, color: Colors.white, size: 24),
      );

  Widget _editBg(Color accent, Alignment align) => Container(
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
        alignment: align,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Symbols.edit, color: Colors.white, size: 24),
      );
}

/// 删除后底部提示，支持撤销。
void _showUndoSnackBar(BuildContext context, TaskProvider provider, Task removed) {
  ScaffoldMessenger.of(context).clearSnackBars();
  final controller = ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已删除「${removed.title}」'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => provider.undoDelete(),
      ),
      duration: const Duration(seconds: 4),
    ),
  );
  // 兜底：无论是否点击撤销，4 秒后强制收起。
  // 个别 ROM / Flutter 组合下 SnackBar.duration 内部计时器可能不触发，导致常驻不消失，
  // 用独立的 Dart 定时器强制 close() 保证 4 秒消失（已关闭时 close() 为安全空操作）。
  Future.delayed(const Duration(seconds: 4), () {
    controller.close();
  });
}
