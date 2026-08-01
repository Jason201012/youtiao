import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';

/// 回收站：展示已删除（可恢复）的任务，支持恢复、彻底删除、清空。
class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final error = Theme.of(context).colorScheme.error;
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // 顶部栏：返回 + 标题 + 清空
            TopAppBar(
              title: '回收站',
              onBack: () => Navigator.pop(context),
              actions: [
                Consumer<TaskProvider>(
                  builder: (ctx, provider, _) => provider.trash.isEmpty
                      ? const SizedBox.shrink()
                      : GestureDetector(
                          onTap: () => _confirmClear(context, provider),
                          child: Icon(Symbols.delete_sweep, size: 24, color: error),
                        ),
                ),
              ],
            ),
        Expanded(
          child: Consumer<TaskProvider>(
            builder: (context, provider, _) {
              final items = provider.trash;
              if (items.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Symbols.delete_outline, size: 48, color: ext.meta),
                      const SizedBox(height: 12),
                      Text(
                        '回收站为空',
                        style: TextStyle(fontSize: 15, color: ext.meta),
                      ),
                    ],
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppColors.pagePadX,
                  8,
                  AppColors.pagePadX,
                  20,
                ),
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppColors.contentGap),
                itemBuilder: (context, i) {
                  final t = items[i];
                  final prioColor = t.done
                      ? ext.meta
                      : (isDark
                          ? t.priority.darkColor()
                          : t.priority.lightColor());
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(AppColors.cardRadius),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 3,
                          height: 36,
                          margin: const EdgeInsets.only(right: 12),
                          decoration: BoxDecoration(
                            color: prioColor,
                            borderRadius:
                                BorderRadius.circular(AppColors.ringBarRadius),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.title,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: onBg,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${t.category.label} ｜ ${_deletedLabel(t.deletedAt)}',
                                style: TextStyle(fontSize: 12, color: ext.meta),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 恢复
                        IconButton(
                          onPressed: () => provider.restoreFromTrash(t.id),
                          icon: Icon(Symbols.restore_from_trash,
                              size: 22, color: primary),
                          tooltip: '恢复',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        ),
                        // 彻底删除
                        IconButton(
                          onPressed: () => provider.permanentDelete(t.id),
                          icon: Icon(Symbols.delete_forever,
                              size: 22, color: error),
                          tooltip: '彻底删除',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
        ),
      ),
    );
  }

  String _deletedLabel(DateTime? d) {
    if (d == null) return '已删除';
    return '删除于 ${_fmt(d)}';
  }

  String _fmt(DateTime d) {
    final now = DateTime.now();
    final date = d.year == now.year
        ? '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
        : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '$date ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  void _confirmClear(BuildContext context, TaskProvider provider) {
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('清空回收站？'),
        content: const Text('回收站中的任务将被永久删除，且不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(d);
              provider.clearTrash();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}
