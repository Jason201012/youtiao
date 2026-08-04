/// 一次专注会话（番茄钟）记录。
///
/// 与任务联动：可选关联一个 [taskId]/[taskTitle]，便于回顾"我在哪件事上花了时间"。
/// 不依赖 [Task] 实体，避免历史会话因任务被删而读不出。
class FocusSession {
  final String id;

  /// 关联任务 id；独立专注为 null。
  final String? taskId;

  /// 关联任务标题快照（任务删除后仍可显示）。
  final String? taskTitle;

  /// 本次预设的总时长（秒），如 25 分钟 = 1500。
  final int plannedSec;

  /// 实际专注时长（秒）。停止时按已流逝时间记录；自然跑满则等于 [plannedSec]。
  final int durationSec;

  /// 是否跑满一个番茄（剩余时间为 0）。手动提前停止为 false。
  final bool completed;

  final DateTime startedAt;
  final DateTime endedAt;

  const FocusSession({
    required this.id,
    this.taskId,
    this.taskTitle,
    required this.plannedSec,
    required this.durationSec,
    required this.completed,
    required this.startedAt,
    required this.endedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'taskId': taskId,
        'taskTitle': taskTitle,
        'plannedSec': plannedSec,
        'durationSec': durationSec,
        'completed': completed,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
      };

  factory FocusSession.fromJson(Map<String, dynamic> j) => FocusSession(
        id: j['id'] as String,
        taskId: j['taskId'] as String?,
        taskTitle: j['taskTitle'] as String?,
        plannedSec: j['plannedSec'] as int? ?? 0,
        durationSec: j['durationSec'] as int? ?? 0,
        completed: j['completed'] as bool? ?? false,
        startedAt: DateTime.parse(j['startedAt'] as String),
        endedAt: DateTime.parse(j['endedAt'] as String),
      );
}

/// 把秒格式化为 mm:ss 或 h:mm:ss。
String formatFocusDuration(int totalSec) {
  final s = totalSec.clamp(0, 359999);
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}
