import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/quick_entry_sheet.dart';

/// P1-13：全局标签管理页
/// - 全库标签聚合列表：每个标签显示「任务数 / 完成率」
/// - 操作：重命名（全库同步替换）、合并（两个标签合一）、归档/取消归档、删除
/// - 新增标签入口
/// - 归档标签在首页筛选不可见，但数据保留
class TagManageScreen extends StatefulWidget {
  const TagManageScreen({super.key});

  @override
  State<TagManageScreen> createState() => _TagManageScreenState();
}

class _TagManageScreenState extends State<TagManageScreen> {
  /// 当前选中的过滤模式：null=全部，false=仅活跃，true=仅归档
  bool? _filterArchived;

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Consumer<TaskProvider>(
      builder: (context, provider, _) {
        final all = provider.allTagsIncludingArchived;
        final archived = provider.archivedTags;

        // 按归档状态分组
        final active = all.where((t) => !archived.contains(t)).toList();
        final archivedList = all.where((t) => archived.contains(t)).toList();

        // 按过滤模式选择显示列表
        List<String> showList;
        if (_filterArchived == null) {
          showList = [...active, ...archivedList];
        } else if (_filterArchived == false) {
          showList = active;
        } else {
          showList = archivedList;
        }

        return Scaffold(
          appBar: const TopAppBar(title: '标签管理'),
          body: Column(
            children: [
              // 过滤切换条
              if (archivedList.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppColors.pagePadX,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      _FilterChip(
                        label: '全部',
                        count: all.length,
                        selected: _filterArchived == null,
                        onTap: () => setState(() => _filterArchived = null),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: '活跃',
                        count: active.length,
                        selected: _filterArchived == false,
                        onTap: () => setState(() => _filterArchived = false),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: '归档',
                        count: archivedList.length,
                        selected: _filterArchived == true,
                        onTap: () => setState(() => _filterArchived = true),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              // 标签列表
              Expanded(
                child: showList.isEmpty
                    ? Center(
                        child: Text(
                          _filterArchived == null
                              ? '暂无标签'
                              : _filterArchived == true
                                  ? '暂无归档标签'
                                  : '暂无活跃标签',
                          style: TextStyle(color: ext.meta),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                          AppColors.pagePadX,
                          8,
                          AppColors.pagePadX,
                          100,
                        ),
                        itemCount: showList.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppColors.contentGap),
                        itemBuilder: (context, i) {
                          final tag = showList[i];
                          final isArchived = archived.contains(tag);
                          final count = provider.tagTaskCount(tag);
                          final rate = provider.tagCompletionRate(tag);
                          final pct = (rate * 100).toStringAsFixed(0);

                          return Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius:
                                  BorderRadius.circular(AppColors.cardRadius),
                            ),
                            child: InkWell(
                              onTap: () => _showTagActions(
                                context, provider, tag, isArchived,
                              ),
                              borderRadius:
                                  BorderRadius.circular(AppColors.cardRadius),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                child: Row(
                                  children: [
                                    // 标签图标
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: isArchived
                                            ? ext.meta.withOpacity(0.12)
                                            : primary.withOpacity(0.12),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                        isArchived
                                            ? Symbols.archive
                                            : Symbols.label,
                                        size: 20,
                                        color: isArchived ? ext.meta : primary,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    // 标签名称 + 统计
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  tag,
                                                  style: TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w500,
                                                    color: onBg,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              if (isArchived) ...[
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: ext.meta
                                                        .withOpacity(0.12),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            4),
                                                  ),
                                                  child: Text(
                                                    '已归档',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: ext.meta,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '$count 条任务 · ${rate > 0 ? '已完成 $pct%' : '暂无完成'}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: ext.meta,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    // 完成率进度条
                                    if (count > 0 && rate > 0)
                                      SizedBox(
                                        width: 36,
                                        child: CircularProgressIndicator(
                                          value: rate,
                                          strokeWidth: 3,
                                          color: primary,
                                          backgroundColor:
                                              ext.meta.withOpacity(0.15),
                                        ),
                                      ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Symbols.chevron_right,
                                      size: 20,
                                      color: ext.meta,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
          // 新增标签
          floatingActionButton: FloatingActionButton(
            onPressed: () => _showAddTagDialog(context, provider),
            child: const Icon(Symbols.add),
          ),
        );
      },
    );
  }

  /// 标签操作菜单（底部弹层）
  void _showTagActions(
    BuildContext context,
    TaskProvider provider,
    String tag,
    bool isArchived,
  ) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) {
        final ext = appColors(context);
        final onBg = Theme.of(context).colorScheme.onBackground;
        final primary = Theme.of(context).colorScheme.primary;
        final error = Theme.of(context).colorScheme.error;

        Widget _row(IconData icon, String label, Color? color,
            VoidCallback onTap) {
          return InkWell(
            onTap: () {
              Navigator.pop(sheet);
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                children: [
                  Icon(icon, size: 22, color: color ?? onBg),
                  const SizedBox(width: 14),
                  Text(label, style: TextStyle(fontSize: 15, color: color ?? onBg)),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '标签：$tag',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: onBg,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheet),
                        icon: Icon(Symbols.close, size: 20, color: ext.meta),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                const SizedBox(height: 4),
                // 重命名
                _row(Symbols.edit, '重命名', null, () {
                  _showRenameDialog(context, provider, tag);
                }),
                // 合并
                _row(Symbols.merge, '合并到另一个标签', null, () {
                  _showMergeDialog(context, provider, tag);
                }),
                // 归档/取消归档
                _row(
                  isArchived ? Symbols.unarchive : Symbols.archive,
                  isArchived ? '取消归档' : '归档',
                  null,
                  () {
                    if (isArchived) {
                      provider.unarchiveTag(tag);
                    } else {
                      provider.archiveTag(tag);
                    }
                  },
                ),
                // 删除
                _row(Symbols.delete_forever, '删除标签', error, () {
                  _confirmDelete(context, provider, tag);
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 重命名对话框
  void _showRenameDialog(
      BuildContext context, TaskProvider provider, String oldName) {
    final controller = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('重命名标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新标签名',
            hintText: '输入新的标签名称',
          ),
          onSubmitted: (v) async {
            if (v.trim().isNotEmpty && v.trim() != oldName) {
              await provider.renameTag(oldName, v.trim());
              Navigator.pop(d);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final v = controller.text.trim();
              if (v.isNotEmpty && v != oldName) {
                await provider.renameTag(oldName, v);
                Navigator.pop(d);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 合并对话框
  void _showMergeDialog(
      BuildContext context, TaskProvider provider, String source) {
    final candidates = provider.allTagsIncludingArchived
        .where((t) => t != source)
        .toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有其他标签可合并')),
      );
      return;
    }
    String? target;
    showDialog(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('合并标签'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('将「$source」合并到：'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: candidates.map((t) {
                  final selected = target == t;
                  return ChoiceChip(
                    label: Text(t),
                    selected: selected,
                    onSelected: (v) {
                      setDialog(() => target = v ? t : null);
                    },
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: target != null
                  ? () async {
                      await provider.mergeTags(source, target!);
                      Navigator.pop(d);
                    }
                  : null,
              child: const Text('合并'),
            ),
          ],
        ),
      ),
    );
  }

  /// 删除确认
  void _confirmDelete(
      BuildContext context, TaskProvider provider, String tag) {
    final count = provider.tagTaskCount(tag);
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除标签'),
        content: Text(
          '将从 $count 条任务中移除标签「$tag」，不可恢复。确定删除？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await provider.deleteTag(tag);
              Navigator.pop(d);
            },
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 新增标签对话框。
  ///
  /// U1 修复：标签是任务的属性（存于 [Task.tags]，无独立实体），无法凭空创建；
  /// 旧实现输入名称后只弹「已创建」假提示、无任何数据写入——用户反复重试并
  /// 损害对其它成功提示的信任。现改为真实链路：确认后唤起快速录入层，预填
  /// `#标签名` 语法，用户补一句标题即可建出一条带该标签的任务（标签随之诞生、
  /// 在本页可见可管理）。预填文本里不含日期/优先级，避免被解析器吃掉标签前缀。
  void _showAddTagDialog(BuildContext context, TaskProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('新增标签'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '标签名称',
                hintText: '输入新标签名称',
              ),
              onSubmitted: (v) {
                final name = v.trim();
                if (name.isEmpty) return;
                Navigator.pop(d);
                _createTaskWithTag(context, name);
              },
            ),
            const SizedBox(height: 8),
            const Text(
              '标签需绑定在任务上。确定后将打开快速录入，'
              '输入任务标题并保存，该标签即创建成功。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(d);
              _createTaskWithTag(context, name);
            },
            child: const Text('下一步'),
          ),
        ],
      ),
    );
  }

  /// U1：带标签名唤起快速录入。名字含空白/`#`/`!` 时会被解析器截断，先提示防错位。
  void _createTaskWithTag(BuildContext context, String name) {
    if (!RegExp(r'^[^\s#＃!！]+$').hasMatch(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('标签名「$name」不能含空格或 #/！，请重新输入')),
      );
      return;
    }
    QuickEntrySheet.show(context, initialText: '#$name ');
  }
}

/// 过滤切换芯片（全部 / 活跃 / 归档）
class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final surface = Theme.of(context).colorScheme.surface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? primary.withOpacity(0.12) : surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? primary : Theme.of(context).colorScheme.outline.withOpacity(0.3),
          ),
        ),
        child: Text(
          '$label ($count)',
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? primary : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}