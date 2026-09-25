import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/widgets/top_app_bar.dart';

/// 人类可读体积（与 [AttachmentRef.sizeLabel] 同口径：B/KB/MB/GB）。
String _humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

/// 按附件类型选择 Material Symbols 图标（与 [AttachmentTypeLabel.icon] 保持一致）。
IconData _typeIcon(AttachmentType type) {
  switch (type) {
    case AttachmentType.image:
      return Symbols.image;
    case AttachmentType.audio:
      return Symbols.graphic_eq;
    case AttachmentType.file:
      return Symbols.description;
  }
}

/// P0-2 附件管理页 + 全局存储统计。
///
/// 展示全量附件的「总数 / 总大小 / 按类型占比」，按任务分组列出明细（文件名 / 大小 /
/// 类型 / 时间），支持搜索、单附件滑删、批量删除（二次确认），以及「清理无主文件」
/// （删除不在任何任务元数据中的孤儿文件与过期 _staging 残留）。全程本地 IO，不联网。
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  Map<String, List<AttachmentFileEntry>> _inventory = const {};
  bool _loading = true;
  String _query = '';
  bool _selecting = false;
  final Set<String> _selected = {}; // key 形如 "$taskId/$fileName"

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final inv = await AttachmentService.scanAll();
    if (mounted) setState(() => _inventory = inv);
    if (mounted) setState(() => _loading = false);
  }

  /// 显示用分组：key=taskId（'' 表示 _staging 残留），value=该组文件列表（已按搜索过滤）。
  Map<String, List<AttachmentFileEntry>> get _groups {
    final q = _query.trim().toLowerCase();
    final out = <String, List<AttachmentFileEntry>>{};
    for (final e in _inventory.entries) {
      final filtered = e.value.where((f) {
        if (q.isEmpty) return true;
        final task = context.read<TaskProvider>().byId(e.key);
        final title = task?.title.toLowerCase() ?? '';
        return f.fileName.toLowerCase().contains(q) || title.contains(q);
      }).toList();
      if (filtered.isNotEmpty) out[e.key] = filtered;
    }
    return out;
  }

  /// 全局统计：总大小、总数量、各类型数量（用于占比条）。
  ({int totalBytes, int totalCount, int images, int audios, int files})
      get _stats {
    var totalBytes = 0, totalCount = 0, images = 0, audios = 0, files = 0;
    for (final list in _inventory.values) {
      for (final f in list) {
        totalBytes += f.sizeBytes;
        totalCount++;
        final t = _resolveType(f);
        if (t == AttachmentType.image) {
          images++;
        } else if (t == AttachmentType.audio) {
          audios++;
        } else {
          files++;
        }
      }
    }
    return (
      totalBytes: totalBytes,
      totalCount: totalCount,
      images: images,
      audios: audios,
      files: files,
    );
  }

  /// 从任务元数据中匹配该文件对应的类型；匹配不到则按扩展名粗判，再不行归为 file。
  AttachmentType _resolveType(AttachmentFileEntry f) {
    if (f.taskId.isNotEmpty) {
      final task = context.read<TaskProvider>().byId(f.taskId);
      if (task != null) {
        for (final a in task.attachments) {
          if (a.fileName == f.fileName) return a.type;
        }
      }
    }
    final ext = f.fileName.contains('.')
        ? f.fileName.split('.').last.toLowerCase()
        : '';
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'].contains(ext)) {
      return AttachmentType.image;
    }
    if (['m4a', 'mp3', 'wav', 'aac', 'ogg'].contains(ext)) {
      return AttachmentType.audio;
    }
    return AttachmentType.file;
  }

  String _groupTitle(String taskId) {
    if (taskId.isEmpty) return '_staging 暂存残留';
    return context.read<TaskProvider>().byId(taskId)?.title ?? '(未知任务)';
  }

  Future<void> _deleteEntry(AttachmentFileEntry f) async {
    final provider = context.read<TaskProvider>();
    if (f.taskId.isEmpty) {
      // staging 残留：直接删文件，无元数据。
      try {
        await f.file.delete();
      } catch (_) {}
    } else {
      final task = provider.byId(f.taskId);
      if (task != null) {
        final newAtt =
            task.attachments.where((a) => a.fileName != f.fileName).toList();
        provider.updateTask(task.copyWith(attachments: newAtt));
      }
      await AttachmentService.deleteAttachmentFile(f.taskId, f.fileName);
    }
    _selected.remove('${f.taskId}/${f.fileName}');
    await _reload();
  }

  Future<void> _deleteSelected() async {
    final provider = context.read<TaskProvider>();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除选中附件'),
        content: Text('确认删除选中的 ${_selected.length} 个附件？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirm != true) return;
    for (final key in List<String>.from(_selected)) {
      final sep = key.indexOf('/');
      final taskId = key.substring(0, sep);
      final fileName = key.substring(sep + 1);
      if (taskId.isEmpty) {
        // 在 inventory 的 _staging 残留中找到对应文件实体删除。
        File? targetFile;
        for (final e in (_inventory[''] ?? const <AttachmentFileEntry>[])) {
          if ('${e.taskId}/${e.fileName}' == key) {
            targetFile = e.file;
            break;
          }
        }
        try {
          if (targetFile != null) await targetFile.delete();
        } catch (_) {}
      } else {
        final task = provider.byId(taskId);
        if (task != null) {
          final newAtt =
              task.attachments.where((a) => a.fileName != fileName).toList();
          provider.updateTask(task.copyWith(attachments: newAtt));
        }
        await AttachmentService.deleteAttachmentFile(taskId, fileName);
      }
    }
    _selected.clear();
    setState(() => _selecting = false);
    await _reload();
  }

  Future<void> _cleanOrphans() async {
    final provider = context.read<TaskProvider>();
    // 传入全部仍保有元数据的任务（含回收站），避免误删回收站任务的附件。
    final all = [...provider.tasks, ...provider.trash];
    final bytes = await AttachmentService.previewOrphansBytes(all);
    if (bytes <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未发现无主文件')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('清理无主文件'),
        content: Text('将删除不在任何任务中的孤儿附件与过期暂存残留，'
            '预计释放 ${_humanSize(bytes)}。此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true), child: const Text('清理')),
        ],
      ),
    );
    if (ok != true) return;
    final freed = await AttachmentService.deleteOrphans(all);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已释放 ${_humanSize(freed)}')),
      );
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final stats = _stats;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('存储空间'),
        actions: [
          if (!_selecting)
            IconButton(
              icon: const Icon(Symbols.cleaning),
              tooltip: '清理无主文件',
              onPressed: _cleanOrphans,
            ),
          if (!_selecting)
            IconButton(
              icon: const Icon(Symbols.checklist),
              tooltip: '批量选择',
              onPressed: () => setState(() => _selecting = true),
            ),
          if (_selecting) ...[
            TextButton(
              onPressed: _selected.isEmpty ? null : _deleteSelected,
              child: Text('删除(${_selected.length})'),
            ),
            TextButton(
              onPressed: () {
                _selected.clear();
                setState(() => _selecting = false);
              },
              child: const Text('取消'),
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _SummaryCard(stats: stats),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppColors.pagePadX, 8, AppColors.pagePadX, 0),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: '搜索任务或文件名',
                      prefixIcon: const Icon(Symbols.search),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _groups.isEmpty
                      ? Center(
                          child: Text('暂无附件',
                              style: TextStyle(color: ext.meta)),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                            AppColors.pagePadX,
                            0,
                            AppColors.pagePadX,
                            24,
                          ),
                          itemCount: _groups.length,
                          itemBuilder: (_, i) {
                            final entry = _groups.entries.elementAt(i);
                            return _GroupTile(
                              title: _groupTitle(entry.key),
                              entries: entry.value,
                              selecting: _selecting,
                              selected: _selected,
                              onToggle: (f) {
                                final k = '${f.taskId}/${f.fileName}';
                                // U3-5（v2.9.5 审计）：长按此前只写 `_selected`、
                                // 不改 `_selecting` → 勾选态「隐形」，再点
                                // 「批量选择」时凭空多出已勾选项。改为任何 toggle
                                // 一律先进入选择模式，让勾选态始终可见（选择模式下
                                // 本行为不变：勾 / 取消勾仍只增删 `_selected`）。
                                setState(() {
                                  _selecting = true;
                                  if (_selected.contains(k)) {
                                    _selected.remove(k);
                                  } else {
                                    _selected.add(k);
                                  }
                                });
                              },
                              onDelete: _deleteEntry,
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

/// 顶部统计卡：总数 / 总大小 + 图片/录音/文件三色占比条。
class _SummaryCard extends StatelessWidget {
  final ({int totalBytes, int totalCount, int images, int audios, int files}) stats;
  const _SummaryCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    // U3-4（v2.9.5 审计）：占比条改用前景色分档，需要拿到 colorScheme。
    final scheme = Theme.of(context).colorScheme;
    final total = stats.totalCount;
    final imgF = total == 0 ? 0.0 : stats.images / total;
    final audF = total == 0 ? 0.0 : stats.audios / total;
    final fileF = total == 0 ? 0.0 : stats.files / total;
    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppColors.pagePadX, 8, AppColors.pagePadX, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('共 ${stats.totalCount} 个附件 · ${_humanSize(stats.totalBytes)}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          if (total > 0)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Row(
                children: [
                  // U3-4（v2.9.5 审计）：此前硬编码 Colors.blue/green/orange，
                  // 脱离主题体系（本项目设计偏好纯黑白色系）→ 改用前景色
                  // 三档透明度区分图片 / 录音 / 文件，随明暗主题自适应。
                  if (imgF > 0)
                    Expanded(
                        flex: (imgF * 100).round(),
                        child: Container(
                            height: 10,
                            color: scheme.onBackground.withValues(alpha: 0.9))),
                  if (audF > 0)
                    Expanded(
                        flex: (audF * 100).round(),
                        child: Container(
                            height: 10,
                            color: scheme.onBackground.withValues(alpha: 0.5))),
                  if (fileF > 0)
                    Expanded(
                        flex: (fileF * 100).round(),
                        child: Container(
                            height: 10,
                            color:
                                scheme.onBackground.withValues(alpha: 0.22))),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              _TypeChip(
                  icon: Symbols.image, label: '图片', count: stats.images),
              const SizedBox(width: 12),
              _TypeChip(
                  icon: Symbols.graphic_eq, label: '录音', count: stats.audios),
              const SizedBox(width: 12),
              _TypeChip(
                  icon: Symbols.description, label: '文件', count: stats.files),
            ],
          ),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  const _TypeChip(
      {required this.icon, required this.label, required this.count});
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: ext.meta),
        const SizedBox(width: 4),
        Text('$label $count', style: TextStyle(color: ext.meta, fontSize: 13)),
      ],
    );
  }
}

/// 单个任务的分组：标题（任务名）+ 该任务下全部附件行；支持搜索过滤后的空分组隐藏。
class _GroupTile extends StatelessWidget {
  final String title;
  final List<AttachmentFileEntry> entries;
  final bool selecting;
  final Set<String> selected;
  final void Function(AttachmentFileEntry) onToggle;
  final Future<void> Function(AttachmentFileEntry) onDelete;
  const _GroupTile({
    required this.title,
    required this.entries,
    required this.selecting,
    required this.selected,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Row(
            children: [
              Icon(Symbols.folder, size: 18, color: ext.meta),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              Text('${entries.length}', style: TextStyle(color: ext.meta)),
            ],
          ),
        ),
        ...entries.map((f) => _AttachmentRow(
              entry: f,
              selecting: selecting,
              checked: selected.contains('${f.taskId}/${f.fileName}'),
              onToggle: onToggle,
              onDelete: onDelete,
            )),
      ],
    );
  }
}

/// 单条附件行：图标 + 文件名 + 大小 + 时间；非选择态下可左滑删除（二次确认）。
class _AttachmentRow extends StatelessWidget {
  final AttachmentFileEntry entry;
  final bool selecting;
  final bool checked;
  final void Function(AttachmentFileEntry) onToggle;
  final Future<void> Function(AttachmentFileEntry) onDelete;
  const _AttachmentRow({
    required this.entry,
    required this.selecting,
    required this.checked,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final scheme = Theme.of(context).colorScheme;
    final type = _resolveTypeForRow(context, entry);
    final body = ListTile(
      leading: Icon(_typeIcon(type), color: ext.meta),
      title: Text(entry.fileName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_humanSize(entry.sizeBytes)} · ${_fmtTime(entry.modifiedAt)}',
        style: TextStyle(color: ext.meta, fontSize: 12),
      ),
      trailing: selecting
          ? Checkbox(
              value: checked,
              onChanged: (_) => onToggle(entry),
            )
          : null,
      onTap: selecting ? () => onToggle(entry) : null,
      onLongPress: selecting ? null : () => onToggle(entry),
    );
    if (selecting) return body;
    return Dismissible(
      key: Key('${entry.taskId}/${entry.fileName}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: scheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Symbols.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('删除附件'),
            content: Text('确认删除「${entry.fileName}」？此操作不可撤销。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(d, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('删除')),
            ],
          ),
        );
        return ok == true;
      },
      onDismissed: (_) => onDelete(entry),
      child: body,
    );
  }

  AttachmentType _resolveTypeForRow(BuildContext context, AttachmentFileEntry f) {
    if (f.taskId.isNotEmpty) {
      final task = context.read<TaskProvider>().byId(f.taskId);
      if (task != null) {
        for (final a in task.attachments) {
          if (a.fileName == f.fileName) return a.type;
        }
      }
    }
    final extName = f.fileName.contains('.')
        ? f.fileName.split('.').last.toLowerCase()
        : '';
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'].contains(extName)) {
      return AttachmentType.image;
    }
    if (['m4a', 'mp3', 'wav', 'aac', 'ogg'].contains(extName)) {
      return AttachmentType.audio;
    }
    return AttachmentType.file;
  }

  String _fmtTime(DateTime t) {
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}
