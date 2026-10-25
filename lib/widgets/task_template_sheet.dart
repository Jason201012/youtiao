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

  /// P2-1（v3.0.8 审计）：套用中守卫——applyTemplate 逐条 await addTask（一条
  /// 模板通常 3-7 项，等待时间足以诱发双击），旧实现无 _applying：双击「套用」
  /// 并发跑两遍 → 整份模板复制两份。
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final r = await UserTemplateStore.loadAllWithBroken();
    if (!mounted) return;
    setState(() => _user = r.templates);
    // P3-1（v3.0.2 审计）/ U3-2：损坏模板此前从列表静默消失，用户无从知晓
    // 原因。加载失败数 > 0 时给一条可见提示（SnackBar，不打断浏览）。
    if (r.broken > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${r.broken} 个模板文件已损坏，已跳过；可删除后重新导入'),
      ));
    }
  }

  Future<void> _import(BuildContext ctx) async {
    // L-09：模板 JSON 同样先过大小预检（读入前 stat），超限给出明确提示。
    final picked = await DataIo.pickJsonFile();
    if (picked.cancelled) return;
    if (picked.error != null) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx)
            .showSnackBar(SnackBar(content: Text(picked.error!)));
      }
      return;
    }
    final raw = picked.content!;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      // 安全（P1-A）：导入时无条件丢弃外部 id 重新分配，杜绝 id 携带路径穿越段。
      final t = UserTemplate.fromImportedJson(m);
      if (t.items.isEmpty) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx)
              .showSnackBar(const SnackBar(content: Text('模板文件无有效任务项')));
        }
        return;
      }
      // L11（v3.0.8 审计）：消费保存结果（原子写 + 失败如实提示）。
      final ok = await UserTemplateStore.save(t);
      if (!ok) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(content: Text('模板保存失败：请检查存储空间后重试')),
          );
        }
        return;
      }
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('内置离线清单一键套用；我的模板可编辑 / 分享 / 导入',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          // P3-10（v2.9.5 审计）：把「模板不迁移哪些字段」**显式告知**用户。
          // 此前该边界只存在于代码里，用户「另存为模板 → 套用」后发现子任务/
          // 附件没了，只能理解为 Bug。说明放在模板库顶部（而非藏在帮助页），
          // 因为这正是做「另存为模板」决定前需要知道的信息。
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              '模板保存计划规则（标题 / 分类 / 优先级 / 标签 / 重复 / 截止偏移 / '
              '预计时长 / 备注 / 提醒提前量）；子任务进度、附件与已跳过日期不随模板迁移。',
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline),
            ),
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
                      onTap: () async {
                        // P2-1（v3.0.8 审计）：防重入（见 [_applying]）。
                        if (_applying) return;
                        setState(() => _applying = true);
                        // P2-2（v3.0.7 审计）：applyTemplate 异步化——等待真实
                        // 落库数再提示（落盘失败的条目已被 provider 回滚，不计入）。
                        // U3-6（v3.0.8 审计）：整批一次落盘——失败已整体
                        // 回滚（created=0），按失败分支如实提示，不再出现
                        // 「新增 0 条」后被误读为空模板。
                        final r = await applyTemplate(provider, t);
                        if (!mounted) return;
                        setState(() => _applying = false);
                        if (!context.mounted) return;
                        // N11（v3.0.9 审计）：失败**停留本层**——旧实现失败
                        // 也 Navigator.pop：用户需重开模板库才能重试，与新建
                        // 「失败停留本层」口径不对齐。另：0 项模板时
                        // created==total（0==0）旧显示「新增 0 条」，
                        // 按空模板如实提示。
                        if (r.created == r.total) {
                          Navigator.pop(context);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(r.total == 0
                                      ? '「${t.name}」是空模板，没有可套用的条目'
                                      : '已套用「${t.name}」，新增 ${r.created} 条任务')),
                            );
                          }
                        } else if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('套用失败：「${t.name}」未保存'
                                    '（已整体回滚），请检查存储空间后重试')),
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
                              // P2-1（v3.0.8 审计）：同内置模板防重入。
                              if (_applying) return;
                              setState(() => _applying = true);
                              // P2-2（v3.0.7 审计）：同内置模板——等待真实
                              // 落库数再提示。
                              // U3-6（v3.0.8 审计）：同内置模板——整批
                              // 一次落盘，失败如实提示。
                              final r = await applyUserTemplate(provider, t);
                              if (!mounted) return;
                              setState(() => _applying = false);
                              if (!context.mounted) return;
                              // N11（v3.0.9 审计）：同内置模板——失败停留
                              // 本层可重试；0 项模板按空模板如实提示。
                              if (r.created == r.total) {
                                Navigator.pop(context);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(r.total == 0
                                            ? '「${t.name}」是空模板，没有可套用的条目'
                                            : '已套用「${t.name}」，新增 ${r.created} 条任务')),
                                  );
                                }
                              } else if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text('套用失败：「${t.name}」未保存'
                                          '（已整体回滚），请检查存储空间后重试')),
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
