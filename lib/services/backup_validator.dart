import 'dart:convert';

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

    // 4) 抽样反序列化：至少能成功解析列表中的任务字段；空列表也允许（用户可能清空了全部任务）。
    final list = (tasksRaw as List?) ?? [];
    if (list.isNotEmpty) {
      // 抽前 20 条做轻量结构校验：每条应为对象，且含最基本的 id/title（缺省也兼容）。
      // 这里不强制全量反序列化为 Task（真正的 fromJson 干跑在 restoreFromJson 内完成），
      // 仅做「字段形态」体检，避免恢复一个字段全错的废档。
      for (var i = 0; i < list.length && i < 20; i++) {
        final e = list[i];
        if (e is! Map) {
          return BackupValidationResult(false, '第 ${i + 1} 条任务不是对象，备份可能已损坏');
        }
        // 关键字段形态体检：priority / category 若存在应为字符串（否则 fromJson 会抛）。
        final prio = e['priority'];
        final cat = e['category'];
        if (prio != null && prio is! String) {
          return BackupValidationResult(false, '第 ${i + 1} 条任务 priority 非法');
        }
        if (cat != null && cat is! String) {
          return BackupValidationResult(false, '第 ${i + 1} 条任务 category 非法');
        }
      }
    }

    // 5) 回收站字段若存，也应是列表形态。
    final trashRaw = data['trash'];
    if (trashRaw != null && trashRaw is! List) {
      return const BackupValidationResult(false, '回收站字段形态非法');
    }

    // 全部通过。
    final count = list.length;
    final hasTrash = trashRaw is List && (trashRaw).isNotEmpty;
    return BackupValidationResult(true, '校验通过：含 $count 个任务${hasTrash ? '（含回收站）' : ''}',
        taskCount: count, hasTrash: hasTrash);
  }
}

/// 校验结果：是否通过 + 可读原因（UI 直接展示）。
class BackupValidationResult {
  final bool ok;
  final String message;
  final int taskCount;
  final bool hasTrash;
  const BackupValidationResult(this.ok, this.message,
      {this.taskCount = 0, this.hasTrash = false});

  @override
  String toString() => 'BackupValidationResult(ok=$ok, message=$message)';
}
