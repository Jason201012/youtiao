import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/gbk_codec.dart'; // P3-6（v3.0.0 审计）：共享文本解码链
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/backup_validator.dart';
import 'package:todolist/services/backup_summary.dart';
import 'package:todolist/services/backup_crypto.dart';
import 'package:todolist/services/daily_briefing.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/prefs_backup.dart';
import 'package:todolist/services/task_templates.dart'; // M2（v3.0.8 审计）：备份/恢复纳入用户模板
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/theme_provider.dart';
import 'package:todolist/state/app_lock_provider.dart';
import 'package:todolist/state/onboarding_provider.dart';

/// P2-2（v3.1.4 审计）：恢复前预演——备份里习惯 / 打卡 / 专注段为**空列表**
/// 是危险信号。旧版本在习惯或专注库加载失败时照样生成当日快照（段为空），
/// 面板却显示为正常快照；用户一旦从它恢复，`data['habits'] is List` 成立、
/// 按空列表覆盖，本机习惯与专注历史被静默清空。这里至少给一次二次确认。
/// 两条恢复路径（文件 / 本地快照）共用，避免只补一条又漏一条。
Future<bool> confirmEmptyRestoreSections(
    BuildContext context, Map<String, dynamic> data) async {
  final empty = <String>[
    if (data['habits'] is List && (data['habits'] as List).isEmpty) '习惯',
    if (data['check_ins'] is List && (data['check_ins'] as List).isEmpty) '打卡记录',
    if (data['focus_sessions'] is List &&
        (data['focus_sessions'] as List).isEmpty)
      '专注记录',
  ];
  if (empty.isEmpty) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('这份备份可能不完整'),
      content: Text(
          '备份中的${empty.join('、')}为空。继续恢复会清空本机现有的${empty.join('、')}，且无法撤销。'
          '建议先导出当前数据，或换一份完整备份。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('仍要恢复')),
      ],
    ),
  );
  return ok == true;
}

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
    // T3-1（v2.9.2 功能增强）：口令提示（可选）。预填本机已存提示，便于增量更新；
    // 明文本机存储、不随备份文件导出（见 TaskProvider._kAutoBackupPassHint 注释）。
    final hintCtrl =
        TextEditingController(text: taskProvider.autoBackupPassHint);
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
                  const SizedBox(height: 8),
                  // T3-1（v2.9.2 功能增强）：口令提示（可选）。仅存本机，
                  // 恢复解密失败时展示帮助回忆；不随备份文件导出。
                  TextField(
                    controller: hintCtrl,
                    maxLength: 60,
                    decoration: InputDecoration(
                      labelText: '口令提示（可选）',
                      hintText: '一句只有你看得懂的提醒，如「老家的门牌号」',
                      helperText: '仅存本机、不进备份文件',
                      counterText: '',
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
                      // N14（v3.0.9 审计）：枚举补齐——附件与用户模板实际
                      // 已进备份（P0-1 / M2），文案却停留在「任务、习惯、
                      // 专注记录与设置」，「完整数据」名不副实。
                      : '导出完整数据（任务、习惯、专注记录、附件、用户模板与设置），可分享保存'),
                  onTap: () {
                    // P0-1 修复：口令必须在「清空输入框之前」取成局部变量并传出。
                    // 原实现先 clear() 再读 passCtrl.text，读到空串导致勾选加密仍写明文。
                    String? confirmedPass;
                    // P3-16（v2.9.9 审计）：提示与口令一样先取局部变量，
                    // 备份成功后才由 _doBackup 落本机。
                    String? passHint;
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
                      // 校验全部通过后才锁定口令到局部变量，随后再清空输入框。
                      confirmedPass = p;
                      // T3-1：提示随导出口令传出，**备份成功后**才落本机（P3-16，
                      // v2.9.9 审计：旧实现在导出结果之前就保存——取消保存 /
                      // 导出失败时提示仍已落盘，与实际口令脱节）。
                      // 不等待：提示保存失败不影响备份主流程。
                      passHint = hintCtrl.text;
                      passCtrl.clear();
                      passConfirmCtrl.clear();
                    }
                    Navigator.pop(ctx);
                    _doBackup(taskProvider, focusProvider, habitProvider,
                        context, includeTrash,
                        encryptOn: encrypt, pass: confirmedPass, passHint: passHint);
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
    // P3-16（v2.9.9 审计）：口令提示——备份**成功落盘后**才保存（旧实现在
    // 导出动作之前就落盘，取消 / 失败时提示与口令脱节）。null = 不动提示。
    String? passHint,
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
      // P2-19：手动备份与自动备份保持一致——一并打包 App 级偏好。
      // 旧版仅自动备份含，手动导出不含，恢复后界面开关看着对、实际是默认值。
      // 现在手动备份也带一份；写回时由 _doRestore 调用 applyAppPrefs。
      map['prefs'] = await collectAppPrefs();
      // P2-9：附件统计提示——若 collectBlobs 因超体积 / 缺失跳过了附件，
      // 在 snackbar 文案中告知用户，避免「我存的附件怎么没在备份里」的迷惑。
      final collectStats = readCollectStats(map['attachments'] as Map<String, dynamic>);
      // M2（v3.0.8 审计）：用户自定义模板纳入备份——模板是文件存储，此前
      // 完全不在备份覆盖范围内，恢复 / 换机即全部丢失。恢复见 restoreFromJson
      // （N7 起下沉进本体）。
      // N5（v3.0.9 审计）：消费收集失败信号——模板目录读取失败时备份里
      // user_templates 恒空，旧实现用户毫不知情（换机后才发觉）。失败在
      // 结果 snackbar 里如实告知（不阻断备份主流程）。
      final tplExport = await UserTemplateStore.exportAllForBackup();
      map['user_templates'] = tplExport.templates;
      final tplCollectFailed = tplExport.failed;
      // F13：导出前做大小预检。附件内联后整包若超过 32 MB，分享面板单文件大小
      // 敏感、还原端也会按 [DataIo.maxImportTextBytes] 拒绝读取——「写得出去、
      // 取不回来」。这里自动剥离 attachments 段，保住任务/习惯/偏好主体，
      // 并在 snackbar 文案里告知用户「附件已剥离」，提示有需要可手动另存。
      final stripped = DataIo.trimForExport(map);
      final payloadMap = stripped.$1;
      final attachmentsDropped = stripped.$2;
      final plain = const JsonEncoder.withIndent('  ').convert(payloadMap);

      // 新P3-3（v2.9.7 审计）：加密路径按**密文尺寸**预检——AES-GCM 信封以
      // base64 承载密文（约 1.33× 膨胀），明文约 >24MB 时密文 `.enc.json` 会超
      // 导入端 32MB 硬限（pickJsonFile 读取前拒绝），「备份成功落盘、需要还原
      // 时被拒于解密之前」。此处用**精确明文字节数**（utf8）估算密文文件尺寸，
      // 预算 = 上限 × 3/4 再减 1MB（信封字段 KB 级 + 估算安全余量）。
      if (encryptOn) {
        final plainBytes = utf8.encode(plain).length;
        final cipherBudget =
            (DataIo.maxImportTextBytes * 3 ~/ 4) - (1 << 20);
        if (plainBytes > cipherBudget) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('加密备份未执行：数据超过密文导入上限'
                  '（附件已剥离仍超限）。请减少大附件后重试，或改用不加密备份'),
              duration: Duration(seconds: 5),
            ));
          }
          return;
        }
      }

      // 口令加密导出：明文经 AES-256-GCM 信封化，落盘 / 分享的都是密文。
      // P0-1 守卫：encryptOn 为真而口令缺失时 buildBackupPayload 会抛
      // BackupEncryptException，整个备份中止（不写任何文件），绝不静默降级明文。
      final isEnc = encryptOn;
      final payload =
          buildBackupPayload(plain, encryptOn: encryptOn, pass: pass);
      final name =
          isEnc ? '有条-backup-${_ts()}.enc.json' : '有条-backup-${_ts()}.json';
      // 1) App 私有目录留一份，供「分享」按钮兜底使用（Downloads 写入失败也能发出去）
      final file = await DataIo.saveToAppDocs(name, payload);
      // P3-16（v2.9.9 审计）：备份已在 App 文档目录落盘 → 此刻才保存口令提示。
      // 不等待：提示保存失败不影响备份主流程。
      if (passHint != null) {
        unawaited(provider.setAutoBackupPassHint(passHint));
      }
      // 2) 同时写入系统「下载 / Downloads」目录，文件管理器可见
      String msg = isEnc
          ? '已加密保存到「下载」目录（凭口令恢复）'
          : '已保存到「下载」目录（Downloads）';
      // F13：超额自动剥离附件后，把这件事明确告诉用户，避免「为什么附件没在里面」
      // 的迷惑；并给出后续手动另存的提示（不在本补丁里做导入侧动作，避免范围蔓延）。
      if (attachmentsDropped) {
        msg = isEnc
            ? '已加密保存到「下载」目录（附件因体积超限已剥离，凭口令恢复）'
            : '已保存到「下载」目录（附件因体积超限已剥离）';
      }
      // P2-9：附件被打包阶段被跳过的提示——优先级低于 F13 的「剥离」，
      // 后者更严重，覆盖在前者上。
      else if (collectStats.hasSkipped) {
        final statMsg = collectStats.summary();
        if (statMsg != null) msg = '$msg（$statMsg）';
      }
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
            // N5（v3.0.9 审计）：模板收集失败追加在文案尾部——放在最终
            // snackbar 一处拼接，避免被下方「下载目录写入失败」分支覆盖。
            content: Text(tplCollectFailed
                ? '$msg（用户模板读取失败，未包含在备份中）'
                : msg),
            action: SnackBarAction(
              label: '分享',
              onPressed: () => DataIo.shareFile(file),
            ),
          ),
        );
      }
    } on BackupEncryptException catch (e) {
      // 加密意图无法满足：直接透出原因，不包装成「备份失败：BackupEncryptException: …」。
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
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
    // P2-1（v2.8.8 审计）：偏好类 Provider 必须在首个 await 之前捕获——恢复偏好后
    // 需要重读它们的内存态（与 [_restoreFromAutoBackup] 同口径），跨异步间隙不得
    // 再使用 BuildContext。
    final themeProvider = context.read<ThemeProvider>();
    final appLockProvider = context.read<AppLockProvider>();
    final onboardingProvider = context.read<OnboardingProvider>();
    // L-09：先做大小预检再读入，超限直接提示，避免超大文件把 App 读到 OOM。
    final picked = await DataIo.pickJsonFile();
    if (picked.cancelled) return;
    if (picked.error != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(picked.error!)));
      }
      return;
    }
    final raw = picked.content!;
    // 加密备份：先识别信封，弹出口令框解密成明文，再走与普通备份一致的校验/恢复流程。
    String plaintext = raw;
    if (isEncryptedEnvelope(raw)) {
      final pass = await _requestPassword(context);
      if (pass == null) return; // 用户取消
      try {
        plaintext = decryptEnvelope(raw, pass);
      } on BackupDecryptException catch (e) {
        if (context.mounted) {
          // T3-1（v2.9.2 功能增强）：解密失败时展示本机保存的口令提示帮助回忆。
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(_withPassHint('恢复失败：${e.message}', provider))));
        }
        return;
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(_withPassHint('解密失败：$e', provider))));
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
                // U3-6（v2.9.6 审计）：`Colors.red` → `colorScheme.error`。
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
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
    // A1（v3.1.1 功能增强）：确认前先解析出摘要——解析一次、复用到整个恢复
    // 流程（含干跑与 restoreFromJson 的入参），不产生二次 jsonDecode。
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(plaintext) as Map<String, dynamic>;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复失败：文件格式不正确（$e）')),
        );
      }
      return;
    }
    final summary = await BackupSummary.fromMap(
      data,
      encrypted: plaintext != raw, // 走过解密路径即为加密备份
      currentTaskCount: provider.tasks.length,
      currentTrashCount: provider.trash.length,
      currentHabitCount: habitProvider.habits.length,
      currentFocusCount: focusProvider.sessions.length,
    );
    // P2-2（v3.1.4 审计）：空 habits / check_ins / focus 段先过一道确认。
    if (!await confirmEmptyRestoreSections(context, data)) return;
    final confirm = await _showRestoreConfirm(
      context,
      title: '从备份恢复？',
      summary: summary,
      confirmLabel: '恢复',
    );
    if (confirm == null || !confirm.$1) return;
    // A1 范围选择：关闭「同时恢复设置」时跳过 applyAppPrefs 与偏好重载，
    // 只恢复任务 / 习惯 / 专注 / 模板 / 附件（文案已在开关副标题说明）。
    final restoreSettings = confirm.$2;
    // P3-5（v3.1.2 审计）：恢复全过程套不可取消的进度弹层（分阶段文案）——
    // 快照组装 / 加密与多步恢复都在主 isolate 同步执行，大库 + 加密时表现为
    // 「点了恢复就卡住」，用户可能反复点击。弹层在 finally 中自动收起。
    Future<bool> runRestoreSteps(void Function(String) stage) async {
      // P2-1（v3.1.3 审计）：安全模式下 `_persist` 恒 false，恢复的备份永远
      // 无法落盘——用户被引导「去恢复备份」，恢复又提示「写入未保存」，是
      // 无出口的死局（v3.1.2 报告方向③）。覆盖前先尝试重新加载一次：DB 已
      // 可访问即退出安全模式，本次恢复即可正常写库；仍失败则继续走恢复，
      // 结果里由 blobStats.persisted 如实提示「写入未保存」。
      // P2-1（v3.1.4 审计）：三侧任一处于安全模式都先重试**对应** Provider。
      // 旧实现只重试任务侧：习惯 / 专注仍不可写时 restoreSessions /
      // habitProvider.restoreFromJson 恒返回 false，用户被引导「去恢复备份」
      // 却永远落不了盘，与 v3.1.3 想解决的死局同构，只是换到另两个 Provider。
      if (provider.dbLoadFailed ||
          focusProvider.dbLoadFailed ||
          habitProvider.dbLoadFailed) {
        stage('正在重试加载数据…');
        await Future.wait([
          if (provider.dbLoadFailed) provider.retryLoad(),
          if (focusProvider.dbLoadFailed) focusProvider.retryLoad(),
          if (habitProvider.dbLoadFailed) habitProvider.retryLoad(),
        ]);
      }
      stage('正在生成恢复前回滚点…');
      // A1：恢复前自动快照——失败不阻断恢复，但结果里如实提示「不可回滚」。
      final snapOk = await provider.writePreRestoreSnapshot();
      try {
        stage('正在校验并恢复任务…');
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
        // A1：快照失败记入结果提示（warning 性质，恢复本身继续）。
        if (!snapOk) failures.add('恢复前快照未生成（本次恢复不可回滚）');
        // P3-10（v2.9.4 审计）：rescheduleReminders 仅在「本次会调 provider.load()」
        // 时才让位 —— load() 内部会重排任务提醒，且读到的是恢复后的新 DND/时区。
        // 若在此处再排一次，用的是**旧偏好**排出的结果，会被 load() 立刻覆盖，
        // 中间还多出一个错时提醒窗口。
        // ⚠️ 备份不含 prefs（旧备份）时下方 `if (data['prefs'] is Map)` 不成立、
        // provider.load() 不会执行 —— 此时必须由 restoreFromJson 自己重排，
        // 否则 restoreFromJson 的 cancelAll() 之后任务提醒全部漏挂。
        // A1：范围选择同口径——关「同时恢复设置」时 load() 同样不会执行，
        // 必须由 restoreFromJson 自己重排。
        final blobStats = await provider.restoreFromJson(plaintext,
            includeTrash: includeTrash,
            rescheduleReminders:
                !(restoreSettings && data['prefs'] is Map));
        // P3-6（v3.0.8 审计）：消费任务落盘结果并入 failures——旧实现丢弃，
        // 「已恢复」可能在任务未写库时上报（重启后恢复条目全部蒸发；习惯侧已于
        // v3.0.6 消费 bool，任务侧这里是不对称的漏网口）。
        if (!blobStats.persisted) {
          failures.add('任务（写入未保存，重启可能丢失）');
        }
        // P3-10（v2.9.4 审计）：附件还原的「部分失败」（超单文件上限 / 非法文件名 /
        // 体积截断）此前被 restoreFromJson 直接丢弃，用户只看到「已从备份恢复」，
        // 却在附件列表里发现附件不见了。这里把统计并入既有 failures 机制，
        // 让「任务恢复了、附件丢了」如实告知。
        final blobNote = blobStats.summary();
        if (blobNote != null) failures.add(blobNote);
        stage('正在恢复专注与习惯…');
        // 备份含专注记录时才覆盖；旧备份无此字段则保留现有专注数据不破坏。
        final focusList = data['focus_sessions'];
        if (focusList is List) {
          try {
            // P2-3（v3.1.2 审计）：消费落盘结果——安全模式（dbLoadFailed）下
            // _persist 恒 false，restoreSessions 已回滚内存；不消费会把
            // 「写入未保存」假报成「已恢复」，重启后专注历史静默蒸发。
            final ok = await focusProvider.restoreSessions(focusList);
            if (!ok) failures.add('专注记录（写入未保存，重启可能丢失）');
          } catch (e) {
            failures.add('专注记录（$e）');
          }
        }
        // 仅当备份含习惯/打卡字段时才恢复，避免老备份把现有习惯清空。
        if (data['habits'] is List || data['check_ins'] is List) {
          try {
            // U2-1（v3.0.6 审计）：消费 restoreFromJson 的落盘结果——旧实现
            // Future<void> 忽略：本步写库失败时 UI 仍报「已恢复」，重启后恢复的
            // 习惯/打卡静默丢失。并入既有 failures 机制如实告知。
            final ok = await habitProvider.restoreFromJson(data);
            if (!ok) failures.add('习惯/打卡（写入未保存，重启可能丢失）');
          } catch (e) {
            failures.add('习惯/打卡（$e）');
          }
        }
        // M2（v3.0.8 审计）：恢复用户模板（覆盖同 id）。单条损坏跳过；
        // 失败数并入 failures（≥1 条失败时提示，不打断主流程）。
        // N7（v3.0.9 审计）：恢复已下沉进 provider.restoreFromJson（见其
        // user_templates 段处理与 RestoreBlobsStats.templates*）——此处不再
        // 重复恢复（避免双恢复 / 失败数双计），仅按透出统计如实提示。
        if (blobStats.templatesTotal > 0 && blobStats.templatesFailed > 0) {
          failures.add('用户模板（恢复 ${blobStats.templatesRestored}/'
              '${blobStats.templatesTotal} 条，其余已跳过）');
        }
        stage('正在恢复偏好设置…');
        // P2-19：恢复偏好（仅当备份含 prefs 字段且用户选择「同时恢复设置」；
        // 老备份无则保持现有偏好不动，A1 范围选择关闭时同样保持）。
        // applyAppPrefs 内部已做白名单净化，写入 SharedPreferences。
        //
        // P2-1（v2.8.8 审计）：写回 prefs ≠ 内存生效。TaskProvider 的
        // dndEnabled / dndStartHour / dndEndHour / snoozeMinutes / trashRetentionDays /
        // focusGoalMinutes / weeklyGoalCount / autoBackupEnabled / appLockIdleSeconds /
        // calendarLunar / lockScreenPrivate / screenSecurityEnabled / allowExternalLinks /
        // briefingMorning* / briefingEvening* / habitNudge* 等**全部是 load() 从 prefs
        // 读入的内存字段**，getter 直接返回内存值——原实现只调 refreshAfterPrefs()
        // （= notifyListeners 纯刷新 UI），恢复的偏好本会话不生效：设置页仍显示旧值
        // （用户误以为恢复失败）、实际行为仍按旧值运行（免打扰 / 延后时长 / 回收站
        // 保留期 / 早晚简报与习惯挽留时刻 / 自动备份开关），且
        // rescheduleFixedTimeReminders() 会用旧时刻把简报与挽留重排一遍，直到下次
        // 重启才生效。这里补齐与自动备份还原路径完全一致的重载，使恢复即时生效。
        // 注意：AppLockProvider 不能用 load()（会立即 _locked=true 锁屏），
        // 改用 refreshEnabled() 仅刷新开关、不触发锁。
        if (restoreSettings && data['prefs'] is Map) {
          try {
            await applyAppPrefs(
                Map<String, dynamic>.from(data['prefs'] as Map));
            await provider.load(); // 重读任务 + 免打扰/延后/目标/后台保活/自动备份等
            await focusProvider.load();
            await habitProvider.load();
            await themeProvider.load(); // 外观主题（load 内部已 notifyListeners）
            await onboardingProvider.load(); // 引导页标记（load 内部已 notifyListeners）
            await appLockProvider.refreshEnabled(); // 仅刷新开关，不触发锁屏
            // U-3（v3.1.4 审计）：refreshEnabled 在本机无可用生物识别时会把
            // app_lock_enabled 强制写回 false；旧实现结果只提示「加密口令不迁移」，
            // 用户以为应用锁已恢复，实际被静默关闭。并入 failures 如实告知。
            if (appLockProvider.lastRefreshForceDisabled) {
              failures.add('应用锁（本机无可用生物识别/凭据，已关闭；如需启用请到设置中开启）');
            }
          } catch (e) {
            failures.add('偏好（$e）');
            // P3-10（v2.9.4 审计）：上面传了 rescheduleReminders: false，若在此
            // 抛错就跳过了 provider.load()（本次唯一的任务提醒重排点），
            // 而 restoreFromJson 已 cancelAll() —— 任务提醒会全部漏挂。
            // 这里用现有（旧）偏好补排一次，宁可按旧 DND 排也不能不排。
            provider.rescheduleAllNotifications();
          }
        }
        stage('正在重排提醒…');
        // P2-1/P2-2（v2.8.7 审计）：恢复后重建通知。
        // ① restoreFromJson 内部的 cancelAll 会把任务提醒之外的简报 / 挽留 /
        //    回收站预告 / 习惯打卡闹钟一并清空（原流程只重排任务提醒）；
        // ② 恢复的偏好可能携带「提醒时区」覆盖——applyAppPrefs 只写回
        //    SharedPreferences，NotificationService 内存时区不会自动刷新，
        //    不重解析则本轮会话仍按旧时区调度，时区设置形同静默丢失。
        // 因此先重解析时区，再按恢复后的数据全量重排（含习惯打卡闹钟）。
        try {
          await NotificationService.reloadTimezoneOverride();
        } catch (_) {}
        await rescheduleFixedTimeReminders(
            provider, focusProvider, habitProvider);
        try {
          await habitProvider.scheduleAllReminders();
        } catch (_) {}

        if (context.mounted) {
          // P2-2（v3.1.0 审计）：自动备份加密开关（auto_backup_encrypt）刻意不随
          // 备份迁移（口令在 secure storage、跨设备不存在）——恢复后开关回到
          // 关闭，属「静默降级」；在这里显式告知，不再无声。
          const encryptHint =
              '\n自动备份加密与口令不随备份迁移，如需加密请到「设置 → 备份与恢复」重新开启。';
          if (failures.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('已从备份恢复$encryptHint'),
                duration: Duration(seconds: 6),
              ),
            );
          } else {
            // 任务已成功恢复，但部分子系统失败：提示具体步骤，便于用户重试用子集。
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    '任务已恢复，但以下步骤失败：${failures.join('、')}$encryptHint'),
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
      return true;
    }

    await _withRestoreProgress(context, runRestoreSteps);
  }

  /// P3-5（v3.1.2 审计）：恢复过程进度层——[run] 执行期间显示不可取消的模态
  /// 弹层（barrierDismissible=false + PopScope canPop=false），分阶段文案经
  /// [stage] 更新；无论成功失败，弹层都在 finally 中收起后再返回，保证结果
  /// SnackBar 可见。两条恢复路径（文件 / 本地快照）共用。
  static Future<T> _withRestoreProgress<T>(
    BuildContext context,
    Future<T> Function(void Function(String stage) stage) run,
  ) async {
    final stage = ValueNotifier<String>('正在准备恢复…');
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<String>(
            valueListenable: stage,
            builder: (_, s, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(s, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      // P3-3（v3.1.3 审计）：`showDialog` 只是把路由 push 排进队列，旧实现
      // 紧接着就进入快照组装，弹层首帧还没渲染就被同步活占住（配合
      // encodeSnapshotOffMainThread 的 isolate 化才算真正兑现「弹层会转」）。
      // 让出一次事件循环，保证弹层先完成 push + 首帧。
      await Future<void>.delayed(Duration.zero);
      return await run((s) => stage.value = s);
    } finally {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
      try {
        await dialog;
      } catch (_) {}
      stage.dispose();
    }
  }

  /// A1（v3.1.1 功能增强）：恢复确认框——差异摘要 + 「同时恢复设置」开关 +
  /// 「备份比当前旧 N 天」弱提示（不阻止，只提醒）。
  /// 返回 (confirmed, restoreSettings)；用户取消（含点弹层外）返回 null。
  /// 两条恢复路径（文件 / 本地快照）共用，摘要文案由 [BackupSummary.describe]
  /// 单一真源生成。
  static Future<(bool, bool)?> _showRestoreConfirm(
    BuildContext context, {
    required String title,
    required BackupSummary summary,
    required String confirmLabel,
  }) {
    var restoreSettings = true; // 默认开：保持既有「含偏好恢复」的行为
    return showDialog<(bool, bool)>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(summary.describe(),
                      style: const TextStyle(fontSize: 13, height: 1.5)),
                  // A1：旧备份弱提示——不阻止恢复，只提醒用户确认状态。
                  if (summary.ageDays >= 1) ...[
                    const SizedBox(height: 8),
                    Text(
                      '提示：这份备份比当前旧 ${summary.ageDays} 天，'
                      '恢复前请确认它确实是你想要的状态。',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const Divider(height: 24),
                  // A1 范围选择：默认开（保持现有行为）；关闭时只恢复
                  // 任务/习惯/专注/模板/附件，不恢复偏好设置。
                  // P3-4（v3.1.2 审计）：备份不含偏好段时开关完全无效——隐藏
                  // 开关并如实说明，避免「设置被跳过 / 已恢复」的误判。
                  if (summary.prefKeys.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text('此备份未包含设置，仅恢复数据',
                          style: TextStyle(fontSize: 12)),
                    )
                  else
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('同时恢复设置'),
                      subtitle: const Text(
                          '关闭则不恢复早间简报、勿扰时段、提醒时区、应用锁等设置',
                          style: TextStyle(fontSize: 12)),
                      value: restoreSettings,
                      onChanged: (v) => setState(() => restoreSettings = v),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, (true, restoreSettings)),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ),
    );
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

  /// T3-1（v2.9.2 功能增强）：解密失败文案——本机保存过口令提示时附在失败
  /// 原因后帮助回忆。提示**仅存在本机**（明文 SharedPreferences，不进备份
  /// 白名单），因此只对「本机自己加密的备份」有参考意义；从别处导入的加密
  /// 备份用本机提示对不上是正常现象，文案用「本机保存的」限定词避免误导。
  static String _withPassHint(String base, TaskProvider provider) {
    final hint = provider.autoBackupPassHint;
    if (hint.isEmpty) return base;
    return '$base\n本机保存的口令提示：$hint';
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
    try {
      // L-09：快照虽是本地文件，仍按统一上限预检（异常膨胀 / 被外部改写时兜底）。
      final size = await entry.file.length();
      if (size > DataIo.maxImportTextBytes) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('快照文件异常（${(size / 1048576).toStringAsFixed(1)} MB），已拒绝还原'),
            ),
          );
        }
        return;
      }
      // P3-6（v3.0.0 审计）：与其他文本读取路径共享同一解码链（BOM→严格 UTF-8
      // →GBK 回退）——快照是本 App 写出的 UTF-8 JSON，GBK 风险为零，此处为
      // 全应用「读文本文件」口径的一致性收口。
      final raw = decodeTextFileBytes(await entry.file.readAsBytes());
      // L-08：加密快照（.enc.json）需先解密成明文，再走与明文快照一致的校验流程。
      String plaintext = raw;
      if (isEncryptedEnvelope(raw)) {
        final pass = await _requestPassword(context);
        if (pass == null) return; // 用户取消
        try {
          plaintext = decryptEnvelope(raw, pass);
        } on BackupDecryptException catch (e) {
          if (context.mounted) {
            // T3-1（v2.9.2 功能增强）：解密失败时展示本机口令提示帮助回忆。
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(_withPassHint('还原失败：${e.message}', provider))),
            );
          }
          return;
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(_withPassHint('解密失败：$e', provider))),
            );
          }
          return;
        }
      }
      final validation = BackupValidator.validate(plaintext);
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
                  // U3-6（v2.9.6 审计）：`Colors.red` → `colorScheme.error`。
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('仍要清空并还原'),
                ),
              ],
            ),
          );
          if (wipe != true) return;
        }
      }
      // A1（v3.1.1 功能增强）：确认前先解析出摘要（校验器已通过、加密已解开；
      // 解析一次复用到整个恢复流程）。原「校验前的通用确认框」由本摘要确认框
      // 替代——先看到要恢复什么，再决定是否继续。
      final Map<String, dynamic> data;
      try {
        data = jsonDecode(plaintext) as Map<String, dynamic>;
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('还原失败：快照格式不正确（$e）')),
          );
        }
        return;
      }
      final summary = await BackupSummary.fromMap(
        data,
        encrypted: plaintext != raw, // 走过解密路径即为加密快照
        currentTaskCount: provider.tasks.length,
        currentTrashCount: provider.trash.length,
        currentHabitCount: habitProvider.habits.length,
        currentFocusCount: focusProvider.sessions.length,
      );
      // P2-2（v3.1.4 审计）：与 _doRestore 同款的空段危险信号确认。
      if (!await confirmEmptyRestoreSections(context, data)) return;
      final confirm = await _showRestoreConfirm(
        context,
        title: '从 ${entry.label} 的快照还原？',
        summary: summary,
        confirmLabel: '还原',
      );
      if (confirm == null || !confirm.$1) return;
      // A1 范围选择：关闭「同时恢复设置」时跳过偏好恢复（与 _doRestore 同口径）。
      final restoreSettings = confirm.$2;
      // P3-5（v3.1.2 审计）：同 _doRestore——还原全过程套不可取消的进度弹层。
      Future<bool> runRestoreSteps(void Function(String) stage) async {
        // P2-1（v3.1.4 审计）：与 _doRestore 同款的三侧重试出口。
        if (provider.dbLoadFailed ||
            focusProvider.dbLoadFailed ||
            habitProvider.dbLoadFailed) {
          stage('正在重试加载数据…');
          await Future.wait([
            if (provider.dbLoadFailed) provider.retryLoad(),
            if (focusProvider.dbLoadFailed) focusProvider.retryLoad(),
            if (habitProvider.dbLoadFailed) habitProvider.retryLoad(),
          ]);
        }
        stage('正在生成恢复前回滚点…');
        // A1：恢复前自动快照——失败不阻断还原，但结果里如实提示「不可回滚」。
        final snapOk = await provider.writePreRestoreSnapshot();
        stage('正在校验并恢复任务…');
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
        // A1：快照失败记入结果提示（warning 性质，还原本身继续）。
        if (!snapOk) failures.add('恢复前快照未生成（本次还原不可回滚）');
        // P3-10（v2.9.4 审计）：同 _doRestore，消费附件还原统计；并按「本次是否会
        // 调 provider.load()」决定任务提醒的重排责任（A1 范围选择同口径）。
        final blobStats = await provider.restoreFromJson(plaintext,
            includeTrash: includeTrash,
            rescheduleReminders:
                !(restoreSettings && data['prefs'] is Map));
        // P3-6（v3.0.8 审计）：同 _doRestore，消费任务落盘结果并入 failures。
        if (!blobStats.persisted) {
          failures.add('任务（写入未保存，重启可能丢失）');
        }
        final blobNote = blobStats.summary();
        if (blobNote != null) failures.add(blobNote);
        stage('正在恢复专注与习惯…');
        final focusList = data['focus_sessions'];
        if (focusList is List) {
          try {
            // P2-3（v3.1.2 审计）：同 _doRestore——消费专注落盘结果并入 failures。
            final ok = await focusProvider.restoreSessions(focusList);
            if (!ok) failures.add('专注记录（写入未保存，重启可能丢失）');
          } catch (e) {
            failures.add('专注记录（$e）');
          }
        }
        if (data['habits'] is List || data['check_ins'] is List) {
          try {
            // U2-1（v3.0.6 审计）：同 _doRestore——消费落盘结果并入 failures。
            final ok = await habitProvider.restoreFromJson(data);
            if (!ok) failures.add('习惯/打卡（写入未保存，重启可能丢失）');
          } catch (e) {
            failures.add('习惯/打卡（$e）');
          }
        }
        // M2（v3.0.8 审计）：自动快照还原路径同样恢复用户模板。
        // N7（v3.0.9 审计）：同 _doRestore——恢复已下沉进
        // provider.restoreFromJson，此处仅按透出统计提示，不重复恢复。
        if (blobStats.templatesTotal > 0 && blobStats.templatesFailed > 0) {
          failures.add('用户模板（恢复 ${blobStats.templatesRestored}/'
              '${blobStats.templatesTotal} 条，其余已跳过）');
        }
        stage('正在恢复偏好设置…');
        // 还原 App 级偏好（外观/锁/专注/免打扰/通用开关）。
        // 写回 SharedPreferences 后，触发各 Provider 重新读取使内存态即时生效。
        // A1：仅当用户选择「同时恢复设置」且备份含 prefs 时执行；范围选择关闭
        // 或老备份无偏好段时保持现有偏好不动。
        // 注意：AppLockProvider 不能用 load()（会立即 _locked=true 锁屏），
        // 改用 refreshEnabled() 仅刷新开关、不触发锁。
        if (restoreSettings && data['prefs'] is Map) {
          try {
            await applyAppPrefs(data['prefs'] as Map<String, dynamic>);
            await provider.load(); // 重读任务 + 免打扰/延后/目标/后台保活/自动备份等
            await focusProvider.load();
            await habitProvider.load();
            await themeProvider.load(); // 外观主题（load 内部已 notifyListeners）
            await onboardingProvider.load(); // 引导页标记（load 内部已 notifyListeners）
            await appLockProvider.refreshEnabled(); // 仅刷新开关，不触发锁屏
            // U-3（v3.1.4 审计）：refreshEnabled 在本机无可用生物识别时会把
            // app_lock_enabled 强制写回 false；旧实现结果只提示「加密口令不迁移」，
            // 用户以为应用锁已恢复，实际被静默关闭。并入 failures 如实告知。
            if (appLockProvider.lastRefreshForceDisabled) {
              failures.add('应用锁（本机无可用生物识别/凭据，已关闭；如需启用请到设置中开启）');
            }
          } catch (e) {
            failures.add('偏好设置（$e）');
            // P3-10（v2.9.4 审计）：走到这里说明本次已让 restoreFromJson 跳过
            // 任务提醒重排（rescheduleReminders: false），但 provider.load()
            // 没跑成 —— 叠加 restoreFromJson 已 cancelAll()，任务提醒会全部漏挂。
            // 用现有（旧）偏好补排一次：宁可按旧 DND 排，也不能不排。
            provider.rescheduleAllNotifications();
          }
        }
        stage('正在重排提醒…');
        // P2-1/P2-2（v2.8.7 审计）：与 _doRestore 同口径——restoreFromJson 的
        // cancelAll 清空了简报/挽留/回收站预告/习惯打卡闹钟；且恢复的偏好可能
        // 携带「提醒时区」覆盖，须先重解析内存时区再全量重排，否则本轮会话
        // 仍按旧时区调度（设置形同静默丢失）。
        try {
          await NotificationService.reloadTimezoneOverride();
        } catch (_) {}
        await rescheduleFixedTimeReminders(
            provider, focusProvider, habitProvider);
        try {
          await habitProvider.scheduleAllReminders();
        } catch (_) {}
        if (context.mounted) {
          // P2-2（v3.1.0 审计）：同 _doRestore——自动备份加密开关不随备份迁移，
          // 恢复后显式告知（不静默降级）。
          const encryptHint =
              '\n自动备份加密与口令不随备份迁移，如需加密请到「设置 → 备份与恢复」重新开启。';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: failures.isEmpty
                  ? Text('已从 ${entry.label} 的自动备份还原$encryptHint')
                  : Text('任务已还原，但：${failures.join('、')}$encryptHint'),
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return true;
      }

      await _withRestoreProgress(context, runRestoreSteps);
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
                    // A1：恢复前快照用专属图标，与日常快照区分。
                    // U-12②（v3.1.2 审计）：label 已含「恢复前」后缀，不再叠
                    // 加「（回滚点）」——「… 恢复前（回滚点）」属措辞重复。
                    leading: Icon(entry.preRestore
                        ? Symbols.settings_backup_restore
                        : Symbols.history),
                    title: Text(entry.preRestore
                        ? entry.label
                        : '${entry.label} 快照'),
                    subtitle: Text(entry.statusLabel,
                        style: const TextStyle(fontSize: 12)),
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
