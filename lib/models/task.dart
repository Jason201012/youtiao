import 'package:flutter/material.dart';
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

/// 任务状态：待办 / 进行中 / 已完成。
/// 看板页按此分为三列，可在列间拖拽或点击循环切换。
enum TaskStatus { todo, doing, done }

extension TaskStatusLabel on TaskStatus {
  String get label {
    switch (this) {
      case TaskStatus.todo:
        return '待办';
      case TaskStatus.doing:
        return '进行中';
      case TaskStatus.done:
        return '已完成';
    }
  }
}

class Task {
  final String id;
  final String title;
  final Priority priority;
  final Category category;
  final DateTime? dueDate;
  final TaskStatus status;
  final DateTime? completedAt;
  final int subtaskTotal;
  final int subtaskDone;
  final DateTime? deletedAt;

  /// 是否完成：由 [status] 派生，保持对外只读语义一致。
  bool get done => status == TaskStatus.done;

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

  const Task({
    required this.id,
    required this.title,
    required this.priority,
    required this.category,
    this.dueDate,
    this.status = TaskStatus.todo,
    this.completedAt,
    this.subtaskTotal = 0,
    this.subtaskDone = 0,
    this.deletedAt,
    this.repeat = RepeatType.none,
    this.repeatWeekdays = const [],
    this.repeatInterval = 2,
    this.repeatMinute,
    this.repeatAnchor,
    this.note = '',
  });

  Task copyWith({
    String? id,
    String? title,
    Priority? priority,
    Category? category,
    DateTime? dueDate,
    TaskStatus? status,
    DateTime? completedAt,
    int? subtaskTotal,
    int? subtaskDone,
    DateTime? deletedAt,
    RepeatType? repeat,
    List<int>? repeatWeekdays,
    int? repeatInterval,
    int? repeatMinute,
    DateTime? repeatAnchor,
    String? note,
  }) =>
      Task(
        id: id ?? this.id,
        title: title ?? this.title,
        priority: priority ?? this.priority,
        category: category ?? this.category,
        dueDate: dueDate ?? this.dueDate,
        status: status ?? this.status,
        completedAt: completedAt ?? this.completedAt,
        subtaskTotal: subtaskTotal ?? this.subtaskTotal,
        subtaskDone: subtaskDone ?? this.subtaskDone,
        deletedAt: deletedAt ?? this.deletedAt,
        repeat: repeat ?? this.repeat,
        repeatWeekdays: repeatWeekdays ?? this.repeatWeekdays,
        repeatInterval: repeatInterval ?? this.repeatInterval,
        repeatMinute: repeatMinute ?? this.repeatMinute,
        repeatAnchor: repeatAnchor ?? this.repeatAnchor,
        note: note ?? this.note,
      );

  /// 序列化为 JSON（用于 shared_preferences 持久化）
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'priority': priority.name,
        'category': category.name,
        'dueDate': dueDate?.toIso8601String(),
        'status': status.name,
        'done': done, // 保留旧字段，兼容历史备份/读取
        'completedAt': completedAt?.toIso8601String(),
        'subtaskTotal': subtaskTotal,
        'subtaskDone': subtaskDone,
        'deletedAt': deletedAt?.toIso8601String(),
        'repeat': repeat.name,
        'repeatWeekdays': repeatWeekdays,
        'repeatInterval': repeatInterval,
        'repeatMinute': repeatMinute,
        'repeatAnchor': repeatAnchor?.toIso8601String(),
        'note': note,
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
    return Task(
      id: j['id'] as String,
      title: j['title'] as String,
      priority: Priority.values.byName(j['priority'] as String),
      category: Category.values.byName(j['category'] as String),
      dueDate:
          j['dueDate'] == null ? null : DateTime.parse(j['dueDate'] as String),
      status: j['status'] != null
          ? TaskStatus.values.byName(j['status'] as String)
          : ((j['done'] as bool? ?? false) ? TaskStatus.done : TaskStatus.todo),
      completedAt: j['completedAt'] == null
          ? null
          : DateTime.parse(j['completedAt'] as String),
      subtaskTotal: j['subtaskTotal'] as int? ?? 0,
      subtaskDone: j['subtaskDone'] as int? ?? 0,
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
    );
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
}
