import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/period_review.dart';
import 'package:todolist/models/review.dart';
import 'package:todolist/models/review_narrative.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/period_review_card.dart';

/// 构造最小 [PeriodReview] 用于文案单测（不依赖 Provider / 数据库）。
PeriodReview _period({
  int completedCount = 0,
  int prevCompletedCount = 0,
  int focusSec = 0,
  int prevFocusSec = 0,
  int pomodoroCount = 0,
  int focusInterruptCount = 0,
  int focusSessionCount = 0,
  int habitExpected = 0,
  int habitDone = 0,
  List<int> buckets = const [],
  List<String> bucketLabels = const [],
  int activeDays = 0,
  int totalDays = 30,
  int bestBucketIndex = -1,
  int bestBucketCount = 0,
  Map<Category, int> categoryCount = const {},
  Map<Category, int> focusByCategory = const {},
  int focusUntrackedSec = 0,
  List<TaskFocusStat> focusTop = const [],
  List<HabitPeriodStat> habits = const [],
}) =>
    PeriodReview(
      period: ReviewPeriod.month,
      start: DateTime(2026, 8, 1),
      end: DateTime(2026, 8, 31),
      completedCount: completedCount,
      prevCompletedCount: prevCompletedCount,
      focusSec: focusSec,
      prevFocusSec: prevFocusSec,
      pomodoroCount: pomodoroCount,
      focusInterruptCount: focusInterruptCount,
      focusSessionCount: focusSessionCount,
      habitRate: habitExpected == 0
          ? 0.0
          : (habitDone / habitExpected).clamp(0.0, 1.0),
      habitExpected: habitExpected,
      habitDone: habitDone,
      buckets: buckets,
      bucketLabels: bucketLabels,
      activeDays: activeDays,
      totalDays: totalDays,
      bestBucketIndex: bestBucketIndex,
      bestBucketCount: bestBucketCount,
      categoryCount: categoryCount,
      focusTop: focusTop,
      focusByCategory: focusByCategory,
      focusUntrackedSec: focusUntrackedSec,
      habits: habits,
    );

/// 构造最小 [WeeklyReview] 用于文案单测。
WeeklyReview _week({
  int completedCount = 0,
  int focusSec = 0,
  int pomodoroCount = 0,
  int habitExpected = 0,
  int habitDone = 0,
  List<int> trend = const [0, 0, 0, 0, 0, 0, 0],
  List<int> lastTrend = const [0, 0, 0, 0, 0, 0, 0],
  List<DateTime>? weekDates,
  List<TaskFocusStat> focusTop = const [],
  List<HabitWeekStat> habits = const [],
}) =>
    WeeklyReview(
      weekStart: DateTime(2026, 8, 3),
      weekEnd: DateTime(2026, 8, 9),
      completedCount: completedCount,
      focusSec: focusSec,
      pomodoroCount: pomodoroCount,
      habitRate: habitExpected == 0
          ? 0.0
          : (habitDone / habitExpected).clamp(0.0, 1.0),
      habitExpected: habitExpected,
      habitDone: habitDone,
      trend: trend,
      lastTrend: lastTrend,
      weekDates: weekDates ??
          List.generate(7, (i) => DateTime(2026, 8, 3 + i)),
      categoryProgress: const {},
      focusTop: focusTop,
      habits: habits,
    );

void main() {
  group('buildPeriodNarrative', () {
    test('包含完成数/环比/专注/习惯/最佳日', () {
      final r = _period(
        completedCount: 12,
        prevCompletedCount: 8,
        focusSec: 3600,
        prevFocusSec: 1800,
        pomodoroCount: 3,
        habitExpected: 10,
        habitDone: 7,
        bestBucketIndex: 13,
        bestBucketCount: 4,
        bucketLabels: List.generate(31, (i) => '${i + 1}'),
      );
      final t = buildPeriodNarrative(r);
      expect(t, contains('12 个任务'));
      expect(t, contains('比上月多 4 个'));
      expect(t, contains('专注 60 分钟'));
      expect(t, contains('较上月多 30 分钟'));
      expect(t, contains('习惯整体达成率 70%'));
      expect(t, contains('最高产的日是 8月14日'));
      expect(t, endsWith('。'));
    });

    test('专注下降显示「较上月少」', () {
      final r = _period(focusSec: 1200, prevFocusSec: 3600);
      expect(buildPeriodNarrative(r), contains('较上月少 40 分钟'));
    });

    test('空数据返回鼓励文案且不崩、不为空', () {
      final r = _period();
      final t = buildPeriodNarrative(r);
      expect(t, isNotEmpty);
      expect(t, contains('这个周期比较安静'));
    });
  });

  group('buildWeeklyNarrative', () {
    test('包含完成数/与上周环比/最佳日', () {
      final r = _week(
        completedCount: 9,
        lastTrend: [1, 1, 1, 1, 0, 0, 0], // 上周合计 4
        focusSec: 1800,
        pomodoroCount: 2,
        habitExpected: 7,
        habitDone: 5,
        trend: [0, 3, 0, 2, 0, 4, 0], // 最高产：index 5 = 周六
      );
      final t = buildWeeklyNarrative(r);
      expect(t, contains('本周你完成了 9 个任务'));
      expect(t, contains('比上周多 5 个'));
      expect(t, contains('专注 30 分钟'));
      expect(t, contains('习惯整体达成率 71%'));
      expect(t, contains('产出最高的是周六'));
    });

    test('空数据返回鼓励文案', () {
      final r = _week();
      final t = buildWeeklyNarrative(r);
      expect(t, isNotEmpty);
      expect(t, contains('安静'));
    });
  });

  testWidgets('PeriodReviewShareCard 渲染含 AI 小结且无异常', (tester) async {
    final r = _period(
      completedCount: 5,
      prevCompletedCount: 3,
      focusSec: 600,
      prevFocusSec: 300,
      pomodoroCount: 2,
      habitExpected: 4,
      habitDone: 3,
      bestBucketIndex: 2,
      bestBucketCount: 3,
      buckets: const [1, 2, 3],
      bucketLabels: const ['1', '2', '3'],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: lightTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(child: PeriodReviewShareCard(review: r)),
          ),
        ),
      ),
    );
    expect(find.text('AI 小结'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
