import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/task_parser.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/widgets/new_task_sheet.dart';

/// 快速录入弹层：一行自然语言直接建任务。
///
/// 输入时实时解析并把识别结果以 chip 形式回显，让用户随打随确认系统的理解，
/// 不必先学语法。解析不满意时可一键「更多选项」转入完整编辑弹层，草稿原样带过去。
class QuickEntrySheet extends StatefulWidget {
  /// 可选预填文本（如分享入口转发过来的文字），非空时录入层预填并实时解析。
  final String? initialText;
  const QuickEntrySheet({super.key, this.initialText});

  /// 打开快速录入。若用户选择「更多选项」，会带着草稿续开完整编辑弹层。
  /// [initialText] 用于分享建任务等场景：预填文本并立即解析出标题/截止时间。
  static Future<void> show(BuildContext context, {String? initialText}) async {
    final draft = await showModalBottomSheet<Task>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QuickEntrySheet(initialText: initialText),
    );
    // 弹层内部只负责回传草稿，转场由调用方发起，避免 sheet 的 context 已销毁
    if (draft != null && context.mounted) {
      await TaskSheet.show(context, draft: draft);
    }
  }

  @override
  State<QuickEntrySheet> createState() => _QuickEntrySheetState();
}

class _QuickEntrySheetState extends State<QuickEntrySheet> {
  final _controller = TextEditingController();
  ParsedTask _parsed = TaskParser.parse('');

  @override
  void initState() {
    super.initState();
    // 分享建任务等场景：预填 initialText 并立即解析出标题/截止时间回显 chip。
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _controller.text = widget.initialText!;
      _parsed = TaskParser.parse(widget.initialText!);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() => _parsed = TaskParser.parse(v));
  }

  /// 直接入库并关闭
  void _submit() {
    if (!_parsed.isValid) return;
    context.read<TaskProvider>().addTask(_parsed.toTask());
    Navigator.pop(context);
  }

  /// 把当前解析结果作为草稿回传给调用方，由它续开完整编辑弹层
  void _openFullEditor() {
    Navigator.pop(context, _parsed.isValid ? _parsed.toTask() : Task(
      id: '',
      title: _controller.text.trim(),
      priority: Priority.medium,
      category: Category.work,
    ));
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
                      ? _PreviewSection(parsed: _parsed)
                      : const SizedBox(width: double.infinity),
                ),
                const SizedBox(height: 12),
                // 语法提示
                Text(
                  '支持：日期时间 · !优先级 · #标签 · 每天/每周X 等重复',
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

/// 「已识别」区：chip 行 + 提取出的纯标题
class _PreviewSection extends StatelessWidget {
  final ParsedTask parsed;
  const _PreviewSection({required this.parsed});

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
            for (final s in parsed.segments) _SegmentChip(segment: s),
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
  const _SegmentChip({required this.segment});

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
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
        ],
      ),
    );
  }

  Color _priorityColor(String label, AppColorsExt ext) {
    if (label.startsWith('高')) return ext.high;
    if (label.startsWith('低')) return ext.low;
    return ext.medium;
  }
}
