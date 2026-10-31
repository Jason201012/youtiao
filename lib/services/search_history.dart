import 'package:shared_preferences/shared_preferences.dart';

/// A4（v3.1.1 功能增强）：全局搜索历史（最近 [maxEntries] 条，纯本机偏好）。
///
/// 设计口径：
/// - 存 prefs `search_history`（StringList，新→旧）；查询去重（重复查询提至最前）；
/// - **刻意不进** prefs 备份白名单——搜索历史属设备本地行为，换机不迁移
  /// （报告 A4 允许两种取舍，取「不进备份」以最小化隐私面）；
/// - 空查询 / 纯空白不记录；UI 在「搜索框聚焦且为空」时展示，点击即回填。
class SearchHistory {
  SearchHistory._();

  static const String _kKey = 'search_history';
  static const int maxEntries = 10;

  /// 读取历史（新→旧）。无记录返回空列表。
  static Future<List<String>> load() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getStringList(_kKey) ?? const <String>[];
  }

  /// 记录一次查询：去重提前、截断到 [maxEntries]；空查询直接返回现值。
  /// 返回更新后的历史（调用方据此刷新 UI）。
  static Future<List<String>> add(String query) async {
    final q = query.trim();
    final sp = await SharedPreferences.getInstance();
    final old = sp.getStringList(_kKey) ?? const <String>[];
    if (q.isEmpty) return old;
    final next = <String>[q, ...old.where((e) => e != q)];
    if (next.length > maxEntries) {
      next.removeRange(maxEntries, next.length);
    }
    await sp.setStringList(_kKey, next);
    return next;
  }

  /// 清空历史。
  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kKey);
  }
}
