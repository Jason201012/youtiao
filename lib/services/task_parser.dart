/// 自然语言录入解析器。
///
/// 把一行中文文本（如「明天下午3点 交周报 !高 #工作」）解析为结构化的任务字段。
/// 纯 Dart 实现，**不依赖 Flutter**，因此可以在单元测试里直接跑、也便于注入时间基准。
///
/// 设计原则：
/// 1. **减法式解析**——先把能识别的片段从原串中「挖掉」，剩下的文字即任务标题。
/// 2. **边界优先**——`#标签`、`!优先级` 这类有明确前缀的先匹配，避免被日期正则抢走字符。
/// 3. **宁可漏判不可误判**——单个 `!`、裸写的「工作」都不解析，防止误伤正常文案。
library;

import 'package:todolist/models/task.dart';

/// 被识别出来的片段类型（供 UI 渲染 chip / 高亮）。
enum TokenKind { date, time, priority, category, tag, repeat }

/// 一个被识别的片段：记录它在原串中的位置与语义。
class ParseSegment {
  /// 片段语义类型
  final TokenKind kind;

  /// 在原始输入中的起始下标（含）
  final int start;

  /// 在原始输入中的结束下标（不含）
  final int end;

  /// 原文
  final String raw;

  /// 供 UI 展示的规范化文案（如「明天 15:00」「高优先级」）
  final String label;

  const ParseSegment({
    required this.kind,
    required this.start,
    required this.end,
    required this.raw,
    required this.label,
  });
}

/// 解析结果：既可直接读字段，也可用 [toTask] 转成可入库的 [Task]。
class ParsedTask {
  /// 剔除所有识别片段后剩余的纯标题
  final String title;

  /// 截止时间（日期 + 时间合并后的结果），未识别则为 null
  final DateTime? dueDate;

  /// 优先级，未识别则为 null（入库时回落到 [Priority.medium]）
  final Priority? priority;

  /// 分类，未识别则为 null（入库时回落到 [Category.work]）
  final Category? category;

  /// 自定义标签
  final List<String> tags;

  /// 重复规则
  final RepeatType repeat;

  /// 每周重复的星期集合（1=周一 … 7=周日）
  final List<int> repeatWeekdays;

  /// 每隔 N 天
  final int repeatInterval;

  /// 重复提醒时刻（自 00:00 起的分钟数）
  final int? repeatMinute;

  /// 全部识别片段，按在原串中的位置升序
  final List<ParseSegment> segments;

  /// 解析时的时间基准（用于「每隔 N 天」的锚点日）。为空则按调用 [toTask] 的当下算。
  final DateTime? anchorBase;

  const ParsedTask({
    required this.title,
    this.dueDate,
    this.priority,
    this.category,
    this.tags = const [],
    this.repeat = RepeatType.none,
    this.repeatWeekdays = const [],
    this.repeatInterval = 2,
    this.repeatMinute,
    this.segments = const [],
    this.anchorBase,
  });

  /// 是否识别出了任何结构化信息（没有的话 UI 就不必展示「已识别」区）
  bool get hasStructuredInfo => segments.isNotEmpty;

  /// 标题是否可用（空标题不允许创建任务）
  bool get isValid => title.isNotEmpty;

  /// 转成可入库的任务。[id] 留空由 TaskProvider 生成。
  Task toTask() {
    final anchor = anchorBase ?? DateTime.now();
    return Task(
      id: '',
      title: title,
      priority: priority ?? Priority.medium,
      category: category ?? Category.work,
      dueDate: dueDate,
      repeat: repeat,
      repeatWeekdays: repeat == RepeatType.weekly
          ? (repeatWeekdays.isNotEmpty ? repeatWeekdays : [DateTime.monday])
          : const [],
      repeatInterval: repeatInterval,
      repeatMinute: repeatMinute,
      repeatAnchor:
          repeat == RepeatType.interval ? DateTime(anchor.year, anchor.month, anchor.day) : null,
      tags: tags,
    );
  }
}

/// 中文/阿拉伯数字 → 星期序号（1=周一 … 7=周日）
const Map<String, int> _weekdayMap = {
  '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7, '七': 7,
  '1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7,
};

/// 无显式时间时，截止时刻默认落在早上 9 点
const int _defaultHour = 9;

class TaskParser {
  /// 解析入口。[now] 用于注入「当前时间」，便于单元测试；生产环境留空即可。
  static ParsedTask parse(String input, {DateTime? now}) {
    final base = now ?? DateTime.now();
    final src = input;
    if (src.trim().isEmpty) {
      return const ParsedTask(title: '');
    }

    // 字符占用表：被识别走的字符会被标记，最后拼标题时跳过
    final used = List<bool>.filled(src.length, false);
    final segments = <ParseSegment>[];

    Priority? priority;
    Category? category;
    final tags = <String>[];
    RepeatType repeat = RepeatType.none;
    var repeatWeekdays = <int>[];
    var repeatInterval = 2;
    DateTime? datePart;
    int? hour;
    int? minute;

    /// 检查区间是否完全空闲
    bool free(int s, int e) {
      for (var i = s; i < e; i++) {
        if (used[i]) return false;
      }
      return true;
    }

    /// 占用区间并记录片段
    void mark(int s, int e, TokenKind kind, String label) {
      for (var i = s; i < e; i++) {
        used[i] = true;
      }
      segments.add(ParseSegment(
        kind: kind,
        start: s,
        end: e,
        raw: src.substring(s, e),
        label: label,
      ));
    }

    // ── 1. 标签 / 分类：`#xxx` 前缀边界最明确，优先吃掉 ──────────────
    for (final m in RegExp(r'[#＃]([^\s#＃!！]+)').allMatches(src)) {
      if (!free(m.start, m.end)) continue;
      final word = m.group(1)!;
      final cat = _matchCategory(word);
      if (cat != null && category == null) {
        category = cat;
        mark(m.start, m.end, TokenKind.category, '分类·$word');
      } else {
        if (!tags.contains(word)) tags.add(word);
        mark(m.start, m.end, TokenKind.tag, '#$word');
      }
    }

    // ── 2. 优先级：只认「!+明确词」或多个感叹号，单个裸 `!` 不解析 ────
    final priRe = RegExp(r'[!！](高|急|紧急|重要|中|普通|低|缓)|[!！]{2,3}');
    for (final m in priRe.allMatches(src)) {
      if (priority != null) break;
      if (!free(m.start, m.end)) continue;
      final word = m.group(1);
      if (word != null) {
        priority = _priorityOfWord(word);
      } else {
        // `!!!` → 高，`!!` → 中
        priority = (m.end - m.start) >= 3 ? Priority.high : Priority.medium;
      }
      mark(m.start, m.end, TokenKind.priority, '${_priorityLabel(priority)}优先级');
    }

    // ── 3. 重复规则：必须排在日期前面（「每周一」不能被「周一」截胡）──
    final repeatRe = RegExp(
      r'每天|每日|每工作日|工作日每天|每隔(\d+)天|每周([一二三四五六日天1-7、，,和\s]*)',
    );
    for (final m in repeatRe.allMatches(src)) {
      if (repeat != RepeatType.none) break;
      if (!free(m.start, m.end)) continue;
      final raw = m.group(0)!;
      if (raw == '每天' || raw == '每日') {
        repeat = RepeatType.daily;
        mark(m.start, m.end, TokenKind.repeat, '每天');
      } else if (raw.contains('工作日')) {
        repeat = RepeatType.weekday;
        mark(m.start, m.end, TokenKind.repeat, '仅工作日');
      } else if (m.group(1) != null) {
        repeat = RepeatType.interval;
        repeatInterval = int.tryParse(m.group(1)!) ?? 2;
        if (repeatInterval < 1) repeatInterval = 1;
        mark(m.start, m.end, TokenKind.repeat, '每隔$repeatInterval天');
      } else {
        // 「每周一三五」/「每周」
        final days = _parseWeekdayList(m.group(2) ?? '');
        repeat = RepeatType.weekly;
        repeatWeekdays = days.isNotEmpty ? days : [base.weekday];
        // 「每周」后面没跟星期时，正则会多吃掉尾随空格，这里收敛到实际内容
        final end = days.isEmpty ? m.start + 2 : m.end;
        mark(m.start, end, TokenKind.repeat, '每周${_weekdaysLabel(repeatWeekdays)}');
      }
    }

    // ── 4. 日期 ────────────────────────────────────────────────
    final dateRe = RegExp(
      r'大后天|后天|明天|明日|今天|今日'
      r'|下下(?:周|星期|礼拜)[一二三四五六日天]'
      r'|下(?:周|星期|礼拜)[一二三四五六日天]'
      r'|(?:本|这)(?:周|星期|礼拜)[一二三四五六日天]'
      r'|(?:周|星期|礼拜)[一二三四五六日天]'
      r'|(\d{1,2})月(\d{1,2})[日号]'
      r'|(\d{1,2})[/](\d{1,2})'
      r'|(\d+)天后'
      r'|(\d+)周后',
    );
    for (final m in dateRe.allMatches(src)) {
      if (datePart != null) break;
      if (!free(m.start, m.end)) continue;
      final d = _resolveDate(m, base);
      if (d == null) continue;
      datePart = d;
      mark(m.start, m.end, TokenKind.date, _dateLabel(d, base));
    }

    // ── 5. 时间 ────────────────────────────────────────────────
    const meridiem = r'(?:上午|早上|早晨|凌晨|中午|下午|晚上|傍晚|夜里)';
    final timeRe = RegExp(
      '$meridiem?'
      r'(\d{1,2})[:：](\d{2})'
      '|$meridiem?'
      r'(\d{1,2})\s*[点时](半|\d{1,2}\s*分?)?'
      '|($meridiem)',
    );
    for (final m in timeRe.allMatches(src)) {
      if (hour != null) break;
      if (!free(m.start, m.end)) continue;
      final t = _resolveTime(m);
      if (t == null) continue;
      hour = t.$1;
      minute = t.$2;
      mark(m.start, m.end, TokenKind.time,
          '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}');
    }

    // ── 6. 合并日期与时间 ──────────────────────────────────────
    DateTime? due;
    if (datePart != null || hour != null) {
      final day = datePart ?? DateTime(base.year, base.month, base.day);
      final h = hour ?? _defaultHour;
      final mi = minute ?? 0;
      var candidate = DateTime(day.year, day.month, day.day, h, mi);
      // 只给了时间没给日期，且该时刻今天已过 → 顺延到明天
      if (datePart == null && candidate.isBefore(base)) {
        candidate = candidate.add(const Duration(days: 1));
      }
      due = candidate;
    }
    // 有重复规则但没写日期：沿用编辑弹层的约定，把截止时间落在当天 23:59
    if (repeat != RepeatType.none && due == null) {
      due = DateTime(base.year, base.month, base.day, 23, 59);
    }

    // ── 7. 剩余文字即标题 ──────────────────────────────────────
    final buf = StringBuffer();
    for (var i = 0; i < src.length; i++) {
      if (!used[i]) buf.write(src[i]);
    }
    final title = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();

    segments.sort((a, b) => a.start.compareTo(b.start));

    return ParsedTask(
      title: title,
      dueDate: due,
      priority: priority,
      category: category,
      tags: tags,
      repeat: repeat,
      repeatWeekdays: repeatWeekdays,
      repeatInterval: repeatInterval,
      repeatMinute: repeat != RepeatType.none && hour != null ? hour * 60 + (minute ?? 0) : null,
      segments: segments,
      anchorBase: base,
    );
  }

  // ── 私有工具 ────────────────────────────────────────────────

  static Category? _matchCategory(String word) {
    switch (word) {
      case '工作':
        return Category.work;
      case '生活':
        return Category.life;
      case '学习':
        return Category.study;
    }
    return null;
  }

  static Priority _priorityOfWord(String w) {
    switch (w) {
      case '高':
      case '急':
      case '紧急':
      case '重要':
        return Priority.high;
      case '低':
      case '缓':
        return Priority.low;
      default:
        return Priority.medium;
    }
  }

  static String _priorityLabel(Priority? p) {
    switch (p) {
      case Priority.high:
        return '高';
      case Priority.low:
        return '低';
      default:
        return '中';
    }
  }

  /// 解析「一三五」「1,3,5」这类星期列表
  static List<int> _parseWeekdayList(String raw) {
    final out = <int>[];
    for (final ch in raw.split('')) {
      final v = _weekdayMap[ch];
      if (v != null && !out.contains(v)) out.add(v);
    }
    out.sort();
    return out;
  }

  static String _weekdaysLabel(List<int> days) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return days.map((d) => names[(d - 1).clamp(0, 6)]).join('');
  }

  /// 把日期正则的一次命中转换为具体日期（date-only）
  static DateTime? _resolveDate(RegExpMatch m, DateTime base) {
    final raw = m.group(0)!;
    final today = DateTime(base.year, base.month, base.day);

    if (raw == '今天' || raw == '今日') return today;
    if (raw == '明天' || raw == '明日') return today.add(const Duration(days: 1));
    if (raw == '后天') return today.add(const Duration(days: 2));
    if (raw == '大后天') return today.add(const Duration(days: 3));

    // N月N日
    if (m.group(1) != null && m.group(2) != null) {
      return _monthDay(int.parse(m.group(1)!), int.parse(m.group(2)!), base);
    }
    // N/N
    if (m.group(3) != null && m.group(4) != null) {
      return _monthDay(int.parse(m.group(3)!), int.parse(m.group(4)!), base);
    }
    // N天后
    if (m.group(5) != null) {
      return today.add(Duration(days: int.parse(m.group(5)!)));
    }
    // N周后
    if (m.group(6) != null) {
      return today.add(Duration(days: int.parse(m.group(6)!) * 7));
    }

    // 星期类：取最后一个字判断目标星期
    final target = _weekdayMap[raw.substring(raw.length - 1)];
    if (target == null) return null;

    // 按中国习惯以周一为一周之首，「下周X」指的是下一个自然周，
    // 而不是「往后数 7 天」——今天若是周日，两者会差整整一周。
    final thisMonday = today.subtract(Duration(days: base.weekday - 1));
    if (raw.startsWith('下下')) {
      return thisMonday.add(Duration(days: 14 + target - 1));
    }
    if (raw.startsWith('下')) {
      return thisMonday.add(Duration(days: 7 + target - 1));
    }
    if (raw.startsWith('本') || raw.startsWith('这')) {
      return thisMonday.add(Duration(days: target - 1));
    }
    // 裸写「周三」：取最近的那一个（今天就是则算今天，已过则顺延到下周）
    return today.add(Duration(days: (target - base.weekday) % 7));
  }

  /// N月N日 → 具体日期；若该日期今年已过，顺延到明年
  static DateTime? _monthDay(int month, int day, DateTime base) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    var y = base.year;
    var d = DateTime(y, month, day);
    // 溢出校验（如 2月30日会被 Dart 归一化到 3月，视为无效）
    if (d.month != month) return null;
    final today = DateTime(base.year, base.month, base.day);
    if (d.isBefore(today)) {
      y += 1;
      d = DateTime(y, month, day);
    }
    return d;
  }

  /// 把时间正则的一次命中转换为 (时, 分)
  static (int, int)? _resolveTime(RegExpMatch m) {
    final raw = m.group(0)!;
    final prefix = _meridiemOf(raw);

    // 形式一：HH:mm
    if (m.group(1) != null && m.group(2) != null) {
      var h = int.parse(m.group(1)!);
      final mi = int.parse(m.group(2)!);
      if (h > 23 || mi > 59) return null;
      h = _applyMeridiem(h, prefix);
      return (h, mi);
    }
    // 形式二：N点[半|N分]
    if (m.group(3) != null) {
      var h = int.parse(m.group(3)!);
      if (h > 23) return null;
      var mi = 0;
      final tail = m.group(4);
      if (tail != null) {
        if (tail.contains('半')) {
          mi = 30;
        } else {
          mi = int.tryParse(tail.replaceAll(RegExp(r'[^\d]'), '')) ?? 0;
        }
      }
      if (mi > 59) return null;
      h = _applyMeridiem(h, prefix);
      return (h, mi);
    }
    // 形式三：只有「下午」「晚上」这类词，落到该时段的代表时刻
    if (m.group(5) != null) {
      switch (m.group(5)) {
        case '凌晨':
          return (6, 0);
        case '早上':
        case '早晨':
        case '上午':
          return (9, 0);
        case '中午':
          return (12, 0);
        case '下午':
          return (15, 0);
        case '傍晚':
          return (18, 0);
        case '晚上':
        case '夜里':
          return (20, 0);
      }
    }
    return null;
  }

  static String? _meridiemOf(String raw) {
    for (final w in const ['上午', '早上', '早晨', '凌晨', '中午', '下午', '晚上', '傍晚', '夜里']) {
      if (raw.startsWith(w)) return w;
    }
    return null;
  }

  /// 按「上午/下午」修正 12 小时制
  static int _applyMeridiem(int h, String? prefix) {
    if (prefix == null) return h;
    switch (prefix) {
      case '下午':
      case '晚上':
      case '傍晚':
      case '夜里':
        return h < 12 ? h + 12 : h;
      case '中午':
        return h == 12 ? 12 : (h < 12 ? h + 12 : h);
      case '凌晨':
        return h == 12 ? 0 : h;
      default: // 上午 / 早上 / 早晨
        return h == 12 ? 0 : h;
    }
  }

  static String _dateLabel(DateTime d, DateTime base) {
    final today = DateTime(base.year, base.month, base.day);
    final diff = d.difference(today).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    if (diff == 2) return '后天';
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    if (diff > 2 && diff < 7) return '周${names[d.weekday - 1]}';
    return '${d.month}月${d.day}日';
  }
}
