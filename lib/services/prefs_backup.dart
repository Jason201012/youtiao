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
];

/// 读取白名单内的偏好键，返回可被 JSON 序列化的 `{key: value}` 映射。
///
/// 仅保留 SharedPreferences 支持的标量类型（bool / int / double / String /
/// List<String>），其余类型跳过，以免破坏 JSON 编码或写回时类型不匹配。
Future<Map<String, dynamic>> collectAppPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final out = <String, dynamic>{};
  for (final k in _backedUpPrefKeys) {
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
  for (final entry in prefs.entries) {
    final k = entry.key;
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
