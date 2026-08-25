import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/services/prefs_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('collectAppPrefs 仅导出白名单键，排除生物特征/更新状态/计时器', () async {
    SharedPreferences.setMockInitialValues({
      // 白名单内（应全部导出，共 26 个键）
      'theme_mode': false,
      'theme_follow_system': true,
      'theme_use_dynamic': true,
      'theme_seed': 0xFF2196F3,
      'theme_pure_black': true,
      'app_lock_enabled': true,
      'focus_pomo_enabled': true,
      'focus_pomo_focus_sec': 25,
      'focus_pomo_short_sec': 5,
      'focus_pomo_long_sec': 15,
      'focus_pomo_rounds': 4,
      'focus_custom_sec': 45,
      'focus_sound_type': 2,
      'focus_sound_types': ['rain', 'wind'],
      'focus_sound_volume': 0.6,
      'focus_sys_calendar': false,
      'focus_goal_minutes': 120,
      'dnd_enabled': true,
      'dnd_start': 22,
      'dnd_end': 7,
      'snooze_minutes': 15,
      'weekly_goal_count': 5,
      'trash_retention_days': 30,
      'background_guard': true,
      'onboarding_seen': true,
      'auto_backup_enabled': false,
      // 非白名单（应排除）
      'app_lock_biometric': 'enrolled', // 系统生物特征，不可导出
      'update_skip_version': '2.6.5', // 更新检查状态
      'update_last_auto_check': '2026-08-25', // 更新检查状态
      'focus_active_timer': 'running', // 运行中的计时器
      'samples_seeded_v1': true, // 示例数据标记
    });

    final prefs = await collectAppPrefs();

    // 白名单内应存在
    expect(prefs.containsKey('theme_mode'), isTrue);
    expect(prefs.containsKey('theme_follow_system'), isTrue);
    expect(prefs.containsKey('theme_use_dynamic'), isTrue);
    expect(prefs.containsKey('theme_seed'), isTrue);
    expect(prefs.containsKey('theme_pure_black'), isTrue);
    expect(prefs.containsKey('app_lock_enabled'), isTrue);
    expect(prefs.containsKey('focus_pomo_enabled'), isTrue);
    expect(prefs.containsKey('focus_pomo_focus_sec'), isTrue);
    expect(prefs.containsKey('focus_pomo_short_sec'), isTrue);
    expect(prefs.containsKey('focus_pomo_long_sec'), isTrue);
    expect(prefs.containsKey('focus_pomo_rounds'), isTrue);
    expect(prefs.containsKey('focus_custom_sec'), isTrue);
    expect(prefs.containsKey('focus_sound_type'), isTrue);
    expect(prefs.containsKey('focus_sound_types'), isTrue);
    expect(prefs['focus_sound_types'], equals(['rain', 'wind']));
    expect(prefs.containsKey('focus_sound_volume'), isTrue);
    expect(prefs.containsKey('focus_sys_calendar'), isTrue);
    expect(prefs.containsKey('focus_goal_minutes'), isTrue);
    expect(prefs.containsKey('dnd_enabled'), isTrue);
    expect(prefs.containsKey('dnd_start'), isTrue);
    expect(prefs.containsKey('dnd_end'), isTrue);
    expect(prefs.containsKey('snooze_minutes'), isTrue);
    expect(prefs.containsKey('weekly_goal_count'), isTrue);
    expect(prefs.containsKey('trash_retention_days'), isTrue);
    expect(prefs.containsKey('background_guard'), isTrue);
    expect(prefs.containsKey('onboarding_seen'), isTrue);
    expect(prefs.containsKey('auto_backup_enabled'), isTrue);

    // 非白名单应排除
    expect(prefs.containsKey('app_lock_biometric'), isFalse);
    expect(prefs.containsKey('update_skip_version'), isFalse);
    expect(prefs.containsKey('update_last_auto_check'), isFalse);
    expect(prefs.containsKey('focus_active_timer'), isFalse);
    expect(prefs.containsKey('samples_seeded_v1'), isFalse);

    // 总数应恰好等于白名单长度（26）
    expect(prefs.length, 26);
  });

  test('applyAppPrefs 写回后 collectAppPrefs 能原样取回（含 List<String>）', () async {
    SharedPreferences.setMockInitialValues({});
    final sample = <String, dynamic>{
      'theme_mode': false,
      'theme_follow_system': true,
      'theme_use_dynamic': true,
      'theme_seed': 0xFF2196F3,
      'theme_pure_black': false,
      'app_lock_enabled': true,
      'focus_pomo_enabled': true,
      'focus_pomo_focus_sec': 25,
      'focus_pomo_short_sec': 5,
      'focus_pomo_long_sec': 15,
      'focus_pomo_rounds': 4,
      'focus_custom_sec': 45,
      'focus_sound_type': 2,
      'focus_sound_types': ['rain', 'wind'],
      'focus_sound_volume': 0.5,
      'focus_sys_calendar': false,
      'focus_goal_minutes': 120,
      'dnd_enabled': true,
      'dnd_start': 22,
      'dnd_end': 7,
      'snooze_minutes': 10,
      'weekly_goal_count': 0,
      'trash_retention_days': 30,
      'background_guard': true,
      'onboarding_seen': true,
      'auto_backup_enabled': true,
    };

    await applyAppPrefs(sample);
    final back = await collectAppPrefs();
    expect(back, equals(sample));
  });

  test('applyAppPrefs 对 null/空输入安全返回', () async {
    SharedPreferences.setMockInitialValues({});
    await applyAppPrefs(null);
    await applyAppPrefs(<String, dynamic>{});
    final prefs = await collectAppPrefs();
    expect(prefs.isEmpty, isTrue);
  });

  test('applyAppPrefs 跳过含非字符串元素的异常数组，保留现有值', () async {
    SharedPreferences.setMockInitialValues({'focus_sound_types': ['rain']});
    // 含 int 的异常数组：不应覆盖现有合法值。
    await applyAppPrefs(<String, dynamic>{
      'focus_sound_types': [1, 2, 3],
    });
    final sp = await SharedPreferences.getInstance();
    expect(sp.getStringList('focus_sound_types'), equals(['rain']));
  });
}
