import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/theme_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/daily_briefing.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/settings_row.dart';
import 'package:todolist/widgets/backup_sheet.dart';
import 'package:todolist/widgets/export_sheet.dart';
import 'package:todolist/widgets/task_template_sheet.dart';
import 'package:todolist/screens/help_screen.dart';
import 'package:todolist/screens/trash_screen.dart';
import 'package:todolist/screens/storage_screen.dart';
import 'package:todolist/screens/tag_manage_screen.dart'; // P1-13
import 'package:todolist/services/update_checker.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/widgets/update_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // 版本号从 pubspec.yaml 读取，避免与 AndroidManifest 的 versionName 不同步
  // （之前写死 '1.0.0'，导致 pubspec 已是 1.8.3 时界面仍显示旧值）。
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (_) {
      // 读取失败则回退到编译期已知版本，保证不至于显示空白
      if (mounted) setState(() => _version = '2.6.9');
    }
  }

  /// 简报设置变更后，立即重排通知（沿用同 id 覆盖机制，避免旧时间残留）。
  Future<void> _rescheduleBrief(TaskProvider p) => rescheduleBriefings(
        p,
        Provider.of<FocusProvider>(context, listen: false),
        Provider.of<HabitProvider>(context, listen: false),
      );

  /// F4：挽留设置变更后，立即按新时刻/开关重排（沿用同 id 覆盖机制）。
  Future<void> _rescheduleNudge(TaskProvider p) =>
      rescheduleHabitNudge(
        Provider.of<HabitProvider>(context, listen: false),
        enabled: p.habitNudgeEnabled,
        nudgeMinute: p.habitNudgeMinute,
      );

  /// 手动检查更新：有新版弹窗，无新版提示「已是最新」。
  Future<void> _checkUpdateManually(BuildContext context) async {    final res = await UpdateChecker.check();
    if (!mounted) return;
    if (res.hasUpdate && res.info != null) {
      await UpdateDialog.show(context, res.info!);
    } else {
      final msg = res.error != null
          ? '检查更新失败：${res.error}'
          : '已是最新版本 ${_version.isEmpty ? '' : _version}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// L-08：请求设置「自动备份口令」。返回 null 表示用户取消。
  ///
  /// 与手动加密备份共用同一套 AES-GCM 信封，口令仅存本机、不随备份导出。
  /// 如实告知能力边界：防的是「快照文件被单独拷出后可读」，不防 root / 物理接触。
  Future<String?> _requestAutoBackupPassphrase(BuildContext ctx) async {
    final controller = TextEditingController();
    String? errorText;
    final result = await showDialog<String>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setLocal) => AlertDialog(
          title: const Text('设置自动备份口令'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '开启后，每日自动快照会以 AES-256-GCM 加密后落盘。\n'
                '口令仅保存在本机，不会随备份文件导出——换机恢复后需重新设置。',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '口令（至少 6 位）',
                  errorText: errorText,
                ),
                onSubmitted: (v) {
                  if (v.length >= 6) Navigator.of(dctx).pop(v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final v = controller.text;
                if (v.length < 6) {
                  setLocal(() => errorText = '口令至少 6 位');
                  return;
                }
                Navigator.of(dctx).pop(v);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const TopAppBar(title: '设置'),
        Expanded(
          child: Consumer<TaskProvider>(
            builder: (context, provider, _) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppColors.pagePadX,
                  8,
                  AppColors.pagePadX,
                  20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _GroupTitle('通用'),
                    Consumer<ThemeProvider>(
                      builder: (context, theme, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SettingsRow(
                            icon: Symbols.brightness_auto,
                            label: '跟随系统',
                            switchValue: theme.followSystem,
                            onSwitchChanged: (v) => theme.setFollowSystem(v),
                          ),
                          const SizedBox(height: AppColors.contentGap),
                          SettingsRow(
                            icon: Symbols.palette,
                            label: '深色模式',
                            switchValue: theme.followSystem
                                ? MediaQuery.platformBrightnessOf(context) ==
                                    Brightness.dark
                                : theme.dark,
                            onSwitchChanged: theme.followSystem
                                ? null
                                : (v) => theme.setDark(v),
                          ),
                          const SizedBox(height: AppColors.contentGap),
                          SettingsRow(
                            icon: Symbols.auto_awesome,
                            label: 'Material You 跟随取色',
                            switchValue: theme.useDynamic,
                            onSwitchChanged: (v) => theme.setUseDynamic(v),
                          ),
                          const SizedBox(height: AppColors.contentGap),
                          SettingsRow(
                            icon: Symbols.contrast,
                            label: '纯黑背景（深色模式）',
                            switchValue: theme.pureBlack,
                            onSwitchChanged: (v) => theme.setPureBlack(v),
                          ),
                          const SizedBox(height: AppColors.contentGap),
                          const _ThemeColorRow(),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    SettingsRow(
                      icon: Symbols.notifications,
                      label: '通知提醒',
                      switchValue: provider.notificationsEnabled,
                      onSwitchChanged: provider.setNotificationsEnabled,
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    SettingsRow(
                      icon: Symbols.volume_up,
                      label: '声音',
                      switchValue: provider.soundEnabled,
                      onSwitchChanged: provider.setSoundEnabled,
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    SettingsRow(
                      icon: Symbols.shield,
                      label: '后台提醒守护',
                      switchValue: provider.backgroundGuardEnabled,
                      onSwitchChanged: (v) => provider.setBackgroundGuard(v),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    Consumer<FocusProvider>(
                      builder: (context, focus, _) => SettingsRow(
                        icon: Symbols.calendar_month,
                        label: '专注结束记入系统日历',
                        switchValue: focus.sysCalendarEnabled,
                        onSwitchChanged: (v) => focus.setSysCalendarEnabled(v),
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // 每日专注目标：点按在 关闭/30/60/90/120/180 分钟间切换；0=关闭（今日卡不展示进度环）。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.flag,
                        label: '每日专注目标',
                        value: provider.focusGoalLabel,
                        onTap: () async {
                          final options = [0, 30, 60, 90, 120, 180];
                          final picked = await showDialog<int>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('每日专注目标'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: options
                                    .map((m) => RadioListTile<int>(
                                          title: Text(m <= 0 ? '关闭' : '$m 分钟'),
                                          value: m,
                                          groupValue: provider.focusGoalMinutes,
                                          onChanged: (v) => Navigator.pop(d, v),
                                        ))
                                    .toList(),
                              ),
                            ),
                          );
                          if (picked != null) provider.setFocusGoalMinutes(picked);
                        },
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // B1 周目标（本周完成数）：点按在 关闭/10/20/30/50 个间切换；0=关闭（周报卡不展示进度）。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.event_repeat,
                        label: '每周任务目标',
                        value: provider.weeklyGoalLabel,
                        onTap: () async {
                          final options = [0, 10, 20, 30, 50];
                          final picked = await showDialog<int>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('每周任务目标'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: options
                                    .map((n) => RadioListTile<int>(
                                          title: Text(n <= 0 ? '关闭' : '$n 个'),
                                          value: n,
                                          groupValue: provider.weeklyGoalCount,
                                          onChanged: (v) => Navigator.pop(d, v),
                                        ))
                                    .toList(),
                              ),
                            ),
                          );
                          if (picked != null) provider.setWeeklyGoalCount(picked);
                        },
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // 稍后提醒时长：点按在 10/30/60/120 分钟间切换。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.schedule,
                        label: '稍后提醒时长',
                        value: '${provider.snoozeMinutes} 分钟',
                        onTap: () async {
                          final picked = await showDialog<int>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('稍后提醒时长'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: TaskProvider.snoozeOptions
                                    .map((m) => RadioListTile<int>(
                                          title: Text('$m 分钟'),
                                          value: m,
                                          groupValue: provider.snoozeMinutes,
                                          onChanged: (v) =>
                                              Navigator.pop(d, v),
                                        ))
                                    .toList(),
                              ),
                            ),
                          );
                          if (picked != null) provider.setSnoozeMinutes(picked);
                        },
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // 勿扰时段：开关 + 起止小时（整点）。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => Column(
                        children: [
                          SettingsRow(
                            icon: Symbols.do_not_disturb_on,
                            label: '勿扰时段',
                            value: provider.dndEnabled
                                ? '${provider.dndStartHour}:00 - ${provider.dndEndHour}:00'
                                : null,
                            switchValue: provider.dndEnabled,
                            onSwitchChanged: (v) => provider.setDnd(
                                enabled: v,
                                startHour: provider.dndStartHour,
                                endHour: provider.dndEndHour),
                          ),
                          if (provider.dndEnabled) ...[
                            const SizedBox(height: AppColors.contentGap),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _HourPicker(
                                      label: '开始',
                                      value: provider.dndStartHour,
                                      onChanged: (h) => provider.setDnd(
                                          enabled: true,
                                          startHour: h,
                                          endHour: provider.dndEndHour),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _HourPicker(
                                      label: '结束',
                                      value: provider.dndEndHour,
                                      onChanged: (h) => provider.setDnd(
                                          enabled: true,
                                          startHour: provider.dndStartHour,
                                          endHour: h),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    SettingsRow(
                      icon: Symbols.notifications_active,
                      label: '发送测试通知',
                      onTap: () async {
                        // 关键自检：总开关关闭时，所有定时提醒都不会发（但 show() 即时测试仍会弹，
                        // 造成「测试有通知、任务没通知」的假象）。先拦截提示。
                        if (!provider.notificationsEnabled) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  '「通知提醒」总开关已关闭：任务不会提醒，请先打开它再试'),
                            ),
                          );
                          return;
                        }
                        final granted =
                            await provider.requestNotificationPermission();
                        if (granted == false) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  '未授予通知权限：请前往 设置→应用→有条→通知，开启「允许通知」'),
                            ),
                          );
                          return;
                        }
                        // 诊断 + 测试：无论精确闹钟权限是否授予，都先跑测试（即时 + AlarmManager + 应用内延迟），
                        // 让用户一定能看到反馈，并据此判断是被权限拦截还是被系统拦截。
                        final exactOk = await NotificationService
                            .instance.canScheduleExactAlarms();
                        final msg = await NotificationService.instance.showTest();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(msg),
                            duration: const Duration(seconds: 8),
                          ),
                        );
                        // 若未授予精确闹钟权限，仍引导去系统设置开启（ColorOS 常需此权限才放行定时）。
                        if (!exactOk) {
                          await NotificationService.instance
                              .openExactAlarmSettings();
                        }
                      },
                    ),
                    const SizedBox(height: 24),
                    _GroupTitle('简报推送'),
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.nightlight,
                        label: '晚间小结',
                        subtitle: '每日定时推送今日完成 / 专注 / 习惯汇总',
                        value:
                            '${provider.briefingEveningHour}:${provider.briefingEveningMinute.toString().padLeft(2, '0')}',
                        switchValue: provider.briefingEveningEnabled,
                        onSwitchChanged: (v) async {
                          provider.setBriefingEvening(enabled: v);
                          await _rescheduleBrief(provider);
                        },
                        onTap: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay(
                                hour: provider.briefingEveningHour,
                                minute: provider.briefingEveningMinute),
                          );
                          if (picked != null) {
                            provider.setBriefingEvening(
                                enabled: provider.briefingEveningEnabled,
                                hour: picked.hour, minute: picked.minute);
                            await _rescheduleBrief(provider);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.wb_sunny,
                        label: '晨间待办',
                        subtitle: '每日定时推送今日到期 / 逾期 / 昨日未完',
                        value:
                            '${provider.briefingMorningHour}:${provider.briefingMorningMinute.toString().padLeft(2, '0')}',
                        switchValue: provider.briefingMorningEnabled,
                        onSwitchChanged: (v) async {
                          provider.setBriefingMorning(enabled: v);
                          await _rescheduleBrief(provider);
                        },
                        onTap: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay(
                                hour: provider.briefingMorningHour,
                                minute: provider.briefingMorningMinute),
                          );
                          if (picked != null) {
                            provider.setBriefingMorning(
                                enabled: provider.briefingMorningEnabled,
                                hour: picked.hour, minute: picked.minute);
                            await _rescheduleBrief(provider);
                          }
                        },
                      ),
                    ),
                    // F4：习惯漏卡「挽留」通知独立配置（开关 + 时刻）。
                    const SizedBox(height: AppColors.contentGap),
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.notifications_active,
                        label: '习惯挽留提醒',
                        subtitle: '当天该打卡却还没打卡时，定时提醒一次',
                        value:
                            '${provider.habitNudgeMinute ~/ 60}:${(provider.habitNudgeMinute % 60).toString().padLeft(2, '0')}',
                        switchValue: provider.habitNudgeEnabled,
                        onSwitchChanged: (v) async {
                          provider.setHabitNudge(enabled: v);
                          await _rescheduleNudge(provider);
                        },
                        onTap: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay(
                                hour: provider.habitNudgeMinute ~/ 60,
                                minute: provider.habitNudgeMinute % 60),
                          );
                          if (picked != null) {
                            provider.setHabitNudge(
                                enabled: provider.habitNudgeEnabled,
                                minute: picked.hour * 60 + picked.minute);
                            await _rescheduleNudge(provider);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 24),
                    _GroupTitle('数据'),
                    // P1-12：回收站行 + 过期预告统计
                    SettingsRow(
                      icon: Symbols.delete,
                      label: '回收站',
                      value: provider.trashCount > 0 ? '${provider.trashCount}' : null,
                      subtitle: provider.trashRetentionDays < 0
                          ? null // 永不清理，不显示过期提示
                          : () {
                              final expiring = provider.trashExpiringCountWithin(7);
                              if (expiring <= 0) return null;
                              return '$expiring 条将于 7 天内被永久删除';
                            }(),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const TrashScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // P1-13：全局标签管理
                    SettingsRow(
                      icon: Symbols.label,
                      label: '标签管理',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const TagManageScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    SettingsRow(
                      icon: Symbols.backup,
                      label: '备份与恢复',
                      onTap: () => BackupSheet.show(context),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // S1 本地自动备份（滚动快照）：默认开启；跨日首启生成当日快照，
                    // 私有目录保留最近 7 份，作为 allowBackup=false 后的唯一数据防线。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.backup,
                        label: '本地自动备份',
                        // 副标题优先展示异常提示，否则展示最近快照日期。
                        subtitle: provider.lastAutoBackupError != null
                            ? '自动备份异常：${provider.lastAutoBackupError}'
                            : provider.lastAutoBackupLabel,
                        switchValue: provider.autoBackupEnabled,
                        onSwitchChanged: (v) => provider.setAutoBackupEnabled(v),
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // P0-3 日历农历：默认开启，与「农历重复」录入形成展示闭环。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.brightness_4,
                        label: '日历显示农历',
                        subtitle: '月视图每格显示农历日与节气 / 传统节日（离线计算）',
                        switchValue: provider.calendarLunar,
                        onSwitchChanged: (v) => provider.setCalendarLunar(v),
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // A4 应用锁：基于系统生物识别；设备不支持时禁用并提示。
                    // v2.6.4+：验证失败/不可用时系统弹窗允许降级用手机锁屏密码。
                    Consumer<AppLockProvider>(
                      builder: (context, lock, _) => SettingsRow(
                        icon: Symbols.lock,
                        label: '应用锁（生物识别）',
                        subtitle: lock.biometricAvailable
                            ? '仅遮挡界面，本地数据库仍为明文（非真加密）。每次进入需验证指纹/面容，防止身边人随手翻看'
                            : '当前设备不支持生物识别',
                        switchValue: lock.appLockEnabled,
                        onSwitchChanged: lock.biometricAvailable
                            ? (v) async {
                                final ok = await lock.setEnabled(v);
                                if (!ok && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('设备不支持生物识别，无法开启应用锁'),
                                    ),
                                  );
                                }
                              }
                            : null,
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // L-06：锁屏隐藏通知正文（默认隐藏）。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.lock,
                        label: '锁屏隐藏通知内容',
                        subtitle: provider.lockScreenPrivate
                            ? '锁屏只显示「有 N 条待办提醒」，解锁后才显示任务标题'
                            : '锁屏会完整显示任务标题（关闭应用锁时不建议）',
                        switchValue: provider.lockScreenPrivate,
                        onSwitchChanged: (v) => provider.setLockScreenPrivate(v),
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // L-07：FLAG_SECURE 防截屏 / 录屏（默认开启）。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.screenshot,
                        label: '禁止截屏与录屏',
                        subtitle: provider.screenSecurityEnabled
                            ? '最近任务缩略图为空白，系统截图 / 录屏被拦截'
                            : '最近任务会定格任务内容，且可被任意录屏软件录制',
                        switchValue: provider.screenSecurityEnabled,
                        onSwitchChanged: (v) =>
                            provider.setScreenSecurityEnabled(v),
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // L-08：本地自动备份加密（默认关闭，需先设口令）。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.enhanced_encryption,
                        label: '加密本地自动备份',
                        subtitle: provider.autoBackupEncrypt
                            ? '每日快照以 AES-256-GCM 加密后落盘（.enc.json）'
                            : '每日快照为明文 JSON；仅防误删，不防文件被拷出',
                        switchValue: provider.autoBackupEncrypt,
                        onSwitchChanged: (v) async {
                          if (v && !provider.hasAutoBackupPassphrase) {
                            final pass =
                                await _requestAutoBackupPassphrase(context);
                            if (pass == null) return; // 用户取消
                            await provider.setAutoBackupPassphrase(pass);
                          }
                          final ok = await provider.setAutoBackupEncrypt(v);
                          if (!ok && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('开启加密前需要先设置备份口令'),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // L-12：备注外链点击（默认关闭——本 App 除检查更新外不联网）。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.link,
                        label: '允许打开备注中的链接',
                        subtitle: provider.allowExternalLinks
                            ? '点击备注里的 http(s) 链接会唤起外部浏览器'
                            : '点击链接只复制到剪贴板，不静默外跳（推荐）',
                        switchValue: provider.allowExternalLinks,
                        onSwitchChanged: (v) => provider.setAllowExternalLinks(v),
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // 回收站自动清理：选择保留天数（7/30/90/永不）。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.delete_sweep,
                        label: '回收站自动清理',
                        value: provider.trashRetentionLabel,
                        onTap: () async {
                          final picked = await showDialog<int>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('回收站保留时长'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: TaskProvider.trashRetentionOptions
                                    .map((days) => RadioListTile<int>(
                                          title: Text(days < 0 ? '永不自动清理' : '$days 天'),
                                          value: days,
                                          groupValue: provider.trashRetentionDays,
                                          onChanged: (v) => Navigator.of(d).pop(v),
                                        ))
                                    .toList(),
                              ),
                            ),
                          );
                          if (picked != null) {
                            provider.setTrashRetentionDays(picked);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    SettingsRow(
                      icon: Symbols.playlist_add,
                      label: '任务模板库',
                      subtitle: '一键套用内置清单（开学 / 旅行 / 考试等）',
                      onTap: () => TaskTemplateSheet.show(context),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    SettingsRow(
                      icon: Symbols.upload,
                      label: '导出数据',
                      onTap: () => ExportSheet.show(context),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // P0-2 附件管理页 + 全局存储统计入口。
                    SettingsRow(
                      icon: Symbols.storage,
                      label: '存储空间',
                      subtitle: '查看附件占用、清理无主文件',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const StorageScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _GroupTitle('关于'),
                    SettingsRow(
                      icon: Symbols.system_update_alt,
                      label: '检查更新',
                      onTap: () => _checkUpdateManually(context),
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    SettingsRow(
                        icon: Symbols.info,
                        label: '版本',
                        value: _version.isEmpty ? '…' : _version,
                        showArrow: false),
                    const SizedBox(height: AppColors.contentGap),
                    SettingsRow(
                      icon: Symbols.help,
                      label: '帮助',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const HelpScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GroupTitle extends StatelessWidget {
  final String text;
  const _GroupTitle(this.text);
  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppColorsExt>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppColors.contentGap),
      child: Text(text,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ext.meta)),
    );
  }
}

/// 主题色选择行：默认（品牌色）+ 预设种子色。选中以白边 + 对勾标识。
class _ThemeColorRow extends StatelessWidget {
  const _ThemeColorRow();

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Row(
              children: [
                Icon(Symbols.palette, size: 20, color: ext.meta),
                const SizedBox(width: 12),
                Text('主题色', style: TextStyle(fontSize: 15, color: ext.meta)),
              ],
            ),
          ),
          Consumer<ThemeProvider>(
            builder: (context, theme, _) {
              final children = <Widget>[
                _Swatch(
                  label: '默认',
                  color: AppColors.lightPrimary,
                  selected: theme.seedColor == null,
                  onTap: () => theme.setSeedColor(null),
                ),
              ];
              for (final c in ThemeProvider.seedPresets) {
                children.add(_Swatch(
                  color: c,
                  selected: theme.seedColorValue == c.value,
                  onTap: () => theme.setSeedColor(c),
                ));
              }
              return Wrap(spacing: 12, runSpacing: 12, children: children);
            },
          ),
        ],
      ),
    );
  }
}

/// 勿扰时段「起/止小时」选择器：整点 0-23，左右各一个。极简紧凑，避免占用过多纵向空间。
class _HourPicker extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  const _HourPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(label,
              style: TextStyle(fontSize: 12, color: ext.meta)),
        ),
        Container(
          height: 44,
          decoration: BoxDecoration(
            color: ext.chip,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                onPressed: () => onChanged((value - 1).clamp(0, 23)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              GestureDetector(
                onTap: () => _pickHour(context),
                child: Text(
                  '$value:00',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                onPressed: () => onChanged((value + 1).clamp(0, 23)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _pickHour(BuildContext context) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('$label时间'),
        content: SizedBox(
          width: double.maxFinite,
          height: 240,
          child: ListView.builder(
            itemCount: 24,
            itemBuilder: (_, i) => RadioListTile<int>(
              title: Text('$i:00'),
              value: i,
              groupValue: value,
              onChanged: (v) => Navigator.pop(d, v),
            ),
          ),
        ),
      ),
    );
    if (picked != null) onChanged(picked);
  }
}

class _Swatch extends StatelessWidget {
  final String? label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({
    this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected
              ? Border.all(color: Colors.white, width: 3)
              : Border.all(color: Colors.white24, width: 1),
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 20)
            : (label != null
                ? Center(
                    child: Text(label!,
                        style: const TextStyle(color: Colors.white, fontSize: 10)),
                  )
                : null),
      ),
    );
  }
}
