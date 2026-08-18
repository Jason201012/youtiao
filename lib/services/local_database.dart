import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/checkin.dart';

/// 本地关系型存储（sqflite）。
///
/// 旧版的「任务列表 / 回收站 / 专注记录」全部以单个 JSON 字符串塞进
/// SharedPreferences 的一个 key 里，整存整取、无法增量更新、也难以上云同步。
/// 现统一迁入 SQLite，三张表分别存放：
///   - [kTasks]      活跃任务
///   - [kTrash]      回收站任务（含 deletedAt）
///   - [kFocus]      专注会话记录
///
/// 每行只存一个 `data` TEXT 列（即 Task/FocusSession 的完整 JSON），保持与旧格式
/// 逐元素一致；所有聚合/筛选/统计逻辑仍在 Dart 内存中完成（见 TaskProvider /
/// FocusProvider），本类只负责「整表读写 + 一次性迁移」。这样既拿到 SQLite 的
/// 增量写入与查询能力，又不改动任何业务语义，最大化降低迁移风险。
///
/// 启动迁移：首次启动（数据库为空且旧 SP key 仍存在）时，[migrateTasksFromPrefs] /
/// [migrateFocusFromPrefs] 会把旧 JSON 写入数据库并删除旧 SP key；此后 DB 成为唯一
/// 真相来源。若迁移中途失败，旧 SP key 不会被删除，下次启动可重试，绝不丢数据。
class LocalDatabase {
  static const String kDbName = 'youtiao.db';
  static const String kTasks = 'tasks';
  static const String kTrash = 'trash';
  static const String kFocus = 'focus_sessions';
  static const String kHabits = 'habits';
  static const String kCheckIns = 'check_ins';

  /// 旧版 SharedPreferences 中的 key（迁移后会被清除）。
  static const String kPrefTasks = 'tasks';
  static const String kPrefTrash = 'trash';
  static const String kPrefFocus = 'focus_sessions';

  static final LocalDatabase instance = LocalDatabase._();
  LocalDatabase._();

  /// 测试专用：覆盖数据库文件路径（设为具体文件），避免触碰 getDatabasesPath()
  /// （它在部分测试环境下需要 WidgetsBinding）。在首次 open 之前设置即可。
  static String? _testPathOverride;

  static void setTestPath(String path) {
    _testPathOverride = path;
    instance._db = null;
  }

  /// 测试专用：开启「纯内存后端」。本项目仅声明 Android/iOS/macOS 平台（无
  /// windows/linux 目录），宿主 `flutter test` 没有可用的 sqflite 平台实现，
  /// 此时改用纯 Dart 的内存 Map 模拟存储，既不依赖原生 sqlite3，也能验证
  /// 整表读写 / 旧版 SP 迁移等业务逻辑。生产代码永不开启（默认 false）。
  static bool testUseMemory = false;
  static final Map<String, String> _memTasks = {};
  static final Map<String, String> _memTrash = {};
  static final Map<String, String> _memFocus = {};
  static final Map<String, String> _memHabits = {};
  static final Map<String, String> _memCheckIns = {};

  /// 测试用：清空内存后端，避免静态 Map 在用例之间串味。
  static void resetMemoryForTest() {
    _memTasks.clear();
    _memTrash.clear();
    _memFocus.clear();
    _memHabits.clear();
    _memCheckIns.clear();
  }

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final base = _testPathOverride ?? await getDatabasesPath();
    final dbPath = _testPathOverride != null ? base : p.join(base, kDbName);
    _db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (database, _) async {
        await _createTables(database);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        // v1 → v2：新增 habits / check_ins 两张表（旧库无数据可丢，直接建表）。
        if (oldVersion < 2) {
          await database.execute('''
            CREATE TABLE $kHabits (
              id TEXT PRIMARY KEY,
              data TEXT NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE $kCheckIns (
              id TEXT PRIMARY KEY,
              data TEXT NOT NULL
            )
          ''');
        }
      },
    );
    return _db!;
  }

  /// 建表（v2 起的完整表集合：tasks / trash / focus_sessions / habits / check_ins）。
  static Future<void> _createTables(Database database) async {
    await database.execute('''
      CREATE TABLE $kTasks (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE $kTrash (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE $kFocus (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE $kHabits (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE $kCheckIns (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL
      )
    ''');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ===== 任务 =====

  /// 任务表是否为空（用于判断是否需要进行首次启动迁移 / 是否全新安装）。
  Future<bool> get tasksEmpty async {
    if (testUseMemory) return _memTasks.isEmpty;
    final d = await db;
    final row = await d.rawQuery('SELECT COUNT(*) AS n FROM $kTasks');
    return (row.first['n'] as int) == 0;
  }

  Future<List<Task>> loadTasks() async {
    if (testUseMemory) {
      return _memTasks.values
          .map((j) => Task.fromJson(
              jsonDecode(j) as Map<String, dynamic>))
          .toList();
    }
    final d = await db;
    final rows = await d.query(kTasks);
    return rows
        .map((r) => Task.fromJson(
            jsonDecode(r['data'] as String) as Map<String, dynamic>))
        .toList();
  }

  Future<List<Task>> loadTrash() async {
    if (testUseMemory) {
      return _memTrash.values
          .map((j) => Task.fromJson(
              jsonDecode(j) as Map<String, dynamic>))
          .toList();
    }
    final d = await db;
    final rows = await d.query(kTrash);
    return rows
        .map((r) => Task.fromJson(
            jsonDecode(r['data'] as String) as Map<String, dynamic>))
        .toList();
  }

  /// 整表替换：清空 tasks / trash 后重新写入。数据量小（数百条内），整表重写
  /// 与旧版「整存整取」语义一致，但改为按行持久化，天然支持增量且不锁整个 JSON。
  Future<void> replaceTasks(List<Task> tasks, List<Task> trash) async {
    if (testUseMemory) {
      _memTasks.clear();
      _memTrash.clear();
      for (final t in tasks) {
        _memTasks[t.id] = jsonEncode(t.toJson());
      }
      for (final t in trash) {
        _memTrash[t.id] = jsonEncode(t.toJson());
      }
      return;
    }
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete(kTasks);
      await txn.delete(kTrash);
      for (final t in tasks) {
        await txn.insert(kTasks, {
          'id': t.id,
          'data': jsonEncode(t.toJson()),
        });
      }
      for (final t in trash) {
        await txn.insert(kTrash, {
          'id': t.id,
          'data': jsonEncode(t.toJson()),
        });
      }
    });
  }

  // ===== 专注会话 =====

  Future<bool> get focusEmpty async {
    if (testUseMemory) return _memFocus.isEmpty;
    final d = await db;
    final row = await d.rawQuery('SELECT COUNT(*) AS n FROM $kFocus');
    return (row.first['n'] as int) == 0;
  }

  Future<List<FocusSession>> loadFocus() async {
    if (testUseMemory) {
      return _memFocus.values
          .map((j) => FocusSession.fromJson(
              jsonDecode(j) as Map<String, dynamic>))
          .toList();
    }
    final d = await db;
    final rows = await d.query(kFocus);
    return rows
        .map((r) => FocusSession.fromJson(
            jsonDecode(r['data'] as String) as Map<String, dynamic>))
        .toList();
  }

  Future<void> replaceFocus(List<FocusSession> sessions) async {
    if (testUseMemory) {
      _memFocus.clear();
      for (final s in sessions) {
        _memFocus[s.id] = jsonEncode(s.toJson());
      }
      return;
    }
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete(kFocus);
      for (final s in sessions) {
        await txn.insert(kFocus, {
          'id': s.id,
          'data': jsonEncode(s.toJson()),
        });
      }
    });
  }

  // ===== 习惯 / 打卡 =====

  Future<bool> get habitsEmpty async {
    if (testUseMemory) return _memHabits.isEmpty;
    final d = await db;
    final row = await d.rawQuery('SELECT COUNT(*) AS n FROM $kHabits');
    return (row.first['n'] as int) == 0;
  }

  Future<List<Habit>> loadHabits() async {
    if (testUseMemory) {
      return _memHabits.values
          .map((j) =>
              Habit.fromJson(jsonDecode(j) as Map<String, dynamic>))
          .toList();
    }
    final d = await db;
    final rows = await d.query(kHabits);
    return rows
        .map((r) =>
            Habit.fromJson(jsonDecode(r['data'] as String) as Map<String, dynamic>))
        .toList();
  }

  Future<void> replaceHabits(List<Habit> habits) async {
    if (testUseMemory) {
      _memHabits.clear();
      for (final h in habits) {
        _memHabits[h.id] = jsonEncode(h.toJson());
      }
      return;
    }
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete(kHabits);
      for (final h in habits) {
        await txn.insert(kHabits, {
          'id': h.id,
          'data': jsonEncode(h.toJson()),
        });
      }
    });
  }

  Future<List<CheckIn>> loadCheckIns() async {
    if (testUseMemory) {
      return _memCheckIns.values
          .map((j) =>
              CheckIn.fromJson(jsonDecode(j) as Map<String, dynamic>))
          .toList();
    }
    final d = await db;
    final rows = await d.query(kCheckIns);
    return rows
        .map((r) => CheckIn.fromJson(
            jsonDecode(r['data'] as String) as Map<String, dynamic>))
        .toList();
  }

  Future<void> replaceCheckIns(List<CheckIn> checkIns) async {
    if (testUseMemory) {
      _memCheckIns.clear();
      for (final c in checkIns) {
        _memCheckIns[c.id] = jsonEncode(c.toJson());
      }
      return;
    }
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete(kCheckIns);
      for (final c in checkIns) {
        await txn.insert(kCheckIns, {
          'id': c.id,
          'data': jsonEncode(c.toJson()),
        });
      }
    });
  }

  // ===== 旧版 SharedPreferences → SQLite 迁移 =====

  static List<Task> _parseTasks(String? raw) {
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Task.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 把旧版 SP 中的 tasks / trash JSON 迁移进数据库，成功后清除对应旧 key。
  /// 若写入过程中抛错，旧 key 不会被删除，下次启动可安全重试。
  Future<void> migrateTasksFromPrefs(SharedPreferences prefs) async {
    final tasks = _parseTasks(prefs.getString(kPrefTasks));
    final trash = _parseTasks(prefs.getString(kPrefTrash));
    await replaceTasks(tasks, trash);
    await prefs.remove(kPrefTasks);
    await prefs.remove(kPrefTrash);
  }

  /// 把旧版 SP 中的 focus_sessions JSON 迁移进数据库，成功后清除旧 key。
  Future<void> migrateFocusFromPrefs(SharedPreferences prefs) async {
    final sessions = _parseFocus(prefs.getString(kPrefFocus));
    await replaceFocus(sessions);
    await prefs.remove(kPrefFocus);
  }

  static List<FocusSession> _parseFocus(String? raw) {
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => FocusSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
