/// 「任务模板库」底部弹层（P0-4）：内置离线模板一键套用，用户模板可管理 / 编辑 / 分享 / 导入。
///
/// 套用逻辑见 [applyTemplate] / [applyUserTemplate]；本组件只负责展示与触发，不持有业务状态。
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/user_template_editor.dart';

class TaskTemplateSheet {
  /// 打开模板库（内置套用 + 用户模板管理）。
  static Future<void> show(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => const _TemplateLibraryBody(),
    );
  }

  /// 「另存为模板」：把单条任务的结构（标题 / 分类 / 优先级 / 标签 / 重复规则 / 相对截止）
  /// 预填进编辑器，保存为一条用户模板。
  static Future<void> saveTaskAsTemplate(
      BuildContext context, Task task) async {
    final tpl = UserTemplate(
      id: (DateTime.now().microsecondsSinceEpoch % 1000000000).toString(),
      name: task.title,
      iconName: 'checklist',
      items: [TemplateItem.fromTask(task)],
    );
    await UserTemplateEditorSheet.show(context, initial: tpl);
  }
}

class _TemplateLibraryBody extends StatefulWidget {
  const _TemplateLibraryBody();

  @override
  State<_TemplateLibraryBody> createState() => _TemplateLibraryBodyState();
}

class _TemplateLibraryBodyState extends State<_TemplateLibraryBody> {
  List<UserTemplate> _user = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await UserTemplateStore.loadAll();
    if (mounted) setState(() => _user = list);
  }

  Future<void> _import(BuildContext ctx) async {
    final raw = await DataIo.pickJsonFile();
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final t = UserTemplate.fromJson(m);
      if (t.items.isEmpty) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx)
              .showSnackBar(const SnackBar(content: Text('模板文件无有效任务项')));
        }
        return;
      }
      await UserTemplateStore.save(t);
      await _reload();
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx)
            .showSnackBar(SnackBar(content: Text('已导入模板「${t.name}」')));
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  Future<void> _delete(BuildContext ctx, UserTemplate t) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: const Text('删除模板'),
        content: Text('确定删除「${t.name}」？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(d, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await UserTemplateStore.delete(t.id);
      await _reload();
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx)
            .showSnackBar(SnackBar(content: Text('已删除「${t.name}」')));
      }
    }
  }

  Future<void> _share(BuildContext ctx, UserTemplate t) async {
    try {
      final file = await UserTemplateStore.exportTemplate(t);
      if (ctx.mounted) await DataIo.shareFile(file, mimeType: 'application/json');
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx)
            .showSnackBar(SnackBar(content: Text('分享失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<TaskProvider>();
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('任务模板库',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('内置离线清单一键套用；我的模板可编辑 / 分享 / 导入',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Text('内置模板',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                ...builtInTemplates.map((t) => ListTile(
                      leading:
                          Icon(t.icon, color: Theme.of(context).colorScheme.primary),
                      title: Text(t.name),
                      subtitle: Text('${t.description} · ${t.items.length} 项'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        final n = applyTemplate(provider, t);
                        Navigator.pop(context);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('已套用「${t.name}」，新增 $n 条任务')),
                          );
                        }
                      },
                    )),
                const Divider(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: Row(
                    children: [
                      const Text('我的模板',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () =>
                            UserTemplateEditorSheet.show(context),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新建'),
                      ),
                      TextButton.icon(
                        onPressed: () => _import(context),
                        icon: const Icon(Icons.file_download, size: 18),
                        label: const Text('导入'),
                      ),
                    ],
                  ),
                ),
                if (_user.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Text('还没有自定义模板，点「新建」或「另存为模板」开始。',
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  ..._user.map((t) => ListTile(
                        leading: Icon(t.icon,
                            color: Theme.of(context).colorScheme.primary),
                        title: Text(t.name),
                        subtitle: Text('${t.description.isEmpty ? '自定义模板' : t.description} · ${t.items.length} 项'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'apply') {
                              final n = applyUserTemplate(provider, t);
                              Navigator.pop(context);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content:
                                      Text('已套用「${t.name}」，新增 $n 条任务')),
                                );
                              }
                            } else if (v == 'edit') {
                              await UserTemplateEditorSheet.show(context,
                                  initial: t);
                              await _reload();
                            } else if (v == 'share') {
                              await _share(context, t);
                            } else if (v == 'delete') {
                              await _delete(context, t);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'apply', child: Text('套用')),
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(value: 'share', child: Text('分享文件')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                      )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
