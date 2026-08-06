import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/services/local_database.dart';
import 'test_helpers.dart';

/// 验证 LocalDatabase 的「整表往返」与「旧版 SharedPreferences JSON → SQLite 迁移」。
///
/// 通过 test_helpers 开启纯内存后端（不依赖原生 sqlite3），因此既能在无 sqflite
/// 平台实现的宿主机上运行，也完整覆盖了 JSON 映射与迁移逻辑。生产代码使用真 SQLite，
/// 其 SQL 由 flutter analyze 校验、并在 Android 设备上真实运行验证。
void main() {
  setUp(() {
    useMemoryDatabase();
    LocalDatabase.resetMemoryForTest();
  });

  Task _mkTask(String id, {DateTime? deletedAt}) => Task(
        id: id,
        title: '任务$id',
        priority: Priority.medium,
        category: Category.work,
        dueDate: DateTime(2026, 8, 6, 12, 0),
        deletedAt: deletedAt,
      );

  FocusSession _mkSession(String id) => FocusSession(
        id: id,
        plannedSec: 1500,
        durationSec: 1500,
        completed: true,
        startedAt: DateTime(2026, 8, 6, 10, 0),
        endedAt: DateTime(2026, 8, 6, 10, 25),
      );

  test('tasks 表往返（含回收站 deletedAt 不丢失）', () async {
    final db = LocalDatabase.instance;
    final t = _mkTask('1');
    final tr = _mkTask('9', deletedAt: DateTime(2026, 8, 6));
    await db.replaceTasks([t], [tr]);

    final tasks = await db.loadTasks();
    final trash = await db.loadTrash();
    expect(tasks.length, 1);
    expect(trash.length, 1);
    expect(tasks.first.toJson(), t.toJson());
    expect(trash.first.toJson(), tr.toJson());
  });

  test('focus 表往返', () async {
    final db = LocalDatabase.instance;
    final s = _mkSession('s1');
    await db.replaceFocus([s]);

    final list = await db.loadFocus();
    expect(list.length, 1);
    expect(list.first.toJson(), s.toJson());
  });

  test('replaceTasks 整表替换（覆盖而非追加）', () async {
    final db = LocalDatabase.instance;
    await db.replaceTasks([_mkTask('1')], []);
    await db.replaceTasks([_mkTask('2')], []);
    expect((await db.loadTasks()).map((t) => t.id), ['2']);
  });

  test('从旧版 SharedPreferences JSON 迁移 tasks/trash 并清除旧 key', () async {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    final prefs = await SharedPreferences.getInstance();
    final t = _mkTask('1');
    final tr = _mkTask('9', deletedAt: DateTime(2026, 8, 6));
    await prefs.setString('tasks', jsonEncode([t.toJson()]));
    await prefs.setString('trash', jsonEncode([tr.toJson()]));

    final db = LocalDatabase.instance;
    expect(await db.tasksEmpty, isTrue);
    await db.migrateTasksFromPrefs(prefs);

    // 旧 key 已清除，DB 成为唯一真相来源
    expect(prefs.getString('tasks'), isNull);
    expect(prefs.getString('trash'), isNull);
    expect((await db.loadTasks()).map((e) => e.toJson()), [t.toJson()]);
    expect((await db.loadTrash()).map((e) => e.toJson()), [tr.toJson()]);
  });

  test('从旧版 SharedPreferences JSON 迁移 focus_sessions 并清除旧 key', () async {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    final prefs = await SharedPreferences.getInstance();
    final s = _mkSession('s1');
    await prefs.setString('focus_sessions', jsonEncode([s.toJson()]));

    final db = LocalDatabase.instance;
    expect(await db.focusEmpty, isTrue);
    await db.migrateFocusFromPrefs(prefs);

    expect(prefs.getString('focus_sessions'), isNull);
    expect((await db.loadFocus()).map((e) => e.toJson()), [s.toJson()]);
  });
}
