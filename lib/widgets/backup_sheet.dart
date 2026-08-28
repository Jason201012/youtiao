import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/backup_validator.dart';
import 'package:todolist/services/backup_crypto.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/theme_provider.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/state/onboarding_provider.dart';

/// 「备份与恢复」底部弹层：提供「备份到文件」「从备份恢复」，
/// 并可选择是否把回收站一并备份 / 恢复。
class BackupSheet {
  static Future<void> show(BuildContext context) async {
    final taskProvider = context.read<TaskProvider>();
    final focusProvider = context.read<FocusProvider>();
    final habitProvider = context.read<HabitProvider>();
    var includeTrash = true;
    // 加密导出相关状态：开关 + 两次口令输入（校验一致后才允许备份）。
    var encrypt = false;
    final passCtrl = TextEditingController();
    final passConfirmCtrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('备份与恢复',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('包含回收站'),
                  subtitle: const Text('备份与恢复时，一并处理回收站中的任务'),
                  value: includeTrash,
                  onChanged: (v) => setState(() => includeTrash = v),
                ),
                // 口令加密导出（AES-256-GCM）：开启后落盘/分享的都是密文，仅凭口令可恢复。
                // 口令丢失 = 数据不可恢复（这是特性不是缺陷），下方明确提示。
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('加密备份（口令保护）'),
                  subtitle: const Text('用口令加密后导出，落盘/分享都不裸奔；口令丢失将无法恢复'),
                  value: encrypt,
                  onChanged: (v) => setState(() => encrypt = v),
                ),
                if (encrypt) ...[
                  const SizedBox(height: 4),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '加密口令',
                      hintText: '至少 8 位，含大小写或数字中至少两类',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: passConfirmCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '确认口令',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      isDense: true,
                    ),
                  ),
                ],
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Symbols.backup),
                  title: const Text('备份到文件'),
                  subtitle: Text(encrypt
                      ? '加密导出完整数据（凭口令恢复）'
                      : '导出完整数据（任务、习惯、专注记录与设置），可分享保存'),
                  onTap: () {
                    if (encrypt) {
                      final p = passCtrl.text;
                      if (p.length < 8) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('口令至少 8 位，请重新输入')));
                        return;
                      }
                      // P2-6：强制口令复杂度——至少包含「大小写 / 数字」中两类字符，
                      // 杜绝纯数字等可被 GPU 数分钟爆破的弱口令（结合 P1-2 的 35 万轮迭代）。
                      if (!_isStrongPassword(p)) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('口令过弱：需含大小写字母或数字中至少两类')));
                        return;
                      }
                      if (p != passConfirmCtrl.text) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('两次输入的口令不一致')));
                        return;
                      }
                      passCtrl.clear();
                      passConfirmCtrl.clear();
                    }
                    Navigator.pop(ctx);
                    _doBackup(taskProvider, focusProvider, habitProvider,
                        context, includeTrash,
                        encryptOn: encrypt, pass: passCtrl.text);
                  },
                ),
                ListTile(
                  leading: const Icon(Symbols.restore),
                  title: const Text('从备份恢复'),
                  subtitle: const Text('选择此前的备份文件，覆盖当前数据'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _doRestore(taskProvider, focusProvider, habitProvider,
                        context, includeTrash);
                  },
                ),
                const Divider(height: 1),
                // S1：本地自动备份（滚动快照）入口，展示开关状态 + 最近成功时间 + 快照列表。
                _AutoBackupSection(
                    taskProvider: taskProvider,
                    context: context,
                    includeTrash: includeTrash),
              ],
            ),
          );
        },
      ),
    );
  }

  static Future<void> _doBackup(
    TaskProvider provider,
    FocusProvider focusProvider,
    HabitProvider habitProvider,
    BuildContext context,
    bool includeTrash, {
    bool encryptOn = false,
    String? pass,
  }) async {
    try {
      // 与任务数据合并番茄钟专注记录与习惯打卡记录，便于统一备份与恢复。
      final map = provider.backupData(includeTrash: includeTrash);
      map['focus_sessions'] = focusProvider.sessionsJson;
      final habitMap = habitProvider.backupData();
      map['habits'] = habitMap['habits'];
      map['check_ins'] = habitMap['check_ins'];
      // P0-1：手动备份同步纳入附件二进制（base64 内联），与自动备份 (_writeAutoBackup)
      // 一致，保证手动导出的备份也能完整还原附件；缺失文件由 collectBlobs 自动跳过。
      map['attachments'] = await provider.collectAttachmentBlobs(includeTrash);
      final plain = const JsonEncoder.withIndent('  ').convert(map);

      // 口令加密导出：明文经 AES-256-GCM 信封化，落盘 / 分享的都是密文。
      final isEnc = encryptOn && pass != null && pass.isNotEmpty;
      final payload = isEnc ? encrypt(plain, pass!) : plain;
      final name =
          isEnc ? '有条-backup-${_ts()}.enc.json' : '有条-backup-${_ts()}.json';
      // 1) App 私有目录留一份，供「分享」按钮兜底使用（Downloads 写入失败也能发出去）
      final file = await DataIo.saveToAppDocs(name, payload);
      // 2) 同时写入系统「下载 / Downloads」目录，文件管理器可见
      String msg = isEnc
          ? '已加密保存到「下载」目录（凭口令恢复）'
          : '已保存到「下载」目录（Downloads）';
      try {
        await DataIo.saveToDownloads(
          name,
          payload,
          mimeType: 'application/json',
        );
      } catch (e) {
        msg = isEnc
            ? '已生成加密备份（下载目录写入失败，请改用「分享」保存）'
            : '已生成备份（下载目录写入失败，请改用「分享」保存）';
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            action: SnackBarAction(
              label: '分享',
              onPressed: () => DataIo.shareFile(file),
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('备份失败：$e')));
      }
    }
  }

  static Future<void> _doRestore(
    TaskProvider provider,
    FocusProvider focusProvider,
    HabitProvider habitProvider,
    BuildContext context,
    bool includeTrash,
  ) async {
    final raw = await DataIo.pickJsonFile();
    if (raw == null) return;
    // 加密备份：先识别信封，弹出口令框解密成明文，再走与普通备份一致的校验/恢复流程。
    String plaintext = raw;
    if (isEncryptedEnvelope(raw)) {
      final pass = await _requestPassword(context);
      if (pass == null) return; // 用户取消
      try {
        plaintext = decryptEnvelope(raw, pass);
      } on BackupDecryptException catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('恢复失败：${e.message}')));
        }
        return;
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('解密失败：$e')));
        }
        return;
      }
    }
    // S3：恢复前置强校验，拦截「废档」——非「有条」备份 / 结构损坏 / 字段形态错误，
    // 避免在校验失败后才清空当前数据（UI 直接提示原因，不弹覆盖确认框）。
    // 加密备份已在此前解密为明文 plaintext；未加密则 plaintext == raw。
    final validation = BackupValidator.validate(plaintext);
    if (!validation.ok) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复被拒绝：${validation.message}')),
        );
      }
      return;
    }
    // S7 修复：空备份二次确认。备份为空（无任务、无回收站）而当前仍有任务时，
    // 直接覆盖会清空现有数据，必须强提示「将清空现有 N 条任务」并要求显式二次确认；
    // 空备份默认不允许直接覆盖有数据的库（用户需主动点击危险操作才放行）。
    if (validation.isEmpty) {
      final currentCount = provider.tasks.length;
      if (currentCount > 0) {
        final wipe = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('空备份将清空现有任务'),
            content: Text(
              '这份备份里没有任何任务或回收站内容，但你当前共有 $currentCount 条任务。'
              '继续恢复会用空内容覆盖，清空你现有的全部任务，且不可撤销。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(d, true),
                child: const Text('仍要清空并恢复'),
              ),
            ],
          ),
        );
        if (wipe != true) return;
      }
      // 当前也为空：空覆盖空无数据损失，走下方常规确认即可。
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('从备份恢复？'),
        content: const Text('这将用备份文件覆盖当前所有任务、习惯、设置与专注记录，且不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final data = jsonDecode(plaintext) as Map<String, dynamic>;
      // 先干跑解析专注/习惯/打卡：任一失败则在任务被覆盖前抛错，
      // 避免「任务已恢复、专注失败」的部分恢复假象（修复前 tasks 已被清空）。
      if (data['focus_sessions'] is List) {
        (data['focus_sessions'] as List)
            .map((e) => FocusSession.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      if (data['habits'] is List) {
        (data['habits'] as List)
            .map((e) => Habit.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      if (data['check_ins'] is List) {
        (data['check_ins'] as List)
            .map((e) => CheckIn.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      // 🟡 修复 Bug3（部分恢复可观测性）：恢复分三步（任务 → 专注 → 习惯/打卡），
      // 三步各自独立落盘，本身不存在「任务已换、习惯没换」的中间态残留数据问题，
      // 但任一步 IO 失败都应明确告诉用户哪一步失败，而不是笼统的「格式不正确」。
      // 任一步失败不中断已成功的前序步骤（各自已落盘），仅累计错误并提示。
      final failures = <String>[];
      await provider.restoreFromJson(plaintext, includeTrash: includeTrash);
      // 备份含专注记录时才覆盖；旧备份无此字段则保留现有专注数据不破坏。
      final focusList = data['focus_sessions'];
      if (focusList is List) {
        try {
          await focusProvider.restoreSessions(focusList);
        } catch (e) {
          failures.add('专注记录（$e）');
        }
      }
      // 仅当备份含习惯/打卡字段时才恢复，避免老备份把现有习惯清空。
      if (data['habits'] is List || data['check_ins'] is List) {
        try {
          await habitProvider.restoreFromJson(data);
        } catch (e) {
          failures.add('习惯/打卡（$e）');
        }
      }

      if (context.mounted) {
        if (failures.isEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已从备份恢复')));
        } else {
          // 任务已成功恢复，但部分子系统失败：提示具体步骤，便于用户重试用子集。
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('任务已恢复，但以下步骤失败：${failures.join('、')}'),
              duration: const Duration(seconds: 6),
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复失败：文件格式不正确或任务恢复出错（$e）')),
        );
      }
    }
  }

  /// 解密导入时弹出口令输入框；返回输入的口令，用户取消则返回 null。
  static Future<String?> _requestPassword(BuildContext context) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        title: const Text('输入备份口令'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '请输入加密该备份时设置的口令',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onSubmitted: (_) => Navigator.pop(d, ctrl.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctrl.text),
            child: const Text('解密'),
          ),
        ],
      ),
    );
    return result;
  }

  static String _ts() {
    final d = DateTime.now();
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${d.year}${p(d.month)}${p(d.day)}-${p(d.hour)}${p(d.minute)}';
  }

  /// P2-6：口令强度判定——至少包含「小写字母 / 大写字母 / 数字」中的两类字符。
  /// 纯数字 / 纯小写等弱口令可被 GPU 快速爆破，故强制多类组合。
  static bool _isStrongPassword(String p) {
    var classes = 0;
    if (p.contains(RegExp(r'[a-z]'))) classes++;
    if (p.contains(RegExp(r'[A-Z]'))) classes++;
    if (p.contains(RegExp(r'[0-9]'))) classes++;
    return classes >= 2;
  }

  /// 从本地自动备份快照还原：读取该快照文件全文 → 走与「从备份恢复」相同的
  /// 校验 + 覆盖流程（复用 [_doRestore] 的核心步骤，仅 raw 来源为本地文件）。
  static Future<void> _restoreFromAutoBackup(
    BuildContext context,
    AutoBackupEntry entry,
    TaskProvider provider,
    FocusProvider focusProvider,
    HabitProvider habitProvider,
    bool includeTrash,
  ) async {
    // 在首个 await 之前捕获各 Provider，避免跨异步间隙使用 BuildContext 的 lint。
    final themeProvider = context.read<ThemeProvider>();
    final appLockProvider = context.read<AppLockProvider>();
    final onboardingProvider = context.read<OnboardingProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('从自动备份还原？'),
        content: Text('这将用 ${entry.label} 的本地快照覆盖当前所有任务、习惯、设置与专注记录，且不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('还原'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final raw = await entry.file.readAsString();
      final validation = BackupValidator.validate(raw);
      if (!validation.ok) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('还原被拒绝：${validation.message}')),
          );
        }
        return;
      }
      // S7 修复（自动备份分支）：与「从备份恢复」一致的空备份二次确认。
      // 空快照且当前仍有任务时，必须强提示「将清空现有 N 条任务」并要求显式二次确认。
      if (validation.isEmpty) {
        final currentCount = provider.tasks.length;
        if (currentCount > 0) {
          final wipe = await showDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              title: const Text('空备份将清空现有任务'),
              content: Text(
                '这份自动备份快照里没有任何任务或回收站内容，但你当前共有 '
                '$currentCount 条任务。继续还原会用空内容覆盖，清空你现有的全部任务，'
                '且不可撤销。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(d, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('仍要清空并还原'),
                ),
              ],
            ),
          );
          if (wipe != true) return;
        }
      }
      final data = jsonDecode(raw) as Map<String, dynamic>;
      // 干跑解析专注/习惯/打卡（与 _doRestore 一致）。
      if (data['focus_sessions'] is List) {
        (data['focus_sessions'] as List)
            .map((e) => FocusSession.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      if (data['habits'] is List) {
        (data['habits'] as List)
            .map((e) => Habit.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      if (data['check_ins'] is List) {
        (data['check_ins'] as List)
            .map((e) => CheckIn.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      final failures = <String>[];
      await provider.restoreFromJson(raw, includeTrash: includeTrash);
      final focusList = data['focus_sessions'];
      if (focusList is List) {
        try {
          await focusProvider.restoreSessions(focusList);
        } catch (e) {
          failures.add('专注记录（$e）');
        }
      }
      if (data['habits'] is List || data['check_ins'] is List) {
        try {
          await habitProvider.restoreFromJson(data);
        } catch (e) {
          failures.add('习惯/打卡（$e）');
        }
      }
      // 还原 App 级偏好（外观/锁/专注/免打扰/通用开关）。
      // 写回 SharedPreferences 后，触发各 Provider 重新读取使内存态即时生效。
      // 注意：AppLockProvider 不能用 load()（会立即 _locked=true 锁屏），
      // 改用 refreshEnabled() 仅刷新开关、不触发锁。
      if (data['prefs'] is Map) {
        try {
          await applyAppPrefs(data['prefs'] as Map<String, dynamic>);
          await provider.load(); // 重读任务 + 免打扰/延后/目标/后台保活/自动备份等
          await focusProvider.load();
          await habitProvider.load();
          await themeProvider.load(); // 外观主题（load 内部已 notifyListeners）
          await onboardingProvider.load(); // 引导页标记（load 内部已 notifyListeners）
          await appLockProvider.refreshEnabled(); // 仅刷新开关，不触发锁屏
        } catch (e) {
          failures.add('偏好设置（$e）');
        }
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: failures.isEmpty
                ? Text('已从 ${entry.label} 的自动备份还原')
                : Text('任务已还原，但：${failures.join('、')}'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('还原失败：$e')),
        );
      }
    }
  }
}

/// 自动备份（滚动快照）区块：开关 + 最近成功时间 + 快照列表（一键还原）。
/// 设计为 Consumer<TaskProvider>，开关与最近时间变化即时刷新。
class _AutoBackupSection extends StatelessWidget {
  final TaskProvider taskProvider;
  final BuildContext context;
  final bool includeTrash;
  const _AutoBackupSection({
    required this.taskProvider,
    required this.context,
    required this.includeTrash,
  });

  @override
  Widget build(BuildContext context) {
    final provider = taskProvider;
    final lastOk = provider.lastAutoBackupDate;
    final err = provider.lastAutoBackupError;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('本地自动备份'),
          subtitle: Text(err != null
              ? '上次失败：$err'
              : (lastOk != null
                  ? '最近成功：${lastOk.month}月${lastOk.day}日（保留最近 7 天）'
                  : '开启后每天自动生成本地快照')),
          value: provider.autoBackupEnabled,
          onChanged: (v) => provider.setAutoBackupEnabled(v),
        ),
        FutureBuilder<List<AutoBackupEntry>>(
          future: provider.listAutoBackups(),
          builder: (ctx, snap) {
            final items = snap.data;
            if (items == null) {
              return const SizedBox(
                height: 40,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            if (items.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('暂无本地快照',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
              );
            }
            return Column(
              children: [
                for (final entry in items)
                  ListTile(
                    dense: true,
                    leading: const Icon(Symbols.history),
                    title: Text('${entry.label} 快照'),
                    trailing: const Icon(Symbols.restore),
                    onTap: () {
                      Navigator.pop(context); // 收起外层弹层
                      BackupSheet._restoreFromAutoBackup(
                        this.context,
                        entry,
                        taskProvider,
                        this.context.read<FocusProvider>(),
                        this.context.read<HabitProvider>(),
                        includeTrash,
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
