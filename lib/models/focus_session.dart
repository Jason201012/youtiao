/// 番茄钟阶段：专注 / 短休 / 长休。
///
/// 单次（非循环）计时也视作一次 [focus] 阶段，保持模型统一，
/// 历史会话（无 phase 字段）反序列化时默认回退到 [focus]。
enum FocusPhase {
  focus,
  shortBreak,
  longBreak,
}

extension FocusPhaseX on FocusPhase {
  /// 中文标签：专注 / 短休 / 长休。
  String get label {
    switch (this) {
      case FocusPhase.focus:
        return '专注';
      case FocusPhase.shortBreak:
        return '短休';
      case FocusPhase.longBreak:
        return '长休';
    }
  }

  /// 是否为休息阶段（短休 / 长休）。
  bool get isBreak => this != FocusPhase.focus;
}

/// 根据当前阶段与「本轮回合内已完成的专注数」推算下一阶段（纯函数，便于测试）。
///
/// [focusDoneInCycle] 为**包含刚完成的这次**之后、当前回合累计完成的专注数。
/// 规则：
/// - 专注完成后，若累计数恰好是 [roundsBeforeLong] 的整数倍 → 长休，否则 → 短休；
/// - 任一休息完成后 → 回到专注。
int _clampRounds(int rounds) => rounds < 1 ? 1 : rounds;

FocusPhase nextPhaseFrom(
  FocusPhase current,
  int focusDoneInCycle,
  int roundsBeforeLong,
) {
  if (current != FocusPhase.focus) return FocusPhase.focus;
  final rounds = _clampRounds(roundsBeforeLong);
  if (focusDoneInCycle > 0 && focusDoneInCycle % rounds == 0) {
    return FocusPhase.longBreak;
  }
  return FocusPhase.shortBreak;
}

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

  /// 本次会话所属阶段：专注 / 短休 / 长休。统计时仅 [focus] 计入"今日专注"与"番茄数"。
  final FocusPhase phase;

  final DateTime startedAt;
  final DateTime endedAt;

  const FocusSession({
    required this.id,
    this.taskId,
    this.taskTitle,
    required this.plannedSec,
    required this.durationSec,
    required this.completed,
    this.phase = FocusPhase.focus,
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
        'phase': phase.name,
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
        phase: FocusPhase.values.byName(j['phase'] as String? ?? 'focus'),
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
