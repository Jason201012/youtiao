import 'package:todolist/services/local_database.dart';

/// 开启 [LocalDatabase] 的纯内存后端（仅测试用）。本项目仅声明 Android/iOS/macOS
/// 平台（无 windows/linux 目录），宿主 `flutter test` 没有可用的 sqflite 平台实现，
/// 直接 openDatabase 会报 "databaseFactory not initialized"，进而让 TaskProvider /
/// FocusProvider 的 `_persist()` 崩溃、拖垮既有 48 个用例。
///
/// 用纯 Dart 的内存 Map 模拟存储，既不依赖原生 sqlite3，也能验证整表读写与「旧版
/// SP → SQLite」迁移逻辑；生产代码永不开启该开关，依旧使用真 SQLite。
///
/// 注意：本函数须由测试文件**显式调用**（如 _installMocks / main 开头），不能靠
/// 顶层副作用——否则会被 Dart 树摇（tree-shake）掉而失效。
void useMemoryDatabase() {
  LocalDatabase.testUseMemory = true;
}
