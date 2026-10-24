import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/services/csv_safe.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/ical.dart';
import 'package:todolist/services/report_exporter.dart';
import 'package:todolist/services/task_import_service.dart';
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
                  // P2-6（v2.9.1 审计）：CSV / Excel 是**可读副本**（列已补备注 / 标签 /
                  // 子任务 / 开始时间 / 重复规则 / 提醒 / 累计专注，但仍不可能是完整数据：
                  // 附件二进制、完成历史、跳过记录等都不在其中）。副标题如实说明，
                  // 避免用户把它当归档 / 迁移副本后不可逆丢数据。
                  subtitle: const Text('表格格式，含任务、习惯与专注记录，可用 Excel 打开'
                      '（可读副本，完整数据请用备份）'),
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
                  subtitle: const Text('表格工作簿，含任务 / 专注 / 习惯 / 打卡记录，'
                      '可用 Excel / WPS 打开（可读副本，完整数据请用备份）'),
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
                ListTile(
                  leading: const Icon(Symbols.upload_file),
                  title: const Text('从 CSV (.csv) 导入'),
                  // T2-6（v2.9.2 功能增强）：批量导入——列映射宽松、逐行校验，
                  // 失败行如实报告（可修正后重导），成功行走与 iCal 相同的幂等去重。
                  subtitle: const Text('把 Excel / 其它工具导出的表格批量建为任务'
                      '（列名支持中文/英文，追加不覆盖）'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doImportCsv(taskProvider, context);
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
      // P2-5（v2.9.1 审计）：CSV 首部补 UTF-8 BOM（U+FEFF）。Excel / WPS 在没有 BOM
      // 时按系统 ANSI（简体中文 Windows 即 GBK）解码，中文列名与内容**全量乱码**，
      // 与弹层副标题「可用 Excel 打开」直接矛盾。BOM 只加在 CSV：MD / JSON 加 BOM
      // 反而会污染正文与解析。
      final rawContent = '$contentTask\n$contentFocus\n$contentHabit';
      final content = isCsv ? withUtf8Bom(rawContent) : rawContent;
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
      // P3-9（v2.9.6 审计）：补一句「预计时长依赖扩展属性」的说明——DUE 与
      // DURATION 互斥（P2-2，v2.9.5）后预计时长随 `X-YOUTIAO-ESTIMATE-MINUTES`
      // 携带，第三方日历按规范会忽略 `X-` 扩展属性不回显（导回本 App 不丢），
      // 不说明用户会以为时长迁丢了。
      String msg = '已导出 iCal 到「下载」目录（含重复规则与提醒；预计时长为'
          '本 App 扩展属性，部分第三方日历不显示，导回「有条」不丢）';
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
              // M4（v3.0.8 审计）：超 500 条被解析层截断（maxItems），两处文案
              // （本确认框 + 结果 SnackBar）都必须消费 result.truncated——旧实现
              // 都不消费，用户以为全量迁入，尾批任务凭空消失（解析层注释自述
              // 「调用方应提示用户分批导入」从未被执行）。
              '${result.truncated ? '文件超出单批 500 条上限，仅解析前 500 条，请拆分后分批导入。' : ''}'
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
                      overwrite: false, fingerprint: false);
                },
                child: const Text('跳过重复（推荐）'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(dctx);
                  _runImportDedup(provider, context, result,
                      overwrite: true, fingerprint: false);
                },
                child: const Text('覆盖更新'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(dctx);
                  _runImportDedup(provider, context, result,
                      overwrite: false, fingerprint: true);
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
  ///
  /// P2-2（v3.0.0 审计）：iCal 解析层提供「源是否显式提供」元信息
  /// （[IcsImportResult.meta]），透传给 [TaskProvider.importDedup]——覆盖更新
  /// 只改写源显式携带的字段，缺省（无 PRIORITY/CATEGORIES/STATUS 行）保留原值。
  ///
  /// M3 / P3-6（v3.0.8 审计）：await 落盘结果——旧实现不等 importDedup 的
  /// `_persist()` 就报「导入完成」，DB 异常时重启后导入条目全部蒸发。saved=false
  /// 时文案改为「生效但未保存，请重试」。
  static Future<void> _runImportDedup(
    TaskProvider provider,
    BuildContext context,
    IcsImportResult result, {
    required bool overwrite,
    required bool fingerprint,
  }) async {
    final stats = await provider.importDedup(
      result.tasks,
      result.uids,
      overwrite: overwrite,
      fingerprint: fingerprint,
      priorities: [for (final m in result.meta) m.priority],
      categories: [for (final m in result.meta) m.category],
      statuses: [for (final m in result.meta) m.status],
    );
    if (!context.mounted) return;
    final parts = <String>['新增 ${stats.added}'];
    if (stats.overwritten > 0) parts.add('覆盖 ${stats.overwritten}');
    if (stats.skipped > 0) parts.add('跳过 ${stats.skipped}');
    final extra = result.simplifiedRepeat > 0
        ? '（${result.simplifiedRepeat} 条复杂重复已简化为一次性）'
        : '';
    // M4（v3.0.8 审计）：截断提示同步进结果 SnackBar（确认框之后用户可能已
    // 忘记分批提醒，这里再如实给一次）。
    final truncatedNote =
        result.truncated ? '（超出单批 500 条上限，尾批未导入，请分批）' : '';
    // F-10（v2.8.5 审计）：已映射但细节部分丢失的规则单独提示，不再静默。
    final partial = result.partialRepeat > 0
        ? '（${result.partialRepeat} 条重复规则部分保留，间隔/次数细节未支持）'
        : '';
    final notSaved = stats.saved
        ? ''
        : '；写入未保存（DB 异常），请重试或检查存储空间';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('iCal 导入完成：${parts.join('，')}'
              '$extra$partial$truncatedNote$notSaved')),
    );
  }

  /// T2-6（v2.9.2 功能增强）：从 CSV 批量导入任务。
  ///
  /// 流程与 iCal 导入同构：选文件 → 解析（[parseTasksCsv]，逐行校验）→
  /// 策略选择（与 iCal 同款去重弹窗）→ [TaskProvider.importDedup] 幂等入库。
  /// 失败行在弹窗里如实预览（最多 3 条），绝不静默丢弃。
  static Future<void> _doImportCsv(
    TaskProvider provider,
    BuildContext context,
  ) async {
    final picked = await DataIo.pickCsvFile();
    if (picked.cancelled) return;
    if (picked.error != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(picked.error!)));
      }
      return;
    }
    final raw = picked.content!;
    // 与 iCal 导入同款 2MB 业务上限（超大表会拖垮解析与一次性灌注）。
    if (utf8.encode(raw).length > 2 * 1024 * 1024) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件过大（超过 2MB），请拆分后分批导入')),
        );
      }
      return;
    }
    try {
      // P2-4（v2.9.9 审计）：解析移入 isolate——旧实现在 UI isolate 同步解析，
      // 2MB 上限内的大表会明显卡顿。
      final result = await compute(parseTasksCsv, raw);
      // P3-1（v2.9.9 审计）：校验失败明细最多展示 3 条（旧实现只报首条，
      // 与「最多 3 条」的文档注释不符）；分段截断信息一并告知。
      // P3-5（v3.0.0 审计）：被忽略的段数文案如实列举三段（专注/习惯/打卡）——
      // 本 App 导出实为三个非任务段，旧文案只列两个。
      final errHead = result.errors.isEmpty
          ? ''
          : '；${result.errors.length} 行未通过校验被跳过（'
              '${result.errors.take(3).map((e) => '第 ${e.row} 行：${e.reason}').join('；')}'
              '${result.errors.length > 3 ? '…等' : ''}）';
      final sectionNote = result.skippedSections > 0
          ? '；已忽略 ${result.skippedSections} 个非任务数据段（专注 / 习惯 / 打卡）'
          : '';
      // P2-6（v3.0.0 审计）：回收站条目（是否已删除=是）不再导入为活动任务，
      // 跳过数如实提示——旧实现把它们反向复活为活动任务。
      final deletedNote = result.skippedDeleted > 0
          ? '；${result.skippedDeleted} 条回收站条目已跳过（不导入已删除内容）'
          : '';
      // M5（v3.0.8 审计）：单批 500 条上限的截断提示（与 iCal 同口径）。
      final truncatedNote = result.truncated
          ? '；文件超出单批 500 条上限，仅解析前 500 条，请拆分后分批导入'
          : '';
      if (result.tasks.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('未解析到可导入的任务'
                    '$errHead$sectionNote$deletedNote$truncatedNote')),
          );
        }
        return;
      }
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Text('选择导入方式'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '共解析到 ${result.tasks.length} 条任务（数据行 ${result.totalRows} 行）'
                    '$errHead$sectionNote$deletedNote$truncatedNote。'
                    // P1-2（v2.9.9 审计）：CSV 没有稳定 ID（草稿 id 为空），重复判定
                    // 一律按「标题 + 截止日期」指纹——必须如实告知判定依据。
                    '\nCSV 无稳定 ID：重复按「标题 + 截止日期」判定。',
                  ),
                  const SizedBox(height: 8),
                  // U2-3 / P2-6（v3.0.0 审计）：字段保真边界如实披露——导出 16 列
                  // 里只有部分可机器还原，其余为人类可读的存档摘要；用户把 CSV
                  // 当迁移格式时必须先知道哪些列不会回来（迁移请用备份 JSON）。
                  Text(
                    '可导入列：标题、截止、开始、优先级、分类、标签、备注、'
                    '预计、状态、完成时间。\n'
                    '仅存档（导入不还原）：重复规则、提醒、子任务、附件、'
                    '累计专注——迁移请用备份 JSON。\n'
                    '标签以「、」等分隔，标签名本身请勿含分隔符。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(dctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(dctx);
                  _runCsvImportDedup(provider, context, result,
                      overwrite: false);
                },
                child: const Text('跳过重复（推荐）'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(dctx);
                  _runCsvImportDedup(provider, context, result,
                      overwrite: true);
                },
                child: const Text('覆盖更新'),
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

  /// T2-6：按选定策略执行 CSV 幂等导入。
  ///
  /// P1-2（v2.9.9 审计）：CSV 草稿 `id` 为空、UID 全为 null，旧实现把 iCal 的
  /// 三挡策略原样透传且 `fingerprint: false` ——「跳过重复」「覆盖更新」在
  /// importDedup 里拿到的 existing 恒为 null，两挡**都等于无条件全量新增**，
  /// 默认推荐项反而整表制造副本。现收敛为两挡并**强制指纹去重**：跳过 =
  /// 命中「标题+截止」即跳过；覆盖 = 命中后更新（来源为空的字段保留原值，
  /// 见 TaskProvider.importDedup 的合并规则）。
  ///
  /// P2-2（v3.0.0 审计）：透传解析层元信息（[CsvImportResult.meta]）——
  /// 覆盖更新只改写源显式携带的优先级/分类/状态；「是否已删除」行已在
  /// 解析层跳过并计数。
  static Future<void> _runCsvImportDedup(
    TaskProvider provider,
    BuildContext context,
    CsvImportResult result, {
    required bool overwrite,
  }) async {
    final stats = await provider.importDedup(
      result.tasks,
      List<String?>.filled(result.tasks.length, null),
      overwrite: overwrite,
      fingerprint: true, // P1-2：CSV 无 UID，必须走标题+截止指纹
      priorities: [for (final m in result.meta) m.priority],
      categories: [for (final m in result.meta) m.category],
      statuses: [for (final m in result.meta) m.status],
      completedAts: [for (final m in result.meta) m.completedAt],
    );
    if (!context.mounted) return;
    final parts = <String>['新增 ${stats.added}'];
    if (stats.overwritten > 0) parts.add('覆盖 ${stats.overwritten}');
    if (stats.skipped > 0) parts.add('跳过 ${stats.skipped}');
    final failed = result.errors.isEmpty
        ? ''
        : '（${result.errors.length} 行校验失败未导入）';
    // M5（v3.0.8 审计）：截断提示同步进结果 SnackBar。
    final csvTruncatedNote =
        result.truncated ? '（超出单批 500 条上限，尾批未导入，请分批）' : '';
    // M3 / P3-6（v3.0.8 审计）：消费落盘结果（同 iCal 入口）。
    final notSaved = stats.saved
        ? ''
        : '；写入未保存（DB 异常），请重试或检查存储空间';
    // U2-5（v3.0.0 审计）：失败行不再只报条数——完整清单（行号 + 原因，
    // 可滚动）在结果对话框里给出，用户可按行号定位修正后定点重导。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'CSV 导入完成：${parts.join('，')}$failed$csvTruncatedNote$notSaved')),
    );
    if (result.errors.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: Text('未导入的 ${result.errors.length} 行'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final e in result.errors)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('第 ${e.row} 行：${e.reason}',
                          style: TextStyle(
                              fontSize: 12,
                              color:
                                  Theme.of(dctx).colorScheme.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }

  static String _ts() {
    final d = DateTime.now();
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${d.year}${p(d.month)}${p(d.day)}-${p(d.hour)}${p(d.minute)}';
  }
}
