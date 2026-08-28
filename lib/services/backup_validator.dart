import 'dart:convert';

import 'package:todolist/models/task.dart';

/// 备份文件结构校验（S3：防恢复废档）。
///
/// 设计要点：
/// - 与 [TaskProvider.restoreFromJson] 解耦，作为恢复前的「前置关卡」；
/// - 纯 Dart、不依赖 flutter，可直接单测；
/// - 只做结构层面的体检（是不是「有条」的备份、字段是否齐整、能否解析），
///   不负责实际覆盖数据；通过返回 [BackupValidationResult] 让调用方决定
///   是否继续恢复、并给出可读的错误原因。
class BackupValidator {
  /// 校验备份原始字符串。返回 [BackupValidationResult]，含 [ok] 与 [error]。
  ///
  /// 入参 [raw] 为文件全文（UTF-8 文本）。任何异常（非 JSON / 结构非法）都转化为
  /// 非 ok 结果，绝不抛出，便于 UI 直接展示。
  static BackupValidationResult validate(String raw) {
    // 1) 基础：非空且为合法 JSON。
    if (raw.trim().isEmpty) {
      return const BackupValidationResult(false, '文件为空，无法恢复');
    }
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const BackupValidationResult(false, '不是有效的「有条」备份（顶层应为 JSON 对象）');
      }
      data = decoded;
    } on FormatException catch (e) {
      return BackupValidationResult(false, 'JSON 解析失败：$e');
    } catch (e) {
      return BackupValidationResult(false, '读取失败：$e');
    }

    // 2) 来源校验：必须是「有条」的备份，或至少带合法 tasks 列表（兼容老/第三方导出）。
    final app = data['app'];
    final tasksRaw = data['tasks'];
    final isYoutiao = app == '有条';
    final hasTasksList = tasksRaw is List;
    if (!isYoutiao && !hasTasksList) {
      return const BackupValidationResult(
          false, '不是「有条」的备份文件（缺少 app/任务列表），拒绝恢复以防清空数据');
    }

    // 3) schemaVersion / version 容错：有则应为合法整数且 ≥1；缺省不视为错误（老备份无此字段）。
    final version = data['version'];
    if (version != null && (version is! int || version < 1)) {
      return const BackupValidationResult(false, '备份版本号非法（应为 ≥1 的整数）');
    }

    // 4) 全量反序列化体检（S6/S7 修复）：复用与恢复**完全相同**的 [Task.fromJson]
    //    口径，对**每一条**任务做真实解析，而非仅抽样前 20 条或仅查字段形态。
    //    这样第 21 条之后带非法值的备份也能在校验阶段被拦下，不再"校验通过却恢复失败"。
    //    空列表也允许（用户可能清空了全部任务，但需配合 S7 的二次确认）。
    final list = (tasksRaw as List?) ?? [];
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      if (e is! Map) {
        return BackupValidationResult(false, '第 ${i + 1} 条任务不是对象，备份可能已损坏');
      }
      try {
        Task.fromJson(Map<String, dynamic>.from(e as Map));
      } catch (err) {
        return BackupValidationResult(false, '第 ${i + 1} 条任务解析失败（字段非法）：$err');
      }
    }

    // 5) 回收站字段若存，也应是列表形态，且逐条可解析。
    final trashRaw = data['trash'];
    if (trashRaw != null) {
      if (trashRaw is! List) {
        return const BackupValidationResult(false, '回收站字段形态非法');
      }
      for (var i = 0; i < (trashRaw).length; i++) {
        final e = (trashRaw)[i];
        if (e is! Map) {
          return BackupValidationResult(false, '回收站第 ${i + 1} 条不是对象，备份可能已损坏');
        }
        try {
          Task.fromJson(Map<String, dynamic>.from(e as Map));
        } catch (err) {
          return BackupValidationResult(false, '回收站第 ${i + 1} 条解析失败（字段非法）：$err');
        }
      }
    }

    // 全部通过。
    final count = list.length;
    final hasTrash = trashRaw is List && (trashRaw).isNotEmpty;
    // S7：标记是否为"空备份"（0 个任务且无回收站）。空备份恢复会清空现有任务，
    // 调用方须据此对"现有有数据"的情况强提示二次确认，默认不允许直接覆盖。
    final isEmpty = count == 0 && !hasTrash;
    return BackupValidationResult(true, '校验通过：含 $count 个任务${hasTrash ? '（含回收站）' : ''}',
        taskCount: count, hasTrash: hasTrash, isEmpty: isEmpty);
  }
}

/// 校验结果：是否通过 + 可读原因（UI 直接展示）。
class BackupValidationResult {
  final bool ok;
  final String message;
  final int taskCount;
  final bool hasTrash;
  /// S7：是否为空备份（任务数与回收站均为 0）。空备份恢复会清空现有全部数据。
  final bool isEmpty;
  const BackupValidationResult(this.ok, this.message,
      {this.taskCount = 0, this.hasTrash = false, this.isEmpty = false});

  @override
  String toString() => 'BackupValidationResult(ok=$ok, message=$message, isEmpty=$isEmpty)';
}
