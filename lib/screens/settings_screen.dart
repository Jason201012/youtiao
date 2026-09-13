import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/theme_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/daily_briefing.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/command_palette_button.dart';
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

  // P2-3（v2.8.6 审计）：提醒时区覆盖（'' = 跟随系统）。仅用于展示当前值，
  // 持久化在 NotificationService 侧（SharedPreferences）。
  String _tzOverride = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadTimezone();
  }

  Future<void> _loadTimezone() async {
    final v = await NotificationService.getTimezoneOverride();
    if (mounted) setState(() => _tzOverride = v);
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (_) {
      // 读取失败则回退到编译期已知版本，保证不至于显示空白。
      // U17：旧回退值 '2.6.9' 长期未随版本走，展示与真实严重不符；
      // 这里与 pubspec.yaml 同步（每次发版顺手更新该常量）。
      if (mounted) setState(() => _version = '2.9.0');
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
                '口令保存在系统密钥库（Android 密钥库 / iOS Keychain），不再以明文写入磁盘；'
                '也不会随备份文件导出——换机恢复后需重新设置。',
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

  /// F15：修改 / 重置自动备份口令。
  ///
  /// - 已存在口令：先校验旧口令，再写入新口令（防止误改导致旧加密快照永久打不开）。
  /// - 不存在 / 选「强制重设」：跳过校验，但 UI 必须明确告知「旧加密快照永久无法解开」。
  Future<void> _changeAutoBackupPassphrase(BuildContext ctx) async {
    final provider = Provider.of<TaskProvider>(ctx, listen: false);
    final hasOld = provider.hasAutoBackupPassphrase;
    String? oldPass;
    if (hasOld) {
      final ctl = TextEditingController();
      String? err;
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (dctx) => StatefulBuilder(
          builder: (dctx, setLocal) => AlertDialog(
            title: const Text('先验证当前口令'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctl,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: '当前口令',
                    errorText: err,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(true),
                child: const Text('忘了旧密码'),
              ),
              FilledButton(
                onPressed: () {
                  if (!provider.verifyAutoBackupPassphrase(ctl.text)) {
                    setLocal(() => err = '当前口令不正确');
                    return;
                  }
                  Navigator.of(dctx).pop(true);
                },
                child: const Text('下一步'),
              ),
            ],
          ),
        ),
      );
      if (ok == null) return;
      // 走「忘了旧密码」分支：弹强提示确认强制重设。
      if (ok == true) {
        oldPass = null;
      } else {
        oldPass = ctl.text;
        if (!provider.verifyAutoBackupPassphrase(oldPass)) return;
      }
      if (oldPass == null) {
        final forced = await _confirmForceReset(ctx);
        if (forced != true) return;
      }
    }
    // 输入新口令
    final ctlNew = TextEditingController();
    final ctlConfirm = TextEditingController();
    String? errNew;
    final newPass = await showDialog<String>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setLocal) => AlertDialog(
          title: Text(hasOld ? '设置新口令' : '设置自动备份口令'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (oldPass == null && hasOld)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    '【强制重设】旧加密快照将永久无法解开，请确认你知道这意味着什么。',
                    style: TextStyle(color: Colors.deepOrange),
                  ),
                ),
              TextField(
                controller: ctlNew,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '新口令（至少 6 位）',
                  errorText: errNew,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctlConfirm,
                obscureText: true,
                decoration: const InputDecoration(labelText: '再次输入'),
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
                final v = ctlNew.text;
                if (v.length < 6) {
                  setLocal(() => errNew = '新口令至少 6 位');
                  return;
                }
                if (v != ctlConfirm.text) {
                  setLocal(() => errNew = '两次输入不一致');
                  return;
                }
                Navigator.of(dctx).pop(v);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (newPass == null || newPass.isEmpty) return;
    // P2-4：返回 -1 = 失败；否则为被标记失效的旧口令快照数。
    final changed = await provider.changeAutoBackupPassphrase(
      newPass,
      oldPass: oldPass,
      force: oldPass == null && hasOld,
    );
    if (!ctx.mounted) return;
    final msg = changed < 0
        ? '修改失败'
        : changed > 0
            ? '口令已更新；$changed 份旧口令加密快照已标记失效，将在 7 天内滚动清除'
            : '口令已更新';
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Future<bool?> _confirmForceReset(BuildContext ctx) {
    return showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('强制重设口令？'),
        content: const Text(
          '旧口令一旦丢失，无法找回。所有历史加密快照将永久无法解开（仍可手动删掉释放空间）。'
          '继续将清掉旧口令、写入新口令。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('仍要重设'),
          ),
        ],
      ),
    );
  }

  /// P2-3：提醒时区候选（IANA id, 展示名）。'' = 跟随设备时区（默认）。
  /// 常用时区 + 下方「自定义 IANA 时区」入口（P3-3）覆盖绝大多数场景，保持 UI 极简。
  static const List<(String, String)> _tzOptions = [
    ('', '跟随系统（推荐）'),
    ('Asia/Shanghai', '北京时间（Asia/Shanghai）'),
    ('Asia/Tokyo', '东京（Asia/Tokyo）'),
    ('Asia/Singapore', '新加坡（Asia/Singapore）'),
    ('Europe/London', '伦敦（Europe/London）'),
    ('Europe/Berlin', '柏林（Europe/Berlin）'),
    ('America/New_York', '纽约（America/New_York）'),
    ('America/Los_Angeles', '洛杉矶（America/Los_Angeles）'),
    ('Australia/Sydney', '悉尼（Australia/Sydney）'),
    ('UTC', '协调世界时（UTC）'),
  ];

  /// P3-3（v2.8.7 审计）：自定义时区入口的哨兵返回值（区别于候选 id 与 null=取消）。
  static const String _kCustomTzSentinel = '__custom_tz__';

  /// P2-3：行内展示文案（'' → 跟随系统；其余取候选名，未知 id 原样展示）。
  static String _tzLabel(String v) {
    if (v.isEmpty) return '跟随系统';
    for (final (id, name) in _tzOptions) {
      if (id == v) return name;
    }
    return v;
  }

  /// P2-3：选择提醒时区并立即生效——重解析时区、作废落点缓存后整体重排，
  /// 否则已挂的闹钟仍按旧时区响。
  ///
  /// P2-2（v2.8.7 审计）：重排对齐 onDayChanged 全量入口——除任务提醒外，
  /// 简报晨/晚两条、习惯挽留、回收站预告都是按**旧时区**烘焙的一次性闹钟，
  /// 须一并重排，避免切换后当日按旧时区错时响一次。
  /// P3-3（v2.8.7 审计）：候选清单外支持手动输入 IANA 时区（tz.getLocation 校验）；
  /// 切换后 SnackBar 反馈「已生效、已重排」。
  Future<void> _pickTimezone(BuildContext ctx, TaskProvider p) async {
    var picked = await showDialog<String>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: const Text('提醒时区'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ..._tzOptions.map((o) => RadioListTile<String>(
                    title: Text(o.$2),
                    value: o.$1,
                    groupValue: _tzOverride,
                    onChanged: (v) => Navigator.pop(d, v),
                  )),
              const Divider(height: 1),
              // P3-3：底层 tz.getLocation 支持任意 IANA id，固定清单外的时区
              // （如 Asia/Kolkata、Europe/Moscow）从这里手动输入。
              ListTile(
                leading: const Icon(Symbols.edit),
                title: const Text('自定义 IANA 时区…'),
                subtitle: _isCustomTz
                    ? Text('当前：$_tzOverride')
                    : null,
                onTap: () => Navigator.pop(d, _kCustomTzSentinel),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked == _kCustomTzSentinel) {
      picked = await _promptCustomTimezone(ctx);
    }
    if (picked == null) return;
    final value = picked; // 局部非空副本：picked 曾被重赋值，闭包内无法类型提升
    await NotificationService.setTimezoneOverride(value);
    // P2-2：任务提醒 + 简报 / 挽留 / 回收站预告全量重排。
    p.rescheduleAllNotifications();
    await rescheduleFixedTimeReminders(
      p,
      Provider.of<FocusProvider>(ctx, listen: false),
      Provider.of<HabitProvider>(ctx, listen: false),
    );
    if (mounted) setState(() => _tzOverride = value);
    // P3-3：生效反馈——让用户知道全量重排已发生、结果如何。
    if (mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(value.isEmpty
            ? '提醒时区已恢复跟随系统，全部提醒已重排'
            : '提醒时区已切换为「${_tzLabel(value)}」，全部提醒已按新时区重排'),
      ));
    }
  }

  /// P3-3：当前是否为「清单外的自定义时区」（用于行内与弹层展示当前值）。
  bool get _isCustomTz =>
      _tzOverride.isNotEmpty && !_tzOptions.any((o) => o.$1 == _tzOverride);

  /// P3-3：手动输入 IANA 时区名；保存前用 tz.getLocation 校验，非法留在弹层提示。
  Future<String?> _promptCustomTimezone(BuildContext ctx) async {
    final ctrl = TextEditingController(
        // 仅预填「清单外的当前值」；清单内 id / 跟随系统不预填，避免误导。
        text: _isCustomTz ? _tzOverride : '');
    final result = await showDialog<String>(
      context: ctx,
      builder: (d) => StatefulBuilder(
        builder: (d, setLocal) {
          String? error;
          void submit() {
            final v = ctrl.text.trim();
            if (v.isEmpty) {
              setLocal(() => error = '时区名不能为空');
              return;
            }
            try {
              tz.getLocation(v); // 合法性校验：IANA 时区库必须能解析
              Navigator.pop(d, v);
            } catch (_) {
              setLocal(() => error = '无法识别的时区名，请输入有效的 IANA 时区');
            }
          }

          return AlertDialog(
            title: const Text('自定义提醒时区'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'IANA 时区名，如 Asia/Kolkata、Europe/Moscow',
                errorText: error,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: submit,
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    return result;
  }

/// P1-2：把空闲秒数格式化为可读文案（0→关闭）。
String _formatIdle(int seconds) {
  if (seconds <= 0) return '关闭';
  if (seconds < 60) return '$seconds 秒';
  if (seconds % 60 == 0) return '${seconds ~/ 60} 分钟';
  return '${(seconds / 60).toStringAsFixed(1)} 分钟';
}

/// P1-2：选择「无操作自动锁定」时长。0=永不，其余为秒数。
  /// 仅在应用锁开启时才有意义；这里不强制校验开启态，由用户自行决定，
  /// 未开启应用锁时该设置无效（AppLockProvider.lock 在不启用时为空操作）。
  Future<void> _pickIdleLock(BuildContext ctx, TaskProvider p) async {
    final options = const [
      (0, '关闭'),
      (30, '30 秒'),
      (60, '1 分钟'),
      (300, '5 分钟'),
    ];
    final current = p.appLockIdleSeconds;
    final picked = await showDialog<int>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('无操作自动锁定'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('解锁后若持续无操作，到点自动重新上锁。'),
            const SizedBox(height: 8),
            ...options.map(
              (o) => RadioListTile<int>(
                title: Text(o.$2),
                value: o.$1,
                groupValue: current,
                onChanged: (v) => Navigator.of(dctx).pop(v),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked != null && picked != current) {
      await p.setAppLockIdleSeconds(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const TopAppBar(
          title: '设置',
          // U4：命令面板移动端入口。
          actions: [CommandPaletteButton(currentIndex: 5)],
        ),
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
                    // P2-3（v2.8.6 审计）：提醒时区。默认跟随设备；此前调度硬编码
                    // 北京时间，设备在其它时区时提醒早/晚数小时甚至排到「前一天」。
                    // P3-1（v2.8.7 审计）：行内说明能力边界——只管提醒触发时刻，
                    // 不改变任务完成 / 重置 / 统计的日期口径。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.public,
                        label: '提醒时区',
                        value: _tzLabel(_tzOverride),
                        subtitle: '仅改变提醒触发时刻，任务完成与统计仍按设备日期',
                        onTap: () => _pickTimezone(context, provider),
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
                            // U19：勿扰起止倒挂（如 22:00-7:00）在本 App 有明确定义
                            // ——表示「跨天勿扰」（22:00 到次日 7:00）。此前静默接受且
                            // 无任何说明，用户误以为设置未生效。这里显式提示语义。
                            // F-6（v2.8.5 审计）：原提示条件为 `>=`，把「起止相等」
                            // 也当成跨天展示「全天不提醒」——而 isDndHour 对相等
                            // 的真实行为是**不抑制任何提醒**（勿扰完全失效），
                            // 提示与行为相反。现拆成两个互斥分支，各自说真话。
                            if (provider.dndStartHour ==
                                provider.dndEndHour) ...[
                              const SizedBox(height: 6),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: Row(
                                  children: [
                                    Icon(Symbols.warning_amber,
                                        size: 14,
                                        color: appColors(context).meta),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '开始与结束时间相同，勿扰不会抑制任何提醒'
                                        '（请把两端错开至少 1 小时）',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: appColors(context).meta),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ] else if (provider.dndStartHour >
                                provider.dndEndHour) ...[
                              const SizedBox(height: 6),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: Row(
                                  children: [
                                    Icon(Symbols.info,
                                        size: 14,
                                        color: appColors(context).meta),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '结束早于开始 = 跨天勿扰'
                                        '（${provider.dndStartHour}:00 至次日 '
                                        '${provider.dndEndHour}:00 不提醒）',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: appColors(context).meta),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
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
                    // U17：原「数据」一组塞 15 项（回收站/标签/备份/加密/应用锁/截屏/
                    // 模板/导出/存储全混），难找且语义混乱。拆成「数据与备份」、
                    // 「隐私与安全」、「内容与工具」三组（下面组标题见各分隔点）。
                    _GroupTitle('数据与备份'),
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
                    // F15：补「修改 / 重置口令」入口。加密开关行只决定「是否启用」，
                    // 不暴露口令变更路径——找不到入口的用户只能卸装清库。
                    // 已设过口令：进入「先校验旧口令 → 设新口令」；未设：直接设。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.password,
                        label: provider.hasAutoBackupPassphrase
                            ? '修改 / 重置备份口令'
                            : '设置备份口令',
                        subtitle: provider.hasAutoBackupPassphrase
                            ? '修改需先验证当前口令；忘记则可强清（旧加密快照永久无法解开）'
                            : '未设置口令；可现在设置以启用加密快照',
                        onTap: () => _changeAutoBackupPassphrase(context),
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
                    const SizedBox(height: 24),
                    // U17：把原「数据」巨组（15 项全混）拆成更清晰的子组——
                    // 「数据与备份」（回收站/标签/备份/加密/口令/农历）与
                    // 「隐私与安全」（应用锁/锁屏/截屏/外链）。下面这组为隐私与安全。
                    _GroupTitle('隐私与安全'),
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
                    // P1-2：无操作自动锁定（仅在应用锁开启时生效）。点击弹窗选择时长。
                    Consumer<TaskProvider>(
                      builder: (context, provider, _) => SettingsRow(
                        icon: Symbols.timer,
                        label: '无操作自动锁定',
                        subtitle: provider.appLockIdleSeconds <= 0
                            ? '关闭（仅回到前台时锁定）'
                            : '空闲 ${_formatIdle(provider.appLockIdleSeconds)} 后自动锁定',
                        value: provider.appLockIdleSeconds <= 0 ? '关闭' : _formatIdle(provider.appLockIdleSeconds),
                        onTap: () => _pickIdleLock(context, provider),
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
                    const SizedBox(height: 24),
                    _GroupTitle('内容与工具'),
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
