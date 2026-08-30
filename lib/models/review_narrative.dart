import 'package:todolist/models/period_review.dart';
import 'package:todolist/models/review.dart';

/// 回顾页的自然语言小结生成器（「AI 周报 / 月报文案」）。
///
/// 纯函数、零新存储：只消费 [WeeklyReview] / [PeriodReview] 的**公开聚合字段**，
/// 在内存里拼出一段像人写的总结。应用是本地优先、零云端的，因此这里用本地模板式
/// 生成（不接 LLM），通过句式变化 + 鼓励式收尾让文案读起来更像「AI 帮你写的周报」。
///
/// 设计要点：
/// - 始终先陈述事实（完成数 / 专注时长 / 习惯达成率 / 最高产日），再补一句收尾；
/// - 环比用上一周期数据，持平 / 上升 / 下降三种口吻都覆盖；
/// - 全为空数据时返回温和的鼓励文案，绝不崩、绝不输出空串。

const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 周报自然语言小结。
String buildWeeklyNarrative(WeeklyReview r) {
  final parts = <String>[];

  // —— 任务（与上周环比）——
  final lastWeek = r.lastTrend.fold<int>(0, (a, b) => a + b);
  final delta = r.completedCount - lastWeek;
  final taskSent = StringBuffer('本周你完成了 ${r.completedCount} 个任务');
  if (lastWeek > 0) {
    if (delta > 0) {
      taskSent.write('，比上周多 $delta 个');
    } else if (delta < 0) {
      taskSent.write('，比上周少 ${-delta} 个');
    } else {
      taskSent.write('，与上周持平');
    }
  }
  parts.add(taskSent.toString());

  // —— 专注 ——
  if (r.focusMinutes > 0) {
    parts.add('累计专注 ${r.focusMinutes} 分钟，跑满 ${r.pomodoroCount} 个番茄');
  }

  // —— 习惯 ——
  if (r.habitExpected > 0) {
    parts.add('习惯整体达成率 ${r.habitPercent}%，打卡 ${r.habitDone}/${r.habitExpected} 次');
  }

  // —— 最佳日 ——
  final bestIdx = _argMax(r.trend);
  if (bestIdx >= 0 && bestIdx < r.weekDates.length && r.trend[bestIdx] > 0) {
    final wd = _weekdayName(r.weekDates[bestIdx].weekday);
    parts.add('产出最高的是$wd（${r.trend[bestIdx]} 个任务）');
  }

  parts.add(_closing(
    completed: r.completedCount,
    focusMin: r.focusMinutes,
    habitPct: r.habitPercent,
    habitExpected: r.habitExpected,
    completedDelta: delta,
    focusDelta: 0,
  ));

  return parts.join('，') + '。';
}

/// 月报 / 年报自然语言小结。
String buildPeriodNarrative(PeriodReview r) {
  final parts = <String>[];
  final u = r.period.unitLabel; // 本月 / 本年
  final prev = r.period.prevLabel; // 上月 / 去年

  // —— 任务（与上一周期环比）——
  final taskSent = StringBuffer('本期你完成了 ${r.completedCount} 个任务');
  if (r.completedDelta > 0) {
    taskSent.write('，比$prev多 ${r.completedDelta} 个');
  } else if (r.completedDelta < 0) {
    taskSent.write('，比$prev少 ${-r.completedDelta} 个');
  } else {
    taskSent.write('，与$prev持平');
  }
  parts.add(taskSent.toString());

  // —— 专注（与上一周期环比）——
  if (r.focusMinutes > 0) {
    final focusSent = StringBuffer('累计专注 ${r.focusMinutes} 分钟');
    if (r.focusMinutesDelta > 0) {
      focusSent.write('（较$prev多 ${r.focusMinutesDelta} 分钟）');
    } else if (r.focusMinutesDelta < 0) {
      focusSent.write('（较$prev少 ${-r.focusMinutesDelta} 分钟）');
    }
    focusSent.write('，跑满 ${r.pomodoroCount} 个番茄');
    // F2：打断数据展示闭环——月报补充「平均每次专注被打断次数」。
    // 仅当区间内有专注会话时才给出，避免「0 次」「÷0」的怪异表述。
    if (r.focusSessionCount > 0) {
      final avg = (r.focusInterruptCount / r.focusSessionCount);
      focusSent.write('，平均每次专注被打断 ${avg.toStringAsFixed(1)} 次');
    }
    parts.add(focusSent.toString());
  }

  // —— 习惯 ——
  if (r.habitExpected > 0) {
    parts.add('习惯整体达成率 ${r.habitPercent}%，打卡 ${r.habitDone}/${r.habitExpected} 次');
  }

  // —— 最佳日 / 最佳月 ——
  if (r.bestBucketLabel != null && r.bestBucketCount > 0) {
    // 月报按「天」分桶，年报 / 学期报按「月」分桶。
    final unit = r.period == ReviewPeriod.month ? '日' : '月';
    parts.add('最高产的$unit是 ${r.bestBucketLabel}（${r.bestBucketCount} 个任务）');
  }

  parts.add(_closing(
    completed: r.completedCount,
    focusMin: r.focusMinutes,
    habitPct: r.habitPercent,
    habitExpected: r.habitExpected,
    completedDelta: r.completedDelta,
    focusDelta: r.focusMinutesDelta,
  ));

  return parts.join('，') + '。';
}

/// 收尾一句：根据整体表现给不同的鼓励口吻。
String _closing({
  required int completed,
  required int focusMin,
  required int habitPct,
  required int habitExpected,
  required int completedDelta,
  required int focusDelta,
}) {
  final quiet = completed == 0 &&
      focusMin == 0 &&
      (habitExpected == 0 || habitPct == 0);
  if (quiet) {
    return '这个周期比较安静，新的开始总是充满可能，明天就是很好的起点';
  }
  if (completed >= 20 || focusMin >= 600) {
    return '节奏非常稳，这样的坚持最难能可贵，继续保持下去';
  }
  if ((completedDelta >= 0 && focusDelta >= 0) &&
      (habitExpected == 0 || habitPct >= 60)) {
    return '稳步推进，下个周期可以再往前一步';
  }
  return '每一份坚持都有意义，下个周期继续加油';
}

int _argMax(List<int> v) {
  if (v.isEmpty) return -1;
  int idx = -1;
  int max = 0;
  for (int i = 0; i < v.length; i++) {
    if (v[i] > max) {
      max = v[i];
      idx = i;
    }
  }
  return idx;
}

String _weekdayName(int w) => _weekdays[(w - 1).clamp(0, 6)];
