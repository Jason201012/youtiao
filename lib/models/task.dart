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

class Task {
  final String id;
  final String title;
  final Priority priority;
  final Category category;
  final DateTime? dueDate;
  final bool done;
  final DateTime? completedAt;
  final int subtaskTotal;
  final int subtaskDone;
  final DateTime? deletedAt;

  const Task({
    required this.id,
    required this.title,
    required this.priority,
    required this.category,
    this.dueDate,
    this.done = false,
    this.completedAt,
    this.subtaskTotal = 0,
    this.subtaskDone = 0,
    this.deletedAt,
  });

  Task copyWith({
    String? id,
    String? title,
    Priority? priority,
    Category? category,
    DateTime? dueDate,
    bool? done,
    DateTime? completedAt,
    int? subtaskTotal,
    int? subtaskDone,
    DateTime? deletedAt,
  }) =>
      Task(
        id: id ?? this.id,
        title: title ?? this.title,
        priority: priority ?? this.priority,
        category: category ?? this.category,
        dueDate: dueDate ?? this.dueDate,
        done: done ?? this.done,
        completedAt: completedAt ?? this.completedAt,
        subtaskTotal: subtaskTotal ?? this.subtaskTotal,
        subtaskDone: subtaskDone ?? this.subtaskDone,
        deletedAt: deletedAt ?? this.deletedAt,
      );

  /// 序列化为 JSON（用于 shared_preferences 持久化）
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'priority': priority.name,
        'category': category.name,
        'dueDate': dueDate?.toIso8601String(),
        'done': done,
        'completedAt': completedAt?.toIso8601String(),
        'subtaskTotal': subtaskTotal,
        'subtaskDone': subtaskDone,
        'deletedAt': deletedAt?.toIso8601String(),
      };

  /// 从 JSON 反序列化
  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id'] as String,
        title: j['title'] as String,
        priority: Priority.values.byName(j['priority'] as String),
        category: Category.values.byName(j['category'] as String),
        dueDate: j['dueDate'] == null ? null : DateTime.parse(j['dueDate'] as String),
        done: j['done'] as bool? ?? false,
        completedAt:
            j['completedAt'] == null ? null : DateTime.parse(j['completedAt'] as String),
        subtaskTotal: j['subtaskTotal'] as int? ?? 0,
        subtaskDone: j['subtaskDone'] as int? ?? 0,
        deletedAt:
            j['deletedAt'] == null ? null : DateTime.parse(j['deletedAt'] as String),
      );
}
