import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/state/task_provider.dart';

/// 「备份与恢复」底部弹层：提供「备份到文件」「从备份恢复」，
/// 并可选择是否把回收站一并备份 / 恢复。
class BackupSheet {
  static Future<void> show(BuildContext context) async {
    final provider = context.read<TaskProvider>();
    var includeTrash = true;
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
                const Text('备份与恢复',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('包含回收站'),
                  subtitle: const Text('备份与恢复时，一并处理回收站中的任务'),
                  value: includeTrash,
                  onChanged: (v) => setState(() => includeTrash = v),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Symbols.backup),
                  title: const Text('备份到文件'),
                  subtitle: const Text('导出完整数据（任务与设置），可分享保存'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doBackup(provider, context, includeTrash);
                  },
                ),
                ListTile(
                  leading: const Icon(Symbols.restore),
                  title: const Text('从备份恢复'),
                  subtitle: const Text('选择此前的备份文件，覆盖当前数据'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doRestore(provider, context, includeTrash);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static Future<void> _doBackup(
    TaskProvider provider,
    BuildContext context,
    bool includeTrash,
  ) async {
    try {
      final name = '有条-backup-${_ts()}.json';
      final json = provider.backupJson(includeTrash);
      // 1) App 私有目录留一份，供「分享」按钮兜底使用（Downloads 写入失败也能发出去）
      final file = await DataIo.saveToAppDocs(name, json);
      // 2) 同时写入系统「下载 / Downloads」目录，文件管理器可见
      String msg = '已保存到「下载」目录（Downloads）';
      try {
        await DataIo.saveToDownloads(
          name,
          json,
          mimeType: 'application/json',
        );
      } catch (e) {
        msg = '已生成备份（下载目录写入失败，请改用「分享」保存）';
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            action: SnackBarAction(
              label: '分享',
              onPressed: () => DataIo.shareFile(file),
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('备份失败：$e')));
      }
    }
  }

  static Future<void> _doRestore(
    TaskProvider provider,
    BuildContext context,
    bool includeTrash,
  ) async {
    final raw = await DataIo.pickJsonFile();
    if (raw == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('从备份恢复？'),
        content: const Text('这将用备份文件覆盖当前所有任务与设置，且不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await provider.restoreFromJson(raw, includeTrash: includeTrash);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已从备份恢复')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复失败：文件格式不正确（$e）')),
        );
      }
    }
  }

  static String _ts() {
    final d = DateTime.now();
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${d.year}${p(d.month)}${p(d.day)}-${p(d.hour)}${p(d.minute)}';
  }
}
