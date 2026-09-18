import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/services/report_exporter.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';

/// 「导出数据」底部弹层：选择导出为 CSV 或 Markdown 可读副本，
/// 并可选择是否把回收站任务一并导出。
class ExportSheet {
  static Future<void> show(BuildContext context) async {
    final taskProvider = context.read<TaskProvider>();
    final focusProvider = context.read<FocusProvider>();
    final habitProvider = context.read<HabitProvider>();
    var includeTrash = false;
    // P1-10：导出时可选「包含附件清单」（Excel/CSV 追加附件列 / 行）。
    var includeAttachments = false;
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
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('包含附件清单'),
                  subtitle: const Text('Excel/CSV 追加附件列（文件名与大小）'),
                  value: includeAttachments,
                  onChanged: (v) => setState(() => includeAttachments = v),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Symbols.table_chart),
                  title: const Text('导出为 CSV'),
                  subtitle: const Text('表格格式，含任务、习惯与专注记录，可用 Excel 打开'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doExport(taskProvider, focusProvider, habitProvider, context,
                        'csv', includeTrash, includeAttachments);
                  },
                ),
                ListTile(
                  leading: const Icon(Symbols.description),
                  title: const Text('导出为 Markdown'),
                  subtitle: const Text('文本清单，含任务、习惯与专注记录，便于阅读粘贴'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doExport(taskProvider, focusProvider, habitProvider, context,
                        'md', includeTrash, includeAttachments);
                  },
                ),
                ListTile(
                  leading: const Icon(Symbols.grid_on),
                  title: const Text('导出为 Excel'),
                  subtitle: const Text('表格工作簿，含任务 / 专注 / 习惯 / 打卡记录，可用 Excel / WPS 打开'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doExportExcel(taskProvider, focusProvider, habitProvider,
                        context, includeTrash, includeAttachments);
                  },
                ),
                ListTile(
                  leading: const Icon(Symbols.calendar_month),
                  title: const Text('导出为 iCal (.ics)'),
                  subtitle: const Text('标准日历格式，可导入系统日历 / Outlook / Google 日历'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doExportIcs(taskProvider, context, includeTrash);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Symbols.playlist_add),
                  title: const Text('从 iCal (.ics) 导入'),
                  subtitle: const Text('把其它应用的 .ics 任务迁入「有条」（追加，不覆盖现有）'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doImportIcs(taskProvider, context);
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
    HabitProvider habitProvider,
    BuildContext context,
    String kind,
    bool includeTrash,
    bool includeAttachments,
  ) async {
    final isCsv = kind == 'csv';
    try {
      final contentTask = isCsv
          ? provider.exportCsv(
              includeTrash: includeTrash, includeAttachments: includeAttachments)
          : provider.exportMarkdown(
              includeTrash: includeTrash, includeAttachments: includeAttachments);
      final contentFocus =
          isCsv ? focusProvider.exportCsv() : focusProvider.exportMarkdown();
      final contentHabit =
          isCsv ? habitProvider.exportCsv() : habitProvider.exportMarkdown();
      // 任务 → 专注 → 习惯，依次拼接（CSV 各自带独立表头，MD 各自带独立标题）。
      final content = '$contentTask\n$contentFocus\n$contentHabit';
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

  /// 导出为 Excel 工作簿（.xlsx，四张表）：任务 / 专注记录 / 习惯 / 打卡记录。
  /// 落盘到 App 私有文档目录（二进制走 [DataIo.saveBytesToAppDocs]），
  /// 再经系统分享面板交出去；严格离线，不联网。
  static Future<void> _doExportExcel(
    TaskProvider provider,
    FocusProvider focusProvider,
    HabitProvider habitProvider,
    BuildContext context,
    bool includeTrash,
    bool includeAttachments,
  ) async {
    try {
      final bytes = ReportExporter.buildDatasetExcel(
        task: provider,
        focus: focusProvider,
        habit: habitProvider,
        includeTrash: includeTrash,
        includeAttachments: includeAttachments,
      );
      final name = '有条-tasks-${_ts()}.xlsx';
      final file = await DataIo.saveBytesToAppDocs(name, bytes);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('已生成 Excel 工作簿（App 文档目录）'),
            action: SnackBarAction(
              label: '分享',
              onPressed: () => DataIo.shareFile(
                file,
                mimeType:
                    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
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

  /// 把当前任务导出为 iCal (.ics) 标准格式（RFC 5545，CRLF 行尾），
  /// 可被系统日历 / Outlook / Google 日历 / 其它待办应用导入。
  static Future<void> _doExportIcs(
    TaskProvider provider,
    BuildContext context,
    bool includeTrash,
  ) async {
    try {
      final tasks = [...provider.tasks];
      if (includeTrash) tasks.addAll(provider.trash);
      if (tasks.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('没有可导出的任务')));
        }
        return;
      }
      final content = exportIcs(tasks);
      final name = '有条-${_ts()}.ics';
      // 1) App 私有目录留一份，供「分享」按钮兜底使用。
      final file = await DataIo.saveToAppDocs(name, content);
      // 2) 同时写入系统「下载 / Downloads」目录，文件管理器可见。
      String msg = '已导出 iCal 到「下载」目录（含重复规则与提醒，可被系统日历导入）';
      try {
        await DataIo.saveToDownloads(name, content, mimeType: 'text/calendar');
      } catch (e) {
        msg = '已生成 .ics（下载目录写入失败，请改用「分享」）';
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            action: SnackBarAction(
              label: '分享',
              onPressed: () => DataIo.shareFile(file, mimeType: 'text/calendar'),
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

  /// 从 iCal (.ics) 导入任务：解析 VTODO/VEVENT → 逐条 addTask 追加（不覆盖现有）。
  /// 复杂 RRULE 已降级为一次性任务；结果给出成功/简化/跳过计数。
  static Future<void> _doImportIcs(
    TaskProvider provider,
    BuildContext context,
  ) async {
    // L-09：选择阶段已做 32MB 大小预检（读入前），这里保留原有的 2MB 业务上限。
    final picked = await DataIo.pickIcsFile();
    if (picked.cancelled) return;
    if (picked.error != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(picked.error!)));
      }
      return;
    }
    final raw = picked.content!;
    // P2-4：限制 .ics 文件体积（≤2MB），避免超大文件拖垮解析 / 一次性灌注海量任务。
    if (utf8.encode(raw).length > 2 * 1024 * 1024) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件过大（超过 2MB），请拆分后分批导入')),
        );
      }
      return;
    }
    try {
      final result = parseIcs(raw);
      if (result.tasks.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('未解析到可导入的任务（${result.report}）')),
          );
        }
        return;
      }
      // P0-3：先让用户选择导入策略（去重 / 覆盖 / 模糊去重），再走 importDedup 幂等入库，
      // 打通「导出 → 导入 → 模板」整条数据闭环，避免从「有条」导回时产生重复任务。
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Text('选择导入方式'),
            content: Text(
              '共解析到 ${result.tasks.length} 条任务。'
              '${result.simplifiedRepeat > 0 ? '其中 ${result.simplifiedRepeat} 条复杂重复已简化为一次性。' : ''}'
              // P2-1（v2.9.0 审计）：提醒段的迁移结果必须如实告知——迁移不了的要
              // 明说「提醒不迁移」，不能让它静默消失（旧实现整段忽略 AALARM/VALARM）。
              '${result.reminderMigrated > 0 ? '其中 ${result.reminderMigrated} 条任务带提醒，已一并迁移。' : ''}'
              '${result.reminderDropped > 0 ? '其中 ${result.reminderDropped} 条提醒格式不支持，未迁移，请导入后手动补设。' : ''}'
              '请选择重复任务的处理方式：',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(dctx);
                  _runImportDedup(provider, context, result,
                      skipExisting: true, overwrite: false, fingerprint: false);
                },
                child: const Text('跳过重复（推荐）'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(dctx);
                  _runImportDedup(provider, context, result,
                      skipExisting: false, overwrite: true, fingerprint: false);
                },
                child: const Text('覆盖更新'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(dctx);
                  _runImportDedup(provider, context, result,
                      skipExisting: true, overwrite: false, fingerprint: true);
                },
                child: const Text('模糊去重（标题+日期）'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  /// P0-3：按选定策略执行 iCal 幂等导入，并以 SnackBar 展示新增/覆盖/跳过计数。
  static Future<void> _runImportDedup(
    TaskProvider provider,
    BuildContext context,
    IcsImportResult result, {
    required bool skipExisting,
    required bool overwrite,
    required bool fingerprint,
  }) async {
    final stats = provider.importDedup(
      result.tasks,
      result.uids,
      skipExisting: skipExisting,
      overwrite: overwrite,
      fingerprint: fingerprint,
    );
    if (!context.mounted) return;
    final parts = <String>['新增 ${stats.added}'];
    if (stats.overwritten > 0) parts.add('覆盖 ${stats.overwritten}');
    if (stats.skipped > 0) parts.add('跳过 ${stats.skipped}');
    final extra = result.simplifiedRepeat > 0
        ? '（${result.simplifiedRepeat} 条复杂重复已简化为一次性）'
        : '';
    // F-10（v2.8.5 审计）：已映射但细节部分丢失的规则单独提示，不再静默。
    final partial = result.partialRepeat > 0
        ? '（${result.partialRepeat} 条重复规则部分保留，间隔/次数细节未支持）'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('iCal 导入完成：${parts.join('，')}$extra$partial')),
    );
  }

  static String _ts() {
    final d = DateTime.now();
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${d.year}${p(d.month)}${p(d.day)}-${p(d.hour)}${p(d.minute)}';
  }
}
