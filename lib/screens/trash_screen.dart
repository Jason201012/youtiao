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
                                '${t.category.label} ｜ ${_deletedLabel(t.deletedAt, provider.trashRemainingDays(t), provider.trashRetentionDays)}',
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
                          // U1-1（v2.9.5 审计）：两钮此前都是 36dp——低于
                          // Material 48dp 最小可点目标，且两个语义相反的图标
                          // 紧邻，「恢复」与「彻底删除」只差 36 像素，极易点错。
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                        ),
                        // 彻底删除
                        //
                        // U1-1：单条彻底删除此前**无任何二次确认**——一次误触即永久
                        // 删除任务**及其附件目录**（`permanentDelete` 连附件一起删），
                        // 而同屏「清空回收站」尚有确认弹窗（见 [_confirmClear]），
                        // 单条删除的保护反而更弱，逻辑上说不通。
                        // 现补确认（附件是异步 FS 统计，弹窗文案统一按「含附件」
                        // 表述，不为此引入同步 IO）。
                        //
                        // U3-4（v2.9.6 审计）：与「恢复」钮之间拉开 12px——语义相反
                        // 的两个 48dp 按钮此前零间距紧邻，中心距仅 48px，极易点错。
                        const SizedBox(width: 12),
                        IconButton(
                          onPressed: () =>
                              _confirmPermanentDelete(context, provider, t),
                          icon: Icon(Symbols.delete_forever,
                              size: 22, color: error),
                          tooltip: '彻底删除',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
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

  /// P1-12：副标题含剩余天数提示。[remaining] 为距永久删除的天数（-1=永不清理）。
  String _deletedLabel(DateTime? d, int remaining, int retention) {
    final del = d != null ? '删除于 ${_fmt(d)}' : '已删除';
    if (retention < 0) return '$del（永不清理）';
    if (remaining <= 0) return '今天到期 · $del';
    return '剩余 $remaining 天 · $del';
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

  /// U1-1（v2.9.5 审计）：单条彻底删除的二次确认。
  ///
  /// 此前单条删除**无确认**、两钮仅 36dp 且语义相反的图标紧邻，一次误触即永久
  /// 丢失任务及其附件；而同屏「清空回收站」反倒有确认——保护强度与风险倒挂。
  /// 撤销在这里并不可行（回收站是终态区），确认弹窗是唯一可行的兜底。
  void _confirmPermanentDelete(
      BuildContext context, TaskProvider provider, Task t) {
    final name = t.title.trim().isEmpty ? '无标题任务' : t.title.trim();
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('彻底删除？'),
        content: Text('「$name」将被永久删除，其附件也会一并删除，'
            '此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () {
              Navigator.pop(d);
              provider.permanentDelete(t.id);
            },
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
  }
}
