/// A1（v3.1.1 功能增强）：恢复前差异预演摘要（`BackupSummary`）。
///
/// 从**已解析**的备份 JSON（经 [BackupValidator.validate] 通过后）生成恢复
/// 预览，不改备份 schema——只是把现有字段读出来给用户看：
/// - 元信息：生成时间、schemaVersion、App 版本（若有）、是否加密；
/// - 数据量：任务 / 回收站 / 习惯 / 打卡 / 专注 / 附件 / 用户模板；
/// - 时间范围：任务截止最早/最晚、专注记录最早/最晚；
/// - 当前对比：当前任务 / 习惯 / 专注条数（「备份中不存在的当前任务将不会被保留」）；
/// - 设置差异：备份内 prefs 与当前不同的**键名清单**（不显示值，避免 UI 过长
///   与敏感值泄露）。
///
/// 纯 Dart（不依赖 flutter），可直接单测；解析复用调用方已 jsonDecode 的
/// Map，不产生二次解析。
import 'package:shared_preferences/shared_preferences.dart';

class BackupSummary {
  final DateTime? generatedAt;
  final int? schemaVersion;
  final String? appVersion;
  final bool encrypted;
  final int taskCount;
  final int trashCount;
  final int habitCount;
  final int checkInCount;
  final int focusCount;
  final int attachmentCount;
  final int templateCount;
  final DateTime? earliestDue;
  final DateTime? latestDue;
  final DateTime? earliestFocusAt;
  final DateTime? latestFocusAt;
  /// 备份内 prefs 的键清单（白名单净化前的原始键名，仅用于展示数量）。
  final List<String> prefKeys;
  /// 当前与备份 prefs 不同的键名清单（A1 验收：只显示键名，不显示值）。
  final List<String> changedPrefKeys;
  // 当前对比
  final int currentTaskCount;
  final int currentHabitCount;
  final int currentFocusCount;

  const BackupSummary({
    this.generatedAt,
    this.schemaVersion,
    this.appVersion,
    this.encrypted = false,
    this.taskCount = 0,
    this.trashCount = 0,
    this.habitCount = 0,
    this.checkInCount = 0,
    this.focusCount = 0,
    this.attachmentCount = 0,
    this.templateCount = 0,
    this.earliestDue,
    this.latestDue,
    this.earliestFocusAt,
    this.latestFocusAt,
    this.prefKeys = const [],
    this.changedPrefKeys = const [],
    this.currentTaskCount = 0,
    this.currentHabitCount = 0,
    this.currentFocusCount = 0,
  });

  /// 从已解析的备份 Map 构建。[current*] 由调用方从各 Provider 现取。
  ///
  /// 任何字段形态不符一律按缺省计（备份在校验层已过形态体检，这里只做
  /// 摘要展示，绝不因单个坏字段抛错）。
  static Future<BackupSummary> fromMap(
    Map<String, dynamic> data, {
    bool encrypted = false,
    required int currentTaskCount,
    required int currentHabitCount,
    required int currentFocusCount,
  }) async {
    final tasks = _listOf(data['tasks']);
    final trash = _listOf(data['trash']);
    final habits = _listOf(data['habits']);
    final checkIns = _listOf(data['check_ins']);
    final focus = _listOf(data['focus_sessions']);
    final attachments = data['attachments'];
    var attachmentCount = 0;
    if (attachments is Map) {
      attachments.forEach((k, v) {
        // H1（v3.0.8 审计）同款豁免：__skipped 是统计段不是附件列表。
        if (k == '__skipped') return;
        if (v is List) attachmentCount += v.length;
      });
    }
    final templates = _listOf(data['user_templates']);

    DateTime? earliestDue;
    DateTime? latestDue;
    for (final e in [...tasks, ...trash]) {
      if (e is! Map) continue;
      final raw = e['dueDate'];
      if (raw is! String) continue;
      final d = DateTime.tryParse(raw);
      if (d == null) continue;
      if (earliestDue == null || d.isBefore(earliestDue)) earliestDue = d;
      if (latestDue == null || d.isAfter(latestDue)) latestDue = d;
    }
    DateTime? earliestFocusAt;
    DateTime? latestFocusAt;
    for (final e in focus) {
      if (e is! Map) continue;
      final raw = e['startedAt'];
      if (raw is! String) continue;
      final d = DateTime.tryParse(raw);
      if (d == null) continue;
      if (earliestFocusAt == null || d.isBefore(earliestFocusAt)) {
        earliestFocusAt = d;
      }
      if (latestFocusAt == null || d.isAfter(latestFocusAt)) {
        latestFocusAt = d;
      }
    }

    // 设置差异（仅键名）：备份 prefs 与当前 SharedPreferences 的不同键。
    final prefs = data['prefs'];
    final backupPrefKeys = <String>[];
    final changed = <String>[];
    if (prefs is Map) {
      final sp = await SharedPreferences.getInstance();
      prefs.forEach((k, v) {
        if (k is! String) return;
        backupPrefKeys.add(k);
        if (!sp.containsKey(k) || sp.get(k) != v) changed.add(k);
      });
      changed.sort();
    }

    return BackupSummary(
      generatedAt: _tryParse(data['generatedAt']),
      schemaVersion: data['schemaVersion'] is int ? data['schemaVersion'] as int : null,
      appVersion: data['appVersion'] is String ? data['appVersion'] as String : null,
      encrypted: encrypted,
      taskCount: tasks.length,
      trashCount: trash.length,
      habitCount: habits.length,
      checkInCount: checkIns.length,
      focusCount: focus.length,
      attachmentCount: attachmentCount,
      templateCount: templates.length,
      earliestDue: earliestDue,
      latestDue: latestDue,
      earliestFocusAt: earliestFocusAt,
      latestFocusAt: latestFocusAt,
      prefKeys: backupPrefKeys,
      changedPrefKeys: changed,
      currentTaskCount: currentTaskCount,
      currentHabitCount: currentHabitCount,
      currentFocusCount: currentFocusCount,
    );
  }

  static List _listOf(dynamic v) => v is List ? v : const [];

  static DateTime? _tryParse(dynamic v) =>
      v is String ? DateTime.tryParse(v) : null;

  /// 备份比当前旧多少天（按生成时间到现在的整天数；无生成时间 / 同日返回 0）。
  int get ageDays {
    final g = generatedAt;
    if (g == null) return 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(g.year, g.month, g.day);
    return today.difference(day).inDays;
  }

  /// 确认框正文（多行）。紧凑、黑白口径，不显示敏感值。
  String describe() {
    final p = (int n) => n.toString().padLeft(2, '0');
    String? fmt(DateTime? d) => d == null
        ? null
        : '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
    final lines = <String>[];
    final gen = fmt(generatedAt);
    if (gen != null) lines.add('生成于 $gen${ageDays > 0 ? '（$ageDays 天前）' : ''}');
    if (appVersion != null) lines.add('应用版本：$appVersion');
    if (encrypted) lines.add('已加密（口令验证通过）');
    lines.add(
        '数据量：任务 $taskCount、回收站 $trashCount、习惯 $habitCount、'
        '打卡 $checkInCount、专注 $focusCount、附件 $attachmentCount、'
        '模板 $templateCount');
    final dueRange = (fmt(earliestDue) == null && fmt(latestDue) == null)
        ? null
        : '${fmt(earliestDue) ?? '—'} ~ ${fmt(latestDue) ?? '—'}';
    if (dueRange != null) lines.add('任务截止范围：$dueRange');
    final focusRange = (fmt(earliestFocusAt) == null && fmt(latestFocusAt) == null)
        ? null
        : '${fmt(earliestFocusAt) ?? '—'} ~ ${fmt(latestFocusAt) ?? '—'}';
    if (focusRange != null) lines.add('专注记录范围：$focusRange');
    lines.add('当前对比：任务 $currentTaskCount、习惯 $currentHabitCount、'
        '专注 $currentFocusCount；恢复将覆盖现有数据，备份中不存在的当前任务'
        '将不会被保留');
    if (changedPrefKeys.isNotEmpty) {
      lines.add(
          '设置差异：${changedPrefKeys.length} 个偏好键与当前不同'
          '（${changedPrefKeys.take(6).join('、')}'
          '${changedPrefKeys.length > 6 ? ' 等' : ''}）');
    } else if (prefKeys.isNotEmpty) {
      lines.add('设置：与当前无差异（${prefKeys.length} 个键）');
    }
    return lines.join('\n');
  }
}
