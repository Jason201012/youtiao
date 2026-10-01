/// T2-6（v2.9.2 功能增强）：CSV 批量导入服务 —— 把 CSV 文本解析成任务草稿。
///
/// ## 设计要点
///
/// - **宽松列映射**：列名中英文别名都收（标题/title、截止/due…），大小写不敏感，
///   忽略空格与下划线差异；未识别的列**忽略不报错**（Excel 手工表常有附加列）。
///   首行探测不到任何已知列别名时，按固定列序兜底：
///   `标题, 截止, 优先级, 分类, 标签, 备注, 预计`。
/// - **RFC 4180 子集解析**：双引号包裹字段、双写引号转义、逗号 / CR / LF / CRLF
///   行尾、UTF-8 BOM 剥除。不引第三方 CSV 包（零依赖 + 严格离线红线）。
/// - **逐行校验报告**：标题为空 / 截止非空但格式不可解析 → 该行进 [CsvImportResult.errors]，
///   不阻断其余行；优先级 / 分类未知值**宽松回退默认**（与 [Task.fromJson] 的
///   容错口径一致），预计时长不可解析时静默视为「无预估」。
/// - 数值区间夹取与 [Task.fromJson] 同口径（导入是不可信输入）。
library;

import 'package:todolist/models/task.dart';

/// 一条导入失败行。[row] 为 1 起始的物理行号（含表头行）。
class CsvImportRowError {
  final int row;
  final String reason;
  const CsvImportRowError(this.row, this.reason);
}

/// CSV 导入解析结果：成功草稿 + 失败行报告 + 数据行总数（不含表头）。
class CsvImportResult {
  final List<Task> tasks;
  final List<CsvImportRowError> errors;
  final int totalRows;

  /// P1-1（v2.9.9 审计）：被识别并**忽略**的非任务数据段数量。本 App 的 CSV
  /// 导出把任务 / 专注 / 习惯三张表依次拼接（各自带独立表头），旧实现把后续段
  /// 的所有行都按任务列解析 → 导回自带文件会一次性灌入大量伪任务。现在遇到
  /// 后续段的表头行即停止任务解析，被忽略的段数在此如实上报。
  final int skippedSections;

  const CsvImportResult({
    required this.tasks,
    required this.errors,
    required this.totalRows,
    this.skippedSections = 0,
  });
  bool get hasErrors => errors.isNotEmpty;
}

/// 解析 [raw]（UTF-8 文本，可带 BOM）为任务草稿列表。
///
/// 表头自动探测：首行任一格命中「标题」类别名即按表头解析，否则按固定列序。
/// 所有草稿 `id` 为空串（交由 [TaskProvider.importDedup] / addTask 分配新 id）。
CsvImportResult parseTasksCsv(String raw) {
  final rows = _parseCsvRows(raw);
  if (rows.isEmpty) {
    return const CsvImportResult(tasks: [], errors: [], totalRows: 0);
  }

  // 列名归一：小写 + 去空格 + 去下划线 + 去括号（半/全角），中英文别名都能命中。
  // P2-2（v2.9.9 审计）：本 App 导出表头是「预计时长(分钟)」，旧归一不去括号 →
  // 导回时预计列别名全不命中、预计时长往返即丢。
  String norm(String s) => s
      .trim()
      .toLowerCase()
      .replaceAll(' ', '')
      .replaceAll('_', '')
      .replaceAll(RegExp(r'[（）()]'), '');
  final first = rows.first.map(norm).toList();

  const titleAliases = {'标题', '任务', '任务名', 'title', 'task', 'name'};
  final hasHeader = first.any(titleAliases.contains);

  // 列序号映射：canonical → 物理列。
  final cols = <String, int>{};
  var dataRows = rows;
  if (hasHeader) {
    for (var i = 0; i < first.length; i++) {
      if (first[i].isEmpty) continue;
      cols[first[i]] = i;
    }
    dataRows = rows.sublist(1);
  }

  int? colOf(List<String> aliases) {
    for (final a in aliases) {
      final idx = cols[norm(a)];
      if (idx != null) return idx;
    }
    return null;
  }

  // 无表头兜底：固定列序 `标题, 截止, 优先级, 分类, 标签, 备注, 预计`
  // （UI 弹层无列序清单文案，扩第 7 列不与任何提示冲突；旧行为忽略该列，
  // 现按预估解析、不可解析静默为 null，对既有 CSV 零破坏）。
  final iTitle = hasHeader
      ? colOf(titleAliases.toList())
      : (rows.first.isNotEmpty ? 0 : null);
  final iDue = hasHeader
      ? colOf(['截止', '截止时间', '截止日期', '到期', 'due', 'duedate'])
      : 1;
  final iStart = hasHeader
      ? colOf(['开始', '开始时间', '开始日期', 'start', 'startdate'])
      : null;
  final iPriority = hasHeader
      ? colOf(['优先级', 'priority'])
      : 2;
  final iCategory = hasHeader ? colOf(['分类', 'category']) : 3;
  final iTags = hasHeader ? colOf(['标签', 'tags', 'tag']) : 4;
  final iNote = hasHeader
      ? colOf(['备注', '说明', 'note', 'notes', 'remark'])
      : 5;
  final iEstimate = hasHeader
      ? colOf([
          '预计',
          '预计时长',
          '预计分钟',
          '预计时长分钟', // P2-2：本 App 导出表头「预计时长(分钟)」的归一形态
          'estimate',
          'estimateminutes',
          'estimatemin',
        ])
      : 6; // 无表头兜底第 7 列 = 预计（原被忽略，纯增强零破坏）。

  final tasks = <Task>[];
  final errors = <CsvImportRowError>[];
  var totalRows = 0;
  var skippedSections = 0;
  // P1-1（v2.9.9 审计）：命中非任务段表头后置位——此后所有行都视为其它表的
  // 内容丢弃，只有再次命中段表头时继续计数（三表拼接：任务段 + 专注段 + 习惯段，
  // 计数如实反映被忽略的段数），绝不把段内数据行当任务解析。
  var skipping = false;

  for (var r = 0; r < dataRows.length; r++) {
    final cells = dataRows[r];
    // 物理行号：表头占第 1 行；无表头时数据从第 1 行起。
    final physical = hasHeader ? r + 2 : r + 1;
    if (cells.every((c) => c.trim().isEmpty)) continue; // 全空行跳过
    // P1-1（v2.9.9 审计）：三表拼接的导出文件，专注 / 习惯段的表头行首列是
    // 「日期」/「习惯」——命中即认定任务段结束，进入跳过模式：后续行不再按
    // 任务列解析造伪任务、不计错误。段数记入 [CsvImportResult.skippedSections]
    // 由 UI 如实提示。首格恰好叫「日期/习惯」的任务表会被误判提前截断，属
    // 可接受的保守取舍（宁可少导不可灌垃圾）。
    final firstCell = norm(cells.first);
    if (hasHeader && (firstCell == '日期' || firstCell == '习惯')) {
      skippedSections++;
      skipping = true;
      continue;
    }
    if (skipping) continue; // 非任务段的普通行（专注/习惯数据）：整体丢弃
    totalRows++;

    String cell(int? idx) =>
        (idx == null || idx >= cells.length) ? '' : cells[idx].trim();

    final title = cell(iTitle);
    if (title.isEmpty) {
      errors.add(CsvImportRowError(physical, '标题为空，无法导入'));
      continue;
    }
    final dueRaw = cell(iDue);
    DateTime? due;
    if (dueRaw.isNotEmpty) {
      due = _parseDateTime(dueRaw);
      if (due == null) {
        errors.add(CsvImportRowError(physical,
            '截止「$dueRaw」无法识别（支持 yyyy-MM-dd[ HH:mm] 等格式）'));
        continue;
      }
    }
    final startRaw = cell(iStart);
    DateTime? start;
    if (startRaw.isNotEmpty) {
      start = _parseDateTime(startRaw);
      if (start == null) {
        errors.add(CsvImportRowError(physical, '开始「$startRaw」无法识别'));
        continue;
      }
    }
    final estimate = _parseEstimate(cell(iEstimate));
    final tags = _parseTags(cell(iTags));

    tasks.add(Task(
      id: '', // 新任务：由 addTask 分配 id
      title: title,
      priority: _parsePriority(cell(iPriority)),
      category: _parseCategory(cell(iCategory)),
      dueDate: due,
      startDate: start,
      note: cell(iNote),
      tags: tags,
      estimateMinutes: estimate,
    ));
  }
  return CsvImportResult(
      tasks: tasks,
      errors: errors,
      totalRows: totalRows,
      skippedSections: skippedSections);
}

/// RFC 4180 子集 CSV 解析：引号包裹、双写转义、逗号 / CR / LF / CRLF、BOM 剥除。
List<List<String>> _parseCsvRows(String raw) {
  final text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
  final rows = <List<String>>[];
  final field = StringBuffer();
  var row = <String>[];
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',') {
      row.add(field.toString());
      field.clear();
    } else if (ch == '\n' || ch == '\r') {
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
    } else {
      field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

/// 宽松日期解析：ISO（[DateTime.tryParse]）优先，其次
/// `yyyy/M/d`、`yyyy-M-d`、`yyyy.M.d` 可选「HH:mm[:ss]」（T 或空格分隔）。
DateTime? _parseDateTime(String s) {
  final v = s.trim();
  if (v.isEmpty) return null;
  final iso = DateTime.tryParse(v);
  if (iso != null) return iso;
  final m = RegExp(
          r'^(\d{4})[\/\-\.](\d{1,2})[\/\-\.](\d{1,2})'
          r'(?:[T\s]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$')
      .firstMatch(v);
  if (m == null) return null;
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4) ?? '0'),
    int.parse(m.group(5) ?? '0'),
    int.parse(m.group(6) ?? '0'),
  );
}

/// 预计时长：`90` / `90分` / `90分钟` / `1.5h` / `2小时` → 分钟；
/// 无单位按分钟。越界（<1 或 >30 天）与不可解析返回 null（视为无预估，
/// 与 [Task.fromJson] 的夹取口径一致——备份 / 导入是不可信输入）。
int? _parseEstimate(String s) {
  final v = s.trim().toLowerCase();
  if (v.isEmpty) return null;
  final m = RegExp(
          r'^(\d+(?:\.\d+)?)\s*(小时|h|hr|hours?|分钟|分|m|min|minutes?)?$')
      .firstMatch(v);
  if (m == null) return null;
  final n = double.tryParse(m.group(1)!);
  if (n == null) return null;
  final unit = m.group(2);
  final isHour = unit != null &&
      (unit == 'h' || unit == 'hr' || unit.startsWith('hour') ||
          unit.startsWith('小时'));
  final mins = isHour ? (n * 60).round() : n.round();
  if (mins < 1 || mins > 30 * 24 * 60) return null;
  return mins;
}

/// 标签：按中英文常见分隔符切分、去空、去重，保持顺序。
List<String> _parseTags(String s) {
  if (s.trim().isEmpty) return const <String>[];
  final out = <String>[];
  for (final part in s.split(RegExp(r'[,，、;；/|]'))) {
    final t = part.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }
  return out;
}

/// 优先级宽松解析：未知值回退 [Priority.medium]（与 [Task.fromJson] 同口径）。
Priority _parsePriority(String s) {
  final v = s.trim().toLowerCase();
  if (v == '高' || v == 'high' || v == 'h' || v == 'p1' || v == '重要') {
    return Priority.high;
  }
  if (v == '低' || v == 'low' || v == 'l' || v == 'p3' || v == '不重要') {
    return Priority.low;
  }
  return Priority.medium;
}

/// 分类宽松解析：未知值回退 [Category.life]（与 [Task.fromJson] 同口径）。
Category _parseCategory(String s) {
  final v = s.trim().toLowerCase();
  if (v == '工作' || v == 'work') return Category.work;
  if (v == '学习' || v == 'study') return Category.study;
  return Category.life;
}
