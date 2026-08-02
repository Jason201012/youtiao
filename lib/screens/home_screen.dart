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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// 是否处于多选模式
  bool _selecting = false;

  /// 已选中的任务 id（多选模式）
  final Set<String> _selected = {};

  /// 长按进入多选模式，并把当前任务预选上。
  void _enterSelect(Task task) {
    setState(() {
      _selecting = true;
      _selected.add(task.id);
    });
  }

  /// 点选 / 取消点选某项
  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
      if (_selected.isEmpty) _selecting = false;
    });
  }

  /// 退出多选模式
  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  /// 全选 / 反选当前可见任务（今天 + 已完成）
  void _toggleSelectAll(List<Task> visible) {
    final allSelected = visible.isNotEmpty &&
        visible.every((t) => _selected.contains(t.id));
    setState(() {
      if (allSelected) {
        _selected.clear();
        _selecting = false;
      } else {
        _selected.addAll(visible.map((t) => t.id));
      }
    });
  }

  /// 批量删除已选项，并弹出带撤销的提示
  void _deleteSelected(BuildContext context) {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final count = ids.length;
    final provider = context.read<TaskProvider>();
    provider.deleteTasks(ids);
    _exitSelect();
    _showBatchUndoSnackBar(context, provider, count);
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    final onBg = scheme.onBackground;
    final error = scheme.error;

    return Consumer<TaskProvider>(
      builder: (context, provider, _) {
        final tasks = provider.tasks;
        final today = tasks.where((t) => !t.done).toList();
        final done = tasks.where((t) => t.done).toList();
        final visible = [...today, ...done];

        final appBar = _selecting
            ? SizedBox(
                height: 64,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppColors.pagePadX),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      IconButton(
                        onPressed: _exitSelect,
                        icon: Icon(Symbols.close, size: 24, color: onBg),
                        splashRadius: 20,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '已选 ${_selected.length}',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: onBg,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => _toggleSelectAll(visible),
                        child: Text(
                          '全选',
                          style: TextStyle(fontSize: 15, color: primary),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        onPressed: () => _deleteSelected(context),
                        icon: Icon(Symbols.delete, size: 24, color: error),
                        splashRadius: 20,
                        tooltip: '删除所选',
                      ),
                    ],
                  ),
                ),
              )
            : const TopAppBar(title: '首页');

        return Column(
          children: [
            appBar,
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
                        padding:
                            const EdgeInsets.only(bottom: AppColors.contentGap),
                        child: _DismissibleTask(
                          task: t,
                          selecting: _selecting,
                          selected: _selected.contains(t.id),
                          onToggle: () => provider.toggleDone(t.id),
                          onLongPress: () => _enterSelect(t),
                          onEdit: () => TaskSheet.show(context, task: t),
                          onSelect: () => _toggleSelect(t.id),
                          onDeleted: (removed) =>
                              _showUndoSnackBar(context, provider, removed),
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
                        padding:
                            const EdgeInsets.only(bottom: AppColors.contentGap),
                        child: _DismissibleTask(
                          task: t,
                          selecting: _selecting,
                          selected: _selected.contains(t.id),
                          onToggle: () => provider.toggleDone(t.id),
                          onLongPress: () => _enterSelect(t),
                          onEdit: () => TaskSheet.show(context, task: t),
                          onSelect: () => _toggleSelect(t.id),
                          onDeleted: (removed) =>
                              _showUndoSnackBar(context, provider, removed),
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title,
              style:
                  TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: onBg)),
          Container(
            height: 19,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: chipColor,
              borderRadius: BorderRadius.circular(AppColors.chipRadius),
            ),
            child: Text('$count',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500, color: metaColor)),
          ),
        ],
      ),
    );
  }
}

/// 可滑动的任务行：
/// - 向右滑（startToEnd）删除任务，删除后回调 onDeleted(removed) 并支持撤销；
/// - 向左滑（endToStart）进入编辑，回调 onEdit（通常是打开编辑面板，不删除）；
/// - 长按主体进入多选模式（onLongPress），由父级控制 [selecting]；
/// - [selecting] 为 true 时：禁用滑动手势，整行点击切换选中（onSelect）。
class _DismissibleTask extends StatelessWidget {
  final Task task;
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;
  final VoidCallback? onEdit;
  final VoidCallback? onSelect;
  final void Function(Task removed) onDeleted;
  const _DismissibleTask({
    required this.task,
    this.selecting = false,
    this.selected = false,
    this.onToggle,
    this.onLongPress,
    this.onEdit,
    this.onSelect,
    required this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final row = TaskRow(
      task: task,
      onToggle: selecting ? null : onToggle,
      onLongPress: selecting ? null : onLongPress,
      selecting: selecting,
      selected: selected,
      onSelect: selecting ? onSelect : null,
    );

    // 多选模式下不响应滑动手势
    if (selecting) return row;

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
      child: row,
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

/// 单个删除后底部提示，支持撤销。
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
  Future.delayed(const Duration(seconds: 4), () {
    controller.close();
  });
}

/// 批量删除后底部提示，支持整体撤销。
void _showBatchUndoSnackBar(
    BuildContext context, TaskProvider provider, int count) {
  ScaffoldMessenger.of(context).clearSnackBars();
  final controller = ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已删除 $count 个任务'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => provider.undoDelete(),
      ),
      duration: const Duration(seconds: 4),
    ),
  );
  Future.delayed(const Duration(seconds: 4), () {
    controller.close();
  });
}
