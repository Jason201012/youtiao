import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/task.dart';

/// T3-4（v2.9.2 功能增强）：数据体检——常态数据的健康扫描与修复辅助。
///
/// **纯函数库**：零 IO、零依赖 Provider。附件实体存在性由调用方以
/// [existingAttachmentKeys]（key 约定 `taskId/fileName`）传入，时间以 [scan] 的
/// `now` 注入，便于单测覆盖。UI / Provider 侧只做取数与执行修复动作。
///
/// 扫描四类问题（与《功能增强建议报告（v2.9.2）》T3-4 对齐）：
/// 1. **完全重复任务**：未删除列表中同标题（trim 后）+ 同分类同时存在多条；
/// 2. **空白子任务**：子任务标题为空白（录入侧已挡，但历史数据/导入可能带进）；
/// 3. **失效附件引用**：任务元数据里还挂着附件，实体文件已不在私有目录；
/// 4. **超期回收站条目**：已过保留期但尚未被自动清理（仅保留期 ≥ 0 时有意义）。

/// 体检问题类型。
enum DataHealthIssueType {
  /// 完全重复任务（同标题 + 同分类）。
  duplicateTask,

  /// 空白子任务（标题为空白的子项）。
  emptySubtask,

  /// 失效附件引用（实体文件缺失）。
  missingAttachment,

  /// 超期未清理的回收站条目。
  staleTrash,
}

/// 单条体检问题。重复任务类问题以组内**首条**任务为锚点，
/// [relatedIds] 携带组内其余任务 id（修复时移入回收站的就是它们）。
class DataHealthIssue {
  final DataHealthIssueType type;

  /// 锚点任务 id（重复任务 = 每组保留的首条）。
  final String taskId;

  /// 锚点任务标题（展示用）。
  final String title;

  /// 人类可读的详情描述。
  final String detail;

  /// 重复任务组内除锚点外的其余任务 id；其余类型恒为空。
  final List<String> relatedIds;

  const DataHealthIssue({
    required this.type,
    required this.taskId,
    required this.title,
    required this.detail,
    this.relatedIds = const [],
  });
}

/// 一次体检的报告：问题列表 + 按类型计数。
class DataHealthReport {
  final List<DataHealthIssue> issues;

  const DataHealthReport(this.issues);

  bool get isHealthy => issues.isEmpty;

  int countOf(DataHealthIssueType type) =>
      issues.where((i) => i.type == type).length;
}

class DataHealthService {
  /// 重复任务分组的键：trim + 小写 + 内部空白折叠后的标题 + 分类名。
  /// P3-12（v2.9.9 审计）：旧键大小写敏感、内部空格差异都判为不同任务——
  /// 「买菜」与「买菜 」/「Buy milk」与「buy milk」互相漏判。归一后同名
  /// 异写也能聚成一组（修复仍是软删，可反悔）。
  static String duplicateKeyOf(Task t) =>
      '${t.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}'
      '\u0000${t.category.name}';

  /// 扫描四类健康问题（纯函数）。
  ///
  /// [tasks] 未删除任务、[trash] 回收站条目；[existingAttachmentKeys] 为本机
  /// 私有目录实际存在的附件实体 key（`taskId/fileName`，由调用方做文件 IO
  /// 后传入）；[uncertainAttachmentKeys] 为**探测异常**的引用 key（P2-13，
  /// v2.9.9 审计：异常 ≠ 缺失，这类引用不报失效、修复时不剔除）；
  /// [trashRetentionDays] 为回收站保留期（≤ 0 = 永不自动清理，
  /// 此时跳过超期扫描——P3-13，v2.9.9 审计：门槛从 `>= 0` 收紧为 `> 0`，
  /// 防止将来把「0」当「不清理」引入时 cutoff=now 把全部条目判超期）；
  /// [now] 缺省取当前时间。
  static DataHealthReport scan({
    required List<Task> tasks,
    required List<Task> trash,
    required Set<String> existingAttachmentKeys,
    Set<String> uncertainAttachmentKeys = const {},
    required int trashRetentionDays,
    DateTime? now,
  }) {
    final n = now ?? DateTime.now();
    final issues = <DataHealthIssue>[];

    // 1) 完全重复任务：同（trim 标题 + 分类）分组，组内 > 1 条即报一条 issue，
    //    锚点为组内首条（保留它），其余进 [relatedIds] 供修复移入回收站。
    final groups = <String, List<Task>>{};
    for (final t in tasks) {
      groups.putIfAbsent(duplicateKeyOf(t), () => []).add(t);
    }
    for (final g in groups.values) {
      if (g.length < 2) continue;
      final keep = g.first;
      final dupIds = g.skip(1).map((t) => t.id).toList();
      issues.add(DataHealthIssue(
        type: DataHealthIssueType.duplicateTask,
        taskId: keep.id,
        title: keep.title,
        detail: '「${keep.title}」存在 ${g.length} 条同标题同分类任务，'
            '将保留 1 条、其余 ${dupIds.length} 条移入回收站',
        relatedIds: dupIds,
      ));
    }

    // 2) 空白子任务 + 3) 失效附件引用：活动列表与回收站都扫。
    for (final t in [...tasks, ...trash]) {
      final emptyCount =
          t.subtasks.where((s) => s.title.trim().isEmpty).length;
      if (emptyCount > 0) {
        issues.add(DataHealthIssue(
          type: DataHealthIssueType.emptySubtask,
          taskId: t.id,
          title: t.title,
          detail: '「${t.title}」有 $emptyCount 个空白子项，将被剔除',
        ));
      }
      final missing = t.attachments
          .where((a) =>
              !existingAttachmentKeys.contains('${t.id}/${a.fileName}') &&
              // P2-13（v2.9.9 审计）：探测异常的引用不判失效（异常 ≠ 缺失）。
              !uncertainAttachmentKeys.contains('${t.id}/${a.fileName}'))
          .toList();
      if (missing.isNotEmpty) {
        issues.add(DataHealthIssue(
          type: DataHealthIssueType.missingAttachment,
          taskId: t.id,
          title: t.title,
          detail: '「${t.title}」有 ${missing.length} 个附件实体已缺失'
              '（${missing.map((a) => a.fileName).join('、')}），将剔除失效引用',
        ));
      }
    }

    // 4) 超期回收站条目：与 TaskProvider._cleanupTrashIfNeeded 同口径
    //    （deletedAt 严格早于保留期截点；无 deletedAt 视为新近，保留）。
    //    P3-13（v2.9.9 审计）：门槛 `> 0`——保留期 UI 选项为 7/30/90/-1，
    //    「-1 = 永不清理」是唯一收口语义；若将来把「0」当「不清理」引入，
    //    旧判据 `>= 0` 会令 cutoff=now、全部条目被判超期并永久删除。
    if (trashRetentionDays > 0) {
      final cutoff = n.subtract(Duration(days: trashRetentionDays));
      final todayDate = DateTime(n.year, n.month, n.day);
      for (final t in trash) {
        final d = t.deletedAt;
        if (d == null || !d.isBefore(cutoff)) continue;
        final deletedDate = DateTime(d.year, d.month, d.day);
        final days = todayDate.difference(deletedDate).inDays;
        issues.add(DataHealthIssue(
          type: DataHealthIssueType.staleTrash,
          taskId: t.id,
          title: t.title,
          detail: '回收站「${t.title}」已存放 $days 天'
              '（保留期 $trashRetentionDays 天），将被彻底删除（含附件）',
        ));
      }
    }

    return DataHealthReport(issues);
  }

  /// 修复「空白子任务」：返回剔除空白项后的子任务列表。
  static List<SubTask> dropEmptySubtasks(List<SubTask> subtasks) =>
      subtasks.where((s) => s.title.trim().isNotEmpty).toList();

  /// 修复「失效附件引用」：返回剔除失效引用后的附件列表。
  /// [taskId] 用于拼实体 key（`taskId/fileName`）。
  /// [uncertainKeys] 为探测异常的引用（P2-13，v2.9.9 审计）：既不算存在也
  /// 不算缺失，**保留**不剔除——修复绝不基于一次失败的探测删数据。
  static List<AttachmentRef> dropMissingAttachments(
    List<AttachmentRef> attachments,
    String taskId,
    Set<String> existingAttachmentKeys, {
    Set<String> uncertainKeys = const {},
  }) =>
      attachments
          .where((a) =>
              existingAttachmentKeys.contains('$taskId/${a.fileName}') ||
              uncertainKeys.contains('$taskId/${a.fileName}'))
          .toList();

  /// 重复任务组内应**保留**的首条 id 集合（供修复后核对）。
  static Set<String> keepIdsOfDuplicates(List<DataHealthIssue> issues) =>
      issues
          .where((i) => i.type == DataHealthIssueType.duplicateTask)
          .map((i) => i.taskId)
          .toSet();
}
