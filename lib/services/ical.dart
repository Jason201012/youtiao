import 'package:todolist/models/task.dart';

/// iCal (.ics) 标准格式导入 / 导出。
///
/// 纯 Dart、UTF-8 全程，CRLF 行尾（RFC 5545 要求），零依赖，可直接单测。
/// 与系统日历 / Outlook / Google 日历 / 滴答清单等互通的最短路径——「数据主权最后一公里」。
///
/// 导出：把任务映射为 [VTODO]（DUE / CATEGORIES / RRULE / VALARM）；
/// 导入：解析 [VTODO]（及 [VEVENT] 的 DTSTART 当 dueDate）与提醒段
/// （RFC 5545 `VALARM` 的 TRIGGER、vCalendar 1.0 `AALARM`）→ [Task.reminderOffsetMin]，
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
///
/// P2-2（v2.9.1 审计）：改为**单趟左到右解码**——旧实现是两趟 `replaceAll`，无论
/// 顺序如何都会破坏「反斜杠 + 字母 n」这类字面序列：
/// - 先实体后反斜杠（v2.9.1 的原实现）：`a\\nb`（转义前的原始文本是 `a` + `\` + `n` + `b`，
///   导出为 `a\\nb`）第一趟把 `\n` 解成换行，第二趟再把剩下的 `\` 收掉 →
///   得到「`a` + 换行 + `b`」，字面 `\n` 被静默改成真换行；
/// - 先反斜杠后实体：`\\n` 会被先收成 `\`，再与后面的 `n` 组成假转义。
///
/// 唯一正确的做法是像 RFC 5545 §3.3.11 那样逐字符扫描：遇到 `\` 时**消费两个字符**
/// 并一次性还原（`\\`→`\`、`\n`/`\N`→换行、`\t`→制表、`\,`→逗号、`\;`→分号），
/// 绝不回扫。无法识别的转义（`\x`）原样保留（宽容第三方 .ics），末尾孤立 `\` 亦原样保留。
String _unescapeIcs(String s) {
  if (!s.contains('\\')) return s; // 无转义字符：直接返回，避开逐字符扫描
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch != '\\') {
      sb.write(ch);
      continue;
    }
    if (i + 1 >= s.length) {
      sb.write(ch); // 末尾孤立反斜杠：原样保留
      break;
    }
    final next = s[i + 1];
    switch (next) {
      case '\\':
        sb.write('\\');
        break;
      case 'n':
      case 'N':
        sb.write('\n');
        break;
      case 't':
        sb.write('\t');
        break;
      case ',':
        sb.write(',');
        break;
      case ';':
        sb.write(';');
        break;
      default:
        // 未知转义：按 RFC 属非法编码，宽处理为「原样保留两个字符」，
        // 避免把第三方 .ics 里的内容静默吃掉。
        sb.write(ch);
        sb.write(next);
    }
    i++; // 关键：消费掉被转义的那个字符，绝不回扫
  }
  return sb.toString();
}

/// 把 DateTime 格式化为本地浮动时间 YYYYMMDDTHHMMSS（不带时区，符合 iCal 浮动时间语义）。
String _toIcsLocalTime(DateTime d) =>
    '${d.year}${_pad2(d.month)}${_pad2(d.day)}T${_pad2(d.hour)}${_pad2(d.minute)}${_pad2(d.second)}';

/// 把 yyyyMMdd（UNTIL）或 yyyyMMddTHHMMSS 解析为 DateTime；失败返回 null。
///
/// F14：
/// - 行尾 `Z` 表示 UTC，按 RFC 5545 §3.3.5 用 `DateTime.utc(...)` 构造后
///   `.toLocal()` 转本地；此前直接按本地解读，跨时区设备会把 09:00 UTC
///   错算为本地 09:00，造成截止时间偏移数小时。
/// - `VALUE=DATE` 形态（仅日期，无 T 时间段）已由 `digits.length < 14` 分支
///   自动落到 00:00:00，无需特殊处理。
/// - `TZID=...` 形态：本 App 无 IANA 时区数据库，按「本地浮动时间」处理
///   （与导出侧的 `_toIcsLocalTime` 对称——零额外依赖）。
DateTime? _parseIcsDateTime(String s) {
  final trimmed = s.trim();
  // F14：行尾 Z → UTC；前缀空白与 CRLF 由 .trim() 去掉。
  final isUtc = trimmed.toUpperCase().endsWith('Z');
  final body = isUtc ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  final digits = body.replaceAll(RegExp(r'[^0-9]'), '');
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
    if (isUtc) {
      return DateTime.utc(y, mo, d, h, mi, se).toLocal();
    }
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
    // P2-1（v2.9.0 审计）：重复任务的 DUE 取「今天起首个循环日 + repeatMinute」的
    // 真实落点，而不是录入侧的占位 dueDate（常常为 null）——否则 RRULE 无起点、
    // VALARM 也无从表达提醒时刻。
    final due = _exportDue(t);
    if (due != null) {
      buf.writeln('DUE:${_toIcsLocalTime(due)}');
    }
    if (t.note.isNotEmpty) {
      buf.writeln('DESCRIPTION:${_escapeIcs(t.note)}');
    }
    // P3-10（v2.9.4 审计）：预计时长此前只在 Excel/CSV 与应用内展示，iCal 侧
    // 完全没有该字段——用户把任务导入系统日历 / 第三方待办后，「预计 45 分钟」
    // 这一信息单向丢失，排期时只能凭感觉。RFC 5545 用 DURATION 表达时长，
    // 这是 VTODO 表达预计耗时的标准位置（TYPE=DURATION，默认值）。
    if (t.estimateMinutes != null) {
      buf.writeln('DURATION:PT${t.estimateMinutes}M');
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
    // P2-1（v2.9.0 审计）：提醒段（VALARM）——此前导出侧从不写提醒，用户在系统日历 /
    // 第三方待办里看到事件却「到点不响」，跨日历互操作时提醒信息单向静默丢失。
    _writeAlarm(buf, t, due);
    buf.writeln('END:VTODO');
  }
  buf.writeln('END:VCALENDAR');
  // 统一 CRLF（RFC 5545）。
  return buf.toString().replaceAll('\n', '\r\n');
}

/// P2-1（v2.9.0 审计）：导出侧 `DUE` 的真实口径。
///
/// - 非重复任务：即 [Task.dueDate]（提醒提前量由 `VALARM` 的 TRIGGER 表达）；
/// - 重复任务：取「今天起首个循环日」并把时刻设为 [Task.repeatMinute]（该重复的提醒
///   时刻）。此前重复任务只写 `t.dueDate`——自 v2.8.5 起录入侧不再把它钉成
///   「创建当天 23:59」占位，故往往为 null：第三方日历里既没有落点也没有提醒，
///   `RRULE` 也失去锚点。
/// - 重复任务未设 `repeatMinute`（无提醒时刻）或 366 天内已无循环日（已结束重复）时，
///   回退旧的 `t.dueDate` 行为（可能为 null）。
///
/// P3-1（v2.9.1 审计）：首落点自「**提醒时刻尚未过去的今天**」起算，否则自明天起算。
/// 此前恒取「今天（若今天是循环日）」，于是上午导出「每天 07:00」这类任务时会写出
/// 一个今天 07:00 的 DUE + `TRIGGER:PT0S`——第三方日历同步后会把这条已过期的提醒
/// 立刻补响，与 occurrence_sheet「今天提醒已过则自明天起算」的新口径自相矛盾。
DateTime? _exportDue(Task t) {
  if (t.repeat == RepeatType.none) return t.dueDate;
  final hhmm = t.repeatMinute;
  if (hhmm == null) return t.dueDate;
  final now = DateTime.now();
  // 今天在该时刻的落点是否还没过去（PT0S 语义：提醒时刻 == DUE 时刻）。
  final todaySlot = DateTime(now.year, now.month, now.day,
      (hhmm ~/ 60).clamp(0, 23), (hhmm % 60).clamp(0, 59));
  final from = todaySlot.isAfter(now) ? now : now.add(const Duration(days: 1));
  final first = _firstOccurrence(t, from: from);
  if (first == null) return t.dueDate;
  return DateTime(
    first.year,
    first.month,
    first.day,
    (hhmm ~/ 60).clamp(0, 23),
    (hhmm % 60).clamp(0, 59),
  );
}

/// 自 [from]（默认今天）当天（含）起 366 天内的首个循环日；无则返回 null
///（已结束重复 / 规则失效）。
///
/// 复用 [Task.repeatsOn]，因此已跳过的日子会被跳过（提醒不应落在被跳过的当天）。
DateTime? _firstOccurrence(Task t, {DateTime? from}) {
  final n = from ?? DateTime.now();
  final s = DateTime(n.year, n.month, n.day);
  for (var i = 0; i < 366; i++) {
    final d = DateTime(s.year, s.month, s.day + i);
    if (t.repeatsOn(d)) return d;
  }
  return null;
}

/// P2-1（v2.9.0 审计）：把任务的提醒写成语义等价的 `VALARM` 段。
///
/// 语义与通知排程（notification_service `_scheduleDeadline` / 重复提醒落点）严格对齐：
/// - 非重复任务：提醒时刻 = `DUE − reminderOffsetMin` → `TRIGGER:-PT{n}M`；
///   `reminderOffsetMin == 0` 表示与落点同一时刻 → `TRIGGER:PT0S`（零时长，RFC 5545
///   不允许 `-PT0M` 这类「负零」写法）；
/// - 重复任务：提醒时刻即每个循环日的 `repeatMinute`，而 `DUE` 已落在该时刻上
///   → `TRIGGER:PT0S`（见 [_exportDue]）；
/// - 无落点（`due == null`）或重复任务无 `repeatMinute` → 不写该段（无提醒可迁移）。
void _writeAlarm(StringBuffer buf, Task t, DateTime? due) {
  if (due == null) return;
  final int offsetMin;
  if (t.repeat != RepeatType.none) {
    if (t.repeatMinute == null) return;
    offsetMin = 0;
  } else {
    offsetMin = t.reminderOffsetMin;
  }
  buf.writeln('BEGIN:VALARM');
  buf.writeln('ACTION:DISPLAY');
  buf.writeln('DESCRIPTION:${_escapeIcs(t.title)}');
  buf.writeln(offsetMin > 0 ? 'TRIGGER:-PT${offsetMin}M' : 'TRIGGER:PT0S');
  buf.writeln('END:VALARM');
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
  /// F-10（v2.8.5 审计）：重复规则**已映射**、但含未支持成分（COUNT / 间隔>1 的
  /// WEEKLY·MONTHLY / DAILY 带 BYDAY / 带序数前缀的 BYDAY 等）被部分简化的条数。
  /// 此前这类「看似导入成功、实则丢了细节」的条目完全静默。
  final int partialRepeat;
  final int failed;
  final String report;
  /// P2-4：是否因超过单批解析上限（[parseIcs] 的 [maxItems]）被截断。
  final bool truncated;
  /// P2-1（v2.9.0 审计）：**带提醒段但提醒无法迁移**的条数（`TRIGGER` 形态不可表达，
  /// 如「晚于落点提醒」、缺少落点导致绝对时刻无从求差等）。此前这类信息完全静默，
  /// 用户以为「同步成功」，实际第三方日历的提醒丢了。
  final int reminderMigrated;
  final int reminderDropped;
  /// P0-3：与 [tasks] 平行的原始 UID 列表（可能为 null，第三方 .ics 往往无 UID）。
  /// youtiao 导出的 UID 形如 `<数字id>@youtiao`，解析层已把对应任务 id 设为该数字 id，
  /// 故 [tasks] 中这些任务的 id 非空，可直接用于 [TaskProvider.importDedup] 的 UID 去重。
  final List<String?> uids;
  const IcsImportResult({
    required this.tasks,
    required this.simplifiedRepeat,
    this.partialRepeat = 0,
    required this.failed,
    required this.report,
    this.truncated = false,
    this.reminderMigrated = 0,
    this.reminderDropped = 0,
    this.uids = const [],
  });
}

/// 解析 .ics 文本，返回可入库任务列表与统计。
///
/// 只识别 [VTODO]（含 [VEVENT] 的 DTSTART 当 dueDate）。复杂 [RRULE]
///（非 DAILY/WEEKLY、含 COUNT/EXDATE 等）降级为一次性任务并计入 [simplifiedRepeat]。
///
/// P2-4：单批最多解析 [maxItems] 条（默认 500），超出截断并标记 [truncated]，
/// 避免数万条 VTODO 一次性入库导致卡顿/存储膨胀（调用方应提示用户分批导入）。
IcsImportResult parseIcs(String content, {int maxItems = 500}) {
  // 1) 展开 RFC5545 行折叠（以空格/Tab 开头的续行拼到上一行）。
  final lines = _unfold(content);
  // 2) 切分为以 BEGIN:VTODO / BEGIN:VEVENT 起、END 止的块。
  final blocks = <Map<String, String>>[];
  Map<String, String>? current;
  String? currentKind;
  // 提醒段（`BEGIN:VALARM` … `END:VALARM`）内的属性加 `ALARM.` 前缀单独存放。
  // 若不隔离，VALARM 的 `DESCRIPTION`（本 App 导出时写的就是任务标题）会在
  // VTODO 自身没有 DESCRIPTION 时顶替成「备注」——「导出 → 导入」往返会把备注
  // 污染成标题，属静默数据变形。
  var inAlarm = false;
  for (final raw in lines) {
    // P3-5（v2.9.1 审计）：结构判定用 trim 后的行，但**属性值取自未 trim 的原始行**
    // ——RFC 5545 的值内空白有意义（`SUMMARY:  foo` 的前导空格属于标题本身）。
    // 旧实现对整行 `raw.trim()`，把值首尾空白一并削掉，标题 / 备注静默变形。
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('BEGIN:VTODO')) {
      current = <String, String>{};
      currentKind = 'VTODO';
      inAlarm = false;
    } else if (line.startsWith('BEGIN:VEVENT')) {
      current = <String, String>{};
      currentKind = 'VEVENT';
      inAlarm = false;
    } else if (line.startsWith('BEGIN:VALARM')) {
      inAlarm = true;
    } else if (line.startsWith('END:VALARM')) {
      inAlarm = false;
    } else if (line.startsWith('END:VTODO') ||
        line.startsWith('END:VEVENT')) {
      if (current != null && currentKind != null) blocks.add(current);
      current = null;
      currentKind = null;
      inAlarm = false;
    } else if (current != null) {
      // F14：RFC 5545 §3.1 允许属性带参数，形如 `DTSTART;VALUE=DATE:20240101` /
      // `DTSTART;TZID=Asia/Shanghai:20240101T090000`。原本 `indexOf(':')`
      // 直接把前半段当成 key，导致 `DTSTART;VALUE=DATE` 被误识别为完整 key
      // 而查不到 DUE/DTSTART。修正：先以第一个 `:` 切出「name+params / value」，
      // 再以 `;` 切出 name，作为存储 key；参数部分留作后续字段级解析用。
      final idx = raw.indexOf(':');
      if (idx <= 0) continue;
      final head = raw.substring(0, idx);
      final value = raw.substring(idx + 1); // 保留值内空白（P3-5）
      final name = head.split(';').first.trim().toUpperCase();
      if (name.isEmpty) continue;
      // 同一 key 可能出现多次（如多 CATEGORIES），用首个即可。
      current.putIfAbsent(inAlarm ? 'ALARM.$name' : name, () => value);
    }
  }
  // 3) 逐块映射为 Task。
  final tasks = <Task>[];
  // P0-3：与 [tasks] 平行的原始 UID 列表（可能为 null）。youtiao 导出的 UID 形如
  // `<数字id>@youtiao`，解析层已把对应任务 id 设为该数字 id，故这些任务可直接用于
  // [TaskProvider.importDedup] 的 UID 去重；第三方 .ics 往往无 UID → null。
  final uids = <String?>[];
  var simplified = 0;
  var partial = 0;
  var failed = 0;
  var truncated = false;
  var reminderMigrated = 0;
  var reminderDropped = 0;
  for (final b in blocks) {
    // P2-4：达到单批上限即停止，剩余块不再解析，避免批量灌注 DoS。
    if (tasks.length >= maxItems) {
      truncated = true;
      break;
    }
    try {
      final task = _blockToTask(b);
      if (task != null) {
        if (task.repeat == RepeatType.none && b['RRULE'] != null) {
          // 原本有 RRULE 但被降级为一次性 → 计入「简化」。
          simplified++;
        } else if (task.repeat != RepeatType.none &&
            b['RRULE'] != null &&
            _rruleHasUnsupportedParts(b['RRULE']!)) {
          // F-10（v2.8.5 审计）：规则已映射、但部分细节未保留 → 计入「部分简化」，
          // 不再静默（此前如 `FREQ=WEEKLY;INTERVAL=2` 会变成每周，无任何提示）。
          partial++;
        }
        tasks.add(task);
        // 同步收集该块的原始 UID（可能是 null），保持与 tasks 平行。
        uids.add(b['UID']);
        // P2-1（v2.9.0 审计）：统计提醒段的迁移结果——带提醒段但迁移不了的要如实
        // 告知用户「提醒不迁移」，而不是让它静默消失（旧实现整段忽略）。
        // P3-7（v2.9.1 审计）：重复任务的提醒时刻由 `repeatMinute`（当天时刻）表达，
        // 与「相对 DUE 的提前量」不是同一语义——只有提前量为 0（提醒时刻 == 落点时刻）
        // 时才能如实迁移（见 [_blockToTask] 对 repeatMinute 的回填）；非零提前量在
        // 重复语义下无从表达，必须计入「未迁移」，不能算作已迁移（陈述要如实）。
        if (_hasAlarmSegment(b)) {
          final off = _parseAlarmOffsetMin(b, _blockDueDate(b));
          // 判定「是否真的迁成了」：一次性任务看提前量是否可表达；重复任务还要确认
          // repeatMinute 真的被回填（无 DUE 时无从取得时刻，同样属未迁移）。
          final migratable = off != null &&
              (task.repeat == RepeatType.none ||
                  (off == 0 && task.repeatMinute != null));
          if (migratable) {
            reminderMigrated++;
          } else {
            reminderDropped++;
          }
        }
      } else {
        failed++;
      }
    } catch (_) {
      failed++;
    }
  }
  final report = '成功解析 ${tasks.length} 条'
      '${simplified > 0 ? '（其中 $simplified 条复杂重复已简化为一次性）' : ''}'
      '${partial > 0 ? '（$partial 条重复规则部分保留，间隔/次数等细节未支持）' : ''}'
      '${reminderMigrated > 0 ? '（$reminderMigrated 条提醒已迁移）' : ''}'
      '${reminderDropped > 0 ? '（$reminderDropped 条提醒未迁移：格式不支持）' : ''}'
      '${failed > 0 ? '，跳过 $failed 条' : ''}'
      '${truncated ? '，已截断（最多 $maxItems 条，请分批导入）' : ''}';
  return IcsImportResult(
    tasks: tasks,
    simplifiedRepeat: simplified,
    partialRepeat: partial,
    failed: failed,
    report: report,
    truncated: truncated,
    reminderMigrated: reminderMigrated,
    reminderDropped: reminderDropped,
    uids: uids,
  );
}

/// P2-1（v2.9.0 审计）：块内是否含提醒段（RFC 5545 `TRIGGER` 或 vCalendar 1.0
/// `AALARM`）。`VALARM` 内的属性以 `ALARM.` 前缀隔离存放；同时兼容「无
/// `BEGIN:VALARM` 包裹、直接把 TRIGGER 写在块级」的宽容写法（第三方生成器常见）。
bool _hasAlarmSegment(Map<String, String> b) =>
    (_triggerProp(b)?.trim().isNotEmpty ?? false) ||
    (_aalarmProp(b)?.trim().isNotEmpty ?? false);

/// 提醒段里的 `TRIGGER` 值：优先取 `VALARM` 隔离键，回退块级裸键（宽容第三方写法）。
String? _triggerProp(Map<String, String> b) => b['ALARM.TRIGGER'] ?? b['TRIGGER'];

/// 提醒段里的 `AALARM`（vCalendar 1.0）值：同上。
String? _aalarmProp(Map<String, String> b) => b['ALARM.AALARM'] ?? b['AALARM'];

/// 块的落点（`DUE` 优先，其次 `DTSTART`），无则 null。抽出来供 [_blockToTask] 与
/// 提醒迁移统计共用，避免两处口径漂移。
DateTime? _blockDueDate(Map<String, String> b) {
  final due = b['DUE'] ?? b['DTSTART'];
  return due != null ? _parseIcsDateTime(due) : null;
}

/// P2-1（v2.9.0 审计）：把块的提醒段解析为 [Task.reminderOffsetMin]（提前分钟数）。
///
/// 支持两种形态：
///  1. RFC 5545 `VALARM` → `TRIGGER` 的 duration 形态（`-PT30M` / `PT1H` / `-P1DT2H`）：
///     负值即「提前」，直接取绝对值；正值（晚于落点）本 App 无对应语义 → null；
///  2. 绝对时刻形态（`TRIGGER;VALUE=DATE-TIME:19970317T133000Z`、vCalendar 1.0
///     `AALARM:19970317T133000Z;...`）：与落点求差得提前量，需要落点存在。
///
/// 无法表达 / 缺少落点时返回 null（调用方计入「提醒未迁移」并如实提示）。
int? _parseAlarmOffsetMin(Map<String, String> b, DateTime? due) {
  // 1) TRIGGER：先按 duration 解析（本 App 自身的导出形态即此类）。
  final trig = _triggerProp(b)?.trim();
  if (trig != null && trig.isNotEmpty) {
    final rel = _triggerDurationToOffsetMin(trig);
    if (rel != null) return rel;
    final abs = _parseIcsDateTime(trig);
    final mins = _offsetFromAbsolute(abs, due);
    if (mins != null) return mins;
  }
  // 2) vCalendar 1.0 AALARM：`AALARM:<触发时刻>;<时长>;...`（只取首段绝对时刻）。
  final aal = _aalarmProp(b)?.trim();
  if (aal != null && aal.isNotEmpty) {
    final abs = _parseIcsDateTime(aal.split(';').first);
    final mins = _offsetFromAbsolute(abs, due);
    if (mins != null) return mins;
  }
  return null;
}

/// 绝对触发时刻 → 相对落点的「提前分钟数」；落点缺失 / 触发晚于落点 / 超出 7 天
/// （与 [Task.reminderOffsetMin] 的合法区间一致）返回 null。
int? _offsetFromAbsolute(DateTime? trigger, DateTime? due) {
  if (trigger == null || due == null) return null;
  final mins = due.difference(trigger).inMinutes;
  if (mins < 0 || mins > 7 * 24 * 60) return null;
  return mins;
}

/// 解析 RFC 5545 duration（`[+-]P[nW][nD][T[nH][nM][nS]]`）为「提前分钟数」。
///
/// 返回正数表示**早于**落点（`-PT30M` → 30）；零时长（`PT0S`）→ 0；
/// 「晚于落点」（`PT10M`）或格式非法 → null（本 App 只表达提前量）。
int? _triggerDurationToOffsetMin(String raw) {
  final s = raw.trim().toUpperCase();
  if (s.isEmpty) return null;
  final m = RegExp(
          r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
      .firstMatch(s);
  if (m == null) return null;
  // 「P」后面什么都没有（如 "P" / "PT"）不视为合法时长。
  if (m.group(2) == null &&
      m.group(3) == null &&
      m.group(4) == null &&
      m.group(5) == null &&
      m.group(6) == null) {
    return null;
  }
  final sign = m.group(1) == '-' ? -1 : 1;
  final w = int.tryParse(m.group(2) ?? '') ?? 0;
  final d = int.tryParse(m.group(3) ?? '') ?? 0;
  final h = int.tryParse(m.group(4) ?? '') ?? 0;
  final mi = int.tryParse(m.group(5) ?? '') ?? 0;
  final se = int.tryParse(m.group(6) ?? '') ?? 0;
  final seconds = sign * ((((w * 7 + d) * 24 + h) * 60 + mi) * 60 + se);
  if (seconds > 0) return null; // 晚于落点：无法表达
  // P3-7（v2.9.1 审计）：秒级精度取**最近的分钟**，不再向下取整。
  // 旧实现 `(-seconds) ~/ 60` 会把 `-PT30S` 变成 0（语义从「提前 30 秒」漂移成
  // 「准点提醒」）、把 `-PT90S` 变成 1（少 30 秒）。本 App 的最小粒度是分钟，
  // 四舍五入到最近分钟是误差最小的表达（且不会把 30 秒错当成准点）。
  final mins = ((-seconds) + 30) ~/ 60;
  return mins > 7 * 24 * 60 ? null : mins;
}

/// F-10（v2.8.5 审计）：判断一条**已被映射**的 RRULE 是否含未支持成分
/// （这些成分会被静默丢弃，故导入时单独计数提示）：
/// - `COUNT=`：出现次数上限未保留（任务会无限循环）；
/// - WEEKLY / MONTHLY 带 `INTERVAL>1`：App 的每周 / 每月模型无「每 N 周/月」概念；
/// - DAILY 带 `BYDAY`：本应「仅某些天」，现被映射为每天；
/// - BYDAY 带序数前缀（如 `2MO` / `-1FR`）：WEEKLY 下「第 N 个周几」无法表达。
bool _rruleHasUnsupportedParts(String rrule) {
  final map = <String, String>{};
  for (final part in rrule.toUpperCase().split(';')) {
    final kv = part.split('=');
    if (kv.length == 2) map[kv[0]] = kv[1];
  }
  if (map.containsKey('COUNT')) return true;
  final freq = map['FREQ'] ?? '';
  final interval = int.tryParse(map['INTERVAL'] ?? '') ?? 1;
  if ((freq == 'WEEKLY' || freq == 'MONTHLY') && interval > 1) return true;
  final byday = map['BYDAY'];
  if (freq == 'DAILY' && byday != null && byday.isNotEmpty) return true;
  if (freq == 'WEEKLY' && byday != null && RegExp(r'^-?\d').hasMatch(byday)) {
    return true;
  }
  return false;
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

  DateTime? dueDate = _blockDueDate(b);
  // P2-1（v2.9.0 审计）：导入侧解析提醒段（VALARM/AALARM）→ reminderOffsetMin。
  // 无法迁移时保持 0（= 落点时刻提醒），并由 [parseIcs] 计入「提醒未迁移」如实提示。
  final reminderOffsetMin = _parseAlarmOffsetMin(b, dueDate) ?? 0;

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
      // P2-4（v2.9.1 审计）：仅当 BYDAY **恰好就是工作日集合（MO-FR）** 时才映射为
      // 「仅工作日」。此前判据是「长度 ≥5 且包含周一~周五」，而
      // `BYDAY=MO,TU,WE,TH,FR,SA,SU`（App 内「每周」多选全部 7 天导出的形态）同样满足
      // ——于是往返时周六日被静默丢掉，第三方日历的 6 天写法亦然。
      final set = days.toSet();
      if (set.length == 5 && set.containsAll(const [1, 2, 3, 4, 5])) {
        // 含且仅含全部工作日 → 仅工作日。
        repeat = RepeatType.weekday;
      } else if (days.isNotEmpty) {
        // P3-6（v2.9.1 审计）：原 `days.length == 1` 与 `isNotEmpty` 两个分支体完全
        // 相同（死代码），此处合并；单日 / 多日一律按逐日集合保留。
        repeat = RepeatType.weekly;
        weekdays = days;
      } else {
        // P3-6（v2.9.1 审计）：不带 BYDAY 的 `FREQ=WEEKLY` 是合法写法（RFC 5545 缺省
        // 即落点当日的周几）。旧实现静默默认周一，会把第三方日历里的「每周三」搬成
        // 「每周一」。这里改以落点（DUE / DTSTART）的周几为锚，无落点才回退周一。
        repeat = RepeatType.weekly;
        weekdays = [dueDate?.weekday ?? DateTime.monday];
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

  // youtiao 导出的 UID 形如 `<数字id>@youtiao`；保留数字 id 以支持「导出→导入」幂等去重
  // （[TaskProvider.importDedup] 会按 task.id 直查现有任务）。第三方 .ics 多无 UID 或带其它
  // 后缀，则留空（入库时由 addTask 分配新 id）。
  String idForImport = '';
  final rawUid = b['UID'];
  if (rawUid != null && rawUid.endsWith('@youtiao')) {
    final numPart = rawUid.substring(0, rawUid.length - '@youtiao'.length);
    if (int.tryParse(numPart) != null) idForImport = numPart;
  }

  // P3-7（v2.9.1 审计）：重复任务的提醒时刻在本 App 只有一种表达——`repeatMinute`
  // （每个循环日的当天时刻）。故当提醒段表达的是「提醒时刻 == 落点时刻」（提前量 0）
  // 时，把落点的时分回填为 `repeatMinute`，让重复提醒真正迁移过来（此前导入侧从不写
  // 该字段，重复任务导入后一律无提醒，而统计却报「提醒已迁移」）。提前量非 0 的
  // 重复提醒无对应语义，保持 null 并由调用方计入「未迁移」。
  int? repeatMinute;
  if (repeat != RepeatType.none && dueDate != null) {
    final off = _parseAlarmOffsetMin(b, dueDate);
    if (off == 0) repeatMinute = dueDate.hour * 60 + dueDate.minute;
  }

  return Task(
    id: idForImport,
    title: title,
    priority: priority,
    category: category,
    dueDate: dueDate,
    status: done ? TaskStatus.done : TaskStatus.todo,
    completedAt: completedAt,
    note: note,
    tags: tags,
    // P2-1：提醒提前量随导入落库（无提醒段时为 0 = 落点时刻提醒）。
    reminderOffsetMin: reminderOffsetMin,
    repeat: repeat,
    repeatMinute: repeatMinute,
    repeatWeekdays: weekdays,
    repeatInterval: interval,
    repeatUntil: repeatUntil,
    monthlyDay: monthlyDayIcs,
    monthlyWeekday: monthlyWeekdayIcs,
    monthlyWeekIndex: monthlyWeekIndexIcs,
    pinyinInitials: Task.computePinyinInitials(title),
  );
}
