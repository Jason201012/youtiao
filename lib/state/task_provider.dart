import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/background_service.dart';
import 'package:todolist/services/widget_refresh.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';

/// 首页列表筛选（看板统计卡点击后跳转首页并套用）。
enum TaskFilter { all, todo, done, overdue }

/// 内存状态 + shared_preferences 持久化（任务列表与开关设置落盘，重启不丢）
class TaskProvider extends ChangeNotifier {
  static const String _kTasks = 'tasks';
  static const String _kNotify = 'notifications_enabled';
  static const String _kSound = 'sound_enabled';
  static const String _kGuard = 'background_guard';
  static const String _kTrashRetention = 'trash_retention_days';
  /// 是否已执行过「首启示例预置」决策。一旦置位（预置过 mock 或用户选过「从零开始」），
  /// 即便日后任务库被清空，[load] 也不再重新塞回 7 条 mock，避免「从零开始」后重启复活示例。
  static const String _kSeeded = 'samples_seeded_v1';

  // ===== 稍后提醒时长（分钟）=====
  /// 点击通知「稍后提醒」后的顺延时长，默认 10 分钟。可选 10/30/60/120。
  static const List<int> snoozeOptions = [10, 30, 60, 120];
  static const String _kSnooze = 'snooze_minutes';
  int _snoozeMinutes = 10;
  int get snoozeMinutes => _snoozeMinutes;
  Future<void> setSnoozeMinutes(int v) async {
    if (v == _snoozeMinutes) return;
    _snoozeMinutes = v;
    notifyListeners();
    await _persistSettings();
  }

  // ===== 早晚简报推送（P0-1）=====
  /// 晚间「今日小结」默认 22:00；晨间「今日待办」默认 07:30；两者默认均开启。
  static const String _kBriefEveningOn = 'brief_evening_on';
  static const String _kBriefEveningH = 'brief_evening_h';
  static const String _kBriefEveningM = 'brief_evening_m';
  static const String _kBriefMorningOn = 'brief_morning_on';
  static const String _kBriefMorningH = 'brief_morning_h';
  static const String _kBriefMorningM = 'brief_morning_m';
  static const String _kHabitNudgeOn = 'habit_nudge_on';
  static const String _kHabitNudgeMin = 'habit_nudge_min';
  // F4：习惯漏卡「挽留」通知独立配置——开关 + 固定时刻（自 00:00 起的分钟数）。
  // 硬编码 23:00 迁移为「可配置入参」，并感知勿扰区间（见 notification_service）。
  bool _habitNudgeEnabled = true;
  int _habitNudgeMinute = 23 * 60;
  bool get habitNudgeEnabled => _habitNudgeEnabled;
  int get habitNudgeMinute => _habitNudgeMinute;
  Future<void> setHabitNudge({required bool enabled, int? minute}) async {
    _habitNudgeEnabled = enabled;
    if (minute != null) _habitNudgeMinute = minute.clamp(0, 24 * 60 - 1);
    notifyListeners();
    await _persistSettings();
  }
  bool _briefingEveningEnabled = true;
  int _briefingEveningHour = 22;
  int _briefingEveningMinute = 0;
  bool _briefingMorningEnabled = true;
  int _briefingMorningHour = 7;
  int _briefingMorningMinute = 30;
  bool get briefingEveningEnabled => _briefingEveningEnabled;
  int get briefingEveningHour => _briefingEveningHour;
  int get briefingEveningMinute => _briefingEveningMinute;
  bool get briefingMorningEnabled => _briefingMorningEnabled;
  int get briefingMorningHour => _briefingMorningHour;
  int get briefingMorningMinute => _briefingMorningMinute;
  Future<void> setBriefingEvening(
      {required bool enabled, int? hour, int? minute}) async {
    _briefingEveningEnabled = enabled;
    if (hour != null) _briefingEveningHour = hour.clamp(0, 23);
    if (minute != null) _briefingEveningMinute = minute.clamp(0, 59);
    notifyListeners();
    await _persistSettings();
  }

  Future<void> setBriefingMorning(
      {required bool enabled, int? hour, int? minute}) async {
    _briefingMorningEnabled = enabled;
    if (hour != null) _briefingMorningHour = hour.clamp(0, 23);
    if (minute != null) _briefingMorningMinute = minute.clamp(0, 59);
    notifyListeners();
    await _persistSettings();
  }

  // ===== 勿扰时段（本地时间，小时 0-23）=====
  /// 勿扰开始/结束小时；[dndEnabled]=false 时表示不启用勿扰。
  /// 一次性提醒若落在勿扰区间，自动顺延到时段结束 + 5 分钟再弹（重复/习惯提醒不动）。
  static const String _kDndEnabled = 'dnd_enabled';
  static const String _kDndStart = 'dnd_start';
  static const String _kDndEnd = 'dnd_end';
  bool _dndEnabled = false;
  bool get dndEnabled => _dndEnabled;
  int _dndStartHour = 22;
  int get dndStartHour => _dndStartHour;
  int _dndEndHour = 7;
  int get dndEndHour => _dndEndHour;
  Future<void> setDnd({
    required bool enabled,
    int? startHour,
    int? endHour,
  }) async {
    _dndEnabled = enabled;
    if (startHour != null) _dndStartHour = startHour.clamp(0, 23);
    if (endHour != null) _dndEndHour = endHour.clamp(0, 23);
    notifyListeners();
    await _persistSettings();
  }

  /// 判断给定小时（0-23）是否处于勿扰区间内。区间可跨午夜（start>end 表示
  /// 如 22→07 覆盖当晚到次晨）。勿扰未启用时恒为 false。
  bool isDndHour(int hour) {
    if (!_dndEnabled) return false;
    if (_dndStartHour == _dndEndHour) return false; // 起止相同视为全天不限制
    if (_dndStartHour < _dndEndHour) {
      return hour >= _dndStartHour && hour < _dndEndHour;
    }
    // 跨午夜：[22,24) ∪ [0,7)
    return hour >= _dndStartHour || hour < _dndEndHour;
  }

  // ===== 每日专注目标（分钟）=====
  /// 用户自定的「每日专注目标」分钟数；0 表示不启用目标（今日卡不展示进度环）。
  /// 默认 120（与历史硬编码值一致）。在设置页可调，持久化到 SharedPreferences。
  static const String _kFocusGoal = 'focus_goal_minutes';
  int _focusGoalMinutes = 120;
  int get focusGoalMinutes => _focusGoalMinutes;
  /// 人类可读文案：0=关闭，否则「N 分钟」。
  String get focusGoalLabel => _focusGoalMinutes <= 0 ? '关闭' : '$_focusGoalMinutes 分钟';
  Future<void> setFocusGoalMinutes(int v) async {
    final val = v.clamp(0, 1440);
    if (val == _focusGoalMinutes) return;
    _focusGoalMinutes = val;
    notifyListeners();
    await _persistSettings();
  }

  // ===== 周目标（本周完成任务数，B1）=====
  /// 用户自定的「每周完成任务数」目标；0 表示不启用目标（周报卡不展示进度）。
  /// 默认 0（关闭）。在设置页可调，持久化到 SharedPreferences。
  static const String _kWeeklyGoal = 'weekly_goal_count';
  int _weeklyGoalCount = 0;
  int get weeklyGoalCount => _weeklyGoalCount;
  /// 人类可读文案：0=关闭，否则「N 个」。
  String get weeklyGoalLabel => _weeklyGoalCount <= 0 ? '关闭' : '$_weeklyGoalCount 个';
  Future<void> setWeeklyGoalCount(int v) async {
    final val = v.clamp(0, 200);
    if (val == _weeklyGoalCount) return;
    _weeklyGoalCount = val;
    notifyListeners();
    await _persistSettings();
  }

  /// 本周（周一 00:00 – 周日 23:59:59）已完成的任务数。基于全部任务（含回收站外的）的
  /// completedAt 落在周区间内计数，与 [WeeklyReview.completedCount] 口径一致（复用同一区间逻辑）。
  int get weeklyCompletedCount {
    final start = _mondayOf(DateTime.now());
    final end = start.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
    int n = 0;
    for (final t in _tasks) {
      if (t.done && t.completedAt != null) {
        final d = DateTime(t.completedAt!.year, t.completedAt!.month, t.completedAt!.day);
        if (!d.isBefore(start) && !d.isAfter(end)) n++;
      }
    }
    return n;
  }

  /// 取 [d] 所在周的周一（00:00），与 [WeeklyReview._mondayOf] 口径一致。
  static DateTime _mondayOf(DateTime d) {
    final today = DateTime(d.year, d.month, d.day);
    final diff = today.weekday - DateTime.monday;
    return today.subtract(Duration(days: diff));
  }

  // ===== 本地自动备份（滚动快照，S1）=====
  /// 是否启用「本地自动备份」：跨日首启自动生成当日滚动快照，默认开启。
  /// 纯本地文件（App 私有文档目录 backup/auto/），不上传任何服务器。
  static const String _kAutoBackup = 'auto_backup_enabled';
  /// P1-13：已归档标签名集合（JSON 数组），归档后首页筛选不可见但数据保留。
  static const String _kArchivedTags = 'archived_tags';
  /// P0-3：日历月视图是否显示农历 / 节气 / 传统节日（纯离线计算，默认开启）。
  static const String _kCalendarLunar = 'calendar_lunar';
  bool _autoBackupEnabled = true;
  bool get autoBackupEnabled => _autoBackupEnabled;
  /// 最近一次自动备份成功的本地日期（YYYY-MM-DD），null 表示从未成功过。
  DateTime? _lastAutoBackupDate;
  DateTime? get lastAutoBackupDate => _lastAutoBackupDate;
  /// 最近一次自动备份失败的提示（用于设置页展示）；null = 无错误。
  String? _lastAutoBackupError;
  String? get lastAutoBackupError => _lastAutoBackupError;
  /// 设置页副标题：展示最近一次成功备份的本地日期；从未成功则提示「未备份」。
  String get lastAutoBackupLabel =>
      _lastAutoBackupDate == null ? '尚未生成快照' : '最近快照：${_dateKey(_lastAutoBackupDate!)}';
  Future<void> setAutoBackupEnabled(bool v) async {
    if (v == _autoBackupEnabled) return;
    _autoBackupEnabled = v;
    notifyListeners();
    await _persistSettings();
    // 开启后立即尝试补一次（若今天还没备），关闭则不动作。
    if (v) {
      try {
        await _autoBackupIfNeeded();
      } catch (_) {
        // 错误已在内部记录，不阻断 UI。
      }
    }
  }

  // ===== P0-3：日历农历 / 节气展示 =====
  /// 日历月视图每格是否显示农历日与节气 / 传统节日。默认 true——v2.7.0 已支持
  /// 「农历重复」录入，但日历页不显示农历会形成认知断层（设了农历任务却找不到
  /// 对应阳历位置）。转换由 `package:lunar` 纯 Dart 离线完成，零联网。
  bool _calendarLunar = true;
  bool get calendarLunar => _calendarLunar;
  Future<void> setCalendarLunar(bool v) async {
    if (v == _calendarLunar) return;
    _calendarLunar = v;
    notifyListeners();
    await _persistSettings();
  }

  // ===== P1-13：全局标签管理 =====

  /// 已归档标签名集合（JSON 数组持久化）。归档后首页筛选不可见，但数据保留。
  Set<String> _archivedTags = {};
  Set<String> get archivedTags => Set.unmodifiable(_archivedTags);

  /// 归档标签：标记为不可见但保留数据。返回是否实际变更。
  Future<void> archiveTag(String name) async {
    if (!_archivedTags.add(name)) return;
    notifyListeners();
    await _persistTagArchive();
  }

  /// 取消归档：重新在首页筛选中可见。
  Future<void> unarchiveTag(String name) async {
    if (!_archivedTags.remove(name)) return;
    notifyListeners();
    await _persistTagArchive();
  }

  /// 重命名标签：全库替换所有任务上的 [oldName] 为 [newName]，并持久化。
  /// 重命名后旧标签不再存在，新标签自动加入筛选。
  Future<void> renameTag(String oldName, String newName) async {
    if (oldName == newName || newName.trim().isEmpty) return;
    final trimmed = newName.trim();
    var changed = false;
    for (final t in _tasks) {
      if (t.tags.contains(oldName)) {
        final newTags = t.tags.map((e) => e == oldName ? trimmed : e).toList();
        updateTask(t.copyWith(tags: newTags));
        changed = true;
      }
    }
    // 归档状态迁移：旧标签已归档 → 新标签继承归档状态
    if (_archivedTags.remove(oldName)) {
      _archivedTags.add(trimmed);
    }
    if (changed) {
      notifyListeners();
      await _persist();
      await _persistTagArchive();
    }
  }

  /// 合并标签：把 [source] 标签的所有任务改为 [target] 标签，然后删除 [source]。
  Future<void> mergeTags(String source, String target) async {
    if (source == target) return;
    var changed = false;
    for (final t in _tasks) {
      if (t.tags.contains(source)) {
        final newTags = <String>[];
        for (final e in t.tags) {
          if (e == source) {
            if (!newTags.contains(target)) newTags.add(target);
          } else {
            if (!newTags.contains(e)) newTags.add(e);
          }
        }
        updateTask(t.copyWith(tags: newTags));
        changed = true;
      }
    }
    _archivedTags.remove(source);
    if (changed) {
      notifyListeners();
      await _persist();
      await _persistTagArchive();
    }
  }

  /// 删除标签：从所有任务中移除 [name]。
  Future<void> deleteTag(String name) async {
    var changed = false;
    for (final t in _tasks) {
      if (t.tags.contains(name)) {
        final newTags = t.tags.where((e) => e != name).toList();
        updateTask(t.copyWith(tags: newTags));
        changed = true;
      }
    }
    _archivedTags.remove(name);
    if (changed) {
      notifyListeners();
      await _persist();
      await _persistTagArchive();
    }
  }

  /// 某标签下的任务数（含所有状态）。
  int tagTaskCount(String name) =>
      _tasks.where((t) => t.tags.contains(name)).length;

  /// 某标签的任务完成率（0.0~1.0，无任务时返回 0.0）。
  double tagCompletionRate(String name) {
    final matched = _tasks.where((t) => t.tags.contains(name)).toList();
    if (matched.isEmpty) return 0.0;
    return matched.where((t) => t.status == TaskStatus.done).length / matched.length;
  }

  /// 获取所有标签（首页筛选用，排除已归档）。
  List<String> get allTags {
    final seen = <String>{};
    final out = <String>[];
    for (final t in _tasks) {
      for (final tag in t.tags) {
        if (tag.isNotEmpty && !_archivedTags.contains(tag) && seen.add(tag)) {
          out.add(tag);
        }
      }
    }
    return out;
  }

  /// 获取所有标签（含已归档，仅管理页使用）。
  List<String> get allTagsIncludingArchived {
    final seen = <String>{};
    final out = <String>[];
    for (final t in _tasks) {
      for (final tag in t.tags) {
        if (tag.isNotEmpty && seen.add(tag)) out.add(tag);
      }
    }
    return out;
  }

  /// 仅持久化归档标签集合（写入 SharedPreferences JSON 数组）。
  Future<void> _persistTagArchive() async {
    final prefs = await SharedPreferences.getInstance();
    if (_archivedTags.isEmpty) {
      await prefs.remove(_kArchivedTags);
    } else {
      await prefs.setStringList(_kArchivedTags, _archivedTags.toList());
    }
  }

  /// 跨日首启时生成当日滚动快照；今天已有快照则跳过。失败静默（仅记录 _lastAutoBackupError）。
  Future<void> _autoBackupIfNeeded() async {
    if (!_autoBackupEnabled) return;
    final now = DateTime.now();
    final todayKey = _dateKey(now);
    if (_lastAutoBackupDate != null && _dateKey(_lastAutoBackupDate!) == todayKey) {
      return; // 今天已备份
    }
    try {
      await _writeAutoBackup(now);
      _lastAutoBackupDate = DateTime(now.year, now.month, now.day);
      _lastAutoBackupError = null;
    } catch (e, s) {
      _lastAutoBackupError = '自动备份失败：$e';
      debugPrint('$_lastAutoBackupError\n$s');
    }
    notifyListeners();
  }

  /// 供 [main] 在所有 Provider（FocusProvider / HabitProvider）加载完成后显式触发一次
  /// 跨日快照。必须在单例注册之后调用，否则快照内 focus_sessions / 习惯打卡会因
  /// [FocusProvider.instanceOrNull] / [HabitProvider.instanceOrNull] 尚未就绪而恒为空（P0-2）。
  Future<void> triggerAutoBackup() => _autoBackupIfNeeded();

  /// 把当前全部数据（任务 + 回收站 + 偏好 + 专注 + 习惯 + 打卡）写入当日滚动快照。
  /// 文件名 backup/auto/YYYY-MM-DD.json，复用 [backupData] + 其余 Provider 的导出；
  /// 用 DataIo 原子写（.tmp + rename）避免写入中途打断导致快照损坏。
  Future<void> _writeAutoBackup(DateTime now) async {
    final focus = FocusProvider.instanceOrNull;
    final habit = HabitProvider.instanceOrNull;
    final payload = <String, dynamic>{
      'version': 3,
      'app': '有条',
      'schemaVersion': 1, // 自动备份标记（区别于手动导出的纯任务备份）
      'generatedAt': now.toIso8601String(),
      ...backupData(includeTrash: true),
      'focus_sessions': focus?.sessionsJson ?? [],
      ...habit?.backupData() ?? {'habits': [], 'check_ins': []},
      // 纳入 App 级偏好（外观/锁/专注/免打扰/通用开关），换机后体验更完整。
      // 排除系统生物特征、更新检查状态、运行中的计时器（见 prefs_backup.dart）。
      'prefs': await collectAppPrefs(),
      // P0-1：附件二进制（base64 内联）一并纳入滚动快照，保证本地快照可完整还原。
      'attachments': await collectAttachmentBlobs(true),
    };
    final json =
        const JsonEncoder.withIndent('  ').convert(payload);
    await DataIo.saveToAppDocs('backup/auto/${_dateKey(now)}.json', json);
    _rotateAutoBackups();
  }

  /// 滚动保留：仅保留最近 7 份当日快照（backup/auto/ 目录），删除更早的。
  /// 用日期字符串排序即可（YYYY-MM-DD 字典序=时间序）。失败静默，不阻断主流程。
  Future<void> _rotateAutoBackups() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/backup/auto');
      if (!await base.exists()) return;
      final files = base
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path)); // 旧→新
      // 保留最新 7 份，其余删除
      final excess = files.length - 7;
      if (excess > 0) {
        for (var i = 0; i < excess; i++) {
          try {
            await files[i].delete();
          } catch (_) {
            // 单文件删除失败不影响其余
          }
        }
      }
    } catch (e) {
      debugPrint('滚动快照清理失败（忽略）：$e');
    }
  }

  /// 列出本地自动备份快照（新→旧），供「备份与恢复」面板还原。
  /// 每项含 date(DateTime) 与 file(File)。
  Future<List<AutoBackupEntry>> listAutoBackups() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/backup/auto');
      if (!await base.exists()) return const [];
      final files = base
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path)); // 新→旧
      final out = <AutoBackupEntry>[];
      for (final f in files) {
        final name = f.path.split(RegExp(r'[\\/]')).last;
        // 文件名形如 YYYY-MM-DD.json
        final key = name.replaceAll('.json', '');
        final parts = key.split('-');
        if (parts.length == 3) {
          final y = int.tryParse(parts[0]);
          final m = int.tryParse(parts[1]);
          final d = int.tryParse(parts[2]);
          if (y != null && m != null && d != null) {
            out.add(AutoBackupEntry(
              date: DateTime(y, m, d),
              file: f,
            ));
          }
        }
      }
      return out;
    } catch (e) {
      debugPrint('列出自动备份失败：$e');
      return const [];
    }
  }

  /// 把日期格式化为 YYYY-MM-DD（本地时区）。
  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ===== 回收站自动清理（保留天数）=====
  /// 回收站条目超过该天数后，在每日 00:00 的原生重置接收器 + App 启动时兜底清理。
  /// -1 表示「永不自动清理」（回收站仅手动管理）。可选 7 / 30 / 90 / -1。
  static const List<int> trashRetentionOptions = [7, 30, 90, -1];
  int _trashRetentionDays = 30;
  int get trashRetentionDays => _trashRetentionDays;
  /// 人类可读的保留期文案（含「永不」）。
  String get trashRetentionLabel {
    return _trashRetentionDays < 0 ? '永不' : '$_trashRetentionDays 天';
  }
  Future<void> setTrashRetentionDays(int v) async {
    if (v == _trashRetentionDays) return;
    _trashRetentionDays = v;
    notifyListeners();
    await _persistSettings();
    // 立即按新规则清理一次（仅影响内存中的回收站，落盘在 _persist）。
    _cleanupTrashIfNeeded(persist: true);
    _syncTrashExpireNotice(); // P1-12：保留期变更后重排预告通知
  }

  /// 按当前保留期移除过期的回收站条目；[persist]=true 时变更会落 SQLite。
  /// 返回是否发生了实际清理。被 load() 兜底与 setTrashRetentionDays 调用。
  bool _cleanupTrashIfNeeded({bool persist = false}) {
    if (_trashRetentionDays < 0) return false; // 永不自动清理
    final cutoff = DateTime.now().subtract(Duration(days: _trashRetentionDays));
    final before = _trash.length;
    _trash.removeWhere((t) {
      if (t.deletedAt == null) return false; // 无删除时间视为新近，保留
      return t.deletedAt!.isBefore(cutoff);
    });
    final removed = _trash.length != before;
    if (removed && persist) _persist();
    return removed;
  }

  // ===== P1-12：回收站过期预告 =====

  /// 某条回收站任务的剩余保留天数（按日期口径，与原生 MidnightResetReceiver 一致）。
  /// 0 = 今天到期（即将被清理），负数 = 已过期（理论上不应出现在列表中）。
  /// -1（永不清理）统一返回 99999。
  int trashRemainingDays(Task t) {
    if (_trashRetentionDays < 0) return 99999;
    if (t.deletedAt == null) return _trashRetentionDays; // 无删除时间视为新近
    final deletedDate = DateTime(t.deletedAt!.year, t.deletedAt!.month, t.deletedAt!.day);
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final elapsed = todayDate.difference(deletedDate).inDays;
    return _trashRetentionDays - elapsed;
  }

  /// 将于明天 00:00 被永久删除的任务列表（trashRemainingDays == 1）。
  List<Task> get trashExpiringTomorrow =>
      _trash.where((t) => trashRemainingDays(t) == 1).toList();

  /// N 天内将被删除的回收站任务数量（含今天到期、明天到期……）。
  int trashExpiringCountWithin(int days) =>
      _trash.where((t) {
        final r = trashRemainingDays(t);
        return r >= 0 && r <= days;
      }).length;

  /// 同步「回收站过期预告」通知：有将于明天删除的任务则调度聚合预告，否则取消。
  /// 为 fire-and-forget（由 [_cleanupTrashIfNeeded] / [load] 触发，无需等待）。
  void _syncTrashExpireNotice() {
    final expiring = trashExpiringTomorrow;
    NotificationService.instance.scheduleTrashExpireNotice(expiring).catchError((_) {});
  }

  // ===== 通知总开关 =====
  bool _notificationsEnabled = true;
  bool get notificationsEnabled => _notificationsEnabled;
  Future<void> setNotificationsEnabled(bool v) async {
    _notificationsEnabled = v;
    NotificationService.instance.enabled = v;
    if (v) {
      // 打开开关时重新请求通知权限（若之前被拒可再次弹窗）
      NotificationService.instance.requestPermission();
      // 重新调度所有「未完成且未过期」的截止提醒 + 每日提醒，应用新状态
      _rescheduleAllActive();
    } else {
      NotificationService.instance.cancelAll();
    }
    notifyListeners();
    await _persistSettings();
  }

  /// 请求通知权限并返回是否授予（设置页「发送测试通知」前调用，
  /// 未授予时引导用户去系统设置开启）。Android 13+ 才需要。
  Future<bool?> requestNotificationPermission() =>
      NotificationService.instance.requestPermission();

  // ===== 声音开关（控制提醒是否响铃）=====
  bool _soundEnabled = true;
  bool get soundEnabled => _soundEnabled;

  // ===== 后台提醒守护（前台服务保活）=====
  bool _backgroundGuard = true;
  bool get backgroundGuardEnabled => _backgroundGuard;

  /// 午夜守护是否已启动（防止 [load] 被重复调用时叠加多个周期定时器 / 生命周期观察者）。
  bool _midnightWatchStarted = false;
  Future<void> setSoundEnabled(bool v) async {
    _soundEnabled = v;
    // 重新调度所有提醒（截止 + 每日），应用新的声音设置
    if (_notificationsEnabled) {
      _rescheduleAllActive();
    }
    notifyListeners();
    await _persistSettings();
  }

  /// 后台提醒守护开关：开启则拉起前台服务（进程常驻），关闭则停止。
  /// ColorOS 等国产 ROM 划掉后台后会速冻第三方 App，前台服务是唯一可靠的保活手段。
  Future<void> setBackgroundGuard(bool v) async {
    if (_backgroundGuard == v) return;
    _backgroundGuard = v;
    if (v) {
      await BackgroundService.instance.start();
    } else {
      await BackgroundService.instance.stop();
    }
    notifyListeners();
    _persistSettings();
  }

  // ===== 持久化（shared_preferences + sqflite）=====
  /// 启动时调用：从本地读取任务列表与开关设置；首次启动则保留 7 条 mock 并落盘。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // 确保数据库已打开（首次启动会建表）。内存测试后端无需真实 SQLite，跳过打开。
    final db = LocalDatabase.instance;
    // 快照内置首启示例：下面的 DB 载入会用库内容覆盖 _tasks（clear + addAll），
    // 全新安装（库为空）时必须靠这份快照把 7 条示例预置回去。
    // 历史缺陷：此前没有快照，新用户首启实际看到 0 条示例而非设计的 7 条。
    final builtInSamples = List<Task>.from(_tasks);
    try {
      if (!LocalDatabase.testUseMemory) {
        await db.db;
      }
      // —— 从旧版 SharedPreferences JSON 迁移到 SQLite（仅首次：DB 为空且旧 key 存在）——
      if (await db.tasksEmpty && prefs.getString(_kTasks) != null) {
        await db.migrateTasksFromPrefs(prefs);
      }
      final loadedTasks = await db.loadTasks();
      final loadedTrash = await db.loadTrash();
      _tasks
        ..clear()
        ..addAll(loadedTasks);
      _trash
        ..clear()
        ..addAll(loadedTrash);
    } catch (e, s) {
      // S13 修复：数据库加载/读取失败 → 进入只读安全模式，禁止后续 [_persist]
      // 用内存态（可能为空）覆盖尚可抢救的坏库。标记后 rethrow，由 main._safeLoad
      // 捕获并允许 App 继续启动（UI 显示安全模式横幅引导导出/修复）。
      _dbLoadFailed = true;
      debugPrint('[TaskProvider] 数据库加载失败，进入只读安全模式：$e\n$s');
      rethrow;
    }
    final seeded = prefs.getBool(_kSeeded) ?? false;
    if (_tasks.isEmpty && _trash.isEmpty && !seeded) {
      // 全新安装：DB 为空 → 回填内置 7 条示例并落库；置位标志，
      // 避免「从零开始」后重启又被塞回。
      _tasks.addAll(builtInSamples);
      await _persist();
      await prefs.setBool(_kSeeded, true);
    } else {
      // 兜底清理：App 启动时按保留期移除过期回收站条目（原生 MidnightResetReceiver
      // 负责「App 已关闭」的每日 00:00 清理，这里覆盖 App 已开、长期未跨午夜边界的情况）。
      _cleanupTrashIfNeeded(persist: true);
      _syncTrashExpireNotice(); // P1-12：启动时兜底重排过期预告通知
      // 已有数据，或用户已做过首启示例决策（含「从零开始」）：标记已预置，
      // 日后即便任务库被清空也不再复活示例。
      await prefs.setBool(_kSeeded, true);
    }
    _notificationsEnabled = prefs.getBool(_kNotify) ?? true;
    _soundEnabled = prefs.getBool(_kSound) ?? true;
    _backgroundGuard = prefs.getBool(_kGuard) ?? true;
    _snoozeMinutes = prefs.getInt(_kSnooze) ?? 10;
    _dndEnabled = prefs.getBool(_kDndEnabled) ?? false;
    _dndStartHour = prefs.getInt(_kDndStart) ?? 22;
    _dndEndHour = prefs.getInt(_kDndEnd) ?? 7;
    _trashRetentionDays = prefs.getInt(_kTrashRetention) ?? 30;
    _focusGoalMinutes = prefs.getInt(_kFocusGoal) ?? 120;
    _weeklyGoalCount = prefs.getInt(_kWeeklyGoal) ?? 0;
    _autoBackupEnabled = prefs.getBool(_kAutoBackup) ?? true;
    _archivedTags = (prefs.getStringList(_kArchivedTags) ?? []).toSet(); // P1-13
    _calendarLunar = prefs.getBool(_kCalendarLunar) ?? true; // P0-3
    _briefingEveningEnabled = prefs.getBool(_kBriefEveningOn) ?? true;
    _briefingEveningHour = prefs.getInt(_kBriefEveningH) ?? 22;
    _briefingEveningMinute = prefs.getInt(_kBriefEveningM) ?? 0;
    _briefingMorningEnabled = prefs.getBool(_kBriefMorningOn) ?? true;
    _briefingMorningHour = prefs.getInt(_kBriefMorningH) ?? 7;
    _briefingMorningMinute = prefs.getInt(_kBriefMorningM) ?? 30;
    _habitNudgeEnabled = prefs.getBool(_kHabitNudgeOn) ?? true;
    _habitNudgeMinute = prefs.getInt(_kHabitNudgeMin) ?? 23 * 60;
    NotificationService.instance.enabled = _notificationsEnabled;
    // 每日任务：若今天之前已完成且未到截止日期，则重置为未完成，实现「每天循环」提醒。
    // （原生 MidnightResetReceiver 会在每天 00:00 后台自动做同样的事，这里作为
    //  App 启动时的兜底，并在 App 前台时由 _startMidnightWatch 周期性刷新。）
    _resetDailyIfNeeded();
    // 挂上「当天 00:00 自动重置」的午夜闹钟（不依赖 App 是否打开）。
    NotificationService.instance.armMidnightReset();
    // 启动时为已有「未完成且未过期」的任务 + 每日提醒重新调度（老任务/初始 mock 也能响）
    if (_notificationsEnabled) _rescheduleAllActive();
    _recomputeIdSeq();
    _startMidnightWatch();
    notifyListeners();
  }

  /// 把「已完成、未过截止日、且今天是其循环日、且上次完成早于今天」的重复任务重置为未完成。
  /// 返回是否发生了变更（仅在变更时落盘 + 通知 UI）。与原生 MidnightResetReceiver 逻辑一致。
  bool _resetDailyIfNeeded() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var dailyDirty = false;
    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.isRepeating &&
          t.status == TaskStatus.done &&
          (t.dueDate == null || !_dateHasPassed(t.dueDate!)) &&
          t.repeatsOn(today)) {
        final c = t.completedAt;
        if (c == null || DateTime(c.year, c.month, c.day).isBefore(today)) {
          _tasks[i] = t.copyWith(status: TaskStatus.todo, completedAt: null);
          dailyDirty = true;
        }
      }
    }
    if (dailyDirty) _persist();
    return dailyDirty;
  }

  /// 供生命周期/周期守护调用的对外入口：跨天则重置每日任务并刷新 UI。
  void checkDailyReset() {
    if (_resetDailyIfNeeded()) notifyListeners();
  }

  /// App 在前台/后台存活期间的轻量守护：周期性（15 分钟）+ 回到前台时检查「日期是否已跨天」，
  /// 若跨天则重置每日任务。原生午夜闹钟负责「App 已关闭」的情况，本守护负责「App 正开着」的边界。
  void _startMidnightWatch() {
    if (_midnightWatchStarted) return; // 防止 load() 重复调用叠加观察者/定时器
    _midnightWatchStarted = true;
    // 周期性检查（App 进程存活时有效）
    Future.doWhile(() async {
      await Future.delayed(const Duration(minutes: 15));
      checkDailyReset();
      return true; // 持续循环直到进程退出
    });
    // 回到前台时补一次（覆盖后台被系统节流、多年未触发的边界）
    WidgetsBinding.instance.addObserver(_LifecycleObserver(this));
  }

  /// 仅持久化开关/主题等偏好（写入 SharedPreferences）。任务数据由 [_persist] 落 SQLite。
  Future<void> _persistSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotify, _notificationsEnabled);
    await prefs.setBool(_kSound, _soundEnabled);
    await prefs.setBool(_kGuard, _backgroundGuard);
    await prefs.setInt(_kSnooze, _snoozeMinutes);
    await prefs.setBool(_kDndEnabled, _dndEnabled);
    await prefs.setInt(_kDndStart, _dndStartHour);
    await prefs.setInt(_kDndEnd, _dndEndHour);
    await prefs.setInt(_kTrashRetention, _trashRetentionDays);
    await prefs.setInt(_kFocusGoal, _focusGoalMinutes);
    await prefs.setInt(_kWeeklyGoal, _weeklyGoalCount);
    await prefs.setBool(_kAutoBackup, _autoBackupEnabled);
    await prefs.setBool(_kCalendarLunar, _calendarLunar); // P0-3
    await prefs.setBool(_kBriefEveningOn, _briefingEveningEnabled);
    await prefs.setInt(_kBriefEveningH, _briefingEveningHour);
    await prefs.setInt(_kBriefEveningM, _briefingEveningMinute);
    await prefs.setBool(_kBriefMorningOn, _briefingMorningEnabled);
    await prefs.setInt(_kBriefMorningH, _briefingMorningHour);
    await prefs.setInt(_kBriefMorningM, _briefingMorningMinute);
    await prefs.setBool(_kHabitNudgeOn, _habitNudgeEnabled);
    await prefs.setInt(_kHabitNudgeMin, _habitNudgeMinute);
  }

  /// 完整持久化：偏好写 SharedPreferences，任务 / 回收站写 SQLite。
  /// 捕获写盘异常并输出，避免「变更仅存于内存、重启即回退」被静默吞掉。
  Future<void> _persist() async {
    if (_dbLoadFailed) {
      // S13 修复：安全模式下禁止向可疑数据库落盘，避免用内存态覆盖尚可抢救的坏库。
      // 仅持久化偏好到 SharedPreferences（与任务库解耦、风险低）；任务变更仅存内存、
      // 重启不保留。用户应前往「设置 → 备份与恢复」导出/修复后再正常加载。
      try {
        await _persistSettings();
      } catch (_) {
        // 偏好落盘失败也无妨，安全模式下本就不依赖持久化。
      }
      return;
    }
    try {
      await _persistSettings();
      await LocalDatabase.instance.replaceTasks(_tasks, _trash);
      // 任务变更后主动刷新桌面小组件（今日任务列表），不必等系统定时刷新兜底。
      requestWidgetRefresh();
    } catch (e, s) {
      debugPrint('TaskProvider 持久化失败（变更仅存于内存，重启将回退）：$e\n$s');
    }
  }

  /// 载入后重算自增 id 起点，避免新任务 id 与已有（含回收站）冲突。
  void _recomputeIdSeq() {
    int max = 7;
    for (final t in [..._tasks, ..._trash]) {
      final n = int.tryParse(t.id);
      if (n != null && n > max) max = n;
    }
    _idSeq = max + 1;
  }

  /// 清空首启示例任务（引导页「从零开始」选项调用）。
  /// 把内存中的 7 条 mock 与回收站清空并落库为空，使全新用户可以从空白开始。
  /// 必须在 [load] 预置 mock 之后、主页渲染之前调用（引导页完成环节里触发）。
  Future<void> clearSampleTasks() async {
    _tasks.clear();
    _trash.clear();
    NotificationService.instance.cancelTrashExpireNotice(); // P1-12：首启清空时取消预告
    _recomputeIdSeq(); // 重置自增 id 起点（空库 → 8 起）
    notifyListeners();
    await _persist();
    // 标记已做过首启示例决策，避免下次启动因 DB 为空又把 7 条 mock 塞回来。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSeeded, true);
  }

  // ===== 首页筛选状态（已移除搜索 / 筛选功能）=====

  // ===== Mock 数据（7 条，分类进度：工作 75% / 生活 100% / 学习 50%）=====
  final List<Task> _tasks = [
    Task(
      id: '1',
      title: '整理周会纪要',
      priority: Priority.high,
      category: Category.work,
      dueDate: DateTime.now().add(const Duration(hours: 6)),
    ),
    Task(
      id: '2',
      title: '回复客户邮件',
      priority: Priority.medium,
      category: Category.work,
      dueDate: DateTime.now().add(const Duration(days: 1)),
    ),
    Task(
      id: '3',
      title: '买周末食材',
      priority: Priority.low,
      category: Category.life,
      dueDate: DateTime.now().add(const Duration(days: 2)),
    ),
    Task(
      id: '4',
      title: '阅读《设计心理学》',
      priority: Priority.medium,
      category: Category.study,
      dueDate: DateTime.now().add(const Duration(days: 3)),
    ),
    Task(
      id: '5',
      title: '提交季度报表',
      priority: Priority.high,
      category: Category.work,
      dueDate: DateTime.now().add(const Duration(days: -1)),
      status: TaskStatus.done,
      completedAt: DateTime.now().add(const Duration(days: -2)),
    ),
    Task(
      id: '6',
      title: '给绿植浇水',
      priority: Priority.low,
      category: Category.life,
      status: TaskStatus.done,
      completedAt: DateTime.now().add(const Duration(days: -4)),
    ),
    Task(
      id: '7',
      title: '完成算法作业',
      priority: Priority.high,
      category: Category.study,
      status: TaskStatus.done,
      completedAt: DateTime.now().add(const Duration(days: -6)),
    ),
  ];

  List<Task> get tasks => List.unmodifiable(_tasks);

  /// S13 修复：数据库加载是否失败（只读安全模式标志）。
  /// 一旦置位，[_persist] 不会向可疑数据库落盘，避免用内存态（可能是空/示例）
  /// 覆盖掉尚可抢救的坏库；UI 据此展示安全模式横幅引导用户导出/修复。
  bool _dbLoadFailed = false;
  bool get dbLoadFailed => _dbLoadFailed;

  /// 回收站（已删除但可恢复的任务，按删除时间倒序）
  final List<Task> _trash = [];
  List<Task> get trash => List.unmodifiable(_trash);
  int get trashCount => _trash.length;

  /// 今日待办（未完成）
  List<Task> get todayTasks => _tasks.where((t) => !t.done).toList();

  /// 已完成
  List<Task> get doneTasks => _tasks.where((t) => t.done).toList();

  // ===== 聚合统计 =====
  int get total => _tasks.length;
  int get completed => _tasks.where((t) => t.done).length;
  int get overdue =>
      _tasks.where((t) => Task.isOverdue(t, DateTime.now())).length;
  double get completionRate => total == 0 ? 0 : completed / total;

  /// 判断任务是否为「今天的事务」：未删除，且（无截止日期 / 截止日期为今天 / 今天为循环日）。
  /// 无截止日期视为当天，并始终跟随当前日期（跨天自动顺延到第二天）。
  bool _isEventToday(Task t, DateTime now) {
    if (t.deletedAt != null) return false;
    final today = DateTime(now.year, now.month, now.day);
    if (t.dueDate != null) {
      final d = DateTime(t.dueDate!.year, t.dueDate!.month, t.dueDate!.day);
      if (d == today) return true;
    } else if (!t.isRepeating) {
      // 非循环且无截止日期 → 视为当天（始终跟随当前日期，跨天自动顺延到第二天）
      return true;
    }
    return t.repeatsOn(today);
  }

  /// 当日事件总数：截止今天或今天循环出现的任务数（不含已删除）。
  int get todayEventTotal {
    final now = DateTime.now();
    return _tasks.where((t) => _isEventToday(t, now)).length;
  }

  /// 当日已完成：当日事件中已完成的任务数。
  int get todayCompleted {
    final now = DateTime.now();
    return _tasks.where((t) => _isEventToday(t, now) && t.done).length;
  }

  /// 当日任务完成率：当日已完成 / 当日事件总数。
  double get todayCompletionRate =>
      todayEventTotal == 0 ? 0 : todayCompleted / todayEventTotal;

  /// 各分类完成比例
  Map<Category, double> categoryProgress() {
    final Map<Category, int> total = {};
    final Map<Category, int> done = {};
    for (final c in Category.values) {
      total[c] = 0;
      done[c] = 0;
    }
    for (final t in _tasks) {
      total[t.category] = total[t.category]! + 1;
      if (t.done) done[t.category] = done[t.category]! + 1;
    }
    return {
      for (final c in Category.values)
        c: total[c]! == 0 ? 0 : done[c]! / total[c]!,
    };
  }

  /// 近 7 日（含今天）的完整日期列表，旧→新。
  List<DateTime> get weekTrendDates {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return List.generate(7, (i) => today.subtract(Duration(days: 6 - i)));
  }

  /// 近 7 日每日完成数（旧→新），按 completedAt 统计。
  List<int> get weekTrend {
    final days = weekTrendDates;
    final counts = List.filled(7, 0);
    for (final t in _tasks) {
      if (!t.done || t.completedAt == null) continue;
      final d = DateTime(t.completedAt!.year, t.completedAt!.month, t.completedAt!.day);
      final idx = days.indexWhere((day) => day.isAtSameMomentAs(d));
      if (idx != -1) counts[idx]++;
    }
    return counts;
  }

  /// 上一周（往前 8-14 天）每日完成数（旧→新），用于环比。
  List<int> get lastWeekTrend {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = List.generate(7, (i) => today.subtract(Duration(days: 13 - i)));
    final counts = List.filled(7, 0);
    for (final t in _tasks) {
      if (!t.done || t.completedAt == null) continue;
      final d = DateTime(t.completedAt!.year, t.completedAt!.month, t.completedAt!.day);
      final idx = days.indexWhere((day) => day.isAtSameMomentAs(d));
      if (idx != -1) counts[idx]++;
    }
    return counts;
  }

  /// 有完成记录（completedAt 当天 ≥1 个已完成任务）的所有日期（date-only）。
  Set<DateTime> get completionDays {
    final s = <DateTime>{};
    for (final t in _tasks) {
      if (t.done && t.completedAt != null) {
        s.add(DateTime(t.completedAt!.year, t.completedAt!.month, t.completedAt!.day));
      }
    }
    return s;
  }

  static DateTime _dateOnly(DateTime d) =>
      DateTime(d.year, d.month, d.day);

  /// 当前连续打卡天数：从最近一个完成日往回数连续天数；若最近完成日距今 >1 天则视为中断，记为 0。
  int get currentStreak {
    final days = completionDays;
    if (days.isEmpty) return 0;
    final today = _dateOnly(DateTime.now());
    DateTime last = days.first;
    for (final d in days) {
      if (d.isAfter(last)) last = d;
    }
    final gap = today.difference(last).inDays;
    if (gap > 1) return 0; // 中间空了一整天 → 中断
    int streak = 0;
    var cursor = last;
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// 历史最长连续打卡天数。
  int get longestStreak {
    final days = completionDays.toList()..sort();
    if (days.isEmpty) return 0;
    int best = 1;
    int run = 1;
    for (int i = 1; i < days.length; i++) {
      if (days[i].difference(days[i - 1]).inDays == 1) {
        run++;
        if (run > best) best = run;
      } else {
        run = 1;
      }
    }
    return best;
  }

  /// 指定月份内「每天完成数」映射（date-only → 完成数），用于日历热力图。
  Map<DateTime, int> completionsInMonth(DateTime monthAnchor) {
    final map = <DateTime, int>{};
    for (final t in _tasks) {
      if (!t.done || t.completedAt == null) continue;
      final d = _dateOnly(t.completedAt!);
      if (d.year == monthAnchor.year && d.month == monthAnchor.month) {
        map[d] = (map[d] ?? 0) + 1;
      }
    }
    return map;
  }

  /// 某月累计完成数（日历页顶部概览用）。
  int completionsInMonthCount(DateTime monthAnchor) =>
      completionsInMonth(monthAnchor).values.fold(0, (a, b) => a + b);

  /// 某天完成的所有任务（按完成时间倒序），点击日历格查看当天明细用。
  List<Task> tasksCompletedOn(DateTime day) {
    final d = _dateOnly(day);
    final list = _tasks
        .where((t) =>
            t.done &&
            t.completedAt != null &&
            _dateOnly(t.completedAt!) == d)
        .toList();
    list.sort((a, b) => b.completedAt!.compareTo(a.completedAt!));
    return list;
  }

  /// 某天到期的所有任务（未删除，含已完成灰显），按截止时间升序；
  /// 日历月/周视图展示当天任务、以及拖拽改期后定位目标日用。
  List<Task> tasksDueOn(DateTime day) {
    final d = _dateOnly(day);
    final list = _tasks
        .where((t) =>
            t.deletedAt == null &&
            t.dueDate != null &&
            _dateOnly(t.dueDate!) == d)
        .toList();
    list.sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    return list;
  }

  // ===== 首页筛选（看板统计卡点击跳转）=====
  TaskFilter _taskFilter = TaskFilter.all;
  TaskFilter get taskFilter => _taskFilter;
  void setTaskFilter(TaskFilter f) {
    if (_taskFilter == f) return;
    _taskFilter = f;
    notifyListeners();
  }

  /// 看板/首页注册的「跳回首页」回调：统计卡点击后由 scaffold 切换 Tab。
  void Function()? _onRequestHome;
  set onRequestHome(void Function()? cb) => _onRequestHome = cb;
  void requestHomeWithFilter(TaskFilter f) {
    _taskFilter = f;
    _onRequestHome?.call();
    notifyListeners();
  }

  /// 看板两列分组：待办 / 已完成（保留列表原顺序）。
  Map<TaskStatus, List<Task>> get kanbanGroups {
    final map = {for (final s in TaskStatus.values) s: <Task>[]};
    for (final t in _tasks) {
      map[t.status]!.add(t);
    }
    return map;
  }

  /// 未完成任务的优先级分布（高/中/低），用于看板「优先级」进度条。
  Map<Priority, int> get priorityCounts {
    final map = {for (final p in Priority.values) p: 0};
    for (final t in _tasks) {
      if (!t.done) map[t.priority] = map[t.priority]! + 1;
    }
    return map;
  }

  /// 首页分区计数：逾期 / 今天 / 未来 / 每天 / 已完成。
  /// 口径与首页完全一致（按「天」比较截止日期，每日提醒任务单独成段、不参与日期切分），
  /// 供分享卡片直接复用，避免再依赖首页私有的 _dueDayDiff。
  Map<String, int> get sectionCounts {
    int? dayDiff(DateTime? due) {
      if (due == null) return null;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      return DateTime(due.year, due.month, due.day).difference(today).inDays;
    }

    final active = _tasks.where((t) => !t.done && !t.isRepeating);
    final overdue = active.where((t) => (dayDiff(t.dueDate) ?? 0) < 0).length;
    final today =
        active.where((t) => dayDiff(t.dueDate) == 0 || t.dueDate == null).length;
    final future = active.where((t) {
      final d = dayDiff(t.dueDate);
      return d != null && d > 0;
    }).length;
    final repeat = _tasks.where((t) => t.isRepeating && !t.done).length;
    final done = _tasks.where((t) => t.done).length;
    return {
      'overdue': overdue,
      'today': today,
      'future': future,
      'repeat': repeat,
      'done': done,
    };
  }

  /// 首页分区任务列表：逾期 / 今天 / 未来 / 每天 / 已完成（各自已排序）。
  /// 与首页 [_section] 完全一致的分组与排序口径，供分享卡片列出「详细事件 / 任务」，
  /// 而非只有计数。置顶(pinned)任务在各分区内优先于 order / 截止时间排最前。
  Map<String, List<Task>> get homeTasks {
    int? dayDiff(DateTime? due) {
      if (due == null) return null;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      return DateTime(due.year, due.month, due.day).difference(today).inDays;
    }

    // 未完成 + 非重复，按截止日期切分为 逾期 / 今天 / 未来。
    final active = _tasks.where((t) => !t.done && !t.isRepeating).toList();
    final overdue = active
        .where((t) => (dayDiff(t.dueDate) ?? 0) < 0)
        .toList()
      ..sort((a, b) {
        // 置顶优先；其次手动排序 order；最后截止时间早的排前（拖最久的排前）。
        final p = _comparePinned(a, b);
        if (p != 0) return p;
        final c = a.order.compareTo(b.order);
        if (c != 0) return c;
        return a.dueDate!.compareTo(b.dueDate!);
      });
    final today = active
        .where((t) => dayDiff(t.dueDate) == 0 || t.dueDate == null)
        .toList()
      ..sort((a, b) {
        final p = _comparePinned(a, b);
        if (p != 0) return p;
        final c = a.order.compareTo(b.order);
        if (c != 0) return c;
        // 排序键：优先用截止时间；无截止但有开始时间时用开始时间；两者皆无排末。
        DateTime? keyA = a.dueDate ?? a.startDate;
        DateTime? keyB = b.dueDate ?? b.startDate;
        if (keyA == null && keyB == null) return 0;
        if (keyA == null) return 1;
        if (keyB == null) return -1;
        return keyA.compareTo(keyB);
      });
    final future = active.where((t) {
      final d = dayDiff(t.dueDate);
      return d != null && d > 0;
    }).toList()
      ..sort((a, b) {
        final p = _comparePinned(a, b);
        if (p != 0) return p;
        final c = a.order.compareTo(b.order);
        if (c != 0) return c;
        return a.dueDate!.compareTo(b.dueDate!);
      });
    // 重复任务单独成段，按提醒时刻升序（置顶优先，其次 order 优先）。
    final repeat = _tasks.where((t) => t.isRepeating && !t.done).toList()
      ..sort((a, b) {
        final p = _comparePinned(a, b);
        if (p != 0) return p;
        final c = a.order.compareTo(b.order);
        if (c != 0) return c;
        return (a.repeatMinute ?? 24 * 60)
            .compareTo(b.repeatMinute ?? 24 * 60);
      });
    // 已完成统一进「已完成」（置顶优先，其次 order 优先）。
    final done = _tasks.where((t) => t.done).toList()
      ..sort((a, b) {
        final p = _comparePinned(a, b);
        if (p != 0) return p;
        return a.order.compareTo(b.order);
      });
    return {
      'overdue': overdue,
      'today': today,
      'future': future,
      'repeat': repeat,
      'done': done,
    };
  }

  /// 按「天」计算截止日期相对今天的差值（忽略时分秒）。
  /// 负数=逾期，0=今天，正数=未来，null=无截止。供分区与拖拽落点复用。
  static int? _dayDiff(DateTime? due) {
    if (due == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(due.year, due.month, due.day).difference(today).inDays;
  }

  /// 置顶排序比较器：置顶(pinned=true)任务始终排在前（降序），与首页 home_screen 一致。
  static int _comparePinned(Task a, Task b) {
    if (a.pinned == b.pinned) return 0;
    return a.pinned ? -1 : 1;
  }

  /// 判断某任务在首页属于哪个分区（逾期/今天/未来/每天/已完成）。
  /// 与 [homeTasks] 的分组口径一致，供新建任务落点与拖拽写回 order 使用。
  String _sectionNameOf(Task t) {
    if (t.done) return 'done';
    if (t.isRepeating) return 'repeat';
    final d = _dayDiff(t.dueDate);
    if (d == null) return 'today';
    if (d < 0) return 'overdue';
    if (d == 0) return 'today';
    return 'future';
  }

  /// 专注会话回填：把某次专注时长（秒）累加到关联任务的 [Task.focusSecTotal]，
  /// 并持久化。任务已删除（不在 _tasks）则忽略。回调自 FocusProvider.addSession。
  void addFocusSec(String taskId, int sec) {
    if (sec <= 0) return;
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i == -1) return;
    _tasks[i] = _tasks[i].copyWith(
      focusSecTotal: _tasks[i].focusSecTotal + sec,
    );
    notifyListeners();
    _persist();
  }

  /// 拖拽重排某分区内的任务顺序：把分区当前显示列表的 [oldIndex] 移到 [newIndex]，
  /// 并把它及其后续任务的 [Task.order] 顺次写为 1,2,3…，使手动顺序持久化（order 优先于日期排序）。
  void reorderTasks(String section, int oldIndex, int newIndex) {
    final list = homeTasks[section];
    if (list == null || list.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex < 0 || newIndex > list.length) return;
    final reordered = List<Task>.from(list);
    // Flutter ReorderableListView 的 newIndex 系「移除后」下标，下移需 -1 对齐。
    final insertAt = oldIndex < newIndex ? newIndex - 1 : newIndex;
    if (insertAt < 0 || insertAt >= reordered.length) return;
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(insertAt, moved);
    for (var i = 0; i < reordered.length; i++) {
      final t = reordered[i];
      final idx = _tasks.indexWhere((x) => x.id == t.id);
      if (idx != -1) {
        _tasks[idx] = _tasks[idx].copyWith(order: (i + 1).toDouble());
      }
    }
    notifyListeners();
    _persist();
  }

  /// 把任务在 待办/已完成 之间移动（看板拖拽 / 点击切换）。
  void setStatus(String id, TaskStatus s) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final cur = _tasks[i];
    if (cur.status == s) return;
    _tasks[i] = cur.copyWith(
      status: s,
      completedAt: s == TaskStatus.done ? DateTime.now() : null,
    );
    if (_tasks[i].isRepeating) {
      _rescheduleRepeatOnCompletion(_tasks[i]);
    } else {
      _reconcileDeadlineOnCompletion(_tasks[i]);
    }
    notifyListeners();
    _persist();
  }

  /// 按 id 取任务（详情页实时读取用）。找不到返回 null。
  Task? byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 切换某任务的某个子任务勾选态，并持久化。
  void toggleSubTask(String taskId, String subId) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i == -1) return;
    final subs = _tasks[i].subtasks.map((s) {
      return s.id == subId ? s.copyWith(done: !s.done) : s;
    }).toList();
    _tasks[i] = _tasks[i].copyWith(subtasks: subs);
    notifyListeners();
    _persist();
  }

  void toggleDone(String id) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final willDone = !_tasks[i].done;
    _tasks[i] = _tasks[i].copyWith(
      status: willDone ? TaskStatus.done : TaskStatus.todo,
      completedAt: willDone ? DateTime.now() : null,
    );
    // 重复任务完成/取消完成：重排重复提醒。当天已完成则跳过今日（不弹今天提醒），
    // 否则照常挂今日；同一通知 id 覆盖掉旧闹钟。
    if (_tasks[i].isRepeating) {
      _rescheduleRepeatOnCompletion(_tasks[i]);
    } else {
      _reconcileDeadlineOnCompletion(_tasks[i]);
    }
    notifyListeners();
    _persist();
  }

  /// 切换任务置顶/星标状态：置顶任务在所属分区内固定排最前（优先于手动 order）。
  void togglePinned(String id) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i == -1) return;
    _tasks[i] = _tasks[i].copyWith(pinned: !_tasks[i].pinned);
    notifyListeners();
    _persist();
  }

  /// 把 DateTime 格式化为 yyyy-MM-dd（date-only），与 [Task.skipDates] 的存储格式一致。
  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 本次跳过：把 [day]（默认今天）追加进任务的 [Task.skipDates]。
  /// 跳过 ≠ 完成——当天不出现、不打卡、不影响连续天数；次日恢复正常。
  /// 对 interval 重复任务额外重排提醒，避免「跳过当天仍弹提醒」。
  void skipOccurrence(String taskId, {DateTime? day}) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i == -1) return;
    final d = day ?? DateTime.now();
    final ymd = _ymd(DateTime(d.year, d.month, d.day));
    if (_tasks[i].skipDates.contains(ymd)) return; // 已跳过，幂等
    final updated = _tasks[i].copyWith(
      skipDates: [..._tasks[i].skipDates, ymd],
    );
    _tasks[i] = updated;
    if (updated.repeat == RepeatType.interval) {
      // interval 为一次性闹钟，取消后按新 skipDates 重排到下一个有效循环日（自动跳过今天）。
      _cancelRemindersFor(updated.id);
      _scheduleRemindersFor(updated);
    }
    notifyListeners();
    _persist();
  }

  /// 结束重复：把 [Task.repeatUntil] 设为昨天，从今天起不再循环（保留历史任务不删）。
  /// 结束当天即停止出现 / 提醒 / 午夜重置。
  void endRepeat(String taskId) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i == -1) return;
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final updated = _tasks[i].copyWith(repeatUntil: _ymd(yesterday));
    _tasks[i] = updated;
    _cancelRemindersFor(updated.id);
    notifyListeners();
    _persist();
  }

  /// 仅此一次改期：跳过 [origDay]（默认今天）这一次 occurrence，并创建一条一次性副本任务，
  /// 截止时间设为 [newDay]（其余字段沿用原任务）。实现上即现有 [addTask]，无需新概念。
  void rescheduleOnceOccurrence(
    String taskId,
    DateTime newDay, {
    DateTime? origDay,
  }) {
    final src = byId(taskId);
    if (src == null) return;
    // 1) 把原 occurrence 当天加入 skipDates，避免原任务当天仍出现/提醒。
    skipOccurrence(taskId, day: origDay ?? DateTime.now());
    // 2) 创建一次性副本（repeat=none），dueDate 指向改期后的日期，其余沿用。
    final copy = src.copyWith(
      id: '', // addTask 会分配新 id
      repeat: RepeatType.none,
      repeatWeekdays: const [],
      repeatInterval: 2,
      repeatMinute: null,
      repeatAnchor: null,
      skipDates: const [],
      repeatUntil: null,
      dueDate: DateTime(newDay.year, newDay.month, newDay.day,
          src.dueDate?.hour ?? 9, src.dueDate?.minute ?? 0),
      status: TaskStatus.todo,
      completedAt: null,
    );
    addTask(copy);
  }

  int _idSeq = 8;

  /// 外部来源的 id（如 iCal UID 里的 `<数字>@youtiao`）能否安全复用。
  ///
  /// 安全（P2-A）：早期实现是「非空且不冲突就照单全收」，带来两个隐患——
  /// ① 外部 .ics 传入超大 id 时不推进 `_idSeq`，后续新建任务会再次拿到同一 id；
  /// ② 传入与既有任务相同的 id 会把真实任务内容整体改写。
  /// 这里收紧为：纯数字 + 数值落在当前自增序列已覆盖区间（`< _idSeq`）+ 无同 id 任务。
  bool _canReuseExternalId(String id) {
    if (id.isEmpty) return false;
    final n = int.tryParse(id);
    if (n == null || n <= 0 || n >= _idSeq) return false;
    return byId(id) == null;
  }

  /// 新建任务：插入到列表头部，自动分配唯一 id；有截止时间或每日提醒则调度。
  /// 返回创建后的 [Task]（含已分配 id），便于调用方把暂存附件目录提升为正式目录
  /// （见 [new_task_sheet] 的附件保存流程）。
  Task addTask(Task task) {
    // P0-3：若调用方传入了可安全复用的 id（如 iCal 导入的 youtiao UID），
    // 则保留该 id，使「从有条导出再导回」能稳定去重；否则用自增序列分配新 id。
    // 安全（P2-A）：见 [_canReuseExternalId]——不再无条件信任外部 id。
    final useId =
        _canReuseExternalId(task.id) ? task.id : (_idSeq++).toString();
    var newTask = task.copyWith(
      id: useId,
      // A1：落库时统一计算拼音首字母，保证所有新建入口（NL 快速录入等）都自动覆盖。
      pinyinInitials: Task.computePinyinInitials(task.title),
    );
    // 落点到对应分区的末尾：取该分区现有最大 order + 1，避免新建任务跳到手动排序的区顶。
    final section = _sectionNameOf(newTask);
    double maxOrder = 0;
    for (final t in _tasks) {
      if (_sectionNameOf(t) == section && t.order > maxOrder) maxOrder = t.order;
    }
    newTask = newTask.copyWith(order: maxOrder + 1);
    _tasks.insert(0, newTask);
    _scheduleRemindersFor(newTask);
    notifyListeners();
    _persist();
    return newTask;
  }

  /// P0-3：iCal / CSV 导入幂等去重。
  /// [incoming] 为解析出的任务（其 id 已由解析层设为 youtiao UID 前缀，或无 UID 留空）；
  /// [uids] 为与 [incoming] 平行的原始 UID 列表（用于判断是否为 youtiao 来源）。
  /// [skipExisting]=true 时，已存在的任务跳过（不新增）；[overwrite]=true 时对已存在任务
  /// 以新内容覆盖更新（仍不新增）；[fingerprint]=true 时对「无 UID 的第三方 .ics」按
  /// 「标题 + 截止日期」指纹去重（默认关闭，避免同名任务被误合并）。
  /// 返回 {added, skipped, overwritten} 计数，供调用方展示导入报告。
  ({int added, int skipped, int overwritten}) importDedup(
    List<Task> incoming,
    List<String?> uids, {
    bool skipExisting = true,
    bool overwrite = false,
    bool fingerprint = false,
  }) {
    var added = 0, skipped = 0, overwritten = 0;
    for (var i = 0; i < incoming.length; i++) {
      final task = incoming[i];
      final uid = i < uids.length ? uids[i] : null;
      // 判定是否已存在：
      //  1) youtiao UID（task.id 非空即解析层写入的数字 id）→ byId 直查；
      //  2) 指纹去重开启且非 youtiao 来源 → 标题 + 截止日期匹配。
      Task? existing;
      if (task.id.isNotEmpty) {
        final byUid = byId(task.id);
        if (byUid == null) {
          // 无同 id 任务 → 走新增分支（addTask 内部还会再校验 id 是否可复用）。
        } else if (_fingerprintKey(byUid) == _fingerprintKey(task)) {
          existing = byUid; // id + 指纹双一致 → 确实是从「有条」导出过的同一条任务
        } else {
          // 安全（P2-A）：id 撞上了用户已有的**另一条**真实任务（第三方 .ics 可枚举出
          // 小整数 id），但内容指纹不一致。此时绝不能按「覆盖」把真实任务改写掉——
          // 丢弃可疑 id，作为一条全新任务导入。
          addTask(task.copyWith(id: ''));
          added++;
          continue;
        }
      }
      if (existing == null &&
          fingerprint &&
          (uid == null || !uid.endsWith('@youtiao'))) {
        existing = _matchByFingerprint(task);
      }
      if (existing == null) {
        addTask(task);
        added++;
      } else if (overwrite) {
        updateTask(task.copyWith(id: existing.id));
        overwritten++;
      } else {
        skipped++;
      }
    }
    // 安全（P2-A）：导入可能带入外部 id，重算自增起点，杜绝后续新建任务 id 碰撞。
    _recomputeIdSeq();
    return (added: added, skipped: skipped, overwritten: overwritten);
  }

  /// 按「标题 + 截止日期」指纹查找现有任务（供无 UID 的第三方 .ics 去重）。
  Task? _matchByFingerprint(Task task) {
    final key = _fingerprintKey(task);
    for (final t in _tasks) {
      if (_fingerprintKey(t) == key) return t;
    }
    return null;
  }

  /// 任务指纹：标题 + 截止日期（date-only）。用于第三方 .ics 的无 UID 去重。
  static String _fingerprintKey(Task t) {
    final d = t.dueDate;
    final day = d == null ? 'none' : '${d.year}-${d.month}-${d.day}';
    return '${t.title.trim()}@$day';
  }

  /// 更新已有任务：以调用方传入的 [updated]（已携带全部可编辑字段）为基础落库，
  /// 仅强制保留内部派生/不可编辑字段（id / status / completedAt / focusSecTotal / order）
  /// 自 [old] 取，避免丢失 tags / subtasks / reminderOffsetMin 等新字段
  /// （曾于 v1.9.4 / v2.3.3 / v2.3.4 / v2.5.0 多次踩坑）。
  void updateTask(Task updated) {
    final i = _tasks.indexWhere((t) => t.id == updated.id);
    if (i == -1) return;
    final old = _tasks[i];
    // A1：标题变化时重算拼音首字母（标题不变则沿用旧值）。
    final pin = updated.title == old.title
        ? old.pinyinInitials
        : Task.computePinyinInitials(updated.title);
    _tasks[i] = updated.copyWith(
      id: old.id,
      status: old.status,
      completedAt: old.completedAt,
      focusSecTotal: old.focusSecTotal,
      order: old.order,
      pinyinInitials: pin,
    );
    // 截止时间或重复设置发生变化时，先取消旧调度再统一重排，避免状态不一致。
    final remindersChanged = old.dueDate != updated.dueDate ||
        old.repeat != updated.repeat ||
        old.repeatMinute != updated.repeatMinute ||
        old.repeatInterval != updated.repeatInterval ||
        !_listEq(old.repeatWeekdays, updated.repeatWeekdays) ||
        old.repeatAnchor != updated.repeatAnchor;
    if (remindersChanged) {
      _cancelRemindersFor(updated.id);
      _scheduleRemindersFor(_tasks[i]);
    }
    notifyListeners();
    _persist();
  }

  /// P0-1：批量编辑。对 [ids] 命中的任务逐一应用 [transform] 后落库。
  /// 复用 [updateTask] 而非直接改内存，确保提醒重排 / 拼音重算 / 持久化等既有
  /// 逻辑一致生效（避免走捷径导致「改了期但提醒没重挂」这类经典回归）。
  /// 返回实际更新的条数；未命中的 id 静默跳过。
  /// P0-1：对 [ids] 批量施加 [transform]，返回实际更新条数。
  ///
  /// ⚠️ **不能用于修改完成态**。`updateTask` 会强制保留任务原有的 `status`、
  /// `completedAt`、`focusSecTotal`、`order`，因此 transform 里传 `status: done`
  /// 会被**静默丢弃**（返回条数照常，看起来成功实则无效）。
  /// 要改完成态请逐条调用 [toggleDone] / [setStatus]——它们还会顺带重排重复提醒。
  int batchUpdate(List<String> ids, Task Function(Task) transform) {
    if (ids.isEmpty) return 0;
    // 先快照再逐条更新：[updateTask] 会改动 _tasks，边遍历边改不安全。
    final targets = ids.map(byId).whereType<Task>().toList();
    // F1：批量编辑一次性改写 N 条且无快照，历史上「+N 天数输错 / 分类选错」不可逆。
    // 这里外套一份「改前快照」，供 [undoBatchEdit] 一键还原。
    // 撤销按 id 定位（见 [undoBatchEdit]），无需记录索引——中间有插删时索引会错位。
    _lastEditBatch = targets.map((t) => t.copyWith()).toList();
    for (final t in targets) {
      updateTask(transform(t));
    }
    return targets.length;
  }

  // ===== 批量编辑（改前快照 + 撤销）=====
  // 与删除撤销 [_lastBatch] / [_lastBatchIndices] 相互独立，互不覆盖。
  List<Task> _lastEditBatch = [];

  /// 撤销上一次批量编辑：把改前快照逐条写回被改写的任务。
  /// 仅可撤销最近一次批量编辑（覆盖式缓冲）；与 [undoDelete] 互不影响。
  ///
  /// P1-1：必须逐条走 [updateTask] 而非直接改内存——批量顺延「+N 天」后撤销时，
  /// 截止日期会回滚，唯有 updateTask 会触发 `_cancelRemindersFor/_scheduleRemindersFor`
  /// 重排提醒，否则系统里残留的提醒仍指向顺延后的新日期（截止日期与通知错位）。
  ///
  /// P1-2：按 id 定位而非索引——快照记录的是 batchUpdate 执行时的列表位置，
  /// 之后若用户新增/删除/排序过任务，按旧索引写回会覆盖到无辜任务（数据错乱）。
  /// 这里用 `indexWhere(id)` 找当前位置；找不到说明任务已被删除，跳过（不复活）。
  void undoBatchEdit() {
    if (_lastEditBatch.isEmpty) return;
    for (final orig in _lastEditBatch) {
      final cur = byId(orig.id);
      if (cur == null) continue; // 任务已不在列表（被删除），不允许复活
      // updateTask 会强制保留 status/completedAt/focusSecTotal/order（批量编辑
      // 本就不改这些字段），并复用提醒重排 / 拼音重算 / 持久化等既有逻辑。
      updateTask(orig);
    }
    _lastEditBatch = [];
    notifyListeners();
  }

  /// P0-2：把 [ids] 任务的截止日期整体改到 [targetDay]（date-only，保留原时刻）。
  /// 语义是「改期」而非「加天数」——过期多久都拉到同一天，重复任务的重锚点不受影响，
  /// 提醒由 [updateTask] 统一重排。无截止日期的任务原样保留。返回实际更新条数。
  int postponeTo(List<String> ids, DateTime targetDay) {
    return batchUpdate(ids, (t) {
      final d = t.dueDate;
      if (d == null) return t;
      return t.copyWith(
        dueDate: DateTime(
            targetDay.year, targetDay.month, targetDay.day, d.hour, d.minute),
      );
    });
  }

  // ===== 删除（移入回收站，带撤销）=====
  // 用批量撤销缓冲，使「单个删除」与「多选批量删除」共用同一套撤销逻辑。
  List<Task> _lastBatch = [];
  List<int> _lastBatchIndices = [];

  /// 批量删除指定 id 的任务：从任务列表移除，移入回收站（记录删除时间），
  /// 并取消其全部本地提醒。返回被删除的任务列表（按原始索引升序）。
  /// 注意：每次调用都会覆盖上一次删除的撤销缓冲（仅可撤销最近一次删除操作）。
  List<Task> _removeMany(List<String> ids) {
    // 收集待删任务的原始索引与对象（升序）
    final toRemove = <int, Task>{};
    for (final id in ids) {
      final i = _tasks.indexWhere((t) => t.id == id);
      if (i != -1) toRemove[i] = _tasks[i];
    }
    final sortedIdx = toRemove.keys.toList()..sort(); // 升序
    // 按索引降序删除，保证删除时索引依然有效
    for (final i in sortedIdx.reversed) {
      final r = _tasks.removeAt(i);
      _cancelRemindersFor(r.id);
      _trash.insert(0, r.copyWith(deletedAt: DateTime.now()));
    }
    _lastBatch = sortedIdx.map((i) => toRemove[i]!).toList(); // 升序
    _lastBatchIndices = sortedIdx; // 升序，与 _lastBatch 一一对应
    notifyListeners();
    _persist();
    _syncTrashExpireNotice(); // P1-12：新入回收站后重排过期预告
    return _lastBatch;
  }

  /// 删除指定 id 的任务：从任务列表移除，并移入回收站（记录删除时间）。
  /// 返回被删除的任务（用于撤销 / 提示）。
  Task? deleteTask(String id) {
    final removed = _removeMany([id]);
    return removed.isEmpty ? null : removed.first;
  }

  /// 多选批量删除：一次删除多个任务（移入回收站，可整体撤销）。
  void deleteTasks(List<String> ids) => _removeMany(ids);

  /// 撤销上一次删除（支持批量）：从回收站取回并按原始索引归位，恢复其本地提醒。
  void undoDelete() {
    if (_lastBatch.isEmpty) return;
    for (var k = 0; k < _lastBatch.length; k++) {
      final r = _lastBatch[k];
      final idx = _lastBatchIndices[k].clamp(0, _tasks.length);
      _tasks.insert(idx, r);
      _trash.removeWhere((t) => t.id == r.id);
      _scheduleRemindersFor(r);
    }
    _lastBatch = [];
    _lastBatchIndices = [];
    notifyListeners();
    _persist();
    _syncTrashExpireNotice(); // P1-12：撤销删除后重排
  }

  /// 从回收站恢复任务到任务列表（清除 deletedAt，放回顶部），并恢复其本地提醒。
  void restoreFromTrash(String id) {
    final i = _trash.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final t = _trash.removeAt(i);
    final restored = t.copyWith(deletedAt: null);
    _tasks.insert(0, restored);
    _scheduleRemindersFor(restored);
    notifyListeners();
    _persist();
    _syncTrashExpireNotice(); // P1-12：恢复后重排
  }

  /// 在回收站中彻底删除某任务（不可恢复），并取消其本地提醒。
  void permanentDelete(String id) {
    _trash.removeWhere((t) => t.id == id);
    _cancelRemindersFor(id);
    // P0-1：彻底删除时一并清理其附件目录，避免孤立文件长期占用空间。
    AttachmentService.removeDir(id);
    notifyListeners();
    _persist();
    _syncTrashExpireNotice(); // P1-12：彻底删除后重排
  }

  /// 清空回收站（全部彻底删除），并取消其中所有任务的本地提醒。
  void clearTrash() {
    if (_trash.isEmpty) return;
    for (final t in _trash) {
      _cancelRemindersFor(t.id);
      // P0-1：清理附件目录。
      AttachmentService.removeDir(t.id);
    }
    _trash.clear();
    notifyListeners();
    _persist();
    NotificationService.instance.cancelTrashExpireNotice(); // P1-12：清空回收站即取消预告
  }

  /// 完整备份数据（任务 + 偏好 + 可选回收站），用于「备份与恢复」导出。
  /// [includeTrash] 为 true 时一并将回收站任务写入备份。
  Map<String, dynamic> backupData({bool includeTrash = true}) => {
        'version': 3,
        'app': '有条',
        'tasks': _tasks.map((t) => t.toJson()).toList(),
        'trash': includeTrash
            ? _trash.map((t) => t.toJson()).toList()
            : <Map<String, dynamic>>[],
        'notifications_enabled': _notificationsEnabled,
        'sound_enabled': _soundEnabled,
      };

  /// 备份 JSON 字符串（带缩进，便于人工查看与分段恢复）。
  String backupJson([bool includeTrash = true]) =>
      const JsonEncoder.withIndent('  ').convert(backupData(includeTrash: includeTrash));

  /// 从备份 JSON 字符串恢复：覆盖全部任务与偏好，并重排通知。
  /// [includeTrash] 为 true 且备份含回收站时，用备份的回收站覆盖当前回收站。
  Future<void> restoreFromJson(String raw, {bool includeTrash = true}) async {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    // 结构预校验：选到其它应用的 JSON 时直接拒绝，避免清空全部任务。
    if (data['app'] != '有条' && data['tasks'] is! List) {
      throw Exception('不是「有条」的备份文件');
    }
    // 干跑解析：任一任务字段非法（如未知 priority / category）先在此抛错，
    // 此时尚未清空内存态，用户数据不被破坏（修复前会留下空列表吓人）。
    final list = (data['tasks'] as List?) ?? [];
    final parsed = list
        .map((e) => Task.fromJson(e as Map<String, dynamic>))
        .toList();
    final trashParsed = <Task>[];
    if (includeTrash) {
      final trashList = (data['trash'] as List?) ?? [];
      trashParsed.addAll(
          trashList.map((e) => Task.fromJson(e as Map<String, dynamic>)));
    }
    // 全部解析通过后，才真正覆盖内存态并落库。
    // P1-2：恢复后统一按标题重算拼音首字母（旧版备份 pinyinInitials 多为空串，
    // 直接采用会导致恢复后拼音搜索静默失效），保证搜索始终可用。
    _tasks
      ..clear()
      ..addAll(parsed
          .map((t) =>
              t.copyWith(pinyinInitials: Task.computePinyinInitials(t.title)))
          .toList());
    if (includeTrash) {
      _trash
        ..clear()
        ..addAll(trashParsed);
    }
    if (data['notifications_enabled'] is bool) {
      _notificationsEnabled = data['notifications_enabled'];
    }
    if (data['sound_enabled'] is bool) _soundEnabled = data['sound_enabled'];
    NotificationService.instance.enabled = _notificationsEnabled;
    NotificationService.instance.cancelAll();
    if (_notificationsEnabled) _rescheduleAllActive();
    _recomputeIdSeq();
    notifyListeners();
    await _persist();
    // P0-1：还原附件二进制。备份里随任务 JSON 携带 base64 内联文件（key=attachments），
    // 在此统一写回 `attachments/<taskId>/`，保证手动恢复与自动备份还原都覆盖附件。
    await AttachmentService.restoreBlobs(data['attachments'] as Map<String, dynamic>?);
  }

  /// P0-1：收集备份所需的附件二进制（base64 内联），随任务一起加密打包。
  /// [includeTrash] 为 true 时一并纳入回收站任务的附件。
  Future<Map<String, dynamic>> collectAttachmentBlobs(bool includeTrash) async {
    final tasks = <Task>[..._tasks];
    if (includeTrash) tasks.addAll(_trash);
    return AttachmentService.collectBlobs(tasks);
  }

  /// 导出可读 CSV（标题,优先级,分类,截止时间,状态,完成时间,是否已删除）。
  /// [includeTrash] 为 true 时，回收站任务也一并列出（最后一列标记为「是」）。
  String exportCsv({bool includeTrash = false, bool includeAttachments = false}) {
    final buf = StringBuffer();
    buf.writeln('标题,优先级,分类,截止时间,状态,完成时间,是否已删除,附件');
    void writeRow(Task t, bool deleted) {
      final due = t.dueDate == null ? '' : _fmt(t.dueDate!);
      final completed = t.completedAt == null ? '' : _fmt(t.completedAt!);
      buf.writeln('"${_esc(t.title)}","${_prioLabel(t.priority)}",'
          '"${_catLabel(t.category)}","$due","${t.done ? '已完成' : '未完成'}","$completed",'
          '"${deleted ? '是' : '否'}","${_esc(_attachmentSummary(t, includeAttachments))}"');
    }

    for (final t in _tasks) {
      writeRow(t, false);
    }
    if (includeTrash) {
      for (final t in _trash) {
        writeRow(t, true);
      }
    }
    return buf.toString();
  }

  /// 导出可读 Markdown 清单（未完成 / 已完成两组；可选回收站）。
  /// [includeTrash] 为 true 且回收站非空时，追加「回收站」分组。
  String exportMarkdown({bool includeTrash = false, bool includeAttachments = false}) {
    final buf = StringBuffer();
    buf.writeln('# 有条 任务导出');
    buf.writeln('');
    buf.writeln('> 导出时间：${_fmt(DateTime.now())}');
    buf.writeln('');
    buf.writeln('## 未完成（${_tasks.where((e) => !e.done).length}）');
    for (final t in _tasks.where((e) => !e.done)) {
      final due = t.dueDate == null ? '' : ' ｜ 截止 ${_fmt(t.dueDate!)}';
      final rep = t.repeatFull.isNotEmpty ? ' ｜ ${t.repeatFull}' : '';
      // P1-10：开启「包含附件清单」时，任务行后追加附件摘要。
      final att = _attachmentSummary(t, includeAttachments);
      buf.writeln('- [ ] ${_esc(t.title)} ｜ ${_prioLabel(t.priority)} / ${_catLabel(t.category)}$due$rep${att.isNotEmpty ? ' ｜ $att' : ''}');
    }
    buf.writeln('');
    buf.writeln('## 已完成（${_tasks.where((e) => e.done).length}）');
    for (final t in _tasks.where((e) => e.done)) {
      final c = t.completedAt == null ? '' : ' ｜ 完成于 ${_fmt(t.completedAt!)}';
      final rep = t.repeatFull.isNotEmpty ? ' ｜ ${t.repeatFull}' : '';
      final att = _attachmentSummary(t, includeAttachments);
      buf.writeln('- [x] ${_esc(t.title)} ｜ ${_prioLabel(t.priority)} / ${_catLabel(t.category)}$c$rep${att.isNotEmpty ? ' ｜ $att' : ''}');
    }
    if (includeTrash && _trash.isNotEmpty) {
      buf.writeln('');
      buf.writeln('## 回收站（${_trash.length}）');
      for (final t in _trash) {
        final d = t.deletedAt == null ? '' : ' ｜ 删除于 ${_fmt(t.deletedAt!)}';
        final att = _attachmentSummary(t, includeAttachments);
        buf.writeln('- [x] ${_esc(t.title)} ｜ ${_prioLabel(t.priority)} / ${_catLabel(t.category)}$d${att.isNotEmpty ? ' ｜ $att' : ''}');
      }
    }
    return buf.toString();
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  static String _fmtMinute(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  static String _prioLabel(Priority p) =>
      p == Priority.high ? '高' : p == Priority.medium ? '中' : '低';
  static String _catLabel(Category c) =>
      c == Category.work ? '工作' : c == Category.life ? '生活' : '学习';
  static String _esc(String s) {
    final v = s.replaceAll('"', '""');
    // S11 修复：CSV 公式注入防护。以 = + - @ 开头的单元格在 Excel/WPS 中会被当作公式执行
    // （如任务名为 "=HYPERLINK(...)" 时）。前置单引号强制按文本处理（OWASP CSV Injection 惯例）。
    if (v.isNotEmpty && const ['=', '+', '-', '@'].contains(v[0])) {
      return "'$v";
    }
    return v;
  }

  /// P1-10：从任务附件派生「附件：a.jpg(1.2MB), b.m4a(34KB)」摘要文本。
  /// [enabled] 为 false 或任务无附件时返回空串；超长截断省略，避免单元格过大。
  static String _attachmentSummary(Task t, bool enabled) {
    if (!enabled || t.attachments.isEmpty) return '';
    final parts = t.attachments
        .map((ref) => '${ref.fileName}(${ref.sizeLabel})')
        .toList();
    var s = '附件：${parts.join(', ')}';
    if (s.length > 200) s = '${s.substring(0, 197)}…';
    return s;
  }

  /// 新建任务时按 dueDate 调度本地通知
  Future<void> scheduleFor(Task task) async {
    await NotificationService.instance.scheduleForTask(task);
  }

  /// 为单个任务调度其全部本地提醒（截止提醒 + 重复提醒）。
  /// 重复提醒只在「有截止日期且截止日期未过」时才调度，逾期后自动停止。
  void _scheduleRemindersFor(Task t) {
    if (t.dueDate != null) {
      NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
    }
    if (t.isRepeating && t.repeatMinute != null &&
        t.dueDate != null && !_dateHasPassed(t.dueDate!)) {
      NotificationService.instance.scheduleRepeatReminder(t, playSound: _soundEnabled);
    }
  }

  /// 取消单个任务的全部本地提醒（截止提醒 + 重复提醒）。
  void _cancelRemindersFor(String id) {
    NotificationService.instance.cancel(id);
    NotificationService.instance.cancelRepeatReminder(id);
  }

  /// 重复任务完成态变更后（toggleDone / setStatus / 取消完成）重排其重复提醒。
  /// 仅当任务仍「未过截止日」才挂；具体「是否跳过今日」由通知服务依据
  /// [Task.done] + [Task.completedAt] 是否为今天自行判断（当天已完成→挂明天）。
  void _rescheduleRepeatOnCompletion(Task t) {
    if (t.isRepeating &&
        t.repeatMinute != null &&
        t.dueDate != null &&
        !_dateHasPassed(t.dueDate!)) {
      NotificationService.instance.scheduleRepeatReminder(t, playSound: _soundEnabled);
    }
  }

  /// 非重复任务完成态变更后：取消 / 恢复其一次性「截止时间提醒」。
  /// - 完成（含提前完成）：取消已调度的截止提醒，避免到期后仍弹出。
  /// - 取消完成：若截止时间未过，恢复调度。
  /// 重复任务不在此处理——其整体截止提醒仍有效（只是当天完成由
  /// [_rescheduleRepeatOnCompletion] 跳过今日重复提醒），故直接跳过。
  void _reconcileDeadlineOnCompletion(Task t) {
    if (t.isRepeating) return;
    if (t.done) {
      NotificationService.instance.cancel(t.id);
    } else if (t.dueDate != null && t.dueDate!.isAfter(DateTime.now())) {
      NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
    }
  }

  /// 统一重排所有活动任务的提醒：未完成且未过期的截止提醒 + 未过期的重复提醒。
  /// 用于开关/声音变化、启动时刷新。
  void _rescheduleAllActive() {
    final now = DateTime.now();
    for (final t in _tasks) {
      if (!t.done && t.dueDate != null && t.dueDate!.isAfter(now)) {
        NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
      }
      if (t.isRepeating && t.repeatMinute != null &&
          t.dueDate != null && !_dateHasPassed(t.dueDate!)) {
        NotificationService.instance.scheduleRepeatReminder(t, playSound: _soundEnabled);
      }
    }
  }

  /// 两个 int 列表内容是否相等（[List] 默认 == 比较引用，重复星期需按内容比较）。
  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 判断日期是否已完全过去（以「今天 00:00」为界，与 dueDate 的 23:59 语义一致）。
  static bool _dateHasPassed(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(d.year, d.month, d.day).isBefore(today);
  }
}

/// 自动备份快照的轻量描述（供「备份与恢复」面板列出与还原）。
class AutoBackupEntry {
  final DateTime date; // 快照对应的本地日期（YYYY-MM-DD）
  final File file; // 快照文件（App 私有文档目录 backup/auto/ 下）
  const AutoBackupEntry({required this.date, required this.file});

  /// 友好展示：M月D日。
  String get label => '${date.month}月${date.day}日';
}

/// 监听 App 生命周期：回到前台（resumed）时补一次每日重置检查，
/// 覆盖「App 后台挂了一夜、系统节流了周期守护」的边界。
class _LifecycleObserver extends WidgetsBindingObserver {
  final TaskProvider _provider;
  _LifecycleObserver(this._provider);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _provider.checkDailyReset();
    }
  }
}
