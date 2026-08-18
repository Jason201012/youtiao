import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/models/achievement.dart';

void main() {
  group('Habit 序列化', () {
    test('toJson → fromJson 往返一致', () {
      final h = Habit(
        id: 'h1',
        title: '阅读',
        emoji: '📚',
        colorValue: 0xFF6750A4,
        weekdays: [1, 3, 5],
        createdAt: DateTime(2024, 5, 1, 10, 30),
      );
      final j = h.toJson();
      final back = Habit.fromJson(j);
      expect(back.id, 'h1');
      expect(back.title, '阅读');
      expect(back.emoji, '📚');
      expect(back.colorValue, 0xFF6750A4);
      expect(back.weekdays, [1, 3, 5]);
      expect(back.createdAt, DateTime(2024, 5, 1, 10, 30));
    });

    test('weekdays 缺省为空（每天）', () {
      final j = {'id': 'x', 'title': 't'} as Map<String, dynamic>;
      final h = Habit.fromJson(j);
      expect(h.weekdays, isEmpty);
      expect(h.shouldCheckInOn(DateTime(2024, 1, 1)), isTrue);
    });

    test('shouldCheckInOn 按 weekday 过滤', () {
      final h = Habit(id: 'x', title: 't', weekdays: [1, 3, 5],
          createdAt: DateTime.now());
      // 2024-01-01 是周一(1) → 应打卡；2024-01-02 是周二(2) → 不应
      expect(h.shouldCheckInOn(DateTime(2024, 1, 1)), isTrue);
      expect(h.shouldCheckInOn(DateTime(2024, 1, 2)), isFalse);
    });

    test('copyWith 仅改指定字段', () {
      final h = Habit(id: 'x', title: 'old', createdAt: DateTime(2020));
      final c = h.copyWith(title: 'new');
      expect(c.title, 'new');
      expect(c.id, 'x');
      expect(c.emoji, '✅');
    });

    test('reminderMinute 往返一致，缺省为 null', () {
      final h = Habit(
        id: 'r1',
        title: '喝水',
        reminderMinute: 21 * 60 + 30, // 21:30
        createdAt: DateTime(2024, 1, 1),
      );
      final back = Habit.fromJson(h.toJson());
      expect(back.reminderMinute, 1290);

      // 旧数据（无该字段）解析为 null，不崩
      final legacy = Habit.fromJson({'id': 'r2', 'title': 't'});
      expect(legacy.reminderMinute, isNull);
    });

    test('copyWith 改提醒时间 / clearReminder 才能清空', () {
      final h = Habit(
        id: 'r3',
        title: 't',
        reminderMinute: 480,
        createdAt: DateTime(2024),
      );
      // 改时间
      expect(h.copyWith(reminderMinute: 1260).reminderMinute, 1260);
      // 传 null 视为「不修改」，保留原值（避免可空字段语义歧义）
      expect(h.copyWith(reminderMinute: null).reminderMinute, 480);
      // 显式清除
      expect(h.copyWith(clearReminder: true).reminderMinute, isNull);
      // 清除时不影响其他字段
      final cleared = h.copyWith(clearReminder: true);
      expect(cleared.id, 'r3');
      expect(cleared.title, 't');
    });
  });

  group('CheckIn 序列化', () {
    test('forDay 同一天生成稳定 id（去重）', () {
      final a = CheckIn.forDay('h1', DateTime(2024, 1, 1, 9, 0));
      final b = CheckIn.forDay('h1', DateTime(2024, 1, 1, 23, 59));
      expect(a.id, b.id);
      expect(a.id, 'h1@2024-01-01');
      expect(a.date, DateTime(2024, 1, 1)); // date-only
    });

    test('不同习惯/不同天 id 不同', () {
      final a = CheckIn.forDay('h1', DateTime(2024, 1, 1));
      final b = CheckIn.forDay('h2', DateTime(2024, 1, 1));
      final c = CheckIn.forDay('h1', DateTime(2024, 1, 2));
      expect(a.id, isNot(b.id));
      expect(a.id, isNot(c.id));
    });

    test('toJson → fromJson 往返', () {
      final a = CheckIn.forDay('h1', DateTime(2024, 1, 1));
      final back = CheckIn.fromJson(a.toJson());
      expect(back.id, a.id);
      expect(back.habitId, 'h1');
      expect(back.date, DateTime(2024, 1, 1));
    });
  });

  group('成就解锁判定', () {
    test('首次打卡解锁 first_checkin', () {
      const ctx = AchievementContext(totalCheckIns: 1);
      expect(allAchievements.byId('first_checkin').unlocked(ctx), isTrue);
      expect(allAchievements.byId('streak_7').unlocked(ctx), isFalse);
    });

    test('连续 7 天解锁 streak_7 与 streak_3', () {
      const ctx = AchievementContext(longestStreak: 7);
      expect(allAchievements.byId('streak_3').unlocked(ctx), isTrue);
      expect(allAchievements.byId('streak_7').unlocked(ctx), isTrue);
      expect(allAchievements.byId('checkin_100').unlocked(ctx), isFalse);
    });

    test('百日坚持 / 三好习惯 / 大师', () {
      const ctx = AchievementContext(totalCheckIns: 200, habitCount: 5);
      expect(allAchievements.byId('checkin_100').unlocked(ctx), isTrue);
      expect(allAchievements.byId('habits_3').unlocked(ctx), isTrue);
      expect(allAchievements.byId('master').unlocked(ctx), isTrue);
    });

    test('任务达人 / 专注一小时 依赖跨域统计', () {
      const ctx = AchievementContext(completedTasks: 50, focusMinutes: 60);
      expect(allAchievements.byId('tasks_50').unlocked(ctx), isTrue);
      expect(allAchievements.byId('focus_60').unlocked(ctx), isTrue);
    });
  });
}

extension _ById on List<Achievement> {
  Achievement byId(String id) => firstWhere((a) => a.id == id);
}
