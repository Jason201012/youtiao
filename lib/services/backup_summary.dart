/// A1（v3.1.1 功能增强）：恢复前差异预演摘要（`BackupSummary`）。
///
/// 从**已解析**的备份 JSON（经 [BackupValidator.validate] 通过后）生成恢复
/// 预览，不改备份 schema——只是把现有字段读出来给用户看：
/// - 元信息：生成时间、schemaVersion、App 版本（若有）、是否加密；
/// - 数据量：任务 / 回收站 / 习惯 / 打卡 / 专注 / 附件 / 用户模板；
/// - 时间范围：任务截止最早/最晚、专注记录最早/最晚；
/// - 当前对比：当前任务 / 习惯 / 专注条数（「备份中不存在的当前任务将不会被保留」）；
/// - 设置差异：备份内 prefs 与当前不同的**键名清单**（不显示值，避免 UI 过长
///   与敏感值泄露）。
///
/// 纯 Dart（不依赖 flutter），可直接单测；解析复用调用方已 jsonDecode 的
/// Map，不产生二次解析。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'prefs_backup.dart'; // P3-6（v3.1.3 审计）：与恢复执行侧共用不迁移键名单

class BackupSummary {
  final DateTime? generatedAt;
  final int? schemaVersion;
  final String? appVersion;
  final bool encrypted;
  final int taskCount;
  final int trashCount;
  final int habitCount;
  final int checkInCount;
  final int focusCount;
  final int attachmentCount;
  final int templateCount;
  final DateTime? earliestDue;
  final DateTime? latestDue;
  final DateTime? earliestFocusAt;
  final DateTime? latestFocusAt;
  /// 备份内 prefs 的键清单（白名单净化前的原始键名，仅用于展示数量）。
  final List<String> prefKeys;
  /// 当前与备份 prefs 不同的键名清单（A1 验收：只显示键名，不显示值）。
  final List<String> changedPrefKeys;
  // 当前对比
  final int currentTaskCount;
  final int currentTrashCount;
  final int currentHabitCount;
  final int currentFocusCount;

  const BackupSummary({
    this.generatedAt,
    this.schemaVersion,
    this.appVersion,
    this.encrypted = false,
    this.taskCount = 0,
    this.trashCount = 0,
    this.habitCount = 0,
    this.checkInCount = 0,
    this.focusCount = 0,
    this.attachmentCount = 0,
    this.templateCount = 0,
    this.earliestDue,
    this.latestDue,
    this.earliestFocusAt,
    this.latestFocusAt,
    this.prefKeys = const [],
    this.changedPrefKeys = const [],
    this.currentTaskCount = 0,
    this.currentTrashCount = 0,
    this.currentHabitCount = 0,
    this.currentFocusCount = 0,
  });

  /// 从已解析的备份 Map 构建。[current*] 由调用方从各 Provider 现取。
  ///
  /// 任何字段形态不符一律按缺省计（备份在校验层已过形态体检，这里只做
  /// 摘要展示，绝不因单个坏字段抛错）。
  static Future<BackupSummary> fromMap(
    Map<String, dynamic> data, {
    bool encrypted = false,
    required int currentTaskCount,
    int currentTrashCount = 0,
    required int currentHabitCount,
    required int currentFocusCount,
  }) async {
    final tasks = _listOf(data['tasks']);
    final trash = _listOf(data['trash']);
    final habits = _listOf(data['habits']);
    final checkIns = _listOf(data['check_ins']);
    final focus = _listOf(data['focus_sessions']);
    final attachments = data['attachments'];
    var attachmentCount = 0;
    if (attachments is Map) {
      attachments.forEach((k, v) {
        // H1（v3.0.8 审计）同款豁免：__skipped 是统计段不是附件列表。
        if (k == '__skipped') return;
        if (v is List) attachmentCount += v.length;
      });
    }
    final templates = _listOf(data['user_templates']);

    DateTime? earliestDue;
    DateTime? latestDue;
    for (final e in [...tasks, ...trash]) {
      if (e is! Map) continue;
      final raw = e['dueDate'];
      if (raw is! String) continue;
      final d = DateTime.tryParse(raw);
      if (d == null) continue;
      if (earliestDue == null || d.isBefore(earliestDue)) earliestDue = d;
      if (latestDue == null || d.isAfter(latestDue)) latestDue = d;
    }
    DateTime? earliestFocusAt;
    DateTime? latestFocusAt;
    for (final e in focus) {
      if (e is! Map) continue;
      final raw = e['startedAt'];
      if (raw is! String) continue;
      final d = DateTime.tryParse(raw);
      if (d == null) continue;
      if (earliestFocusAt == null || d.isBefore(earliestFocusAt)) {
        earliestFocusAt = d;
      }
      if (latestFocusAt == null || d.isAfter(latestFocusAt)) {
        latestFocusAt = d;
      }
    }

    // 设置差异（仅键名）：备份 prefs 与当前 SharedPreferences 的不同键。
    final prefs = data['prefs'];
    final backupPrefKeys = <String>[];
    final changed = <String>[];
    if (prefs is Map) {
      final sp = await SharedPreferences.getInstance();
      prefs.forEach((k, v) {
        if (k is! String) return;
        // P3-6（v3.1.3 审计）：applyAppPrefs 会丢弃「不随备份迁移」的本机状态
        // 键（自动备份加密开关 / 临时静音窗口），旧备份里却常带着它们。若摘要
        // 仍把它们列进「设置差异」，用户看到差异、切换「同时恢复设置」后却
        // 毫无效果（标签表也没有这些键，只会回退显示英文键名）。此处与执行侧
        // 共用同一份名单过滤，摘要只列真正会被应用的键。
        if (neverBackedUpPrefKeys.contains(k)) return;
        backupPrefKeys.add(k);
        // P3-1（v3.1.2 审计）：列表键深比较——备份 JSON 解码出的 List 是
        // List<dynamic>，SharedPreferences 返回 List<String>，Dart 的 `==`
        // 是引用比较，直接 `!=` 会把内容完全相同的列表键（focus_sound_types /
        // archived_tags 等）恒判为「与当前不同」。归一化后比较。
        if (!sp.containsKey(k) || !_prefEquals(sp.get(k), v)) changed.add(k);
      });
      changed.sort();
    }

    return BackupSummary(
      generatedAt: _tryParse(data['generatedAt']),
      schemaVersion: data['schemaVersion'] is int ? data['schemaVersion'] as int : null,
      appVersion: data['appVersion'] is String ? data['appVersion'] as String : null,
      encrypted: encrypted,
      taskCount: tasks.length,
      trashCount: trash.length,
      habitCount: habits.length,
      checkInCount: checkIns.length,
      focusCount: focus.length,
      attachmentCount: attachmentCount,
      templateCount: templates.length,
      earliestDue: earliestDue,
      latestDue: latestDue,
      earliestFocusAt: earliestFocusAt,
      latestFocusAt: latestFocusAt,
      prefKeys: backupPrefKeys,
      changedPrefKeys: changed,
      currentTaskCount: currentTaskCount,
      currentTrashCount: currentTrashCount,
      currentHabitCount: currentHabitCount,
      currentFocusCount: currentFocusCount,
    );
  }

  static List _listOf(dynamic v) => v is List ? v : const [];

  /// P3-1（v3.1.2 审计）：偏好值等价比较。两值分别来自「JSON 域」（备份）
  /// 与「SharedPreferences 域」（当前），List 的运行时类型不同但内容可能
  /// 一致；jsonEncode 归一化后按串比较。任一侧不可编码（实际不可达：值均
  /// 源自 JSON/SP 的合法标量）时退回引用比较语义（判不等，宁可多报不漏报）。
  static bool _prefEquals(dynamic a, dynamic b) {
    if (a == b) return true;
    final ea = _tryEncode(a);
    final eb = _tryEncode(b);
    if (ea == null || eb == null) return false;
    return ea == eb;
  }

  static String? _tryEncode(dynamic v) {
    try {
      return jsonEncode(v);
    } catch (_) {
      return null;
    }
  }

  /// U-12①（v3.1.2 审计）：差异键名 → 用户可读标签。摘要面向用户展示，
  /// 直接给 `archived_tags` 这类英文键名非用户语言；未登记的键回退原键名
  /// （新增白名单键漏登记只影响可读性，不影响正确性）。
  static const Map<String, String> _prefKeyLabels = {
    'theme_mode': '主题模式',
    'theme_follow_system': '跟随系统深浅色',
    'theme_use_dynamic': '动态取色',
    'theme_seed': '主题色',
    'theme_pure_black': '纯黑模式',
    'app_lock_enabled': '应用锁',
    'app_lock_idle_seconds': '应用锁自动锁定时长',
    'focus_pomo_enabled': '番茄循环',
    'focus_pomo_focus_sec': '专注时长',
    'focus_pomo_short_sec': '短休息时长',
    'focus_pomo_long_sec': '长休息时长',
    'focus_pomo_rounds': '番茄轮数',
    'focus_custom_sec': '自定义专注时长',
    'focus_sound_type': '提示音类型',
    'focus_sound_types': '提示音多选',
    'focus_sound_volume': '提示音音量',
    'focus_sys_calendar': '专注写入系统日历',
    'focus_goal_minutes': '每日专注目标',
    'dnd_enabled': '免打扰',
    'dnd_start': '免打扰开始时刻',
    'dnd_end': '免打扰结束时刻',
    'snooze_minutes': '提醒延后时长',
    'weekly_goal_count': '每周完成目标',
    'trash_retention_days': '回收站保留期',
    'background_guard': '后台保活',
    'onboarding_seen': '引导页标记',
    'auto_backup_enabled': '自动备份',
    'calendar_lunar': '日历农历显示',
    'lock_screen_private': '锁屏隐藏通知内容',
    'flag_secure': '防截屏/录屏',
    'allow_external_links': '备注外链点击',
    'brief_morning_on': '早间简报开关',
    'brief_morning_h': '早间简报时刻（时）',
    'brief_morning_m': '早间简报时刻（分）',
    'brief_evening_on': '晚间简报开关',
    'brief_evening_h': '晚间简报时刻（时）',
    'brief_evening_m': '晚间简报时刻（分）',
    'habit_nudge_on': '习惯挽留开关',
    'habit_nudge_min': '习惯挽留时刻',
    'archived_tags': '归档标签',
    'reminder_timezone_override': '提醒时区',
    'daily_mit': '今日三件',
  };

  static String _prefLabel(String key) => _prefKeyLabels[key] ?? key;

  static DateTime? _tryParse(dynamic v) =>
      v is String ? DateTime.tryParse(v) : null;

  /// 备份比当前旧多少天（按生成时间到现在的整天数；无生成时间 / 同日返回 0）。
  int get ageDays {
    final g = generatedAt;
    if (g == null) return 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(g.year, g.month, g.day);
    return today.difference(day).inDays;
  }

  /// 确认框正文（多行）。紧凑、黑白口径，不显示敏感值。
  String describe() {
    final p = (int n) => n.toString().padLeft(2, '0');
    String? fmt(DateTime? d) => d == null
        ? null
        : '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
    final lines = <String>[];
    final gen = fmt(generatedAt);
    if (gen != null) lines.add('生成于 $gen${ageDays > 0 ? '（$ageDays 天前）' : ''}');
    if (appVersion != null) lines.add('应用版本：$appVersion');
    // U-11⑤（v3.1.2 审计）：schemaVersion 此前计算后从不展示——摘要补一行，
    // 让用户能核对备份的数据格式版本。
    if (schemaVersion != null) lines.add('数据格式版本：v$schemaVersion');
    if (encrypted) lines.add('已加密（口令验证通过）');
    lines.add(
        '数据量：任务 $taskCount、回收站 $trashCount、习惯 $habitCount、'
        '打卡 $checkInCount、专注 $focusCount、附件 $attachmentCount、'
        '模板 $templateCount');
    final dueRange = (fmt(earliestDue) == null && fmt(latestDue) == null)
        ? null
        : '${fmt(earliestDue) ?? '—'} ~ ${fmt(latestDue) ?? '—'}';
    if (dueRange != null) lines.add('任务截止范围：$dueRange');
    final focusRange = (fmt(earliestFocusAt) == null && fmt(latestFocusAt) == null)
        ? null
        : '${fmt(earliestFocusAt) ?? '—'} ~ ${fmt(latestFocusAt) ?? '—'}';
    if (focusRange != null) lines.add('专注记录范围：$focusRange');
    // U-12③（v3.1.2 审计）：当前对比补回收站条数，与「备份中不存在的当前
    // 任务/回收站条目将不会被保留」的警示对称。
    lines.add('当前对比：任务 $currentTaskCount、回收站 $currentTrashCount、'
        '习惯 $currentHabitCount、专注 $currentFocusCount；恢复将覆盖现有数据，'
        '备份中不存在的当前任务/回收站条目将不会被保留');
    if (changedPrefKeys.isNotEmpty) {
      // U-12①（v3.1.2 审计）：展示用户可读标签而非英文键名。
      final labels = changedPrefKeys.map(_prefLabel).toList();
      lines.add(
          '设置差异：${labels.length} 项偏好与当前不同'
          '（${labels.take(6).join('、')}'
          '${labels.length > 6 ? ' 等' : ''}）');
    } else if (prefKeys.isNotEmpty) {
      lines.add('设置：与当前无差异（${prefKeys.length} 个键）');
    } else {
      // P3-4（v3.1.2 审计）：备份无偏好段时如实说明——旧版/纯任务备份恢复时
      // 「同时恢复设置」开关无效，摘要与确认框口径一致。
      lines.add('设置：此备份未包含设置（仅恢复数据）');
    }
    return lines.join('\n');
  }
}
