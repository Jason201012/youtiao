import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/task_provider.dart';

/// 「导出数据」底部弹层：选择导出为 CSV 或 Markdown 可读副本，
/// 并可选择是否把回收站任务一并导出。
class ExportSheet {
  static Future<void> show(BuildContext context) async {
    final taskProvider = context.read<TaskProvider>();
    final focusProvider = context.read<FocusProvider>();
    var includeTrash = false;
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('导出数据',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('包含回收站'),
                  subtitle: const Text('导出时一并包含已删除（回收站）的任务'),
                  value: includeTrash,
                  onChanged: (v) => setState(() => includeTrash = v),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Symbols.table_chart),
                  title: const Text('导出为 CSV'),
                  subtitle: const Text('表格格式，含任务与专注记录，可用 Excel 打开'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doExport(taskProvider, focusProvider, context, 'csv', includeTrash);
                  },
                ),
                ListTile(
                  leading: const Icon(Symbols.description),
                  title: const Text('导出为 Markdown'),
                  subtitle: const Text('文本清单，含任务与专注记录，便于阅读粘贴'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doExport(taskProvider, focusProvider, context, 'md', includeTrash);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static Future<void> _doExport(
    TaskProvider provider,
    FocusProvider focusProvider,
    BuildContext context,
    String kind,
    bool includeTrash,
  ) async {
    final isCsv = kind == 'csv';
    try {
      final contentTask = isCsv
          ? provider.exportCsv(includeTrash: includeTrash)
          : provider.exportMarkdown(includeTrash: includeTrash);
      final contentFocus =
          isCsv ? focusProvider.exportCsv() : focusProvider.exportMarkdown();
      // 任务内容之后追加专注记录段落（CSV 追加独立表头，MD 追加独立标题）。
      final content = '$contentTask\n$contentFocus';
      final name =
          '有条-${isCsv ? 'tasks' : 'export'}-${_ts()}.${isCsv ? 'csv' : 'md'}';
      // 1) App 私有目录留一份，供「分享」按钮兜底
      final file = await DataIo.saveToAppDocs(name, content);
      // 2) 同时写入系统「下载 / Downloads」目录，文件管理器可见
      String msg = '已导出 ${isCsv ? 'CSV' : 'Markdown'} 到「下载」目录（Downloads）';
      try {
        await DataIo.saveToDownloads(
          name,
          content,
          mimeType: isCsv ? 'text/csv' : 'text/markdown',
        );
      } catch (e) {
        msg = '已导出 ${isCsv ? 'CSV' : 'Markdown'}（下载目录写入失败，请改用「分享」）';
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            action: SnackBarAction(
              label: '分享',
              onPressed: () => DataIo.shareFile(
                file,
                mimeType: isCsv ? 'text/csv' : 'text/markdown',
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  static String _ts() {
    final d = DateTime.now();
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${d.year}${p(d.month)}${p(d.day)}-${p(d.hour)}${p(d.minute)}';
  }
}
