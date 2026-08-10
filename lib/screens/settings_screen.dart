import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/theme_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/settings_row.dart';
import 'package:todolist/widgets/backup_sheet.dart';
import 'package:todolist/widgets/export_sheet.dart';
import 'package:todolist/screens/help_screen.dart';
import 'package:todolist/screens/trash_screen.dart';
import 'package:todolist/services/update_checker.dart';
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
      if (mounted) setState(() => _version = '2.4.7');
    }
  }

  /// 手动检查更新：有新版弹窗，无新版提示「已是最新」。
  Future<void> _checkUpdateManually(BuildContext context) async {
    final res = await UpdateChecker.check();
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
                    _GroupTitle('数据'),
                    SettingsRow(
                      icon: Symbols.delete,
                      label: '回收站',
                      value: provider.trashCount > 0 ? '${provider.trashCount}' : null,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const TrashScreen(),
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
                    SettingsRow(
                      icon: Symbols.upload,
                      label: '导出数据',
                      onTap: () => ExportSheet.show(context),
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
