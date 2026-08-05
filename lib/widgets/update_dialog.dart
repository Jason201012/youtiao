import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:todolist/services/update_checker.dart';

/// 发现新版本时的弹窗：展示版本与更新说明，提供下载 / 稍后 / 跳过此版本。
class UpdateDialog {
  static Future<void> show(BuildContext context, UpdateInfo info) async {
    if (!context.mounted) return;

    final notes = (info.releaseNotes ?? '').trim();
    final displayNotes = notes.length > 600 ? '${notes.substring(0, 600)}…' : notes;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Symbols.system_update_alt, size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text('发现新版本 v${info.version}',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (displayNotes.isNotEmpty) ...[
                  Text(displayNotes, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 12),
                ],
                Text('将升级到 v${info.version}',
                    style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              UpdateChecker.setSkipVersion(info.version);
            },
            child: const Text('跳过此版本'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final url = info.apkUrl ?? info.releaseUrl;
              if (url != null) {
                final uri = Uri.parse(url);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              }
            },
            child: const Text('立即下载'),
          ),
        ],
      ),
    );
  }
}
