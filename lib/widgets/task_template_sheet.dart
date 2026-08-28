/// 「任务模板库」底部弹层（P1-7）：列出内置离线模板，一键套用为多条任务。
///
/// 套用逻辑见 [applyTemplate]；本组件只负责展示与触发，不持有任何业务状态。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/state/task_provider.dart';

class TaskTemplateSheet {
  static Future<void> show(BuildContext context) async {
    final provider = context.read<TaskProvider>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
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
              child: Text('内置离线清单，一键套用为多条任务',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                controller: scroll,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: builtInTemplates.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = builtInTemplates[i];
                  return ListTile(
                    leading: Icon(t.icon, color: Theme.of(context).colorScheme.primary),
                    title: Text(t.name),
                    subtitle: Text('${t.description} · ${t.items.length} 项'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      final n = applyTemplate(provider, t);
                      Navigator.pop(ctx);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已套用「${t.name}」，新增 $n 条任务')),
                        );
                      }
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
}
