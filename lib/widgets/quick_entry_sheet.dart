import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/task_parser.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/widgets/new_task_sheet.dart';
import 'package:todolist/widgets/task_toggle_undo.dart';

/// 快速录入弹层：一行自然语言直接建任务。
///
/// 输入时实时解析并把识别结果以 chip 形式回显，让用户随打随确认系统的理解，
/// 不必先学语法。解析不满意时可一键「更多选项」转入完整编辑弹层，草稿原样带过去。
class QuickEntrySheet extends StatefulWidget {
  /// 可选预填文本（如分享入口转发过来的文字），非空时录入层预填并实时解析。
  final String? initialText;
  /// P2-8：分享来源包名（原生侧经 getCallingActivity 取得），非空时显示「来自 XX」。
  final String? sourcePackage;
  /// P1-11：系统分享接收的图片/文件附件（已落盘到暂存目录的 [AttachmentRef]）。
  /// 非空时录入层展示附件预览，确认保存后挂到任务；[attachmentSession] 为该附件所在的暂存会话 id，
  /// 保存后由 [AttachmentService.promoteStaging] 提升为正式目录，取消则清理。
  final AttachmentRef? initialAttachment;
  final String? attachmentSession;
  const QuickEntrySheet(
      {super.key,
      this.initialText,
      this.sourcePackage,
      this.initialAttachment,
      this.attachmentSession});

  /// 打开快速录入。若用户选择「更多选项」，会带着草稿续开完整编辑弹层。
  /// [initialText] 用于分享建任务等场景：预填文本并立即解析出标题/截止时间。
  /// [sourcePackage] 为分享来源包名，用于在录入层提示用户内容来自哪个 App。
  /// [initialAttachment]/[attachmentSession] 为系统分享接收的附件（P1-11）。
  static Future<void> show(BuildContext context,
      {String? initialText,
      String? sourcePackage,
      AttachmentRef? initialAttachment,
      String? attachmentSession}) async {
    final draft = await showModalBottomSheet<Task>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QuickEntrySheet(
        initialText: initialText,
        sourcePackage: sourcePackage,
        initialAttachment: initialAttachment,
        attachmentSession: attachmentSession,
      ),
    );
    // 弹层内部只负责回传草稿，转场由调用方发起，避免 sheet 的 context 已销毁
    if (draft != null && context.mounted) {
      await TaskSheet.show(context,
          draft: draft, inheritedAttachmentSession: attachmentSession);
    }
  }

  @override
  State<QuickEntrySheet> createState() => _QuickEntrySheetState();
}

class _QuickEntrySheetState extends State<QuickEntrySheet> {
  final _controller = TextEditingController();
  ParsedTask _parsed = TaskParser.parse('');

  /// P1-11：系统分享接收的附件（已落盘暂存目录）。非空时展示预览，保存后挂到任务。
  AttachmentRef? _pendingAttachment;
  String? _attachmentSession;
  /// 附件所有权是否已转移（直接保存或转入完整编辑）：转移后 dispose 不再清理暂存目录。
  bool _consumed = false;

  @override
  void initState() {
    super.initState();
    // 分享建任务等场景：预填 initialText 并立即解析出标题/截止时间回显 chip。
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _controller.text = widget.initialText!;
      _parsed = TaskParser.parse(widget.initialText!);
    }
    // P1-11：预填分享接收的附件（已落盘暂存目录），保存后挂到任务。
    if (widget.initialAttachment != null) {
      _pendingAttachment = widget.initialAttachment;
      _attachmentSession = widget.attachmentSession;
    }
  }

  @override
  void dispose() {
    // P1-11：用户未保存（关闭/返回）且附件所有权仍在快速录入层时，清理未消费的暂存目录。
    if (!_consumed && _attachmentSession != null) {
      AttachmentService.removeStaging(_attachmentSession!).catchError((_) {});
    }
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() => _parsed = TaskParser.parse(v));
  }

  /// 直接入库并关闭
  Future<void> _submit() async {
    if (!_parsed.isValid) return;
    final provider = context.read<TaskProvider>();
    // P1-11：分享接收的附件随任务一并保存，并把暂存目录提升为正式目录。
    final base = _parsed.toTask();
    // P2-2（v3.0.7 审计）：消费新建落盘结果——null = 落盘失败且 provider 已
    // 回滚内存。旧实现 fire-and-forget 后直接 pop：列表立刻出现、重启即丢且
    // 零提示。失败停留本层提示（输入内容还在，重试不造重复任务），暂存附件
    // 不提升（dispose 按未消费清理）。
    final created = await provider.addTask(base.copyWith(
      attachments: _pendingAttachment != null ? [_pendingAttachment!] : const [],
    ));
    if (created == null) {
      if (context.mounted) {
        showTaskPersistFailedHint(context, provider: provider);
      }
      return;
    }
    if (_attachmentSession != null) {
      AttachmentService.promoteStaging(_attachmentSession!, created.id)
          .catchError((_) {});
    }
    _consumed = true;
    Navigator.pop(context);
  }

  /// 点击识别 chip 上的「×」：从输入文本中移除该片段区间并重新解析。
  void _removeSegment(ParseSegment s) {
    final t = _controller.text;
    if (s.start < 0 || s.end > t.length) return;
    final newText =
        (t.substring(0, s.start) + t.substring(s.end)).replaceAll(RegExp(r'\s+'), ' ').trim();
    _parsed = TaskParser.parse(newText);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
    setState(() {});
  }

  /// 把当前解析结果作为草稿回传给调用方，由它续开完整编辑弹层
  void _openFullEditor() {
    // P1-11：附件所有权转移给完整编辑弹层（由其负责提升/清理暂存目录）。
    _consumed = true;
    final draft = _parsed.isValid
        ? _parsed.toTask().copyWith(
            attachments: _pendingAttachment != null
                ? [_pendingAttachment!]
                : const [],
          )
        : Task(
            id: '',
            title: _controller.text.trim(),
            priority: Priority.medium,
            category: Category.work,
            attachments: _pendingAttachment != null
                ? [_pendingAttachment!]
                : const [],
          );
    Navigator.pop(context, draft);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);

    return Padding(
      // 贴住键盘上沿，保证输入区始终可见
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(AppColors.pagePadX, 12, AppColors.pagePadX, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 拖拽条
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: ext.track,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // 标题栏
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '快速新建',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: scheme.onSurface,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Symbols.close, color: ext.meta),
                      onPressed: () => Navigator.pop(context),
                      tooltip: '关闭',
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 来源提示（P2-8）：分享建任务时展示来源包名，便于识别可疑来源。
                if (widget.sourcePackage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '来自应用：${widget.sourcePackage}',
                      style: TextStyle(fontSize: 12, color: ext.meta),
                    ),
                  ),
                // P1-11：分享接收的附件预览（图片缩略图 / 文件卡片），可移除。
                if (_pendingAttachment != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _SharedAttachmentPreview(
                      ref: _pendingAttachment!,
                      sessionId: _attachmentSession,
                      onRemove: () {
                        setState(() {
                          _pendingAttachment = null;
                          // 附件移除即视为放弃：清理暂存目录（所有权仍在本层）。
                          if (_attachmentSession != null) {
                            AttachmentService.removeStaging(_attachmentSession!)
                                .catchError((_) {});
                            _attachmentSession = null;
                          }
                        });
                      },
                    ),
                  ),
                // 输入区
                TextField(
                  controller: _controller,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  textInputAction: TextInputAction.done,
                  onChanged: _onChanged,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: '例如：明天下午3点 交周报 !高 #工作',
                    hintStyle: TextStyle(color: ext.meta, fontSize: 15),
                    filled: true,
                    fillColor: ext.chip,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppColors.cardRadius),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  style: TextStyle(color: scheme.onSurface, fontSize: 17, height: 1.5),
                ),
                // 识别结果（无内容时整块收起，避免空占位）
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: _parsed.hasStructuredInfo
                      ? _PreviewSection(parsed: _parsed, onRemoveSegment: _removeSegment)
                      : const SizedBox(width: double.infinity),
                ),
                const SizedBox(height: 12),
                // 语法提示
                Text(
                  '支持：每月/农历 · 提前量 · 日期时间 · !优先级 · #标签 · 每天/每周X',
                  style: TextStyle(fontSize: 12, color: ext.meta),
                ),
                const SizedBox(height: 16),
                // 操作区
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _controller.text.trim().isEmpty ? null : _openFullEditor,
                      icon: const Icon(Symbols.tune, size: 18),
                      label: const Text('更多选项'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _parsed.isValid ? _submit : null,
                      icon: const Icon(Symbols.add, size: 20),
                      label: const Text('添加任务'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppColors.cardRadius),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// P1-11：分享接收附件的预览卡片（快速录入层内）。图片显示缩略图，其余显示类型+体积；
/// 点击可移除（移除即清理暂存目录）。
class _SharedAttachmentPreview extends StatelessWidget {
  final AttachmentRef ref;
  final String? sessionId;
  final VoidCallback onRemove;
  const _SharedAttachmentPreview(
      {required this.ref, this.sessionId, required this.onRemove});

  Future<File?> _file() async {
    if (sessionId == null) return null;
    try {
      final dir = await AttachmentService.stagingDir(sessionId!);
      final f = File('${dir.path}/${ref.fileName}');
      return f.existsSync() ? f : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    final icon = ref.type == AttachmentType.image
        ? Symbols.image
        : ref.type == AttachmentType.audio
            ? Symbols.graphic_eq
            : Symbols.description;
    return FutureBuilder<File?>(
      future: _file(),
      builder: (context, snap) {
        final file = snap.data;
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: ext.chip,
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
          ),
          child: Row(
            children: [
              if (ref.type == AttachmentType.image && file != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(file, width: 44, height: 44, fit: BoxFit.cover),
                )
              else
                Icon(icon, size: 28, color: ext.meta),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('已附附件',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface)),
                    const SizedBox(height: 2),
                    Text('${ref.type.label} · ${ref.sizeLabel}',
                        style: TextStyle(fontSize: 12, color: ext.meta)),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Symbols.close, size: 18, color: ext.meta),
                onPressed: onRemove,
                tooltip: '移除附件',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 「已识别」区：chip 行 + 提取出的纯标题
class _PreviewSection extends StatelessWidget {
  final ParsedTask parsed;
  final void Function(ParseSegment) onRemoveSegment;
  const _PreviewSection({required this.parsed, required this.onRemoveSegment});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Text(
          '已识别',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ext.meta),
        ),
        const SizedBox(height: 10),
        // 用 Wrap 而非 Row：标签多了会自动换行，不会在窄屏上溢出
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in parsed.segments)
              _SegmentChip(segment: s, onRemove: () => onRemoveSegment(s)),
          ],
        ),
        const SizedBox(height: 10),
        // 剥离标记后的纯标题，让用户确认「真正会被存下来的是什么」
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: ext.chip,
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
          ),
          child: Row(
            children: [
              Icon(Symbols.edit_note, size: 18, color: ext.meta),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  parsed.isValid ? parsed.title : '还缺一个任务名',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: parsed.isValid ? scheme.onSurface : ext.meta,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单个识别片段 chip：按语义类型上色配图标
class _SegmentChip extends StatelessWidget {
  final ParseSegment segment;
  final VoidCallback? onRemove;
  const _SegmentChip({required this.segment, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);

    late final Color bg;
    late final Color fg;
    late final IconData icon;

    switch (segment.kind) {
      case TokenKind.date:
        bg = scheme.primaryContainer;
        fg = scheme.onPrimaryContainer;
        icon = Symbols.event;
      case TokenKind.time:
        bg = scheme.primaryContainer;
        fg = scheme.onPrimaryContainer;
        icon = Symbols.schedule;
      case TokenKind.priority:
        final c = _priorityColor(segment.label, ext);
        bg = c.withOpacity(0.16);
        fg = c;
        icon = Symbols.flag;
      case TokenKind.category:
        bg = scheme.secondaryContainer;
        fg = scheme.onSecondaryContainer;
        icon = Symbols.folder;
      case TokenKind.tag:
        bg = scheme.secondaryContainer;
        fg = scheme.onSecondaryContainer;
        icon = Symbols.sell;
      case TokenKind.repeat:
        bg = scheme.tertiaryContainer;
        fg = scheme.onTertiaryContainer;
        icon = Symbols.repeat;
      case TokenKind.reminder:
        bg = scheme.errorContainer;
        fg = scheme.onErrorContainer;
        icon = Symbols.alarm;
      case TokenKind.duration:
        bg = scheme.tertiaryContainer;
        fg = scheme.onTertiaryContainer;
        icon = Symbols.timer;
      case TokenKind.location:
        bg = scheme.secondaryContainer;
        fg = scheme.onSecondaryContainer;
        icon = Symbols.location_on;
    }

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppColors.chipRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 5),
          Text(
            segment.label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: fg),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 2),
            Icon(Icons.close, size: 14, color: fg.withOpacity(0.8)),
          ],
        ],
      ),
    );
    if (onRemove == null) return chip;
    return InkWell(
      onTap: onRemove,
      borderRadius: BorderRadius.circular(AppColors.chipRadius),
      child: chip,
    );
  }

  Color _priorityColor(String label, AppColorsExt ext) {
    if (label.startsWith('高')) return ext.high;
    if (label.startsWith('低')) return ext.low;
    return ext.medium;
  }
}
