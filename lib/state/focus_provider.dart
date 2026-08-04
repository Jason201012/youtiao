import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/models/focus_session.dart';

/// 专注会话的持久化与统计。独立于 TaskProvider，避免相互耦合；
/// 仅依赖 shared_preferences，key 为 [ _kFocus ]。
class FocusProvider extends ChangeNotifier {
  static const String _kFocus = 'focus_sessions';

  final List<FocusSession> _sessions = [];

  /// 所有会话（按结束时间倒序，最新在前）。
  List<FocusSession> get sessions =>
      _sessions.toList()..sort((a, b) => b.endedAt.compareTo(a.endedAt));

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFocus);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _sessions
        ..clear()
        ..addAll(list.map((e) => FocusSession.fromJson(e as Map<String, dynamic>)));
      notifyListeners();
    } catch (_) {
      // 解析失败：丢弃损坏数据，不阻塞启动。
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kFocus,
      jsonEncode(_sessions.map((s) => s.toJson()).toList()),
    );
  }

  void addSession(FocusSession s) {
    _sessions.add(s);
    _persist();
    notifyListeners();
  }

  /// 某天（date-only）专注总秒数。
  int totalSecOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return _sessions
        .where((s) =>
            DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == d)
        .fold(0, (sum, s) => sum + s.durationSec);
  }

  /// 今日专注总秒数。
  int get todayTotalSec => totalSecOn(DateTime.now());

  /// 累计专注总秒数。
  int get totalSec => _sessions.fold(0, (sum, s) => sum + s.durationSec);

  /// 今日完成的番茄数（跑满预设时长）。
  int get todayCompleted =>
      _sessions.where((s) {
        final d = DateTime.now();
        final today = DateTime(d.year, d.month, d.day);
        return s.completed &&
            DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == today;
      }).length;

  void clear() {
    _sessions.clear();
    _persist();
    notifyListeners();
  }
}
