import 'package:shared_preferences/shared_preferences.dart';

/// 自动备份时一并序列化的 App 级偏好键（白名单）。
///
/// 覆盖范围：外观主题 / 应用锁开关 / 专注与番茄钟 / 免打扰 / 提醒延后 / 统计目标 /
/// 通用开关（回收站保留期、后台保活、引导页、自动备份自身）。
///
/// 明确排除（恢复无意义或跨设备有害）：
/// - 系统生物特征录入：系统保管，任何 App 无法导出，恢复后须重录；
/// - 更新检查状态（update_last_auto_check / update_skip_version）：避免跨设备带偏；
/// - 运行中的计时器（focus_active_timer）：跨安装无效；
/// - 示例数据标记（samples_seeded_v1）：非用户偏好，恢复不应篡改首启决策。
const List<String> _backedUpPrefKeys = <String>[
  // —— 外观主题 ——
  'theme_mode',
  'theme_follow_system',
  'theme_use_dynamic',
  'theme_seed',
  'theme_pure_black',
  // —— 应用锁 ——
  'app_lock_enabled',
  'app_lock_idle_seconds',
  // —— 专注 / 番茄钟 ——
  'focus_pomo_enabled',
  'focus_pomo_focus_sec',
  'focus_pomo_short_sec',
  'focus_pomo_long_sec',
  'focus_pomo_rounds',
  'focus_custom_sec',
  'focus_sound_type',
  'focus_sound_types',
  'focus_sound_volume',
  'focus_sys_calendar',
  'focus_goal_minutes',
  // —— 提醒与免打扰 ——
  'dnd_enabled',
  'dnd_start',
  'dnd_end',
  'snooze_minutes',
  'weekly_goal_count',
  // —— 通用开关 ——
  'trash_retention_days',
  'background_guard',
  'onboarding_seen',
  'auto_backup_enabled',
  // P2-12：v2.7.x / v2.8.x 新增的偏好若未纳入白名单，恢复后会被静默丢弃，
  // 用户表现为「我明明打开了 X，怎么同步过来还是关着」。逐项与 task_provider / 其它
  // Provider 的 setter / 持久化键名核对补齐：
  'calendar_lunar',           // 日历农历显示
  'lock_screen_private',      // 锁屏隐藏通知内容（L-06）
  'flag_secure',              // 防截屏/录屏（L-07）
  'allow_external_links',     // 备注外链点击（L-12）
  // 早晚简报（P2-2，v3.1.0 审计：旧白名单写的是 briefing_morning_* 等
  // **幽灵键**——TaskProvider 实际读写 brief_morning_on / brief_morning_h /
  // brief_morning_m、brief_evening_*、habit_nudge_on / habit_nudge_min（见
  // task_provider 顶部常量），导出必然为空、恢复必然写不中，用户改过的
  // 时刻静默回默认。逐项以 Provider 常量为准确认，勿再手抄显示文案）。
  'brief_morning_on',
  'brief_morning_h',
  'brief_morning_m',
  'brief_evening_on',
  'brief_evening_h',
  'brief_evening_m',
  // 习惯漏卡挽留（P1-7；P2-2 同上改真实键名）
  'habit_nudge_on',
  'habit_nudge_min',
  // 归档标签 / 自动备份口令关闭后的清理用标记
  'archived_tags',
  // P2-1（v2.8.7 审计）：提醒时区覆盖（v2.8.7 新增偏好键）。与 P2-12 同型——
  // 新键漏入白名单会让「备份 / 换机恢复后设置静默回到跟随系统」，且用户不可自察。
  // 恢复侧配套：applyAppPrefs 写回后必须调 NotificationService.reloadTimezoneOverride()
  // 重解析内存时区并全量重排（见 backup_sheet 恢复流程），否则仅落盘、本轮不生效。
  'reminder_timezone_override',
  // A5（v3.1.1 功能增强）：今日三件（MIT）选中的任务 id（JSON map，按日期键）。
  // 纯偏好存储、零迁移；旧备份无此键时保持现有选择（不覆盖）。
  'daily_mit',
];

/// P2-2（v3.1.0 审计）：刻意**不**进白名单的键及策略说明。
///
/// - `auto_backup_encrypt`（自动备份加密开关）：口令按设计存于
///   flutter_secure_storage、不随备份导出——若把开关迁过去，换机恢复后
///   「开关开着、口令缺失」，每日自动快照会**因缺口令持续失败**（比明文
///   降级更糟）。不迁移 + 恢复完成后在结果提示里说明「需重新设置」，
///   避免静默从加密降级为明文。
/// - `reminders_muted_until`（全局提醒临时静音窗口）：U-6（v3.1.2 审计）——
///   静音是**本机短期状态**（类似勿扰的一次性会话），不是用户偏好：恢复一份
///   「当时静音到明天」的旧备份会让当前设备立刻被静音，用户「莫名其妙又被
///   噤声」且无从预期。改为本机状态不迁移：导出侧经二道闸排除，恢复侧
///   applyAppPrefs 白名单过滤同样丢弃旧备份携带的该键（旧备份兼容）。
const List<String> _neverBackedUpPrefKeys = <String>[
  'auto_backup_encrypt',
  'reminders_muted_until',
];

/// 读取白名单内的偏好键，返回可被 JSON 序列化的 `{key: value}` 映射。
///
/// 仅保留 SharedPreferences 支持的标量类型（bool / int / double / String /
/// List<String>），其余类型跳过，以免破坏 JSON 编码或写回时类型不匹配。
Future<Map<String, dynamic>> collectAppPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final out = <String, dynamic>{};
  for (final k in _backedUpPrefKeys) {
    // P2-2（v3.1.0 审计）：显式排除段二道闸——即使该键日后被误加回白名单，
    // 也不会出现在备份里（与 applyAppPrefs 的白名单判断互为冗余防线）。
    if (_neverBackedUpPrefKeys.contains(k)) continue;
    if (!prefs.containsKey(k)) continue;
    final v = prefs.get(k);
    if (v is bool || v is int || v is double || v is String) {
      out[k] = v;
    } else if (v is List) {
      // 仅支持 List<String>（如 focus_sound_types 多选音效集合）。
      final strList = v.whereType<String>().toList();
      if (strList.length == v.length) out[k] = strList;
    }
  }
  return out;
}

/// 将备份中的偏好映射写回 SharedPreferences。
///
/// 写回后调用方应触发各 Provider 重新读取（如 [TaskProvider.load]），使内存态生效。
/// [prefs] 为 null 或空时直接返回，保持向后兼容（旧备份无偏好段）。
Future<void> applyAppPrefs(Map<String, dynamic>? prefs) async {
  if (prefs == null || prefs.isEmpty) return;
  final sp = await SharedPreferences.getInstance();
  // M1 安全修复：仅写回白名单 [_backedUpPrefKeys] 内的键。恢复来源不可信（可能被篡改的备份），
  // 若直接回写任意键，攻击者可在备份里植入恶意偏好（如覆盖关键开关 / 注入未知键）。
  // 白名单与 [collectAppPrefs] 共用同一份键集合，保证「导出什么、导入就只恢复什么」。
  for (final entry in prefs.entries) {
    final k = entry.key;
    if (!_backedUpPrefKeys.contains(k)) continue; // 非白名单键直接丢弃
    final v = entry.value;
    if (v is bool) {
      await sp.setBool(k, v);
    } else if (v is int) {
      await sp.setInt(k, v);
    } else if (v is double) {
      await sp.setDouble(k, v);
    } else if (v is String) {
      await sp.setString(k, v);
    } else if (v is List) {
      // JSON 解码后数组为 List<dynamic>，仅保留字符串元素写回。
      final strList = v.whereType<String>().toList();
      // 仅当数组元素全部为字符串时才写回（含空数组 v.length==0）；
      // 若混有非字符串元素则跳过，保留设备现有值，避免破坏。
      if (strList.length == v.length) {
        await sp.setStringList(k, strList);
      }
    }
  }
}
