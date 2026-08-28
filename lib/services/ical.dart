import 'package:todolist/models/task.dart';

/// iCal (.ics) 标准格式导入 / 导出。
///
/// 纯 Dart、UTF-8 全程，CRLF 行尾（RFC 5545 要求），零依赖，可直接单测。
/// 与系统日历 / Outlook / Google 日历 / 滴答清单等互通的最短路径——「数据主权最后一公里」。
///
/// 导出：把任务映射为 [VTODO]；导入：解析 [VTODO]（及 [VEVENT] 的 DTSTART 当 dueDate），
/// 复杂 [RRULE]（MONTHLY/YEARLY/带 COUNT 等）降级为一次性任务并在结果里计数提示。

/// iCal 周几 → DateTime.weekday（1=周一 … 7=周日）。
const Map<String, int> _icsWeekdayToDart = {
  'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7,
};
/// DateTime.weekday（1=周一）→ iCal 周几两字母。
const Map<int, String> _dartWeekdayToIcs = {
  1: 'MO', 2: 'TU', 3: 'WE', 4: 'TH', 5: 'FR', 6: 'SA', 7: 'SU',
};

/// 把一行文本转义为 iCal 属性值（逗号 / 分号 / 反斜杠 / 换行，避免破坏结构）。
String _escapeIcs(String s) => s
    .replaceAll('\\', '\\\\')
    .replaceAll(';', '\\;')
    .replaceAll(',', '\\,')
    .replaceAll('\r', '')
    .replaceAll('\n', '\\n');

/// 还原 iCal 属性值转义。
String _unescapeIcs(String s) => s
    .replaceAll('\\n', '\n')
    .replaceAll('\\,', ',')
    .replaceAll('\\;', ';')
    .replaceAll('\\\\', '\\');

/// 把 DateTime 格式化为本地浮动时间 YYYYMMDDTHHMMSS（不带时区，符合 iCal 浮动时间语义）。
String _toIcsLocalTime(DateTime d) =>
    '${d.year}${_pad2(d.month)}${_pad2(d.day)}T${_pad2(d.hour)}${_pad2(d.minute)}${_pad2(d.second)}';

/// 把 yyyyMMdd（UNTIL）或 yyyyMMddTHHMMSS 解析为 DateTime；失败返回 null。
DateTime? _parseIcsDateTime(String s) {
  // 去掉可能的 Z / 时区前缀，只取数字。
  final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 8) return null;
  final y = int.tryParse(digits.substring(0, 4));
  final mo = int.tryParse(digits.substring(4, 6));
  final d = int.tryParse(digits.substring(6, 8));
  if (y == null || mo == null || d == null) return null;
  int h = 0, mi = 0, se = 0;
  if (digits.length >= 14) {
    h = int.tryParse(digits.substring(8, 10)) ?? 0;
    mi = int.tryParse(digits.substring(10, 12)) ?? 0;
    se = int.tryParse(digits.substring(12, 14)) ?? 0;
  }
  try {
    return DateTime(y, mo, d, h, mi, se);
  } catch (_) {
    return null;
  }
}

String _pad2(int n) => n.toString().padLeft(2, '0');

/// 把一组任务导出为完整 .ics（外层 VCALENDAR + 每个任务的 VTODO）。
///
/// [tasks] 为活跃任务；[extra] 为可选的额外任务（如回收站需一并导出时传入）。
String exportIcs(List<Task> tasks, {List<Task>? extra}) {
  final all = [...tasks, ...?extra];
  final buf = StringBuffer();
  buf.writeln('BEGIN:VCALENDAR');
  buf.writeln('VERSION:2.0');
  buf.writeln('PRODID:-//youtiao//CN');
  buf.writeln('CALSCALE:GREGORIAN');
  for (final t in all) {
    buf.writeln('BEGIN:VTODO');
    buf.writeln('UID:${t.id}@youtiao');
    buf.writeln('SUMMARY:${_escapeIcs(t.title)}');
    if (t.dueDate != null) {
      buf.writeln('DUE:${_toIcsLocalTime(t.dueDate!)}');
    }
    if (t.note.isNotEmpty) {
      buf.writeln('DESCRIPTION:${_escapeIcs(t.note)}');
    }
    // 优先级：高=1 / 中=5 / 低=9（iCal 1 最高、9 最低）。
    final prio = t.priority == Priority.high
        ? 1
        : t.priority == Priority.low
            ? 9
            : 5;
    buf.writeln('PRIORITY:$prio');
    // 分类 + 标签合并进 CATEGORIES。
    final cats = <String>[t.category.label, ...t.tags.where((x) => x.isNotEmpty)];
    if (cats.isNotEmpty) {
      buf.writeln('CATEGORIES:${cats.map(_escapeIcs).join(',')}');
    }
    if (t.status == TaskStatus.done) {
      buf.writeln('STATUS:COMPLETED');
      if (t.completedAt != null) {
        buf.writeln('COMPLETED:${_toIcsLocalTime(t.completedAt!)}');
      }
    }
    // 重复规则 → RRULE（含结束日期 UNTIL）。
    final rrule = _toRrule(t);
    if (rrule != null) buf.writeln(rrule);
    buf.writeln('END:VTODO');
  }
  buf.writeln('END:VCALENDAR');
  // 统一 CRLF（RFC 5545）。
  return buf.toString().replaceAll('\n', '\r\n');
}

/// 把任务重复规则映射为 RRULE 行（含 UNTIL）。无重复返回 null。
String? _toRrule(Task t) {
  if (t.repeat == RepeatType.none) return null;
  String base;
  switch (t.repeat) {
    case RepeatType.daily:
      base = 'FREQ=DAILY';
    case RepeatType.weekday:
      base = 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR';
    case RepeatType.weekly:
      final days = t.repeatWeekdays
          .where((d) => _dartWeekdayToIcs.containsKey(d))
          .map((d) => _dartWeekdayToIcs[d]!)
          .join(',');
      base = 'FREQ=WEEKLY;BYDAY=${days.isEmpty ? 'MO' : days}';
    case RepeatType.interval:
      base = 'FREQ=DAILY;INTERVAL=${t.repeatInterval < 1 ? 1 : t.repeatInterval}';
    case RepeatType.monthly:
      if (t.monthlyWeekday != null && t.monthlyWeekIndex != null) {
        final wd = _dartWeekdayToIcs[t.monthlyWeekday!];
        final pos = t.monthlyWeekIndex == 5 ? -1 : t.monthlyWeekIndex!;
        base = wd != null ? 'FREQ=MONTHLY;BYDAY=$wd;BYSETPOS=$pos' : 'FREQ=MONTHLY';
      } else {
        base = 'FREQ=MONTHLY;BYMONTHDAY=${t.monthlyDay.clamp(1, 31)}';
      }
    case RepeatType.none:
      return null;
  }
  if (t.repeatUntil != null) {
    // UNTIL 用 yyyyMMdd（date-only），与 repeatUntil 的 yyyy-MM-dd 互换。
    final u = t.repeatUntil!.replaceAll('-', '');
    base += ';UNTIL=$u';
  }
  return 'RRULE:$base';
}

/// .ics 导入结果：可入库任务 + 复杂重复被简化计数 + 失败计数 + 可读报告。
class IcsImportResult {
  final List<Task> tasks;
  final int simplifiedRepeat;
  final int failed;
  final String report;
  const IcsImportResult({
    required this.tasks,
    required this.simplifiedRepeat,
    required this.failed,
    required this.report,
  });
}

/// 解析 .ics 文本，返回可入库任务列表与统计。
///
/// 只识别 [VTODO]（含 [VEVENT] 的 DTSTART 当 dueDate）。复杂 [RRULE]
///（非 DAILY/WEEKLY、含 COUNT/EXDATE 等）降级为一次性任务并计入 [simplifiedRepeat]。
IcsImportResult parseIcs(String content) {
  // 1) 展开 RFC5545 行折叠（以空格/Tab 开头的续行拼到上一行）。
  final lines = _unfold(content);
  // 2) 切分为以 BEGIN:VTODO / BEGIN:VEVENT 起、END 止的块。
  final blocks = <Map<String, String>>[];
  Map<String, String>? current;
  String? currentKind;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('BEGIN:VTODO')) {
      current = <String, String>{};
      currentKind = 'VTODO';
    } else if (line.startsWith('BEGIN:VEVENT')) {
      current = <String, String>{};
      currentKind = 'VEVENT';
    } else if (line.startsWith('END:VTODO') ||
        line.startsWith('END:VEVENT')) {
      if (current != null && currentKind != null) blocks.add(current);
      current = null;
      currentKind = null;
    } else if (current != null) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).toUpperCase();
      final value = line.substring(idx + 1);
      // 同一 key 可能出现多次（如多 CATEGORIES），用首个即可。
      current.putIfAbsent(key, () => value);
    }
  }
  // 3) 逐块映射为 Task。
  final tasks = <Task>[];
  var simplified = 0;
  var failed = 0;
  for (final b in blocks) {
    try {
      final task = _blockToTask(b);
      if (task != null) {
        if (task.repeat == RepeatType.none && b['RRULE'] != null) {
          // 原本有 RRULE 但被降级为一次性 → 计入「简化」。
          simplified++;
        }
        tasks.add(task);
      } else {
        failed++;
      }
    } catch (_) {
      failed++;
    }
  }
  final report = '成功解析 ${tasks.length} 条'
      '${simplified > 0 ? '（其中 $simplified 条复杂重复已简化为一次性）' : ''}'
      '${failed > 0 ? '，跳过 $failed 条' : ''}';
  return IcsImportResult(
    tasks: tasks,
    simplifiedRepeat: simplified,
    failed: failed,
    report: report,
  );
}

/// 展开折叠行：前一行为 `KEY:VALUE`，后续以空格/Tab 开头的行是续行。
List<String> _unfold(String content) {
  final out = <String>[];
  for (final raw in content.split('\n')) {
    final line = raw.replaceAll('\r', '');
    if (out.isEmpty) {
      out.add(line);
    } else if (line.startsWith(' ') || line.startsWith('\t')) {
      out[out.length - 1] += line.trimLeft();
    } else {
      out.add(line);
    }
  }
  return out;
}

/// 单个块 → [Task]；解析失败或必要字段缺失返回 null。
Task? _blockToTask(Map<String, String> b) {
  final summary = b['SUMMARY'];
  if (summary == null || summary.isEmpty) return null;
  final title = _unescapeIcs(summary);

  DateTime? dueDate;
  final due = b['DUE'] ?? b['DTSTART'];
  if (due != null) dueDate = _parseIcsDateTime(due);

  final note = b['DESCRIPTION'] != null ? _unescapeIcs(b['DESCRIPTION']!) : '';

  // 优先级：1/2/3 → 高；4/5/6 → 中；7/8/9 → 低；缺省中。
  Priority priority = Priority.medium;
  final p = int.tryParse(b['PRIORITY'] ?? '');
  if (p != null) {
    priority = p <= 3 ? Priority.high : p <= 6 ? Priority.medium : Priority.low;
  }

  // 分类：优先取 CATEGORIES 首个已知分类，否则默认工作。
  Category category = Category.work;
  final catsRaw = b['CATEGORIES'];
  if (catsRaw != null) {
    final first = catsRaw.split(',').first.trim();
    if (first == '生活') category = Category.life;
    if (first == '学习') category = Category.study;
  }

  // 标签：CATEGORIES 中除分类外的部分。
  final tags = <String>[];
  if (catsRaw != null) {
    for (final c in catsRaw.split(',')) {
      final t = c.trim();
      if (t.isNotEmpty && t != category.label) tags.add(t);
    }
  }

  // 完成态。
  final done = (b['STATUS'] ?? '').toUpperCase() == 'COMPLETED';
  DateTime? completedAt;
  if (done && b['COMPLETED'] != null) completedAt = _parseIcsDateTime(b['COMPLETED']!);

  // 重复规则（解析 FREQ/BYDAY/INTERVAL/UNTIL；其余降级一次性）。
  final rrule = b['RRULE'];
  RepeatType repeat = RepeatType.none;
  List<int> weekdays = const <int>[];
  int interval = 2;
  String? repeatUntil;
  // 每月重复（.ics 往返用）：day-of-month 或 第 N 个周几。
  int monthlyDayIcs = 1;
  int? monthlyWeekdayIcs;
  int? monthlyWeekIndexIcs;
  if (rrule != null) {
    final map = <String, String>{};
    for (final part in rrule.split(';')) {
      final kv = part.split('=');
      if (kv.length == 2) map[kv[0].toUpperCase()] = kv[1];
    }
    final freq = (map['FREQ'] ?? '').toUpperCase();
    if (freq == 'DAILY') {
      if (map.containsKey('INTERVAL')) {
        final n = int.tryParse(map['INTERVAL']!);
        if (n != null && n > 1) {
          repeat = RepeatType.interval;
          interval = n;
        } else {
          repeat = RepeatType.daily;
        }
      } else {
        repeat = RepeatType.daily;
      }
    } else if (freq == 'WEEKLY') {
      final byday = map['BYDAY'] ?? '';
      final days = byday
          .split(',')
          .map((s) => _icsWeekdayToDart[s.trim().toUpperCase()])
          .whereType<int>()
          .toList();
      if (days.length >= 5 &&
          days.toSet().containsAll(_dartWeekdayToIcs.keys.where((k) => k <= 5))) {
        // 含全部工作日 → 仅工作日。
        repeat = RepeatType.weekday;
      } else if (days.length == 1) {
        repeat = RepeatType.weekly;
        weekdays = days;
      } else if (days.isNotEmpty) {
        repeat = RepeatType.weekly;
        weekdays = days;
      } else {
        repeat = RepeatType.weekly;
        weekdays = const [1];
      }
    } else if (freq == 'MONTHLY') {
      // 每月 N 号：BYMONTHDAY；每月第 N 个周几：BYDAY + BYSETPOS（-1=最后一个）。
      final byMonthDay = map['BYMONTHDAY'];
      if (byMonthDay != null) {
        final d = int.tryParse(byMonthDay);
        if (d != null && d >= 1 && d <= 31) {
          repeat = RepeatType.monthly;
          monthlyDayIcs = d;
          monthlyWeekdayIcs = null;
          monthlyWeekIndexIcs = null;
        }
      } else {
        final byday = map['BYDAY'] ?? '';
        final wd = _icsWeekdayToDart[byday.trim().toUpperCase()];
        final setposRaw = map['BYSETPOS'];
        if (wd != null && setposRaw != null) {
          final p = int.tryParse(setposRaw);
          final pos = (p == -1)
              ? 5
              : (p != null && p >= 1 && p <= 4 ? p : null);
          if (pos != null) {
            repeat = RepeatType.monthly;
            monthlyWeekdayIcs = wd;
            monthlyWeekIndexIcs = pos;
          }
        }
      }
    } else {
      // YEARLY / 含 COUNT 等 → 降级为一次性。
      repeat = RepeatType.none;
    }
    if (map.containsKey('UNTIL')) {
      final u = _parseIcsDateTime(map['UNTIL']!);
      if (u != null) {
        repeatUntil =
            '${u.year}-${_pad2(u.month)}-${_pad2(u.day)}';
      }
    }
  }

  return Task(
    id: '', // 入库时由 addTask 分配
    title: title,
    priority: priority,
    category: category,
    dueDate: dueDate,
    status: done ? TaskStatus.done : TaskStatus.todo,
    completedAt: completedAt,
    note: note,
    tags: tags,
    repeat: repeat,
    repeatWeekdays: weekdays,
    repeatInterval: interval,
    repeatUntil: repeatUntil,
    monthlyDay: monthlyDayIcs,
    monthlyWeekday: monthlyWeekdayIcs,
    monthlyWeekIndex: monthlyWeekIndexIcs,
    pinyinInitials: Task.computePinyinInitials(title),
  );
}
