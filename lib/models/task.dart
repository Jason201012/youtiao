import 'package:flutter/material.dart';
import 'package:todolist/theme/tokens.dart';

/// 任务数据模型（对应设计稿：优先级色条、分类标签、截止日期、子任务、完成态）
enum Priority { high, medium, low }

enum Category { work, life, study }

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

  /// 是否为「每日提醒」任务：开启后每天在设定时间提醒该任务（如每天 07:00 背单词）。
  final bool dailyReminder;

  /// 每日提醒时间，单位「自 00:00 起的分钟数」(0-1439)。仅在 [dailyReminder]=true 时有意义。
  final int? dailyReminderMinute;

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
    this.dailyReminder = false,
    this.dailyReminderMinute,
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
    bool? dailyReminder,
    int? dailyReminderMinute,
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
        dailyReminder: dailyReminder ?? this.dailyReminder,
        dailyReminderMinute: dailyReminderMinute ?? this.dailyReminderMinute,
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
        'dailyReminder': dailyReminder,
        'dailyReminderMinute': dailyReminderMinute,
      };

  /// 从 JSON 反序列化（兼容旧版仅含 [done] 布尔的备份）
  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id'] as String,
        title: j['title'] as String,
        priority: Priority.values.byName(j['priority'] as String),
        category: Category.values.byName(j['category'] as String),
        dueDate: j['dueDate'] == null ? null : DateTime.parse(j['dueDate'] as String),
        status: j['status'] != null
            ? TaskStatus.values.byName(j['status'] as String)
            : ((j['done'] as bool? ?? false) ? TaskStatus.done : TaskStatus.todo),
        completedAt:
            j['completedAt'] == null ? null : DateTime.parse(j['completedAt'] as String),
        subtaskTotal: j['subtaskTotal'] as int? ?? 0,
        subtaskDone: j['subtaskDone'] as int? ?? 0,
        deletedAt:
            j['deletedAt'] == null ? null : DateTime.parse(j['deletedAt'] as String),
        dailyReminder: j['dailyReminder'] as bool? ?? false,
        dailyReminderMinute: j['dailyReminderMinute'] as int?,
      );
}
