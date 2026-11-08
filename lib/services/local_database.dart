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
    failNextReplaceTasks = false;
  }

  /// P3-6（v3.1.5 审计）：测试用——下一次 [replaceTasks] 抛错，模拟磁盘满 /
  /// 数据库忙等写入失败（用于验证「首启示例落盘失败不置 seeded」）。
  /// 生产代码永不置位。
  static bool failNextReplaceTasks = false;

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

  /// 增量 upsert 通用实现（S5 修复核心）。在单个事务内对单表做「差量合并」：
  ///   - 仅对「数据发生变化的行」落盘（insert/replace），未变行跳过，降低写放大；
  ///   - 删除「库中存在但本次列表未包含」的 id（被删项 / 已清出回收站的项）；
  ///   - 全部操作包进一个事务，保证原子性（要么全成，要么全不成），且不会在
  ///     写入中途清空整表，崩溃时旧数据仍可被抢救。
  /// [incomingIds] 与 [incomingData] 为「id → JSON 字符串」的对应；JSON 取自各
  /// 模型的 `toJson()`，Dart 的 Map 字面量迭代顺序稳定，`jsonEncode` 输出可比较。
  static Future<void> _incrementalUpsert(
    DatabaseExecutor txn,
    String table,
    List<String> incomingIds,
    Map<String, String> incomingData,
  ) async {
    final existing = await txn.query(table, columns: ['id', 'data']);
    final existingData = <String, String>{};
    final existingIds = <String>{};
    for (final r in existing) {
      final id = r['id'] as String;
      existingIds.add(id);
      existingData[id] = r['data'] as String;
    }
    for (final id in incomingIds) {
      final json = incomingData[id]!;
      if (existingData[id] == json) continue; // 未变化，跳过写（减少写放大）
      await txn.insert(
        table,
        {'id': id, 'data': json},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    final toDelete = existingIds.difference(incomingIds.toSet());
    for (final id in toDelete) {
      await txn.delete(table, where: 'id = ?', whereArgs: [id]);
    }
  }

  /// 增量持久化（S5 修复）：不再「整表 DELETE 后全量重插」，改为按主键差量合并。
  /// 调用方仍传入完整列表（Provider 持有全量），本方法内部按 id 做 upsert / 删除，
  /// 对外接口不变，无需改动任何上层调用点。
  Future<void> replaceTasks(List<Task> tasks, List<Task> trash) async {
    if (failNextReplaceTasks) {
      failNextReplaceTasks = false;
      throw StateError('replaceTasks 写入失败（测试注入）');
    }
    // 快照：调用方传入的是 Provider 持有的可变列表引用，事务内多个 await 之间
    // 用户操作（addTask 的 insert / _removeMany 的 removeAt）可能修改原列表，
    // 导致迭代抛出 ConcurrentModificationError 而整次持久化静默失败。
    final tasksCopy = List<Task>.from(tasks);
    final trashCopy = List<Task>.from(trash);
    if (testUseMemory) {
      // 内存后端已是按 id 的 Map：先删「本次未传入」的键，再写入传入项。
      final taskIds = <String>{for (final t in tasksCopy) t.id};
      final trashIds = <String>{for (final t in trashCopy) t.id};
      _memTasks.removeWhere((k, _) => !taskIds.contains(k));
      _memTrash.removeWhere((k, _) => !trashIds.contains(k));
      for (final t in tasksCopy) {
        _memTasks[t.id] = jsonEncode(t.toJson());
      }
      for (final t in trashCopy) {
        _memTrash[t.id] = jsonEncode(t.toJson());
      }
      return;
    }
    final d = await db;
    await d.transaction((txn) async {
      final taskIds = <String>[for (final t in tasksCopy) t.id];
      final taskData = <String, String>{
        for (final t in tasksCopy) t.id: jsonEncode(t.toJson())
      };
      await _incrementalUpsert(txn, kTasks, taskIds, taskData);
      final trashIds = <String>[for (final t in trashCopy) t.id];
      final trashData = <String, String>{
        for (final t in trashCopy) t.id: jsonEncode(t.toJson())
      };
      await _incrementalUpsert(txn, kTrash, trashIds, trashData);
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
    final copy = List<FocusSession>.from(sessions); // 快照，避免迭代期被并发修改
    if (testUseMemory) {
      final ids = <String>{for (final s in copy) s.id};
      _memFocus.removeWhere((k, _) => !ids.contains(k));
      for (final s in copy) {
        _memFocus[s.id] = jsonEncode(s.toJson());
      }
      return;
    }
    final d = await db;
    await d.transaction((txn) async {
      final ids = <String>[for (final s in copy) s.id];
      final data = <String, String>{
        for (final s in copy) s.id: jsonEncode(s.toJson())
      };
      await _incrementalUpsert(txn, kFocus, ids, data);
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
    final copy = List<Habit>.from(habits); // 快照，避免迭代期被并发修改
    if (testUseMemory) {
      final ids = <String>{for (final h in copy) h.id};
      _memHabits.removeWhere((k, _) => !ids.contains(k));
      for (final h in copy) {
        _memHabits[h.id] = jsonEncode(h.toJson());
      }
      return;
    }
    final d = await db;
    await d.transaction((txn) async {
      final ids = <String>[for (final h in copy) h.id];
      final data = <String, String>{
        for (final h in copy) h.id: jsonEncode(h.toJson())
      };
      await _incrementalUpsert(txn, kHabits, ids, data);
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
    final copy = List<CheckIn>.from(checkIns); // 快照，避免迭代期被并发修改
    if (testUseMemory) {
      final ids = <String>{for (final c in copy) c.id};
      _memCheckIns.removeWhere((k, _) => !ids.contains(k));
      for (final c in copy) {
        _memCheckIns[c.id] = jsonEncode(c.toJson());
      }
      return;
    }
    final d = await db;
    await d.transaction((txn) async {
      final ids = <String>[for (final c in copy) c.id];
      final data = <String, String>{
        for (final c in copy) c.id: jsonEncode(c.toJson())
      };
      await _incrementalUpsert(txn, kCheckIns, ids, data);
    });
  }

  // ===== 旧版 SharedPreferences → SQLite 迁移 =====

  /// L9（v3.0.8 审计）：解析失败**抛错**，不再 catch 成空表——旧实现把「JSON
  /// 解析失败 / 字段损坏」与「key 不存在（raw == null，合法空数据）」混为一谈，
  /// 调用方随即 replaceTasks([]) 并 remove(key)：旧 SP 里那份**唯一副本**被当成
  /// 空数据覆盖写进 SQLite 后连锚点一起删除，与类头「绝不丢数据」的契约直接矛盾。
  /// 现在 key 不存在 → 空表（正常首迁）；内容损坏 → 抛 [FormatException]，
  /// 迁移在 replaceTasks 之前中止，旧 key 原样保留（下次启动重试 / 用户处置）。
  static List<Task> _parseTasks(String? raw) {
    if (raw == null) return [];
    final list = jsonDecode(raw) as List; // 损坏 → FormatException 上抛
    return list
        .map((e) => Task.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 把旧版 SP 中的 tasks / trash JSON 迁移进数据库，成功后清除对应旧 key。
  /// 若写入过程中抛错，旧 key 不会被删除，下次启动可安全重试。
  /// L9（v3.0.8 审计）：解析损坏同样抛错（见 [_parseTasks]）——调用方
  /// （TaskProvider.load）已包 try/catch：保留 key、记日志、按空库继续启动。
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

  /// L9（v3.0.8 审计）：同 [_parseTasks]——解析失败抛错、保留旧 key。
  static List<FocusSession> _parseFocus(String? raw) {
    if (raw == null) return [];
    final list = jsonDecode(raw) as List; // 损坏 → FormatException 上抛
    return list
        .map((e) => FocusSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
