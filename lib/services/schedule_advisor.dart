/// T1-1：「今日排程建议」纯函数内核。
///
/// 设计约束（与本项目一贯口径一致）：
/// 1. **严格离线**——纯本地计算，不联网、不引入任何外部服务或新存储；
/// 2. **纯函数、零副作用**——只消费调用方传入的待办列表与时间基准，便于单测，
///    也让「今日」页可以不落任何新表/新字段就展示排程；
/// 3. **不猜测用户意图**——无预估的任务按 [ScheduleAdvice.defaultMinutes] 兜底，
///    并把 `explicit=false` 标记出来，UI 可据此用弱化样式区分「真预估」与「占位」。
library;

import 'package:todolist/models/task.dart';

/// 排序 / 兜底用：无预估时长时每项占用的默认分钟数。
const int kDefaultEstimateMinutes = 30;

/// 一条排程建议项：某任务在「顺延链」上的预计起止时刻。
class ScheduleItem {
  /// 对应的任务（引用原对象，不复制）。
  final Task task;

  /// 生效时长（分钟）：任务自带预估，缺省回落 [explicit] 为 false 时的默认值。
  final int minutes;

  /// 是否为用户显式设定的预估时长（false = 使用了默认占位的 [kDefaultEstimateMinutes]）。
  final bool explicit;

  /// 顺延得到的预计开始时刻。
  final DateTime start;

  /// 顺延得到的预计结束时刻。
  final DateTime end;

  /// 预计结束时刻是否已晚于该任务的截止时间。
  ///
  /// 仅对**有截止时间**的任务可能为 true；无截止任务恒为 false
  /// （无「来不及」可言，只是排到今天末尾）。
  final bool missedDue;

  /// 该任务累计专注分钟（来自 [Task.focusSecTotal]），0 表示尚无专注记录。
  final int focusedMinutes;

  const ScheduleItem({
    required this.task,
    required this.minutes,
    required this.explicit,
    required this.start,
    required this.end,
    required this.missedDue,
    required this.focusedMinutes,
  });

  /// 「可能高估 / 低估」偏差文案（无预估或无专注记录时为 null）。
  ///
  /// 与 [estimateBiasLabel] 同源，供排程建议行与任务详情/统计处复用，
  /// 保证两处口径不会漂移。
  String? get biasLabel => estimateBiasLabel(
        estimatedMinutes: explicit ? minutes : null,
        actualMinutes: focusedMinutes,
      );

  /// 预计时段文案，如「14:05–14:35」。
  String get windowLabel => '${_hhmm(start)}–${_hhmm(end)}';

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// 今日排程建议的完整结果。
class ScheduleAdvice {
  /// 顺延链上的条目（已按「截止时间 → 预计时长 → 优先级」排序）。
  final List<ScheduleItem> items;

  /// 无预估时长时使用的兜底分钟数（记录来源，便于 UI 说明「按 X 分钟估」）。
  final int defaultMinutes;

  /// 顺延起点（= 计算时刻）。
  final DateTime from;

  /// 当天结束时刻（次日 00:00），用于判断「今天排不排得下」。
  final DateTime dayEnd;

  const ScheduleAdvice({
    required this.items,
    required this.defaultMinutes,
    required this.from,
    required this.dayEnd,
  });

  bool get isEmpty => items.isEmpty;

  /// 计划总时长（分钟）。
  int get totalMinutes => items.fold(0, (a, b) => a + b.minutes);

  /// 顺延预计完成时刻（无条目时等于顺延起点）。
  DateTime get finishAt => items.isEmpty ? from : items.last.end;

  /// 相对「今天剩余时间」的超时分钟数；0 = 今天排得下。
  int get overrunMinutes {
    final left = dayEnd.difference(finishAt).inMinutes;
    return left < 0 ? -left : 0;
  }

  /// 预计来不及（预计结束晚于截止）的条目数。
  int get missedDueCount => items.where((i) => i.missedDue).length;

  /// 使用兜底默认时长（非用户显式预估）的条目数。
  int get guessedCount => items.where((i) => !i.explicit).length;

  /// 汇总文案：如「共 4 项 · 约 2 小时 · 预计 16:30 完成」。
  String get summary {
    if (isEmpty) return '今天没有待办，无需排程';
    final buf = StringBuffer('共 ${items.length} 项 · 约 ${formatMinutes(totalMinutes)}');
    buf.write(' · 预计 ${ScheduleItem._hhmm(finishAt)} 完成');
    return buf.toString();
  }
}

/// 分钟数 → 「X 小时 Y 分」/「Y 分钟」。
String formatMinutes(int mins) {
  if (mins <= 0) return '0 分钟';
  if (mins < 60) return '$mins 分钟';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m == 0 ? '$h 小时' : '$h 小时 $m 分';
}

/// 预估 vs 实际的偏差文案（「可能高估 / 低估」提示的单一真源）。
///
/// 判定口径：以预估的 ±20% 作为「接近」的容差带（至少 5 分钟，避免小预估下
/// 1 分钟的抖动就被判定为偏差）。返回 null 表示**无从比较**——无预估、
/// 预估非法、或尚无实际投入，此时 UI 不应展示任何偏差文案。
String? estimateBiasLabel({
  required int? estimatedMinutes,
  required int? actualMinutes,
}) {
  final est = estimatedMinutes;
  final act = actualMinutes;
  if (est == null || est <= 0) return null;
  if (act == null || act <= 0) return null;
  final tolerance = (est * 0.2).ceil().clamp(5, 1 << 30);
  final diff = act - est;
  if (diff > tolerance) return '可能低估：已超预估 $diff 分钟';
  if (-diff > tolerance) return '可能高估：比预估少 ${-diff} 分钟';
  return '与预估接近';
}

/// 计算今日排程建议（纯函数）。
///
/// [pending] 为**今日未完成**的待办（调用方已完成日期过滤，如
/// [TodayAggregate.pendingTasks]）；[now] 为时间基准（默认取当前时刻，
/// 单测可注入）；[defaultMinutes] 为无预估任务占用的兜底时长。
///
/// 排序规则（与报告 T1-1 一致）：
/// 1. **截止时间**——有截止的排前（升序，最紧急的先做）；无截止的排到末尾；
/// 2. **预计时长**——短的先做（先清掉快赢，减少顺延链被长任务堵住）；
/// 3. **优先级**——高 → 中 → 低。
/// 排序是全序（最后以 id 兜底），因此同输入必定同输出，便于回归测试。
///
/// 顺延模型：从 [from] 起，按排序逐条累加时长，得到每条任务的预计起止时刻。
/// 这是「串行」估算（一次只做一件事），与番茄钟的单线程使用方式一致；
/// 不做并行/日历空档的复杂排布——那属于 T2-1 的时间网格，不在本轮范围。
ScheduleAdvice buildScheduleAdvice(
  List<Task> pending, {
  DateTime? now,
  int defaultMinutes = kDefaultEstimateMinutes,
}) {
  final base = now ?? DateTime.now();
  final from = DateTime(base.year, base.month, base.day, base.hour, base.minute);
  final dayEnd = DateTime(base.year, base.month, base.day).add(const Duration(days: 1));
  final def = defaultMinutes <= 0 ? kDefaultEstimateMinutes : defaultMinutes;

  final sorted = pending.toList()..sort((a, b) => compareForSchedule(a, b, def));

  final items = <ScheduleItem>[];
  var cursor = from;
  for (final t in sorted) {
    final explicit = t.hasEstimate;
    final mins = explicit ? t.estimateMinutes! : def;
    final start = cursor;
    final end = cursor.add(Duration(minutes: mins));
    final due = t.dueDate;
    items.add(ScheduleItem(
      task: t,
      minutes: mins,
      explicit: explicit,
      start: start,
      end: end,
      // 无截止时间 → 不存在「来不及」；有截止则比较预计结束时刻。
      missedDue: due != null && end.isAfter(due),
      focusedMinutes: t.focusedMinutes,
    ));
    cursor = end;
  }
  return ScheduleAdvice(
    items: items,
    defaultMinutes: def,
    from: from,
    dayEnd: dayEnd,
  );
}

/// 排程排序比较器（公开以便单测直接钉死排序口径）。
///
/// 全序：截止时间 → 预计时长 → 优先级 → id。id 兜底保证结果稳定，
/// 不会因 `List.sort` 的不稳定性在不同运行中给出不同顺序。
int compareForSchedule(Task a, Task b, [int defaultMinutes = kDefaultEstimateMinutes]) {
  final da = a.dueDate;
  final db = b.dueDate;
  if (da != null && db != null) {
    final c = da.compareTo(db);
    if (c != 0) return c;
  } else if (da != null) {
    return -1; // 有截止的排前
  } else if (db != null) {
    return 1;
  }

  final def = defaultMinutes <= 0 ? kDefaultEstimateMinutes : defaultMinutes;
  final ma = a.hasEstimate ? a.estimateMinutes! : def;
  final mb = b.hasEstimate ? b.estimateMinutes! : def;
  final c2 = ma.compareTo(mb);
  if (c2 != 0) return c2;

  // Priority 枚举顺序为 high, medium, low，index 升序即「高 → 中 → 低」。
  final c3 = a.priority.index.compareTo(b.priority.index);
  if (c3 != 0) return c3;

  return a.id.compareTo(b.id);
}
