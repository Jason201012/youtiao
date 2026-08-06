import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/focus_provider.dart';
import 'test_helpers.dart';

void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

FocusSession mk(int id, int dur, {bool completed = true, DateTime? endedAt}) {
  final end = endedAt ?? DateTime.now();
  return FocusSession(
    id: '$id',
    plannedSec: dur,
    durationSec: dur,
    completed: completed,
    startedAt: end.subtract(Duration(seconds: dur)),
    endedAt: end,
  );
}

void main() {
  setUpAll(_installMocks);

  group('运行态派生 remainingSec / progress', () {
    test('刚启动：满剩余、进度 0', () {
      final p = FocusProvider();
      p.activeTotalSec = 100;
      p.activeAccumulatedSec = 0;
      p.activeRunning = true;
      p.activeSegmentStartEpochMs = DateTime.now().millisecondsSinceEpoch;
      expect(p.remainingSec, 100);
      expect(p.progress, 0.0);
      expect(p.hasActive, isTrue);
    });
    test('累计秒减少剩余、提升进度', () {
      final p = FocusProvider();
      p.activeTotalSec = 100;
      p.activeAccumulatedSec = 30;
      p.activeRunning = false;
      p.activeSegmentStartEpochMs = null;
      expect(p.remainingSec, 70);
      expect(p.progress, closeTo(0.3, 1e-9));
    });
    test('remainingSec 不为负', () {
      final p = FocusProvider();
      p.activeTotalSec = 100;
      p.activeAccumulatedSec = 999;
      p.activeRunning = false;
      expect(p.remainingSec, 0);
    });
  });

  group('会话统计', () {
    test('totalSec / todayTotalSec / todayCompleted / totalSecOn', () {
      final p = FocusProvider();
      final today = DateTime.now();
      final yesterday = today.subtract(const Duration(days: 1));
      p.addSession(mk(1, 600, endedAt: today));
      p.addSession(mk(2, 300, endedAt: today));
      p.addSession(mk(3, 100, endedAt: yesterday));
      expect(p.totalSec, 1000);
      expect(p.todayTotalSec, 900);
      expect(p.todayCompleted, 2);
      expect(p.totalSecOn(yesterday), 100);
    });
  });

  group('start / pause / stop', () {
    test('startTimer 进入运行态；stopTimer 按已逝时间补录未完成会话', () async {
      final p = FocusProvider();
      await p.startTimer(totalSec: 100, modeIndex: 0, customSec: 100);
      expect(p.hasActive, isTrue);
      expect(p.remainingSec, 100);
      // 模拟已专注 30 秒后手动停止（stopTimer 只对 elapsed>0 才记会话）
      p.activeSegmentStartEpochMs =
          DateTime.now().subtract(const Duration(seconds: 30)).millisecondsSinceEpoch;
      p.activeRunning = true;
      await p.stopTimer();
      expect(p.hasActive, isFalse);
      expect(p.sessions.length, 1);
      expect(p.sessions.first.completed, isFalse); // 手动停止
      expect(p.sessions.first.durationSec, 30);
    });
    test('setCustomSec 持久化并更新 getter', () async {
      final p = FocusProvider();
      await p.setCustomSec(45 * 60);
      expect(p.customSec, 45 * 60);
    });
  });

  group('删除 / 清空', () {
    test('removeSession / clear', () {
      final p = FocusProvider();
      p.addSession(mk(1, 600));
      expect(p.totalSec, 600);
      p.removeSession('1');
      expect(p.totalSec, 0);
      p.addSession(mk(2, 300));
      p.clear();
      expect(p.totalSec, 0);
    });
  });

  group('导出', () {
    test('exportCsv / exportMarkdown 含会话', () {
      final p = FocusProvider();
      p.addSession(mk(1, 600, completed: true));
      expect(p.exportCsv(), contains('日期,开始时间'));
      expect(p.exportMarkdown(), contains('专注记录导出'));
    });
  });

  group('任务关联统计', () {
    test('taskStats 按关联任务聚合累计时长/次数，并按时长降序', () {
      final p = FocusProvider();
      final t = DateTime.now();
      p.addSession(FocusSession(
        id: '1', taskId: 'a', taskTitle: '写代码', plannedSec: 600, durationSec: 600,
        completed: true, startedAt: t.subtract(const Duration(seconds: 600)), endedAt: t));
      p.addSession(FocusSession(
        id: '2', taskId: 'a', taskTitle: '写代码', plannedSec: 300, durationSec: 300,
        completed: true, startedAt: t.subtract(const Duration(seconds: 300)), endedAt: t));
      p.addSession(FocusSession(
        id: '3', taskId: 'b', taskTitle: '读书', plannedSec: 100, durationSec: 100,
        completed: true, startedAt: t.subtract(const Duration(seconds: 100)), endedAt: t));
      p.addSession(mk(4, 50)); // 独立专注，无 taskId
      final stats = p.taskStats;
      expect(stats.length, 2);
      expect(stats.first.taskId, 'a');
      expect(stats.first.totalSec, 900);
      expect(stats.first.count, 2);
      expect(stats.last.taskId, 'b');
      expect(stats.last.totalSec, 100);
    });

    test('startTimer 接收关联任务，stopTimer 会话写入 taskId/taskTitle', () async {
      final p = FocusProvider();
      await p.startTimer(totalSec: 100, modeIndex: 0, customSec: 100,
          taskId: 'a', taskTitle: '写代码');
      expect(p.activeTaskId, 'a');
      p.activeSegmentStartEpochMs =
          DateTime.now().subtract(const Duration(seconds: 40)).millisecondsSinceEpoch;
      p.activeRunning = true;
      await p.stopTimer();
      expect(p.sessions.first.taskId, 'a');
      expect(p.sessions.first.taskTitle, '写代码');
      expect(p.sessions.first.durationSec, 40);
    });

    test('sessionsOn 返回某天结束的会话', () {
      final p = FocusProvider();
      final today = DateTime.now();
      final y = today.subtract(const Duration(days: 1));
      p.addSession(mk(1, 600, endedAt: today));
      p.addSession(mk(2, 300, endedAt: y));
      expect(p.sessionsOn(today).length, 1);
      expect(p.sessionsOn(y).length, 1);
    });
  });
}
