import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:todolist/services/app_log.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/csv_safe.dart';
import 'package:todolist/services/backup_crypto.dart';
import 'package:todolist/services/secure_window.dart';
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
  /// 提醒若落在勿扰区间，自动顺延到时段结束 + 5 分钟再弹。
  /// v2.8.5（F-3）起重复 / 习惯提醒同样逐落点感知勿扰（此前注释称
  /// 「重复/习惯提醒不动」已过时——现在任何落点撞进区间都会被顺延）。
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
    // P2-5'：勿扰时段/开关变更后必须重排已调度通知。
    // 此前只有「通知开关 / 声音开关」会重排，导致「周一排的周三 23:30 提醒，
    // 周二才开勿扰 22:00-07:00」时旧闹钟照常深夜弹出；反向关闭也恢复不了顺延。
    // P3-3：落点内容缓存里冻结了按旧勿扰窗口顺延的结果，必须一并清掉，
    // 否则缓存命中会让「新勿扰窗口」在当日剩余时间里不被消费。
    NotificationService.instance.clearOccurrenceMemo();
    if (_notificationsEnabled) _rescheduleAllActive();
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

  /// F7：全库「完成日 → 完成次数」映射（occurrence 级，date-only）。
  ///
  /// 这是全部完成类统计的**单一事实源**。此前统计只读 [Task.completedAt] 单槽，
  /// 而重复任务的 completedAt 会在午夜重置时被清空 → 「连续 30 天完成每天喝水」
  /// 在热力图 / 周报 / 连续天数上只算 1 天。现在按「任务 × 完成日」去重计数，
  /// 一次性任务（doneDates 为空、仅 completedAt）与历史数据同样正确。
  Map<DateTime, int> get completionDayCounts {
    final map = <DateTime, int>{};
    for (final t in _tasks) {
      final keys = <String>{...t.doneDates};
      if (t.done && t.completedAt != null) keys.add(_ymd(t.completedAt!));
      for (final k in keys) {
        final d = _parseYmdSafe(k);
        if (d == null) continue;
        map[d] = (map[d] ?? 0) + 1;
      }
    }
    return map;
  }

  /// 解析 yyyy-MM-dd 串为 date-only [DateTime]；非法串返回 null（避免脏数据污染统计）。
  static DateTime? _parseYmdSafe(String s) {
    final parts = s.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    return DateTime(y, m, d);
  }

  /// 本周（周一 00:00 – 周日 23:59:59）已完成的任务数。
  /// F7：改按 [completionDayCounts] 的 occurrence 级口径统计——重复任务本周
  /// 完成 3 次即计 3 次，而不是被午夜重置抹成 1 次。
  int get weeklyCompletedCount {
    final start = _mondayOf(DateTime.now());
    final end = start.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
    int n = 0;
    for (final entry in completionDayCounts.entries) {
      if (!entry.key.isBefore(start) && !entry.key.isAfter(end)) n += entry.value;
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
  /// P2-17：最近一次成功快照的日期也持久化。此前只存内存，每次冷启动都会重写
  /// 当日快照（拖慢启动）；加密开关切换当天还会出现「明文 + 加密」两份并存，
  /// 挤占 7 份滚动名额，与面板文案「保留最近 7 天」不符。
  static const String _kLastAutoBackup = 'last_auto_backup_date';
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

  // ===== 隐私加固（安全审计 L-06 / L-07 / L-12）=====
  /// L-06：锁屏是否隐藏通知正文（默认 **隐藏**）。
  ///
  /// Android 通知默认 `PUBLIC`，锁屏会完整显示任务标题；而用户开了应用锁却管不到
  /// 锁屏，隐私承诺存在缺口。默认隐藏后，锁屏只提示「有 N 条待办提醒」。
  static const String _kLockScreenPrivate = 'lock_screen_private';
  bool _lockScreenPrivate = true;
  bool get lockScreenPrivate => _lockScreenPrivate;
  Future<void> setLockScreenPrivate(bool v) async {
    if (v == _lockScreenPrivate) return;
    _lockScreenPrivate = v;
    // 立即同步给通知服务，后续新建的通知即按新可见性投递。
    NotificationService.lockScreenPrivate = v;
    notifyListeners();
    await _persistSettings();
  }

  /// L-07：是否禁止截屏 / 录屏（FLAG_SECURE，默认 **开启**）。
  ///
  /// 未开启时最近任务缩略图会完整定格任务内容，任意录屏 / 投屏软件也能录制界面。
  static const String _kScreenSecurity = 'flag_secure';
  bool _screenSecurityEnabled = true;
  bool get screenSecurityEnabled => _screenSecurityEnabled;
  Future<void> setScreenSecurityEnabled(bool v) async {
    if (v == _screenSecurityEnabled) return;
    _screenSecurityEnabled = v;
    notifyListeners();
    await _persistSettings();
    // 运行时切换窗口标志（失败静默，不影响设置项本身）。
    unawaited(SecureWindow.setFlagSecure(v));
  }

  /// L-12：是否允许点击备注里的 http(s) 链接唤起外部浏览器。
  ///
  /// 默认 **关闭**——本 App 定位为「除检查更新外不联网」，点击链接会离开本地
  /// 并由浏览器发起联网。关闭时点击链接只复制链接并提示，不静默外跳。
  static const String _kAllowExternalLinks = 'allow_external_links';
  bool _allowExternalLinks = false;
  bool get allowExternalLinks => _allowExternalLinks;
  Future<void> setAllowExternalLinks(bool v) async {
    if (v == _allowExternalLinks) return;
    _allowExternalLinks = v;
    notifyListeners();
    await _persistSettings();
  }

  // ===== L-08：本地自动备份加密 =====
  /// 是否加密每日自动快照（默认关闭）。开启后快照写为 `YYYY-MM-DD.enc.json`，
  /// 复用手动备份的 AES-256-GCM + PBKDF2 信封。
  static const String _kAutoBackupEncrypt = 'auto_backup_encrypt';
  bool _autoBackupEncrypt = false;
  bool get autoBackupEncrypt => _autoBackupEncrypt;

  /// 自动备份口令的密钥库后端（P1-1 修复）。
  ///
  /// 旧实现把口令以明文写在 SharedPreferences 的 XML 里（路径
  /// `/data/data/com.example.todolist/shared_prefs/`），任何有 ADB / root
  /// 权限的应用都能直接读出口令。改为 `flutter_secure_storage`：
  /// - Android 走 EncryptedSharedPreferences（底层 AES-256 + Android 密钥库），
  ///   口令不再以明文落在磁盘上；
  /// - iOS 走 Keychain。
  /// 该后端使用独立的存储文件，与主 SharedPreferences 互不干扰。
  ///
  /// 能力边界（与旧实现一致，须如实告知用户）：它防的是「口令被静态读出」，
  /// **不**防已取得 root / 物理接触并能读取 App 私有目录、且逆向密钥库实现的攻击者。
  /// 设置页文案已同步收紧。
  static const FlutterSecureStorage _secureStore = FlutterSecureStorage(
    // v11 起 AndroidOptions 默认即 AES-GCM + Android KeyStore 硬件加密，
    // 不再需要（也已移除）encryptedSharedPreferences 选项。
    aOptions: AndroidOptions(),
  );
  static const String _kSecureAutoBackupPass = 'auto_backup_pass';
  /// 旧版（v2.7.9 之前）明文存储口令的 SharedPreferences key，仅用于一次性迁移。
  static const String _kAutoBackupPassLegacy = 'auto_backup_pass';

  /// 自动备份口令。仅保存在本机密钥库（见 [_secureStore]），**不纳入备份白名单**
  /// （见 prefs_backup.dart）——换机恢复后不会带走它，届时若开关仍处于开启态，
  /// 自动备份会以「口令缺失」显式失败并提示重设，绝不静默降级为明文。
  ///
  /// 能力边界：它防的是「快照文件被单独拷出后可读」（文件管理器、ADB pull、
  /// 误分享等）以及「口令在磁盘上以明文静态存储」，**不**防已取得 root / 物理接触
  /// 并能逆向密钥库实现的攻击者（那种场景下口令仍可能被读出）。设置页文案需如实说明这一点。
  String? _autoBackupPass;
  bool get hasAutoBackupPassphrase =>
      _autoBackupPass != null && _autoBackupPass!.isNotEmpty;

  /// 从密钥库载入口令；兼容旧版曾明文存于 SharedPreferences 的情况，
  /// 读到旧值后迁移进密钥库并删除明文副本。
  ///
  /// P2-11：迁移是「写密钥库 → 删明文」两步操作，进程若在两步之间被杀，
  /// 下次启动 `secureStore.read` 已能读到值，迁移分支不再执行，
  /// 明文口令就永久残留在 shared_prefs XML 里。现改为**每次启动都尝试清理**
  /// legacy key（只要密钥库里已有口令，或本次刚写入成功），把两步收敛为幂等。
  Future<void> _loadAutoBackupPass() async {
    String? pass = await _secureStore.read(key: _kSecureAutoBackupPass);
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_kAutoBackupPassLegacy);
    if (pass == null) {
      // 旧版兼容：口令曾明文存于 SharedPreferences，迁移到密钥库后删除明文。
      if (legacy != null && legacy.isNotEmpty) {
        await _secureStore.write(key: _kSecureAutoBackupPass, value: legacy);
        pass = legacy;
      }
    }
    // 无论本次是否发生迁移：只要密钥库已有口令（或刚写入成功），
    // legacy 明文副本就是冗余且危险的，无条件清理（幂等）。
    if (legacy != null && pass != null && pass.isNotEmpty) {
      await prefs.remove(_kAutoBackupPassLegacy);
    }
    _autoBackupPass = pass;
  }

  /// 设置 / 更新自动备份口令（不为空即可，长度下限 6 由 UI 侧校验）。
  /// 空串表示清空口令，从密钥库删除而非写入空值。
  Future<void> setAutoBackupPassphrase(String pass) async {
    _autoBackupPass = pass;
    if (pass.isEmpty) {
      await _secureStore.delete(key: _kSecureAutoBackupPass);
    } else {
      await _secureStore.write(key: _kSecureAutoBackupPass, value: pass);
    }
    notifyListeners();
  }

  /// 校验输入是否与密钥库中现存口令一致（F15「修改口令」先验证旧口令用）。
  /// 密钥库中无口令时恒返回 false（无从比对）。
  bool verifyAutoBackupPassphrase(String pass) {
    final cur = _autoBackupPass;
    if (cur == null || cur.isEmpty) return false;
    return pass == cur;
  }

  /// F15：修改 / 重设自动备份口令。
  ///
  /// - 记得旧口令：[oldPass] 传入并校验通过后才写入新口令（返回 -1 = 旧口令不对）。
  /// - 忘记旧口令：[oldPass] 传 null（或 [force]=true）强制重设——调用方必须在 UI 上
  ///   明示后果：**历史加密快照将永远无法解开**，本操作只保证此后的快照可用新口令打开。
  /// - 同时清掉 legacy 明文副本（若仍残留），避免换口令后旧明文仍躺在 shared_prefs。
  ///
  /// P2-4（v2.8.6 审计）：换口令成功后，把 `backup/auto/` 里旧口令加密的快照
  /// 统一改名标记为 stale（见 [_markStaleEncryptedBackups]）。
  /// 返回值：-1 = 修改失败；否则 = 被标记的旧加密快照数（0 = 没有旧快照）。
  Future<int> changeAutoBackupPassphrase(
    String newPass, {
    String? oldPass,
    bool force = false,
  }) async {
    if (newPass.isEmpty) return -1;
    if (!force) {
      if (oldPass == null || !verifyAutoBackupPassphrase(oldPass)) return -1;
    }
    await setAutoBackupPassphrase(newPass);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kAutoBackupPassLegacy);
    } catch (_) {
      // 明文副本清理失败不阻断换口令主流程。
    }
    // P2-4：旧加密快照无法再用新口令解开。改名标记后恢复面板不再展示，
    // 滚动保留按日期自然淘汰，避免用户对着「废快照」反复试错口令。
    return _markStaleEncryptedBackups();
  }

  /// P2-4：把 `backup/auto/` 下所有 `.enc.json` 加密快照改名为
  /// `<日期>.stale.enc.json`（日期部分保持不变）。
  ///
  /// - 恢复面板（[listAutoBackups]）跳过 stale 文件——它们已不可用当前口令解开；
  /// - 滚动保留（[_rotateAutoBackups]）仍按文件名日期把它们当最旧的一批淘汰，
  ///   约 7 天内自然清完，无需立即删除（保留文件本体，万一用户找回旧口令仍可手工解）。
  /// 返回成功改名的文件数；失败逐文件静默，不阻断换口令主流程。
  Future<int> _markStaleEncryptedBackups() async {
    var n = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/backup/auto');
      if (!await base.exists()) return 0;
      for (final f in base.listSync().whereType<File>().toList()) {
        final name = _autoBackupName(f);
        if (!name.endsWith('.enc.json') || name.contains('.stale.')) continue;
        try {
          final newPath =
              '${f.path.substring(0, f.path.length - '.enc.json'.length)}'
              '.stale.enc.json';
          await f.rename(newPath);
          n++;
        } catch (_) {}
      }
    } catch (e) {
      AppLog.d('标记旧口令快照失败（忽略）：$e');
    }
    return n;
  }

  /// 开关自动备份加密。开启时若尚无口令则拒绝（返回 false），由 UI 引导先设口令。
  Future<bool> setAutoBackupEncrypt(bool v) async {
    if (v && !hasAutoBackupPassphrase) return false;
    _autoBackupEncrypt = v;
    notifyListeners();
    await _persistSettings();
    if (v) {
      // 开启后立刻按新策略重试一次（今天已生成过明文快照也不会重写，
      // 加密从下一次跨日快照开始生效，避免同一天出现两种形态）。
      try {
        await _autoBackupIfNeeded();
      } catch (_) {}
    }
    return true;
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

  // ===== P1-2：无操作自动锁定（应用锁增强）=====
  /// 解锁后无操作多久自动重新上锁，单位秒。0 = 永不（仅依赖「回到前台」锁定）。
  /// 可选值：0 / 30 / 60 / 300。仅在应用锁开启（AppLockProvider.appLockEnabled）时生效。
  static const String _kAppLockIdleSeconds = 'app_lock_idle_seconds';
  int _appLockIdleSeconds = 0;
  int get appLockIdleSeconds => _appLockIdleSeconds;
  /// 解析为 Duration；<=0 视为「永不」（返回 null）。
  Duration? get appLockIdleDuration =>
      _appLockIdleSeconds <= 0 ? null : Duration(seconds: _appLockIdleSeconds);
  Future<void> setAppLockIdleSeconds(int seconds) async {
    if (seconds == _appLockIdleSeconds) return;
    _appLockIdleSeconds = seconds;
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
  ///
  /// P2-23：原实现循环内逐条 `updateTask`，每条都会 notifyListeners + 全量落库，
  /// 500 条任务的标签重命名 = 501 次全量序列化。现改为循环内只改内存
  /// （[`_applyTaskUpdate`] 不 notify / 不落库），循环后统一 notify + 落库一次。
  Future<void> renameTag(String oldName, String newName) async {
    if (oldName == newName || newName.trim().isEmpty) return;
    final trimmed = newName.trim();
    var changed = false;
    for (final t in _tasks) {
      if (t.tags.contains(oldName)) {
        final newTags = t.tags.map((e) => e == oldName ? trimmed : e).toList();
        if (_applyTaskUpdate(t.copyWith(tags: newTags))) changed = true;
      }
    }
    // 归档状态迁移：旧标签已归档 → 新标签继承归档状态
    if (_archivedTags.remove(oldName)) {
      _archivedTags.add(trimmed);
    }
    if (changed) {
      notifyListeners();
      await _persist();
    }
    await _persistTagArchive();
  }

  /// 合并标签：把 [source] 标签的所有任务改为 [target] 标签，然后删除 [source]。
  /// P2-23：同样改为「逐条改内存 + 单次落库」，消除 N 倍写放大。
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
        if (_applyTaskUpdate(t.copyWith(tags: newTags))) changed = true;
      }
    }
    _archivedTags.remove(source);
    if (changed) {
      notifyListeners();
      await _persist();
    }
    await _persistTagArchive();
  }

  /// 删除标签：从所有任务中移除 [name]。
  /// P2-23：同样改为「逐条改内存 + 单次落库」。
  Future<void> deleteTag(String name) async {
    var changed = false;
    for (final t in _tasks) {
      if (t.tags.contains(name)) {
        final newTags = t.tags.where((e) => e != name).toList();
        if (_applyTaskUpdate(t.copyWith(tags: newTags))) changed = true;
      }
    }
    _archivedTags.remove(name);
    if (changed) {
      notifyListeners();
      await _persist();
    }
    await _persistTagArchive();
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
      // P2-17：落盘最近成功日期，避免重启重复写当日快照 / 同日双形态并存。
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastAutoBackup, todayKey);
    } catch (e, s) {
      _lastAutoBackupError = '自动备份失败：$e';
      AppLog.d('$_lastAutoBackupError\n$s');
    }
    notifyListeners();
  }

  /// 供 [main] 在所有 Provider（FocusProvider / HabitProvider）加载完成后显式触发一次
  /// 跨日快照。必须在单例注册之后调用，否则快照内 focus_sessions / 习惯打卡会因
  /// [FocusProvider.instanceOrNull] / [HabitProvider.instanceOrNull] 尚未就绪而恒为空（P0-2）。
  Future<void> triggerAutoBackup() => _autoBackupIfNeeded();

  /// 把当前全部数据（任务 + 回收站 + 偏好 + 专注 + 习惯 + 打卡）写入当日滚动快照。
  /// 文件名 backup/auto/YYYY-MM-DD.json（开启加密时为 .enc.json），复用
  /// [backupData] + 其余 Provider 的导出；用 DataIo 原子写（.tmp + rename）
  /// 避免写入中途打断导致快照损坏。
  ///
  /// L-08：手动备份可以选口令加密，而自动快照此前**恒为明文**，与产品「加密备份」
  /// 的口径不一致（root / 取证 / MDM 场景可直接还原全部隐私数据，用户却无从感知）。
  /// 现在按 [autoBackupEncrypt] 走同一套 AES-GCM 信封。口令缺失时**显式失败**并
  /// 把原因展示在设置页，绝不静默降级为明文（沿用 P0-1 的「不降级」原则）。
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
    final plain = const JsonEncoder.withIndent('  ').convert(payload);
    // L-08：按开关决定是否加密。buildBackupPayload 在「要求加密但无口令」时抛
    // BackupEncryptException，此处不捕获，交由 _autoBackupIfNeeded 记入错误提示。
    final body =
        buildBackupPayload(plain, encryptOn: _autoBackupEncrypt, pass: _autoBackupPass);
    final suffix = _autoBackupEncrypt ? '.enc.json' : '.json';
    await DataIo.saveToAppDocs('backup/auto/${_dateKey(now)}$suffix', body);
    _rotateAutoBackups();
  }

  /// 滚动保留：仅保留最近 7 份当日快照（backup/auto/ 目录），删除更早的。
  /// 明文（YYYY-MM-DD.json）与加密（YYYY-MM-DD.enc.json）快照一并计入，
  /// 排序用文件名前缀的日期串（YYYY-MM-DD 字典序=时间序），与扩展名无关。
  /// 失败静默，不阻断主流程。
  Future<void> _rotateAutoBackups() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/backup/auto');
      if (!await base.exists()) return;
      final all = base.listSync().whereType<File>().toList();
      // P2-18：原子写中断留下的 .tmp / .bak 残片（含附件 base64，可达数十 MB）
      // 此前既不参与滚动清理、也不展示给用户，属于「看不到也删不掉」的永久泄漏。
      // 这里无条件清理（只认 .json 为有效快照）。
      for (final f in all) {
        if (!f.path.endsWith('.json')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      final files = all.where((f) => f.path.endsWith('.json')).toList();
      // 旧→新：按文件名（含日期）比较，'.' < '-'，故 .enc.json 与 .json 同日排序稳定。
      files.sort((a, b) => _autoBackupName(a).compareTo(_autoBackupName(b)));
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
      AppLog.d('滚动快照清理失败（忽略）：$e');
    }
  }

  /// 取快照文件名（不含目录），用于排序。
  static String _autoBackupName(File f) =>
      f.path.split(RegExp(r'[\\/]')).last;

  /// 列出本地自动备份快照（新→旧），供「备份与恢复」面板还原。
  /// 每项含 date(DateTime)、file(File) 与 encrypted 标记（L-08）。
  Future<List<AutoBackupEntry>> listAutoBackups() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/backup/auto');
      if (!await base.exists()) return const [];
      final files = base
          .listSync()
          .whereType<File>()
          // P2-4：`*.stale.enc.json` 是换口令后已不可解的旧口令快照标记，
          // 不再出现在恢复面板（滚动保留会按日期自然淘汰）。
          .where((f) =>
              f.path.endsWith('.json') &&
              !_autoBackupName(f).contains('.stale.'))
          .toList();
      files.sort((a, b) => _autoBackupName(b).compareTo(_autoBackupName(a))); // 新→旧
      final out = <AutoBackupEntry>[];
      for (final f in files) {
        final name = _autoBackupName(f);
        // 文件名形如 YYYY-MM-DD.json 或 YYYY-MM-DD.enc.json（加密快照）
        final encrypted = name.endsWith('.enc.json');
        final key = encrypted
            ? name.substring(0, name.length - '.enc.json'.length)
            : name.substring(0, name.length - '.json'.length);
        final parts = key.split('-');
        if (parts.length == 3) {
          final y = int.tryParse(parts[0]);
          final m = int.tryParse(parts[1]);
          final d = int.tryParse(parts[2]);
          if (y != null && m != null && d != null) {
            out.add(AutoBackupEntry(
              date: DateTime(y, m, d),
              file: f,
              encrypted: encrypted,
            ));
          }
        }
      }
      return out;
    } catch (e) {
      AppLog.d('列出自动备份失败：$e');
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
    // P2-13：回收站到期自动清理此前只 removeWhere，不删附件目录
    // （对比 permanentDelete / clearTrash 都有 AttachmentService.removeDir），
    // 导致 attachments/<taskId>/ 成孤儿目录持续占空间，也与「到期即销毁」的隐私预期不符。
    final expired = _trash
        .where((t) => t.deletedAt != null && t.deletedAt!.isBefore(cutoff))
        .map((t) => t.id)
        .toList();
    _trash.removeWhere((t) {
      if (t.deletedAt == null) return false; // 无删除时间视为新近，保留
      return t.deletedAt!.isBefore(cutoff);
    });
    for (final id in expired) {
      NotificationService.instance.cancel(id);
      NotificationService.instance.cancelRepeatReminder(id);
      AttachmentService.removeDir(id);
    }
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
      // P2-10：打开开关时重新请求通知权限（若之前被拒可再次弹窗）。
      // 此前未 await 也不看返回值：用户首启拒绝后界面仍显示「已开启」，
      // 而所有提醒静默失效，只有点「发送测试通知」才会发现。
      final granted = await NotificationService.instance.requestPermission();
      if (granted != null) _lastNotificationPermissionDenied = !granted;
      // 重新调度所有「未完成且未过期」的截止提醒 + 每日提醒，应用新状态
      _rescheduleAllActive();
    } else {
      NotificationService.instance.cancelAll();
    }
    notifyListeners();
    await _persistSettings();
  }

  /// P2-10：最近一次查询到的「通知权限被系统拒绝」状态（null = 未查询/平台不支持）。
  /// 设置页据此提示用户去系统设置开启，避免「开关已开但提醒从不响」的静默失效。
  bool? _lastNotificationPermissionDenied;
  bool? get notificationPermissionDenied => _lastNotificationPermissionDenied;

  /// P2-10：主动查询一次通知权限状态并刷新 [notificationPermissionDenied]。
  /// 在 App 回到前台 / 设置页展示时调用（Android 13+ 才有效）。
  Future<void> refreshNotificationPermission() async {
    final r = await NotificationService.instance.checkPermission();
    _lastNotificationPermissionDenied = (r == null) ? null : !r;
    notifyListeners();
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

  /// P1-1：上一次执行跨天检查时所在的本地日期（yyyy-MM-dd）。
  ///
  /// 跨天判定必须与「列表里是否有内容发生变化」解耦：原实现把简报 / 挽留的一次性
  /// 闹钟重排挂在 [_resetDailyIfNeeded] 的返回值上，而后者只在「恰有已完成且今天是
  /// 循环日的重复任务被重置」时才为 true。用户若**只有一次性任务**（或今天恰好没有
  /// 循环日重复任务），App 后台跨过 00:00 时返回值恒为 false → 不重排 → 次日简报 /
  /// 挽留静默消失。这里改为纯日期比较：只要日边界变了就触发 [onDayChanged]。
  String? _lastResetDay;
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
      AppLog.d('[TaskProvider] 数据库加载失败，进入只读安全模式：$e\n$s');
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
    // F-8（v2.8.5 审计）：interval 任务缺 repeatAnchor 的自愈（详见
    // [_healRepeatAnchors]）。一次性写回数据库，之后不再反复触发。
    if (_healRepeatAnchors()) {
      await _persist();
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
    // P2-17：恢复最近一次成功快照日期（无记录则回退 null，本次启动会补写）。
    final lastBackup = prefs.getString(_kLastAutoBackup);
    if (lastBackup != null && lastBackup.length >= 10) {
      final y = int.tryParse(lastBackup.substring(0, 4));
      final m = int.tryParse(lastBackup.substring(5, 7));
      final d = int.tryParse(lastBackup.substring(8, 10));
      if (y != null && m != null && d != null) {
        _lastAutoBackupDate = DateTime(y, m, d);
      }
    }
    _archivedTags = (prefs.getStringList(_kArchivedTags) ?? []).toSet(); // P1-13
    _calendarLunar = prefs.getBool(_kCalendarLunar) ?? true; // P0-3
    // L-06 / L-07 / L-12：隐私相关开关（默认值见各字段注释）。
    _lockScreenPrivate = prefs.getBool(_kLockScreenPrivate) ?? true;
    NotificationService.lockScreenPrivate = _lockScreenPrivate;
    _screenSecurityEnabled = prefs.getBool(_kScreenSecurity) ?? true;
    _allowExternalLinks = prefs.getBool(_kAllowExternalLinks) ?? false;
    _autoBackupEncrypt = prefs.getBool(_kAutoBackupEncrypt) ?? false;
    // P1-1：口令改从密钥库读取（含旧版明文迁移），不再读 SharedPreferences 明文副本。
    await _loadAutoBackupPass();
    _appLockIdleSeconds = prefs.getInt(_kAppLockIdleSeconds) ?? 0; // P1-2
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
    // P1-1：记录本次启动的日边界基线——启动阶段 main.dart 已显式重排过一次简报 /
    // 挽留，这里同步基线可避免紧随其后的第一次 15 分钟守护再做一次冗余重排。
    _lastResetDay = _ymd(DateTime.now());
    // 挂上「当天 00:00 自动重置」的午夜闹钟（不依赖 App 是否打开）。
    NotificationService.instance.armMidnightReset();
    // 启动时为已有「未完成且未过期」的任务 + 每日提醒重新调度（老任务/初始 mock 也能响）
    if (_notificationsEnabled) _rescheduleAllActive();
    _recomputeIdSeq();
    _startMidnightWatch();
    notifyListeners();
  }

  /// 把「已完成、且今天是其循环日、且上次完成早于今天」的重复任务重置为未完成。
  /// 返回是否发生了变更（仅在变更时落盘 + 通知 UI）。与原生 MidnightResetReceiver 逻辑一致。
  ///
  /// F-1 连带：此前这里额外要求 `dueDate == null || !_dateHasPassed(dueDate)`，
  /// 而录入侧把重复任务的截止日钉成「创建当天 23:59」——创建次日该条件恒为 false，
  /// 于是「每天喝水」第二天**永远不会被重置回未完成**，一直挂在「已完成」区，
  /// 与 [Task.isRepeatEnded] / [Task.repeatsOn] 两套判定脱节。
  /// 重复任务是否继续循环只由 `repeatsOn`（内含 repeatUntil + skipDates）决定。
  bool _resetDailyIfNeeded() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var dailyDirty = false;
    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.isRepeating &&
          t.status == TaskStatus.done &&
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
  ///
  /// F5 / F-2：本 App 的全部重复提醒都是**一次性**闹钟，响过一次后不会自动挂
  /// 下一个周期；而本 App 默认开启「后台提醒守护」保进程常驻，用户恰恰最不容易
  /// 重启 App——「每隔 3 天浇水」「每天 7:00 喝水」响一次后就此静默失踪。
  /// 这里在每次回到前台 / 每 15 分钟守护周期补挂一次全部重复提醒（见
  /// [_rescheduleOneShotReminders]）。
  void checkDailyReset() {
    // P1-1：先单独判定「日边界是否真的变了」，与列表内容变化解耦。
    // 只有一次性任务的用户跨天时 _resetDailyIfNeeded() 恒为 false，旧实现因此
    // 永不重排简报 / 挽留（次日静默断更）。这里以日期为准，与列表内容无关。
    // 基线未知（null，未走过 load）时按「已跨天」处理——宁可多排一次，不可漏排。
    final today = _ymd(DateTime.now());
    final dayChanged = _lastResetDay != today;
    _lastResetDay = today;
    final changed = _resetDailyIfNeeded();
    if (_notificationsEnabled) _rescheduleOneShotReminders();
    // F-2：习惯打卡提醒同样是一次性闹钟，需在每次守护周期补挂（见 [onGuardTick]）。
    if (_notificationsEnabled) onGuardTick?.call();
    if (changed || dayChanged) {
      // F-07：简报 / 习惯挽留已改为一次性闹钟（不再由系统按天重发），
      // 跨天时必须重排，否则 App 一直挂在前台跨过 00:00 后次日就没有简报了。
      // 钩子由 main.dart 注入，避免 TaskProvider 反向依赖 daily_briefing（会成环）。
      onDayChanged?.call();
      notifyListeners();
    }
  }

  /// F-07：跨天回调（由 main.dart 注册为重排简报 / 习惯挽留）。可空，未注册时静默跳过。
  static void Function()? onDayChanged;

  /// F-2：每次周期守护都**无条件**回调一次，供 main.dart 重挂「一次性闹钟」类提醒。
  ///
  /// 习惯打卡提醒与任务重复提醒同属一次性闹钟（不再由 OS 周期循环承载），
  /// 必须在进程存活期间持续补挂，否则预挂的若干次响完后就会静默断档。
  /// 与 [onDayChanged] 区分：后者只在「日边界真的变了」时触发。
  /// 回调实现必须幂等且自带代价控制（通知服务的落点签名缓存已能跳过多余下发）。
  static void Function()? onGuardTick;

  /// F5 / F-03 / F-2：为「一次性闹钟」类重复任务重挂下一次 occurrence。
  ///
  /// F-2 起**全部**重复类型的提醒都改为一次性闹钟（见 notification_service
  /// `scheduleRepeatReminder` 的说明），不再有任何任务依赖 OS 的
  /// `matchDateTimeComponents` 周期循环，因此这里统一覆盖所有重复任务：
  /// - interval（每隔 N 天）：系统没有该原语，只能排一次性闹钟；
  /// - monthly 的复杂规则（每月最后一天 / 倒数第 N 天 / 第 N 个周几 / 29~31 号）：
  ///   目标日每月都在变或在某些月份不存在，交给系统按「号」循环会日期漂移 / 漏响（F-03）；
  /// - daily / weekly / weekday / 简单 monthly：系统周期闹钟无法消费
  ///   `skipDates` 与 `repeatUntil`（「没到点就本次跳过」无效、提前跳过未来某个
  ///   星期无效、结束日到期后长期不开 App 仍照响），故同样按一次性处理。
  ///
  /// 与 [_rescheduleAllActive] 区分：后者是全量重排（含一次性截止提醒），代价更高，
  /// 不适合每 15 分钟跑一次；这里只补挂真正会丢的那部分。
  void _rescheduleOneShotReminders() {
    for (final t in _tasks) {
      if (!t.isRepeating) continue;
      if (!shouldScheduleRepeatReminder(t)) continue;
      NotificationService.instance
          .scheduleRepeatReminder(t, playSound: _soundEnabled);
    }
  }

  /// App 在前台/后台存活期间的轻量守护：周期性（15 分钟）+ 回到前台时检查「日期是否已跨天」，
  /// 若跨天则重置每日任务。原生午夜闹钟负责「App 已关闭」的情况，本守护负责「App 正开着」的边界。
  void _startMidnightWatch() {
    if (_midnightWatchStarted) return; // 防止 load() 重复调用叠加观察者/定时器
    _midnightWatchStarted = true;
    // 周期性检查（App 进程存活时有效）
    //
    // F-06 修复：循环体此前没有 try/catch，`checkDailyReset()`（内含跨天重置 +
    // 通知重排）一旦抛出任何异常，整个 Future 立即进入错误态并被**永久**终止，
    // 之后不再有任何 15 分钟轮询，interval / 复杂月重复的一次性闹钟静默失效，
    // 且没有任何报错——直到用户下次冷启动。这里整体包 try/catch：
    // 记录日志后始终返回 true，让守护活到进程结束。
    Future.doWhile(() async {
      await Future.delayed(const Duration(minutes: 15));
      try {
        checkDailyReset();
      } catch (e, s) {
        AppLog.d('[守护] 周期检查异常（已忽略，继续循环）：$e\n$s');
      }
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
    // L-06 / L-07 / L-12：隐私开关。口令单独存（不进 prefs 备份白名单）。
    await prefs.setBool(_kLockScreenPrivate, _lockScreenPrivate);
    await prefs.setBool(_kScreenSecurity, _screenSecurityEnabled);
    await prefs.setBool(_kAllowExternalLinks, _allowExternalLinks);
    await prefs.setBool(_kAutoBackupEncrypt, _autoBackupEncrypt);
    await prefs.setInt(_kAppLockIdleSeconds, _appLockIdleSeconds); // P1-2
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
      AppLog.d('TaskProvider 持久化失败（变更仅存于内存，重启将回退）：$e\n$s');
    }
  }

  /// F-8（v2.8.5 审计）：interval 任务缺 [Task.repeatAnchor] 的自愈。
  ///
  /// 此前锚点缺失（旧备份 / 手改数据库）时任务仍带着「每隔 N 天」标签出现在
  /// 列表，但 [Task._baseRepeatsOn] 对 anchor==null 恒返回 false——永远不是
  /// 循环日、永远不提醒的「哑循环」，且无任何异常提示、无修复入口。
  /// 这里补锚点为「今天」（date-only，无 createdAt 字段可用，取当日使循环
  /// 从载入当天重新起算），并返回是否有修复、由调用方统一落库。
  /// 只在 load / 覆盖恢复时执行（一次性自愈 + 持久化），避免每次解析都漂移。
  bool _healRepeatAnchors() {
    var changed = false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.repeat == RepeatType.interval && t.repeatAnchor == null) {
        _tasks[i] = t.copyWith(repeatAnchor: today);
        changed = true;
        AppLog.d('[F-8] interval 任务缺锚点已补为今天：id=${t.id} "${t.title}"');
      }
    }
    return changed;
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

  /// 近 7 日每日完成数（旧→新）。F7：按 occurrence 级 [completionDayCounts] 统计。
  List<int> get weekTrend {
    final days = weekTrendDates;
    final counts = List.filled(7, 0);
    final src = completionDayCounts;
    for (var i = 0; i < days.length; i++) {
      counts[i] = src[days[i]] ?? 0;
    }
    return counts;
  }

  /// 上一周（往前 8-14 天）每日完成数（旧→新），用于环比。
  /// F7：同样改按 occurrence 级统计口径。
  List<int> get lastWeekTrend {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = List.generate(7, (i) => today.subtract(Duration(days: 13 - i)));
    final counts = List.filled(7, 0);
    final src = completionDayCounts;
    for (var i = 0; i < days.length; i++) {
      counts[i] = src[days[i]] ?? 0;
    }
    return counts;
  }

  /// 有完成记录（当天 ≥1 个完成任务）的所有日期（date-only）。
  /// F7：来源由「遍历 completedAt」改为 [completionDayCounts]，
  /// 重复任务被午夜重置掉的历史完成日不再丢失。
  Set<DateTime> get completionDays => completionDayCounts.keys.toSet();

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
  /// F7：改按 [completionDayCounts] 统计，重复任务的历史完成日不再因午夜重置而消失。
  Map<DateTime, int> completionsInMonth(DateTime monthAnchor) {
    final map = <DateTime, int>{};
    for (final entry in completionDayCounts.entries) {
      final d = entry.key;
      if (d.year == monthAnchor.year && d.month == monthAnchor.month) {
        map[d] = entry.value;
      }
    }
    return map;
  }

  /// 某月累计完成数（日历页顶部概览用）。
  int completionsInMonthCount(DateTime monthAnchor) =>
      completionsInMonth(monthAnchor).values.fold(0, (a, b) => a + b);

  /// 某天完成的所有任务，按完成时间倒序；点击日历格查看当天明细用。
  /// F7：命中条件改为 [Task.isDoneOn]——重复任务当天完成但已被午夜重置为未完成
  /// 时，仍然要出现在「那天完成了什么」的明细里。
  List<Task> tasksCompletedOn(DateTime day) {
    final d = _dateOnly(day);
    final list = _tasks.where((t) => t.isDoneOn(d)).toList();
    list.sort((a, b) {
      final ca = a.completedAt ?? d;
      final cb = b.completedAt ?? d;
      return cb.compareTo(ca);
    });
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

    final now = DateTime.now();
    // P2-1：「结束重复」（repeatUntil = 昨天）后，重复任务不再属于「重复」分区，
    // 回落到日期分区——此前弹窗承诺「今天起不再出现」，首页却仍把它留在重复区。
    // 口径统一为 [Task.isRepeatEnded]，与首页 / 分享卡片 / 拖拽落点共用。
    bool inRepeat(Task t) => t.isRepeating && !t.isRepeatEnded(now);

    final stillRepeating = _tasks.where((t) => !t.done && inRepeat(t)).length;
    final overdue = _tasks.where((t) {
      if (t.done || inRepeat(t)) return false;
      return (dayDiff(_effectiveDue(t, now)) ?? 0) < 0;
    }).length;
    final today = _tasks.where((t) {
      if (t.done || inRepeat(t)) return false;
      final ed = _effectiveDue(t, now);
      return dayDiff(ed) == 0 || ed == null;
    }).length;
    final future = _tasks.where((t) {
      if (t.done || inRepeat(t)) return false;
      final d = dayDiff(_effectiveDue(t, now));
      return d != null && d > 0;
    }).length;
    final done = _tasks.where((t) => t.done).length;
    return {
      'overdue': overdue,
      'today': today,
      'future': future,
      'repeat': stillRepeating,
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

    final now = DateTime.now();
    // P2-1 / F6：重复分区口径统一为「仍在循环期内」（[Task.isRepeatEnded]），
    // 「结束重复」后的任务回落到日期分区，与 [sectionCounts] 完全一致。
    bool inRepeat(Task t) => t.isRepeating && !t.isRepeatEnded(now);

    // 未完成 + 非（仍在循环的）重复任务，按截止日期切分为 逾期 / 今天 / 未来。
    // F-5：已结束的重复任务用 [_effectiveDue] 中性化其过期占位截止日。
    final active = _tasks.where((t) => !t.done && !inRepeat(t)).toList();
    final overdue = active
        .where((t) => (dayDiff(_effectiveDue(t, now)) ?? 0) < 0)
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
        .where((t) {
          final ed = _effectiveDue(t, now);
          return dayDiff(ed) == 0 || ed == null;
        })
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
      final d = dayDiff(_effectiveDue(t, now));
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
    final repeat = _tasks.where((t) => !t.done && inRepeat(t)).toList()
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
    // P2-1：已结束的重复任务回落到日期分区，与 [homeTasks] / [sectionCounts] 同源。
    if (t.isRepeating && !t.isRepeatEnded(DateTime.now())) return 'repeat';
    final d = _dayDiff(_effectiveDue(t, DateTime.now()));
    if (d == null) return 'today';
    if (d < 0) return 'overdue';
    if (d == 0) return 'today';
    return 'future';
  }

  /// F-5：某任务在「日期分区」判定中应使用的截止日。
  ///
  /// 已结束的重复任务（主动「结束重复」或自然到期）不再把那个早已过期的
  /// 「创建当天 23:59」占位截止日当作真实期限——否则它会以 `d < 0` 被永久归入
  /// 「逾期」分区，每天挂在列表里等用户手动完成 / 删除。
  /// 主动结束已在 [endRepeat] 里直接清空 dueDate；自然到期无法在数据层改写
  /// （判定是派生的），故在此统一中性化，两条路径口径一致。
  static DateTime? _effectiveDue(Task t, DateTime now) =>
      (t.isRepeating && t.isRepeatEnded(now)) ? null : t.dueDate;

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

  /// F-12：对外暴露的「偏好已变更，请重建」入口。
  ///
  /// 备份恢复（[backup_sheet]）写回 SharedPreferences 后需要让设置面板立刻反映新值，
  /// 此前 UI 层直接调 `Provider.of<TaskProvider>(...).notifyListeners()`——
  /// notifyListeners 是 ChangeNotifier 的 **protected** 成员，外部调用会触发
  /// analyzer 的 invalid_use_of_protected_member（当前能跑，但破坏封装、
  /// 依赖框架的内部容忍）。这里给出公开方法，语义也更明确。
  void refreshAfterPrefs() => notifyListeners();

  /// 把任务在 待办/已完成 之间移动（看板拖拽 / 点击切换）。
  void setStatus(String id, TaskStatus s) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final cur = _tasks[i];
    if (cur.status == s) return;
    _tasks[i] = cur.copyWith(
      status: s,
      completedAt: s == TaskStatus.done ? DateTime.now() : null,
      // F7：完成/取消完成同步维护 occurrence 级完成历史。
      doneDates: _withDoneDate(cur, s == TaskStatus.done, DateTime.now()),
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
      // F7：完成/取消完成同步维护 occurrence 级完成历史。
      doneDates: _withDoneDate(_tasks[i], willDone, DateTime.now()),
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

  /// 在 [t.doneDates] 中加入 / 移除 [day]（date-only），保持升序去重。
  /// F7：occurrence 级完成历史的唯一写入口，供完成态切换与循环日「标记完成」共用。
  /// F-7：写回前统一过一遍滚动保留窗口（见 [Task.pruneHistory]），
  /// 避免「每天」任务用几年后把上千条历史内联进单任务 JSON（写放大）。
  static List<String> _withDoneDate(Task t, bool done, DateTime day) {
    final key = _ymd(DateTime(day.year, day.month, day.day));
    final set = <String>{...t.doneDates};
    if (done) {
      set.add(key);
    } else {
      set.remove(key);
    }
    final out = set.toList()..sort();
    return Task.pruneHistory(out, day) ?? out;
  }

  /// F1：把任务在某个循环日标记为完成（occurrence 级）。
  ///
  /// 此前「未来循环日预览 → 标记完成」走的是 `updateTask(copyWith(status: done))`，
  /// 而 `_applyTaskUpdate` 会强制回填旧的 status / completedAt，写入被静默丢弃、
  /// 界面毫无反应——该功能 100% 无效。这里提供显式入口，走与 [toggleDone] 一致的
  /// 完成态 + 重排链路：
  /// - 无论哪一天，都把该日记入 [Task.doneDates]（完成历史不被午夜重置抹除）；
  /// - 若 [day] 恰为今天，同步把任务置为已完成（并触发「今日已完成 → 跳过今日提醒」）。
  void markOccurrenceDone(String taskId, DateTime day) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i == -1) return;
    final cur = _tasks[i];
    final d = DateTime(day.year, day.month, day.day);
    if (cur.isDoneOn(d)) return; // 幂等
    final now = DateTime.now();
    final isToday = d.year == now.year && d.month == now.month && d.day == now.day;
    _tasks[i] = cur.copyWith(
      doneDates: _withDoneDate(cur, true, d),
      status: isToday ? TaskStatus.done : cur.status,
      completedAt: isToday ? now : cur.completedAt,
    );
    if (_tasks[i].isRepeating) {
      _rescheduleRepeatOnCompletion(_tasks[i]);
    }
    notifyListeners();
    _persist();
  }

  /// F1 配套：取消某循环日的完成记录（从 [Task.doneDates] 移除）。
  /// 若 [day] 为今天且任务当前为已完成，则一并取消完成态并恢复今日提醒。
  void unmarkOccurrenceDone(String taskId, DateTime day) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i == -1) return;
    final cur = _tasks[i];
    final d = DateTime(day.year, day.month, day.day);
    if (!cur.doneDates.contains(_ymd(d))) return; // 幂等
    final now = DateTime.now();
    final isToday = d.year == now.year && d.month == now.month && d.day == now.day;
    _tasks[i] = cur.copyWith(
      doneDates: _withDoneDate(cur, false, d),
      status: (isToday && cur.done) ? TaskStatus.todo : cur.status,
      completedAt: (isToday && cur.done) ? null : cur.completedAt,
    );
    if (_tasks[i].isRepeating) {
      _rescheduleRepeatOnCompletion(_tasks[i]);
    }
    notifyListeners();
    _persist();
  }

  /// 本次跳过：把 [day]（默认今天）追加进任务的 [Task.skipDates]。
  /// 跳过 ≠ 完成——当天不出现、不打卡、不影响连续天数；次日恢复正常。
  /// 对 interval 重复任务额外重排提醒，避免「跳过当天仍弹提醒」。
  void skipOccurrence(String taskId, {DateTime? day}) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i == -1) return;
    final d = day ?? DateTime.now();
    final ymd = _ymd(DateTime(d.year, d.month, d.day));
    if (_tasks[i].skipDates.contains(ymd)) return; // 已跳过，幂等
    // F-7：跳过日期在其 occurrence 过去后即无用途，统一走滚动保留窗口清掉。
    final skip2 = [..._tasks[i].skipDates, ymd];
    final updated = _tasks[i].copyWith(
      skipDates: Task.pruneHistory(skip2, d) ?? skip2,
    );
    _tasks[i] = updated;
    // P2-2：此前只有 interval 重排提醒——「每天 07:00 喝水」点「本次跳过」后
    // 列表层生效、07:00 提醒照响，与 occurrence_sheet 的「已跳过」标记自相矛盾。
    // 现对所有重复类型统一重排（daily/weekly/monthly 的 OS 周期闹钟会被
    // 通知服务按新的 skipDates 重新计算首个落点）。
    if (updated.isRepeating) {
      _cancelRemindersFor(updated.id);
      _scheduleRemindersFor(updated);
    }
    notifyListeners();
    _persist();
  }

  /// P2-1：撤销一次 [skipOccurrence]——把 [day]（默认今天）从 [Task.skipDates] 移除。
  ///
  /// 与 skipOccurrence 严格互逆（幂等：不在列表里则什么都不做），供「移到下一天」的
  /// 撤销使用——原实现只删副本、不退 skipDates，撤销后原日仍显示「已跳过」，
  /// UI 对用户说谎。方法内部同样重排提醒，避免撤销后当天提醒仍被跳过。
  void unskipOccurrence(String taskId, {DateTime? day}) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i == -1) return;
    final d = day ?? DateTime.now();
    final ymd = _ymd(DateTime(d.year, d.month, d.day));
    if (!_tasks[i].skipDates.contains(ymd)) return; // 未跳过，幂等
    // F-7：顺带把已过期的跳过日期一并清掉（历史版本可能留下超期条目）。
    final remaining =
        _tasks[i].skipDates.where((s) => s != ymd).toList();
    final updated = _tasks[i].copyWith(
      skipDates: Task.pruneHistory(remaining, d) ?? remaining,
    );
    _tasks[i] = updated;
    if (updated.isRepeating) {
      _cancelRemindersFor(updated.id);
      _scheduleRemindersFor(updated);
    }
    notifyListeners();
    _persist();
  }

  /// 结束重复：把 [Task.repeatUntil] 设为昨天，从今天起不再循环（保留历史任务不删）。
  /// 结束当天即停止出现 / 提醒 / 午夜重置。
  ///
  /// F-5：同时清空 [Task.dueDate]。重复任务的 dueDate 只是录入侧「创建当天 23:59」
  /// 的占位（不是真实截止日），保留它会让这条已退场的任务立刻以 `d < 0` 掉进
  /// 「逾期」分区**永久残留**——用户点「结束重复」的本意是干净退场，
  /// 结果每天在逾期列表里看到一个陈旧条目，必须再手动完成或删除。
  ///
  /// F-3（v2.8.5 审计）：[markDone]=true 时（弹窗「结束并标记完成」动作），
  /// 结束的同时把任务置为已完成并计入今天的完成历史——任务直接落「已完成」分区，
  /// 而不是因 dueDate 被清空而落进「今天」分区还要用户再手动完成一次。
  /// 默认 false（「结束并保留待办」：任务留在「今天」分区由用户处置）。
  void endRepeat(String taskId, {bool markDone = false}) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i == -1) return;
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final now = DateTime.now();
    _tasks[i] = _tasks[i].copyWith(
      repeatUntil: _ymd(yesterday),
      dueDate: null,
      status: markDone ? TaskStatus.done : null,
      completedAt: markDone ? now : null,
      doneDates: markDone ? _withDoneDate(_tasks[i], true, now) : null,
    );
    _cancelRemindersFor(_tasks[i].id);
    notifyListeners();
    _persist();
  }

  /// 仅此一次改期：跳过 [origDay]（默认今天）这一次 occurrence，并创建一条一次性副本任务，
  /// 截止时间设为 [newDay]（其余字段沿用原任务）。实现上即现有 [addTask]，无需新概念。
  ///
  /// P2-1：返回**新建的一次性副本**；调用方凭返回值的 id 精确撤销。
  ///
  /// F-2（v2.8.5 审计）：当 [newDay] **本身就是该任务的循环日**（且 ≠ [origDay]）时，
  /// 该日的 occurrence 已由原循环覆盖——此时**不再另建副本**、仅跳过 [origDay]，
  /// 返回 null。此前 daily 任务「移到下一天」会把副本落到明天，而明天同时是循环日：
  /// 目标日循环提醒 + 副本一次性提醒双响，且循环任务完成后副本仍以未完成姿态挂着
  /// （「改期」变「复制」）。目标日若已被用户显式跳过（在 skipDates 里），仍照常建副本。
  Task? rescheduleOnceOccurrence(
    String taskId,
    DateTime newDay, {
    DateTime? origDay,
  }) {
    final src = byId(taskId);
    if (src == null) return null;
    final orig = origDay ?? DateTime.now();
    final origDay0 = DateTime(orig.year, orig.month, orig.day);
    final target = DateTime(newDay.year, newDay.month, newDay.day);
    // 1) 防撞（F-2）：目标日是循环日 → 仅 skip 本次，交由原循环覆盖。
    final coveredByLoop =
        !target.isAtSameMomentAs(origDay0) && src.repeatsOn(target);
    // 2) 把原 occurrence 当天加入 skipDates，避免原任务当天仍出现/提醒。
    skipOccurrence(taskId, day: origDay0);
    if (coveredByLoop) return null;
    // 3) 创建一次性副本（repeat=none），dueDate 指向改期后的日期，其余沿用。
    // F-4：副本的提醒时刻必须优先取「该重复原本的提醒时刻」[Task.repeatMinute]，
    // 回退才用 dueDate。此前只取 `src.dueDate`，而重复任务的 dueDate 被录入侧钉成
    // 「创建当天 23:59」→「把今天 7 点这件事挪到明天」实际得到「明天 23:59 提醒」。
    final hhmm = src.repeatMinute;
    final copy = src.copyWith(
      id: '', // addTask 会分配新 id
      repeat: RepeatType.none,
      repeatWeekdays: const [],
      // F-10：一次性副本不再残留 repeatInterval=2 脏字段（repeat 已为 none，
      // 该字段无意义，保留会让「改回重复」时莫名其妙地变成「每 2 天」）。
      repeatInterval: 1,
      repeatMinute: null,
      repeatAnchor: null,
      skipDates: const [],
      repeatUntil: null,
      // F-9：月内规则一并清空——副本已是一次性任务，残留的
      // monthlyWeekday/monthlyWeekIndex 会让「改回每月」时沿用旧规则。
      monthlyWeekday: null,
      monthlyWeekIndex: null,
      monthlyFromEnd: 0,
      dueDate: DateTime(
        newDay.year,
        newDay.month,
        newDay.day,
        hhmm != null ? hhmm ~/ 60 : (src.dueDate?.hour ?? 9),
        hhmm != null ? hhmm % 60 : (src.dueDate?.minute ?? 0),
      ),
      status: TaskStatus.todo,
      completedAt: null,
      // P2-2（v2.8.6 审计）：副本必须清空 occurrence 级完成历史。此前 copyWith
      // 默认沿用原任务的 doneDates → 「每天喝水」改期后副本带着 [9/1, 9/2]，
      // 与原任务完全一致，completionDayCounts 把同样的完成记录算两遍
      // （热力图 / 周报 / streak 系统性虚增，且用户无法自察）。
      // 一次性任务的完成历史由 completedAt 表达，这里清空不影响统计口径。
      doneDates: const [],
    );
    return addTask(copy);
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
        // P2-20：覆盖更新必须允许写入来源方的完成态，否则「外部日历已标记完成」
        // 的任务导回后仍显示未完成（updateTask 会强制回填旧 status/completedAt）。
        if (_applyTaskUpdate(task.copyWith(id: existing.id),
            allowStatusChange: true)) {
          overwritten++;
        }
      } else {
        skipped++;
      }
    }
    // 安全（P2-A）：导入可能带入外部 id，重算自增起点，杜绝后续新建任务 id 碰撞。
    _recomputeIdSeq();
    // 覆盖更新走的是 `_applyTaskUpdate`（不落库），此处统一补一次持久化 + 通知。
    if (overwritten > 0) {
      notifyListeners();
      _persist();
    }
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
    final ok = _applyTaskUpdate(updated);
    if (ok) {
      notifyListeners();
      _persist();
    }
  }

  /// P2-4：把一次任务更新应用到内存列表（重算拼音 / 重排提醒），但**不** notify、
  /// **不**落库——供批量路径（[batchUpdate] / [undoBatchEdit]）循环复用后统一
  /// 落库一次，消除逐条 `_persist()` 的 N 倍写放大（全量差量写 SQLite + 小组件刷新）。
  /// 返回是否命中（未命中 = 任务不存在，调用方可据此决定是否需要通知/落库）。
  bool _applyTaskUpdate(Task updated, {bool allowStatusChange = false}) {
    final i = _tasks.indexWhere((t) => t.id == updated.id);
    if (i == -1) return false;
    final old = _tasks[i];
    // A1：标题变化时重算拼音首字母（标题不变则沿用旧值）。
    final pin = updated.title == old.title
        ? old.pinyinInitials
        : Task.computePinyinInitials(updated.title);
    // F2 兜底：切换到「每隔 N 天」却没带锚点时补为今天。
    // 编辑弹层里把「每天/每周/工作日」改成「每隔 N 天」时，原任务没有 repeatAnchor，
    // 而 Task.copyWith 对 repeatAnchor 用 _kKeep 哨兵，显式传 null 是**真写入 null**；
    // 锚点为 null 时 Task.repeatsOn 对任何一天都返回 false → 任务从此不循环、不提醒。
    final anchored = (updated.repeat == RepeatType.interval &&
            updated.repeatAnchor == null)
        ? updated.copyWith(repeatAnchor: _dateOnly(DateTime.now()))
        : updated;
    _tasks[i] = anchored.copyWith(
      id: old.id,
      // P2-20：默认强制保留旧完成态（避免 UI 层误改），但「备份/日历覆盖更新」
      // 这类显式导入场景需要允许写入来源方的完成态，否则外部日历标记完成的任务
      // 覆盖导回后仍显示未完成。
      status: allowStatusChange ? anchored.status : old.status,
      completedAt:
          allowStatusChange ? anchored.completedAt : old.completedAt,
      focusSecTotal: old.focusSecTotal,
      order: old.order,
      pinyinInitials: pin,
    );
    // 截止时间或重复设置发生变化时，先取消旧调度再统一重排，避免状态不一致。
    // P1-1：判定必须覆盖「一切会影响提醒触发时刻/是否触发」的字段——
    // - reminderOffsetMin：一次性提醒时刻 = due.subtract(offset)（notification_service L405）；
    // - monthlyDay / monthlyWeekday / monthlyWeekIndex / monthlyFromEnd：
    //   monthly 的「每月几号 / 第几个周几 / 倒数第 N 天」由它们决定（OS 周期闹钟，
    //   不重排则旧规则的闹钟继续按旧日期每月响，新规则永远不响）；
    // - repeatUntil / skipDates：interval 下次 occurrence 的边界（不重排则结束日期
    //   之后仍可能弹、已设置的跳过日不生效）。
    // 旧判定只比 dueDate/repeat/repeatMinute/repeatInterval/repeatWeekdays/repeatAnchor，
    // 「只改提前量 / 只改每月几号 / 只设结束日期」时 remindersChanged=false，旧提醒继续响。
    final remindersChanged = old.dueDate != anchored.dueDate ||
        old.repeat != anchored.repeat ||
        old.repeatMinute != anchored.repeatMinute ||
        old.repeatInterval != anchored.repeatInterval ||
        !_listEq(old.repeatWeekdays, anchored.repeatWeekdays) ||
        old.repeatAnchor != anchored.repeatAnchor ||
        old.reminderOffsetMin != anchored.reminderOffsetMin ||
        old.monthlyDay != anchored.monthlyDay ||
        old.monthlyWeekday != anchored.monthlyWeekday ||
        old.monthlyWeekIndex != anchored.monthlyWeekIndex ||
        old.monthlyFromEnd != anchored.monthlyFromEnd ||
        old.repeatUntil != anchored.repeatUntil ||
        !_listEq(old.skipDates, anchored.skipDates);
    if (remindersChanged) {
      _cancelRemindersFor(updated.id);
      _scheduleRemindersFor(_tasks[i]);
    }
    return true;
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
    // 先快照再逐条更新：更新会改动 _tasks，边遍历边改不安全。
    final targets = ids.map(byId).whereType<Task>().toList();
    // F1：批量编辑一次性改写 N 条且无快照，历史上「+N 天数输错 / 分类选错」不可逆。
    // 这里外套一份「改前快照」，供 [undoBatchEdit] 一键还原。
    // 撤销按 id 定位（见 [undoBatchEdit]），无需记录索引——中间有插删时索引会错位。
    _lastEditBatch = targets.map((t) => t.copyWith()).toList();
    var changed = 0;
    for (final t in targets) {
      // P2-4：循环内只改内存（拼音/提醒重排照常逐条生效），循环后统一落库一次。
      if (_applyTaskUpdate(transform(t))) changed++;
    }
    if (changed > 0) {
      notifyListeners();
      _persist();
    }
    return changed;
  }

  // ===== 批量编辑（改前快照 + 撤销）=====
  // 与删除撤销 [_lastBatch] / [_lastBatchAnchors] 相互独立，互不覆盖。
  List<Task> _lastEditBatch = [];

  /// 撤销上一次批量编辑：把改前快照逐条写回被改写的任务。
  /// 仅可撤销最近一次批量编辑（覆盖式缓冲）；与 [undoDelete] 互不影响。
  ///
  /// P1-1(v2.7.6)：必须逐条应用完整更新链路而非直接改内存——批量顺延「+N 天」后撤销时，
  /// 截止日期会回滚，唯有重排链路会触发 `_cancelRemindersFor/_scheduleRemindersFor`
  /// 重排提醒，否则系统里残留的提醒仍指向顺延后的新日期（截止日期与通知错位）。
  ///
  /// P1-2(v2.7.6)：按 id 定位而非索引——快照记录的是 batchUpdate 执行时的列表位置，
  /// 之后若用户新增/删除/排序过任务，按旧索引写回会覆盖到无辜任务（数据错乱）。
  /// 这里用 `indexWhere(id)` 找当前位置；找不到说明任务已被删除，跳过（不复活）。
  ///
  /// P2-4：撤销循环内只改内存（[undoBatchEdit] 逐条走 [_applyTaskUpdate]，
  /// 提醒重排 / 拼音重算照常生效），循环结束后统一 notify + 落库一次，
  /// 消除 N 条 × 全量持久化的写放大。
  void undoBatchEdit() {
    if (_lastEditBatch.isEmpty) return;
    var changed = false;
    for (final orig in _lastEditBatch) {
      if (byId(orig.id) == null) continue; // 任务已不在列表（被删除），不允许复活
      // _applyTaskUpdate 会强制保留 status/completedAt/focusSecTotal/order
      // （批量编辑本就不改这些字段），并复用提醒重排 / 拼音重算等既有逻辑。
      if (_applyTaskUpdate(orig)) changed = true;
    }
    _lastEditBatch = [];
    if (changed) {
      notifyListeners();
      _persist();
    }
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

  /// F-05：删除时记下的**邻居锚点**（每个被删任务一条，与 [_lastBatch] 一一对应）。
  ///
  /// 此前记的是删除瞬间的列表下标，撤销时按下标插回。
  /// 问题是删除后用户可能又新增 / 删除 / 勾选 / 拖拽过，列表早已不是当时的样子——
  /// 陈旧下标会把任务插到**错误位置**（甚至挤掉无关任务附近），且旧 order 与
  /// 新邻居不连续，后续手动排序错乱（CHANGELOG v2.5.8 自记的「Bug5 择机延后」）。
  /// 这里改成记「删除时紧邻的前后任务 id」（跳过同时被删的邻居），
  /// 撤销时按 id 定位——与 [undoBatchEdit] 的「按 id 定位」口径统一。
  List<({String? prevId, String? nextId})> _lastBatchAnchors = [];

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
    // F-05：删除前先记锚点——取「左右两侧第一个不被本次删除波及」的任务 id，
    // 这样多个相邻任务同时被删时，锚点仍指向撤销后依然存在的任务。
    final anchors = <({String? prevId, String? nextId})>[];
    for (final i in sortedIdx) {
      String? prevId;
      for (var p = i - 1; p >= 0; p--) {
        if (!toRemove.containsKey(p)) {
          prevId = _tasks[p].id;
          break;
        }
      }
      String? nextId;
      for (var n = i + 1; n < _tasks.length; n++) {
        if (!toRemove.containsKey(n)) {
          nextId = _tasks[n].id;
          break;
        }
      }
      anchors.add((prevId: prevId, nextId: nextId));
    }
    // 按索引降序删除，保证删除时索引依然有效
    for (final i in sortedIdx.reversed) {
      final r = _tasks.removeAt(i);
      _cancelRemindersFor(r.id);
      _trash.insert(0, r.copyWith(deletedAt: DateTime.now()));
    }
    _lastBatch = sortedIdx.map((i) => toRemove[i]!).toList(); // 升序
    _lastBatchAnchors = anchors; // 升序，与 _lastBatch 一一对应
    notifyListeners();
    _persist();
    _syncTrashExpireNotice(); // P1-12：新入回收站后重排过期预告
    return _lastBatch;
  }

  /// P2-22：从删除撤销缓冲中移除指定任务（_lastBatch 与 [_lastBatchAnchors] 一一对应，
  /// 必须同步删除，否则后续撤销会按错位锚点把快照塞回错误的位置）。
  void _dropFromUndoBuffer(String id) {
    final k = _lastBatch.indexWhere((t) => t.id == id);
    if (k == -1) return;
    _lastBatch.removeAt(k);
    if (k < _lastBatchAnchors.length) _lastBatchAnchors.removeAt(k);
  }

  /// 删除指定 id 的任务：从任务列表移除，并移入回收站（记录删除时间）。
  /// 返回被删除的任务（用于撤销 / 提示）。
  Task? deleteTask(String id) {
    final removed = _removeMany([id]);
    return removed.isEmpty ? null : removed.first;
  }

  /// 多选批量删除：一次删除多个任务（移入回收站，可整体撤销）。
  void deleteTasks(List<String> ids) => _removeMany(ids);

  /// 撤销上一次删除（支持批量）：从回收站取回，按**邻居锚点**归位，恢复其本地提醒。
  ///
  /// F-05 修复：不再用删除瞬间的下标（列表早已变动，陈旧下标会插错位置），改为
  /// 按记下的前后邻居 id 定位：
  ///  1) 前邻仍存在 → 插到它后面（最接近「原位」）；
  ///  2) 否则后邻仍存在 → 插到它前面；
  ///  3) 两端都不在了（邻居也被删并已彻底清除等）→ 落到所属**分区末尾**，
  ///     比按陈旧下标乱插安全得多。
  /// 归位后对该分区重算 [Task.order]，使手动排序重新连续（旧 order 会与邻居重叠）。
  void undoDelete() {
    if (_lastBatch.isEmpty) return;
    for (var k = 0; k < _lastBatch.length; k++) {
      final r = _lastBatch[k];
      final anchor = k < _lastBatchAnchors.length
          ? _lastBatchAnchors[k]
          : (prevId: null, nextId: null);
      _trash.removeWhere((t) => t.id == r.id);
      final at = _resolveUndoIndex(r, anchor);
      _tasks.insert(at, r);
      _scheduleRemindersFor(r);
      _renumberSection(_sectionNameOf(r));
    }
    _lastBatch = [];
    _lastBatchAnchors = [];
    notifyListeners();
    _persist();
    _syncTrashExpireNotice(); // P1-12：撤销删除后重排
  }

  /// F-05：按邻居锚点解析撤销插入位置（见 [undoDelete] 的三档兜底）。
  int _resolveUndoIndex(Task r, ({String? prevId, String? nextId}) anchor) {
    final prevId = anchor.prevId;
    if (prevId != null) {
      final i = _tasks.indexWhere((t) => t.id == prevId);
      if (i != -1) return i + 1;
    }
    final nextId = anchor.nextId;
    if (nextId != null) {
      final i = _tasks.indexWhere((t) => t.id == nextId);
      if (i != -1) return i;
    }
    // 两端锚点都失效：落所属分区末尾（分区内最后一个任务的后面）；
    // 分区里一个任务都没有时插到列表末尾。
    final section = _sectionNameOf(r);
    for (var i = _tasks.length - 1; i >= 0; i--) {
      if (_sectionNameOf(_tasks[i]) == section) return i + 1;
    }
    return _tasks.length;
  }

  /// F-05：把某分区内任务的 [Task.order] 按当前显示顺序重算为 1,2,3…，
  /// 供撤销归位 / 外部批量改动后消除 order 空洞与重复，保证手动排序语义稳定。
  void _renumberSection(String section) {
    final list = homeTasks[section];
    if (list == null || list.isEmpty) return;
    for (var i = 0; i < list.length; i++) {
      final idx = _tasks.indexWhere((x) => x.id == list[i].id);
      if (idx != -1) {
        _tasks[idx] = _tasks[idx].copyWith(order: (i + 1).toDouble());
      }
    }
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

  /// P2-1：把一条**活动列表**中的任务直接移除（不进回收站）。
  ///
  /// 与 [permanentDelete] 的区别很关键——后者只作用于**回收站**（`_trash`），
  /// 对活动列表里的任务是彻底的 no-op。此前 occurrence_sheet 的「移到下一天」撤销
  /// 就是误用了 `permanentDelete(copy.id)`：副本仍在活动列表里，「撤销」形同虚设。
  ///
  /// 本方法用于清掉「系统自动生成、用户从未要求保留」的一次性副本——
  /// 放进回收站反而会让用户困惑。附件目录一并清理，避免孤立文件。
  /// 幂等：id 不存在时什么都不做。
  void discardTask(String id) {
    final before = _tasks.length;
    _tasks.removeWhere((t) => t.id == id);
    if (_tasks.length == before) return; // 不存在，幂等
    _cancelRemindersFor(id);
    // P0-1 一致：彻底移除时一并清理附件目录，避免孤立文件长期占用空间。
    AttachmentService.removeDir(id);
    // 与 permanentDelete 同口径：作废删除撤销缓冲中的对应项，避免「先撤销移除、
    // 再点删除撤销」把已清理附件的任务复活成「文件不存在」。
    _dropFromUndoBuffer(id);
    notifyListeners();
    _persist();
  }

  /// 在回收站中彻底删除某任务（不可恢复），并取消其本地提醒。
  void permanentDelete(String id) {
    _trash.removeWhere((t) => t.id == id);
    _cancelRemindersFor(id);
    // P0-1：彻底删除时一并清理其附件目录，避免孤立文件长期占用空间。
    AttachmentService.removeDir(id);
    // P2-22：彻底删除后必须作废删除撤销缓冲中的对应项。此前 permanentDelete /
    // clearTrash 物理删除了附件却不清 _lastBatch，撤销窗口内先彻底删除再点撤销 →
    // 任务复活但附件已删，详情页附件全部「文件不存在」。
    _dropFromUndoBuffer(id);
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
    // P2-22：清空回收站后同样作废删除撤销缓冲（附件已物理删除，不允许复活）。
    if (_lastBatch.isNotEmpty) {
      _lastBatch = [];
      _lastBatchAnchors = [];
    }
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
    // 结构预校验（P2-2）：`tasks` 必须是显式列表，无论 app 标记如何。
    // 旧逻辑 `app != '有条' && tasks is! List` 会放行「带『有条』标记但 tasks 缺失/
    // 非列表」的损坏/截断备份（list 兜底为 []），恢复时把现有任务+回收站**全清**，
    // 清空数据仅靠 UI 二次确认兜底——纵深防线单薄。现在校验层直接拒绝；
    // 「清空恢复」只允许 `tasks: []` 显式空数组这一条有意路径。
    if (data['tasks'] is! List) {
      throw Exception('不是「有条」的备份文件（缺少任务列表）');
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
    // F-8（v2.8.5 审计）：覆盖恢复同样自愈 interval 缺锚点（下方 _persist 落库，
    // 与 load() 的自愈口径一致）。
    _healRepeatAnchors();
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
    // F-11：覆盖恢复后回收本机旧附件。
    // 备份只带回「备份内存在的」附件字节，本机原有、备份中并不存在的任务附件目录
    // 会就此变成孤儿并持续占用私有空间（换机 / 用旧备份覆盖时尤其明显）。
    // 这里复用设置页「清理无主文件」的同一套计划器，按**恢复后**的任务元数据判定
    // 无主目录（同 id 取并集 → 绝不误删真实附件），一次性回收，省去用户手动再来一遍。
    try {
      await AttachmentService.deleteOrphans([..._tasks, ..._trash]);
    } catch (e) {
      // 清理失败不影响恢复结果（用户仍可在设置里手动清理）。
      AppLog.d('[恢复] 附件孤儿清理失败（忽略）：$e');
    }
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
  static String _esc(String s) => csvCell(s);

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

  /// 重复任务当前是否仍应（重新）挂重复提醒。
  ///
  /// **唯一权威判据是 [Task.repeatUntil]（重复是否已结束）**，与 [Task.dueDate]
  /// 是否设置 / 是否已过**完全无关**。
  ///
  /// F-1（P1）：历史上这里对非 interval 类型要求 `dueDate != null &&
  /// !_dateHasPassed(dueDate)`，而录入侧会把重复任务的 dueDate 钉成「创建当天
  /// 23:59」——创建次日该门槛恒为 false。于是「本次跳过 / 撤销跳过 / 编辑保存 /
  /// 通知总开关关→开 / 覆盖恢复」这些「先取消、再按门槛重挂」的常规操作，
  /// 取消之后就再也挂不回来：系统里的周期闹钟被取消且不再注册，任务卡片仍显示
  /// 「每天」，却永久静默不响，且没有任何自愈机制（跨天守护原先只补 interval）。
  /// P1-2 当年已为 interval 修过同一问题（注释写明「旧门槛会让无 dueDate 的
  /// interval 首轮后永久丢失」），此处把该修法推广到**全部**重复类型。
  ///
  /// F3 的 [repeatUntil] 前置判断保留：`repeatUntil` 为 date-only「含当日」，
  /// [_dateHasPassed] 以「今天 00:00」为界，故「结束日 = 今天」仍算有效、
  /// 「结束日 = 昨天」（即 endRepeat 的写法）才算结束。
  ///
  /// 暴露为 `@visibleForTesting` 便于回归测试直接钉死这条门槛
  /// （F-1 的复现路径正是「dueDate 已过 + 各类常规操作后仍必须重挂」）。
  @visibleForTesting
  static bool shouldScheduleRepeatReminder(Task t) {
    if (!t.isRepeating || t.repeatMinute == null) return false;
    final u = t.repeatUntil;
    if (u != null) {
      final until = DateTime.tryParse(u);
      if (until != null && _dateHasPassed(until)) return false;
    }
    return true;
  }

  /// 为单个任务调度其全部本地提醒（截止提醒 + 重复提醒）。
  /// 重复提醒只在「重复未结束」时才调度（见 [shouldScheduleRepeatReminder]）。
  ///
  /// F-1（v2.8.5 审计）：两类提醒**互斥**——重复任务的提醒只由
  /// [NotificationService.scheduleRepeatReminder] 负责（结束由 repeatUntil 表达），
  /// 不再因其残留的 dueDate 额外挂一条用户不可见、改不了的一次性「截止提醒」
  /// （此前同一任务会在循环提醒之外再多挂一条同标题通知，到 dueDate 当天双响）。
  void _scheduleRemindersFor(Task t) {
    if (shouldScheduleDeadlineReminder(t)) {
      NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
    }
    if (shouldScheduleRepeatReminder(t)) {
      NotificationService.instance.scheduleRepeatReminder(t, playSound: _soundEnabled);
    }
  }

  /// F-1（v2.8.5 审计）：是否应挂「一次性截止提醒」。
  ///
  /// 唯一判据：有 dueDate 且**非重复任务**。重复任务即便带 dueDate 也返回 false
  /// ——其提醒由 [shouldScheduleRepeatReminder] 的重复链路负责，二者互斥。
  /// 暴露为 `@visibleForTesting` 便于回归测试钉死「重复任务不得产生截止提醒」。
  @visibleForTesting
  static bool shouldScheduleDeadlineReminder(Task t) =>
      t.dueDate != null && !t.isRepeating;

  /// 取消单个任务的全部本地提醒（截止提醒 + 重复提醒）。
  void _cancelRemindersFor(String id) {
    NotificationService.instance.cancel(id);
    NotificationService.instance.cancelRepeatReminder(id);
  }

  /// 重复任务完成态变更后（toggleDone / setStatus / 取消完成）重排其重复提醒。
  /// 仅当任务仍「未过截止日」才挂；具体「是否跳过今日」由通知服务依据
  /// [Task.done] + [Task.completedAt] 是否为今天自行判断（当天已完成→挂明天）。
  void _rescheduleRepeatOnCompletion(Task t) {
    // P1-2：门槛统一收口到 [shouldScheduleRepeatReminder]（interval 不再受 dueDate 限制）。
    if (shouldScheduleRepeatReminder(t)) {
      NotificationService.instance.scheduleRepeatReminder(t, playSound: _soundEnabled);
    }
  }

  /// 非重复任务完成态变更后：取消 / 恢复其一次性「截止时间提醒」。
  /// - 完成（含提前完成）：取消已调度的截止提醒，避免到期后仍弹出。
  /// - 取消完成：若截止时间未过，恢复调度。
  /// 重复任务不在此处理——F-1（v2.8.5 审计）起重复任务的提醒**只**由
  /// [shouldScheduleRepeatReminder] 的重复链路负责（与其截止提醒互斥），
  /// 当天完成由 [scheduleRepeatReminder] 内部依据 done/completedAt 跳过今日落点，
  /// 故直接跳过。
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
      // F-1（v2.8.5 审计）：调度互斥——重复任务不再挂一次性截止提醒；
      // 存量用户的系统里可能仍挂着升级前的「双响」截止闹钟，这里顺手幂等取消。
      if (t.isRepeating && t.dueDate != null) {
        NotificationService.instance.cancel(t.id);
      }
      if (!t.done &&
          !t.isRepeating &&
          t.dueDate != null &&
          t.dueDate!.isAfter(now)) {
        NotificationService.instance.scheduleForTask(t, playSound: _soundEnabled);
      }
      // P1-2：门槛统一收口到 [shouldScheduleRepeatReminder]——interval 重复提醒
      // 不再因 dueDate 缺失 / 已过而漏挂（否则首轮后永久丢失）。
      if (shouldScheduleRepeatReminder(t)) {
        NotificationService.instance.scheduleRepeatReminder(t, playSound: _soundEnabled);
      }
    }
  }

  /// P2-3（v2.8.6 审计）：设置页修改「提醒时区」后的公开重排入口。
  /// 时区变化会平移全部已挂落点，必须整体重排；习惯打卡提醒不在本 Provider
  /// 管辖内，经 [onGuardTick] 回调（main.dart 注入的 habit.scheduleAllReminders）补挂。
  void rescheduleAllNotifications() {
    if (!_notificationsEnabled) return;
    _rescheduleAllActive();
    onGuardTick?.call();
  }

  /// 列表内容是否相等（[List] 默认 == 比较引用，重复星期 / 跳过日期需按内容比较）。
  /// P1-1：泛型化——除 repeatWeekdays(List<int>) 外，skipDates(List<String>) 也按内容比较。
  static bool _listEq<T>(List<T> a, List<T> b) {
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
  /// L-08：该快照是否为加密信封（.enc.json）。还原时需先解密。
  final bool encrypted;
  const AutoBackupEntry({
    required this.date,
    required this.file,
    this.encrypted = false,
  });

  /// 友好展示：M月D日。
  String get label => '${date.month}月${date.day}日';

  /// 副标题：明确标注加密状态（L-08 的知情权部分）。
  String get statusLabel => encrypted ? '已加密' : '明文';
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
