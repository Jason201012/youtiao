import 'package:flutter/material.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:todolist/theme/tokens.dart';

/// 任务数据模型（对应设计稿：优先级色条、分类标签、截止日期、子任务、完成态）
enum Priority { high, medium, low }

enum Category { work, life, study }

/// 重复规则：控制任务在哪些天「循环出现 / 提醒」。
/// - none：一次性任务（不重复）
/// - daily：每天
/// - weekly：每周指定的若干星期（[Task.repeatWeekdays]）
/// - interval：每隔 N 天（[Task.repeatInterval]，以 [Task.repeatAnchor] 为锚点）
/// - weekday：仅工作日（周一至周五）
enum RepeatType { none, daily, weekly, interval, weekday }

extension RepeatTypeLabel on RepeatType {
  /// 弹层 / 标签上的短名
  String get label {
    switch (this) {
      case RepeatType.none:
        return '不重复';
      case RepeatType.daily:
        return '每天';
      case RepeatType.weekly:
        return '每周';
      case RepeatType.interval:
        return '每隔N天';
      case RepeatType.weekday:
        return '仅工作日';
    }
  }
}

extension PriorityColor on Priority {
  /// 返回对应优先级语义色（浅/深由调用方按 brightness 选择）
  Color lightColor() {
    switch (this) {
      case Priority.high:
        return AppColors.lightHigh;
      case Priority.medium:
        return AppColors.lightMedium;
      case Priority.low:
        return AppColors.lightLow;
    }
  }

  Color darkColor() {
    switch (this) {
      case Priority.high:
        return AppColors.darkHigh;
      case Priority.medium:
        return AppColors.darkMedium;
      case Priority.low:
        return AppColors.darkLow;
    }
  }
}

extension CategoryLabel on Category {
  String get label {
    switch (this) {
      case Category.work:
        return '工作';
      case Category.life:
        return '生活';
      case Category.study:
        return '学习';
    }
  }
}

/// 任务状态：待办 / 已完成。
/// 看板页按此分为两列，可在列间拖拽或点击切换。
enum TaskStatus { todo, done }

extension TaskStatusLabel on TaskStatus {
  String get label {
    switch (this) {
      case TaskStatus.todo:
        return '待办';
      case TaskStatus.done:
        return '已完成';
    }
  }
}

/// 子任务条目：可勾选的细项，用于把一个任务拆成若干步骤并跟踪进度。
/// 纯数据，序列化进 [Task.toJson] 的 `subtasks` 列表，复用任务的 SQLite JSON 存储，无需额外迁移。
class SubTask {
  final String id;
  final String title;
  final bool done;

  const SubTask({required this.id, required this.title, this.done = false});

  SubTask copyWith({String? title, bool? done}) => SubTask(
        id: id,
        title: title ?? this.title,
        done: done ?? this.done,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'done': done,
      };

  factory SubTask.fromJson(Map<String, dynamic> j) => SubTask(
        id: (j['id'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        done: (j['done'] as bool?) ?? false,
      );
}

class Task {
  final String id;
  final String title;
  final Priority priority;
  final Category category;
  final DateTime? dueDate;
  /// 任务开始时间（可空）。用于表达「时间段」任务的起点（如「14:00-15:00 开会」），
  /// 与 [dueDate]（截止时间）并列。序列化为 `startDate`，旧数据缺省为 null（向后兼容）。
  /// 仅作展示与排序语义使用，不参与提醒调度（提醒仍以 [dueDate]/重复规则为准）。
  final DateTime? startDate;
  final TaskStatus status;
  final DateTime? completedAt;

  /// 子任务列表（可勾选细项）。取代旧的 subtaskTotal/subtaskDone 两个整数字段；
  /// 进度由 [subtaskTotal]/[subtaskDone] 派生，保持对外可读语义不变。
  final List<SubTask> subtasks;

  final DateTime? deletedAt;

  /// 是否完成：由 [status] 派生，保持对外只读语义一致。
  bool get done => status == TaskStatus.done;

  /// 是否「逾期」：统一口径（看板统计卡、首页「逾期」筛选、分享长图共用）。
  /// 规则：未完成、非重复任务，且截止日期按「天」严格早于今天
  /// （今天到点未做不算逾期）。重复任务不计逾期（v2.2.8 对齐过）。
  static bool isOverdue(Task t, DateTime now) {
    if (t.done || t.isRepeating || t.dueDate == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(t.dueDate!.year, t.dueDate!.month, t.dueDate!.day)
        .isBefore(today);
  }

  /// 子任务总数（由 [subtasks] 派生）。
  int get subtaskTotal => subtasks.length;

  /// 已勾选的子任务数（由 [subtasks] 派生）。
  int get subtaskDone => subtasks.where((s) => s.done).length;

  /// 重复规则：控制任务在哪些天循环出现 / 提醒。默认 [RepeatType.none]（一次性）。
  final RepeatType repeat;

  /// 每周重复的星期集合，取值 1..7（[DateTime.weekday]：1=周一 … 7=周日）。
  /// 仅当 [repeat]==[RepeatType.weekly] 时有意义。
  final List<int> repeatWeekdays;

  /// 每隔 N 天重复（N≥1）。仅当 [repeat]==[RepeatType.interval] 时有意义。
  final int repeatInterval;

  /// 重复提醒时间，单位「自 00:00 起的分钟数」(0-1439)。
  /// 任意 [repeat]!=none 时都表示「在这一天的该时刻提醒」。
  final int? repeatMinute;

  /// 每隔 N 天规则的锚点日期（date-only）。[repeat]==[RepeatType.interval] 时，
  /// 从这一天起每 N 天一次。创建时由 UI 默认填为当天；旧数据无此字段则回退为「不重复」。
  final DateTime? repeatAnchor;

  /// 任务备注 / 解释：对任务的补充说明（链接、思路、细节等），可选，默认空串。
  final String note;

  /// 标签：用户自定义自由文本标签（如「紧急」「会议」），用于搜索与筛选。
  /// 存为字符串列表，序列化为 JSON 的 `tags`；旧数据缺省为空列表（向后兼容）。
  final List<String> tags;

  /// 累计专注时长（秒）：由专注会话回填（见 FocusProvider.onFocusRecorded /
  /// TaskProvider.addFocusSec），用于任务行展示「已专注 X 分钟」。序列化为
  /// [`focusSecTotal`]，旧数据缺省为 0。
  final int focusSecTotal;

  /// 同一分区内的手动排序权重（越小越靠前）。拖拽排序时由 TaskProvider 重算并持久化。
  /// 序列化为 `order`（double），缺省为 0.0。
  final double order;

  /// 提醒提前量（分钟）：一次性「截止提醒」在截止时间之前该分钟数触发（0 = 准时）。
  /// 仅对 [repeat]==none 的任务生效（重复任务有自己的 [repeatMinute] 触发时刻）。
  /// 序列化为 `reminderOffsetMin`，旧数据缺省为 0（向后兼容）。
  final int reminderOffsetMin;

  /// 是否置顶/星标：置顶任务在所属分区内固定排最前（优先于手动 [order]），
  /// 用于把高频/重要任务常驻列表顶部。序列化为 `pinned`，缺省 false（向后兼容，零迁移）。
  final bool pinned;

  /// 标题拼音首字母串（如「整理周会纪要」→ "zhenglizhouhuijiyao"），用于「拼音首字母搜索」。
  /// 由 [computePinyinInitials] 在新建/编辑任务时计算并落库，旧数据缺省为空串（向后兼容，零迁移）。
  /// 搜索时与标题一起做包含匹配（见 [GlobalSearch._matchesTask]）。
  /// 注意：此为派生字段，[copyWith] 默认保留旧值，调用方无需每次重算。
  final String pinyinInitials;

  const Task({
    required this.id,
    required this.title,
    required     this.priority,
    required this.category,
    this.dueDate,
    this.startDate,
    this.status = TaskStatus.todo,
    this.completedAt,
    this.subtasks = const [],
    this.deletedAt,
    this.repeat = RepeatType.none,
    this.repeatWeekdays = const [],
    this.repeatInterval = 2,
    this.repeatMinute,
    this.repeatAnchor,
    this.note = '',
    this.tags = const [],
    this.focusSecTotal = 0,
    this.order = 0.0,
    this.reminderOffsetMin = 0,
    this.pinned = false,
    this.pinyinInitials = '',
  });

  // 哨兵：区分"未传该参数（保留旧值）"与"显式传 null（清空该字段）"。
  // 否则 copyWith(dueDate: null) 会被 `?? this.dueDate` 误判为"保留旧值"，
  // 导致取消完成/恢复/清空截止时间等意图清空的操作实际无效。
  static const Object _kKeep = Object();

  Task copyWith({
    String? id,
    String? title,
    Priority? priority,
    Category? category,
    Object? dueDate = _kKeep,
    Object? startDate = _kKeep,
    TaskStatus? status,
    Object? completedAt = _kKeep,
    List<SubTask>? subtasks,
    Object? deletedAt = _kKeep,
    RepeatType? repeat,
    List<int>? repeatWeekdays,
    int? repeatInterval,
    Object? repeatMinute = _kKeep,
    Object? repeatAnchor = _kKeep,
    String? note,
    List<String>? tags,
    int? focusSecTotal,
    double? order,
    int? reminderOffsetMin,
    bool? pinned,
    String? pinyinInitials,
  }) =>
      Task(
        id: id ?? this.id,
        title: title ?? this.title,
        priority: priority ?? this.priority,
        category: category ?? this.category,
        dueDate: dueDate == _kKeep ? this.dueDate : dueDate as DateTime?,
        startDate: startDate == _kKeep ? this.startDate : startDate as DateTime?,
        status: status ?? this.status,
        completedAt:
            completedAt == _kKeep ? this.completedAt : completedAt as DateTime?,
        subtasks: subtasks ?? this.subtasks,
        deletedAt: deletedAt == _kKeep ? this.deletedAt : deletedAt as DateTime?,
        repeat: repeat ?? this.repeat,
        repeatWeekdays: repeatWeekdays ?? this.repeatWeekdays,
        repeatInterval: repeatInterval ?? this.repeatInterval,
        repeatMinute:
            repeatMinute == _kKeep ? this.repeatMinute : repeatMinute as int?,
        repeatAnchor: repeatAnchor == _kKeep
            ? this.repeatAnchor
            : repeatAnchor as DateTime?,
        note: note ?? this.note,
        tags: tags ?? this.tags,
        focusSecTotal: focusSecTotal ?? this.focusSecTotal,
        order: order ?? this.order,
        reminderOffsetMin: reminderOffsetMin ?? this.reminderOffsetMin,
        pinned: pinned ?? this.pinned,
        pinyinInitials: pinyinInitials ?? this.pinyinInitials,
      );

  /// 序列化为 JSON（用于 shared_preferences 持久化）
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'priority': priority.name,
        'category': category.name,
        'dueDate': dueDate?.toIso8601String(),
        'startDate': startDate?.toIso8601String(),
        'status': status.name,
        'done': done, // 保留旧字段，兼容历史备份/读取
        'completedAt': completedAt?.toIso8601String(),
        'subtasks': subtasks.map((s) => s.toJson()).toList(),
        'deletedAt': deletedAt?.toIso8601String(),
        'repeat': repeat.name,
        'repeatWeekdays': repeatWeekdays,
        'repeatInterval': repeatInterval,
        'repeatMinute': repeatMinute,
        'repeatAnchor': repeatAnchor?.toIso8601String(),
        'note': note,
        'tags': tags,
        'focusSecTotal': focusSecTotal,
        'order': order,
        'reminderOffsetMin': reminderOffsetMin,
        'pinned': pinned,
        'pinyinInitials': pinyinInitials,
      };

  /// 从 JSON 反序列化（兼容旧版仅含 [done] 布尔的备份，以及 v1.9.4 之前
  /// 用 [dailyReminder] 布尔表达的「每天」任务）。
  factory Task.fromJson(Map<String, dynamic> j) {
    // 旧数据兼容：没有 repeat 字段时，dailyReminder=true 视作「每天」。
    final repeatStr = j['repeat'] as String?;
    final RepeatType repeat;
    if (repeatStr != null) {
      repeat = RepeatType.values.firstWhere(
        (e) => e.name == repeatStr,
        orElse: () => RepeatType.none,
      );
    } else {
      repeat = (j['dailyReminder'] as bool? ?? false)
          ? RepeatType.daily
          : RepeatType.none;
    }
    final wdRaw = j['repeatWeekdays'];
    final List<int> weekdays = wdRaw is List
        ? wdRaw.whereType<int>().toList()
        : const <int>[];
    final tagsRaw = j['tags'];
    final List<String> tags = tagsRaw is List
        ? tagsRaw.whereType<String>().toList()
        : const <String>[];
    return Task(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '',
      priority: Priority.values.byName(j['priority'] as String),
      category: Category.values.byName(j['category'] as String),
      dueDate:
          j['dueDate'] == null ? null : DateTime.parse(j['dueDate'] as String),
      startDate:
          j['startDate'] == null ? null : DateTime.parse(j['startDate'] as String),
      status: _parseStatus(j['status'] as String?, j['done'] as bool?),
      completedAt: j['completedAt'] == null
          ? null
          : DateTime.parse(j['completedAt'] as String),
      subtasks: _parseSubtasks(j['subtasks']),
      deletedAt: j['deletedAt'] == null
          ? null
          : DateTime.parse(j['deletedAt'] as String),
      repeat: repeat,
      repeatWeekdays: weekdays,
      repeatInterval: j['repeatInterval'] as int? ?? 2,
      repeatMinute: j['repeatMinute'] as int? ?? j['dailyReminderMinute'] as int?,
      repeatAnchor: j['repeatAnchor'] == null
          ? null
          : DateTime.parse(j['repeatAnchor'] as String),
      note: j['note'] as String? ?? '',
      tags: tags,
      focusSecTotal: j['focusSecTotal'] as int? ?? 0,
      order: (j['order'] as num?)?.toDouble() ?? 0.0,
      reminderOffsetMin: j['reminderOffsetMin'] as int? ?? 0,
      pinned: j['pinned'] as bool? ?? false,
      pinyinInitials: j['pinyinInitials'] as String? ?? '',
    );
  }

  /// 解析任务状态，兼容历史数据：
  /// - 旧版「进行中(doing)」状态统一归并为「待办(todo)」（v2.0.6 起移除 doing 概念）；
  /// - 未知字符串回退到旧的 [done] 布尔字段。
  static TaskStatus _parseStatus(String? s, bool? done) {
    if (s == 'done') return TaskStatus.done;
    if (s == 'todo' || s == 'doing' || s == null) return TaskStatus.todo;
    return (done ?? false) ? TaskStatus.done : TaskStatus.todo;
  }

  /// 解析子任务列表；旧数据无 `subtasks` 字段时回退为空列表（向后兼容）。
  static List<SubTask> _parseSubtasks(dynamic raw) {
    if (raw is! List) return const <SubTask>[];
    final out = <SubTask>[];
    for (final e in raw) {
      if (e is Map) {
        out.add(SubTask.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return out;
  }

  /// 判断 [day]（任意时刻，内部按日期归一化）是否为该任务的「循环日」。
  /// 与 android/.../MidnightResetReceiver.kt 的 isRecurrenceToday 保持一致。
  bool repeatsOn(DateTime day) {
    switch (repeat) {
      case RepeatType.none:
        return false;
      case RepeatType.daily:
        return true;
      case RepeatType.weekday:
        final w = day.weekday;
        return w >= DateTime.monday && w <= DateTime.friday;
      case RepeatType.weekly:
        return repeatWeekdays.contains(day.weekday);
      case RepeatType.interval:
        final a = repeatAnchor;
        if (a == null) return false;
        final ad = DateTime(a.year, a.month, a.day);
        final d = DateTime(day.year, day.month, day.day);
        final diff = d.difference(ad).inDays;
        if (diff < 0) return false;
        final n = repeatInterval < 1 ? 1 : repeatInterval;
        return diff % n == 0;
    }
  }

  /// 重复规则的人类可读摘要（不含时间）。如「每天」「工作日」「每周 一、三」「每2天」。
  String get repeatSummary {
    switch (repeat) {
      case RepeatType.none:
        return '';
      case RepeatType.daily:
        return '每天';
      case RepeatType.weekday:
        return '工作日';
      case RepeatType.weekly:
        const names = ['一', '二', '三', '四', '五', '六', '日'];
        final days = repeatWeekdays
            .where((d) => d >= 1 && d <= 7)
            .map((d) => names[d - 1])
            .join('、');
        return days.isEmpty ? '每周' : '每周 $days';
      case RepeatType.interval:
        return '每${repeatInterval < 1 ? 1 : repeatInterval}天';
    }
  }

  /// 完整重复描述（含提醒时间，如「每天 07:00」）；无重复返回空串。
  String get repeatFull {
    if (repeat == RepeatType.none) return '';
    final base = repeatSummary;
    if (repeatMinute == null) return base;
    final hh = (repeatMinute! ~/ 60).toString().padLeft(2, '0');
    final mm = (repeatMinute! % 60).toString().padLeft(2, '0');
    return '$base $hh:$mm';
  }

  /// 是否为「重复任务」（任意规则）。
  bool get isRepeating => repeat != RepeatType.none;

  /// 计算标题的拼音首字母串（小写，不含空格）。如「整理周会纪要」→ "zhenglizhouhuijiyao"。
  /// 依赖 [PinyinHelper]（lpinyin），纯 Dart、无平台调用；非汉字字符（数字/英文/标点）跳过，
  /// 仅取每个汉字的拼音首字母拼接。空标题返回空串。
  /// 用于「拼音首字母搜索」（A1）：搜 "zl" 可命中「整理」。
  static String computePinyinInitials(String title) {
    if (title.isEmpty) return '';
    final buf = StringBuffer();
    for (final rune in title.runes) {
      final ch = String.fromCharCode(rune);
      // 仅对 CJK 统一汉字区（含扩展 A）取拼音首字母；其余（字母/数字/符号）忽略，
      // 避免英文/数字干扰首字母匹配（搜 "abc" 不应被中文标题里的字母串命中）。
      if (_isCjk(rune)) {
        // lpinyin 2.x：getFirstWordPinyin 对单字返回其拼音首字母（小写，如「整」→ "z"）。
        final py = PinyinHelper.getFirstWordPinyin(ch);
        if (py.isNotEmpty) buf.write(py.toLowerCase());
      }
    }
    return buf.toString();
  }

  /// 判断码点是否落在常用汉字区（CJK Unified Ideographs + 扩展 A）。
  static bool _isCjk(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) || // 基本汉字
      (rune >= 0x3400 && rune <= 0x4DBF); // 扩展 A
}
