import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/state/habit_provider.dart';
import 'test_helpers.dart';

void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

void main() {
  setUp(() {
    _installMocks();
    LocalDatabase.resetMemoryForTest();
  });

  test('习惯备份/恢复往返一致（含打卡记录）', () async {
    final p = HabitProvider();
    await p.addHabit(
      title: '阅读',
      emoji: '📚',
      colorValue: 0xFF0061A4,
      weekdays: [1, 3, 5],
    );
    final h = p.habits.first;
    await p.checkInOnDay(h, DateTime(2026, 8, 1));
    await p.checkInOnDay(h, DateTime(2026, 8, 2));

    final map = p.backupData();
    expect(map['habits'], isA<List>());
    expect(map['check_ins'], isA<List>());

    final p2 = HabitProvider();
    await p2.restoreFromJson(map);
    expect(p2.habits.length, 1);
    expect(p2.habits.first.title, '阅读');
    expect(p2.checkInCount(p2.habits.first), 2);
  });

  test('老备份（无 habits 键）恢复不破坏现有习惯', () async {
    final p = HabitProvider();
    await p.addHabit(title: '现有习惯', emoji: '💧', colorValue: 0xFF00696E, weekdays: []);
    final existing = p.habits.first;

    // 模拟一份仅含 tasks 的老备份。
    final legacy = <String, dynamic>{
      'version': 2,
      'app': '有条',
      'tasks': [],
      'trash': [],
    };
    await p.restoreFromJson(legacy);
    expect(p.habits.length, 1);
    expect(p.habits.first.id, existing.id);
  });

  test('习惯导出 CSV / Markdown 含预期段落', () {
    final p = HabitProvider();
    final csv = p.exportCsv();
    expect(csv, contains('习惯,表情'));
    expect(csv, contains('习惯,打卡日期'));
    final md = p.exportMarkdown();
    expect(md, contains('# 有条 习惯导出'));
  });

  test('currentStreak 统计连续天数', () {
    final p = HabitProvider();
    final h = Habit(
      id: 'x',
      title: 't',
      emoji: '✅',
      colorValue: 0,
      createdAt: DateTime.now(),
    );
    p.checkInOnDay(h, DateTime.now());
    p.checkInOnDay(h, DateTime.now().subtract(const Duration(days: 1)));
    p.checkInOnDay(h, DateTime.now().subtract(const Duration(days: 2)));
    expect(p.currentStreak(h), 3);
  });
}
