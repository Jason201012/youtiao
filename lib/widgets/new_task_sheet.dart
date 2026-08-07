import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 新建 / 编辑任务弹层（M3 底部 sheet）。
/// 传入 [task] 为编辑模式（预填并调用 updateTask），否则为新建模式（调用 addTask）。
class TaskSheet extends StatefulWidget {
  final Task? task;
  const TaskSheet({super.key, this.task});

  static Future<void> show(BuildContext context, {Task? task}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TaskSheet(task: task),
    );
  }

  @override
  State<TaskSheet> createState() => _TaskSheetState();
}

class _TaskSheetState extends State<TaskSheet> {
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();
  final _subtaskController = TextEditingController();
  final _subtaskEditController = TextEditingController();
  Priority _priority = Priority.medium;
  Category _category = Category.work;
  DateTime? _dueDate;

  /// 子任务列表（编辑模式从任务预填）。
  List<SubTask> _subtasks = [];
  int? _editingIndex;

  /// 标签列表（编辑模式从任务预填）。
  List<String> _tags = [];
  final _tagController = TextEditingController();

  /// 重复规则与提醒时刻 / 星期 / 间隔。
  RepeatType _repeat = RepeatType.none;
  TimeOfDay _repeatTime = const TimeOfDay(hour: 7, minute: 0);
  List<int> _repeatWeekdays = [DateTime.monday];
  int _repeatInterval = 2;
  DateTime? _repeatAnchor; // interval 锚点，创建时填当天

  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      final t = widget.task!;
      _titleController.text = t.title;
      _priority = t.priority;
      _category = t.category;
      _dueDate = t.dueDate;
      _repeat = t.repeat;
      _repeatWeekdays = List.from(t.repeatWeekdays);
      _repeatInterval = t.repeatInterval;
      _repeatAnchor = t.repeatAnchor;
      _repeatTime = t.repeatMinute != null
          ? TimeOfDay(hour: t.repeatMinute! ~/ 60, minute: t.repeatMinute! % 60)
          : const TimeOfDay(hour: 7, minute: 0);
      _noteController.text = t.note;
      _subtasks = t.subtasks.map((s) => s.copyWith()).toList();
      _tags = List.from(t.tags);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    _subtaskController.dispose();
    _subtaskEditController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _formatTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _formatTimeOfDay(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (picked != null) {
      // 重复任务：截止时间固定为所选日期 23:59（作为重复窗口结束日）；否则保留既有时间或默认 09:00。
      final int h;
      final int m;
      if (_repeat != RepeatType.none) {
        h = 23;
        m = 59;
      } else {
        h = _dueDate?.hour ?? 9;
        m = _dueDate?.minute ?? 0;
      }
      setState(() => _dueDate = DateTime(picked.year, picked.month, picked.day, h, m));
    }
  }

  /// 重复规则变化：从「不重复」切到某种重复时，若没有截止日期则默认设为今天 23:59
  /// （作为重复窗口的结束日，与原「每天」行为一致）。切回「不重复」则保持截止日期不变。
  void _onRepeatChanged(RepeatType v) {
    setState(() {
      _repeat = v;
      if (v != RepeatType.none) {
        final now = DateTime.now();
        if (_dueDate == null) {
          _dueDate = DateTime(now.year, now.month, now.day, 23, 59);
        } else {
          _dueDate = DateTime(_dueDate!.year, _dueDate!.month, _dueDate!.day, 23, 59);
        }
      }
    });
  }

  Future<void> _pickTime() async {
    if (_dueDate == null) return; // 需先选日期
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueDate!),
      helpText: '选择提醒时间',
    );
    if (picked != null) {
      setState(() => _dueDate = DateTime(
        _dueDate!.year,
        _dueDate!.month,
        _dueDate!.day,
        picked.hour,
        picked.minute,
      ));
    }
  }

  Future<void> _pickRepeatTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _repeatTime,
      helpText: '选择提醒时间',
    );
    if (picked != null) setState(() => _repeatTime = picked);
  }

  void _addSubtask() {
    final title = _subtaskController.text.trim();
    if (title.isEmpty) return;
    setState(() {
      _subtasks.add(SubTask(
        id: '${DateTime.now().millisecondsSinceEpoch}_${_subtasks.length}',
        title: title,
      ));
      _subtaskController.clear();
    });
  }

  /// 添加标签：回车或加号触发；[raw] 非空时用于「已有标签」快捷添加。
  void _addTag({String? raw}) {
    final tag = (raw ?? _tagController.text).trim();
    if (tag.isEmpty) return;
    if (_tags.contains(tag)) {
      _tagController.clear();
      return;
    }
    setState(() {
      _tags.add(tag);
      _tagController.clear();
    });
  }

  void _removeTag(String tag) {
    setState(() => _tags.remove(tag));
  }

  /// 供快捷添加的「已有标签」（全库标签中尚未被本任务使用的）。
  List<String> _suggestedTags(TaskProvider provider) =>
      provider.allTags.where((t) => !_tags.contains(t)).toList();

  void _removeSubtask(int i) {
    setState(() {
      _subtasks.removeAt(i);
      if (_editingIndex == i) {
        _editingIndex = null;
        _subtaskEditController.clear();
      } else if (_editingIndex != null && _editingIndex! > i) {
        _editingIndex = _editingIndex! - 1;
      }
    });
  }

  void _toggleSubtask(int i, bool? v) {
    setState(() => _subtasks[i] = _subtasks[i].copyWith(done: v ?? false));
  }

  void _startEditSubtask(int i) {
    _editingIndex = i;
    _subtaskEditController.text = _subtasks[i].title;
    setState(() {});
  }

  void _commitEditSubtask(int i) {
    final title = _subtaskEditController.text.trim();
    setState(() {
      if (title.isNotEmpty) {
        _subtasks[i] = _subtasks[i].copyWith(title: title);
      }
      _editingIndex = null;
      _subtaskEditController.clear();
    });
  }

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    final provider = Provider.of<TaskProvider>(context, listen: false);
    final repeatMinute =
        _repeat != RepeatType.none ? _repeatTime.hour * 60 + _repeatTime.minute : null;
    // 每隔 N 天：创建时把锚点设为当天（date-only），保证从今天起每 N 天循环。
    final anchor = (_repeat == RepeatType.interval && !_isEdit)
        ? DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)
        : _repeatAnchor;
    final weekdays = _repeat == RepeatType.weekly
        ? (_repeatWeekdays.isNotEmpty ? List<int>.from(_repeatWeekdays) : [DateTime.monday])
        : const <int>[];
    if (_isEdit) {
      provider.updateTask(widget.task!.copyWith(
        title: title,
        priority: _priority,
        category: _category,
        dueDate: _dueDate,
        repeat: _repeat,
        repeatWeekdays: weekdays,
        repeatInterval: _repeatInterval,
        repeatMinute: repeatMinute,
        repeatAnchor: anchor,
        note: _noteController.text.trim(),
        tags: List.from(_tags),
        subtasks: List.from(_subtasks),
      ));
    } else {
      provider.addTask(Task(
        id: '',
        title: title,
        priority: _priority,
        category: _category,
        dueDate: _dueDate,
        repeat: _repeat,
        repeatWeekdays: weekdays,
        repeatInterval: _repeatInterval,
        repeatMinute: repeatMinute,
        repeatAnchor: anchor,
        note: _noteController.text.trim(),
        tags: List.from(_tags),
        subtasks: List.from(_subtasks),
      ));
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    final provider = Provider.of<TaskProvider>(context, listen: false);
    final canSave = _titleController.text.trim().isNotEmpty;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height -
            MediaQuery.of(context).viewInsets.bottom -
            12,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          AppColors.pagePadX,
          20,
          AppColors.pagePadX,
          MediaQuery.of(context).padding.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // 标题栏
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_isEdit ? '编辑任务' : '新建任务',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface)),
              IconButton(
                icon: Icon(Symbols.close, color: ext.meta),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 标题输入
          TextField(
            controller: _titleController,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '任务标题',
              hintStyle: TextStyle(color: ext.meta),
              filled: true,
              fillColor: ext.chip,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            style: TextStyle(color: scheme.onSurface, fontSize: 16),
          ),
          const SizedBox(height: 18),
          // 备注
          _SectionLabel('备注'),
          const SizedBox(height: 8),
          TextField(
            controller: _noteController,
            maxLines: 4,
            minLines: 2,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: '补充说明、链接、思路…（可选）',
              hintStyle: TextStyle(color: ext.meta),
              filled: true,
              fillColor: ext.chip,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            style: TextStyle(color: scheme.onSurface, fontSize: 15),
          ),
          const SizedBox(height: 18),
          // 子任务
          _SectionLabel('子任务'),
          const SizedBox(height: 8),
          // 添加输入行
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _subtaskController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addSubtask(),
                  decoration: InputDecoration(
                    hintText: '添加子任务，回车确认',
                    hintStyle: TextStyle(color: ext.meta),
                    filled: true,
                    fillColor: ext.chip,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppColors.chipRadius),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  style: TextStyle(color: scheme.onSurface, fontSize: 15),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _addSubtask,
                icon: const Icon(Symbols.add),
                style: IconButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          if (_subtasks.isNotEmpty)
            ..._subtasks.asMap().entries.map((entry) {
              final i = entry.key;
              final s = entry.value;
              return Container(
                margin: const EdgeInsets.only(top: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Row(
                  children: [
                    Checkbox(
                      value: s.done,
                      onChanged: (v) => _toggleSubtask(i, v),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _editingIndex == i
                          ? TextField(
                              controller: _subtaskEditController,
                              autofocus: true,
                              onSubmitted: (_) => _commitEditSubtask(i),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isCollapsed: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              style: TextStyle(
                                  color: scheme.onSurface, fontSize: 15),
                            )
                          : GestureDetector(
                              onTap: () => _startEditSubtask(i),
                              child: Text(
                                s.title,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: s.done ? ext.meta : scheme.onSurface,
                                  decoration: s.done
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                            ),
                    ),
                    IconButton(
                      onPressed: () => _removeSubtask(i),
                      icon: Icon(Symbols.close, size: 18, color: ext.meta),
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          const SizedBox(height: 18),
          // 标签
          _SectionLabel('标签'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tagController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addTag(),
                  decoration: InputDecoration(
                    hintText: '添加标签，回车确认（如 紧急、会议）',
                    hintStyle: TextStyle(color: ext.meta),
                    filled: true,
                    fillColor: ext.chip,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppColors.chipRadius),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  style: TextStyle(color: scheme.onSurface, fontSize: 15),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _addTag,
                icon: const Icon(Symbols.add),
                style: IconButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          if (_tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _tags
                    .map((tag) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: ext.chip,
                            borderRadius: BorderRadius.circular(AppColors.chipRadius),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('#$tag',
                                  style: TextStyle(fontSize: 13, color: ext.meta)),
                              const SizedBox(width: 4),
                              GestureDetector(
                                onTap: () => _removeTag(tag),
                                child: Icon(Symbols.close, size: 16, color: ext.meta),
                              ),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
          if (_suggestedTags(provider).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _suggestedTags(provider)
                    .map((tag) => GestureDetector(
                          onTap: () => _addTag(raw: tag),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: ext.chip.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(AppColors.chipRadius),
                            ),
                            child: Text('+#$tag',
                                style: TextStyle(fontSize: 13, color: ext.meta)),
                          ),
                        ))
                    .toList(),
              ),
            ),
          const SizedBox(height: 18),
          // 优先级
          _SectionLabel('优先级'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PriorityChip(
                label: '高',
                dot: ext.high,
                selected: _priority == Priority.high,
                onTap: () => setState(() => _priority = Priority.high),
              ),
              _PriorityChip(
                label: '中',
                dot: ext.medium,
                selected: _priority == Priority.medium,
                onTap: () => setState(() => _priority = Priority.medium),
              ),
              _PriorityChip(
                label: '低',
                dot: ext.low,
                selected: _priority == Priority.low,
                onTap: () => setState(() => _priority = Priority.low),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // 分类
          _SectionLabel('分类'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _CategoryChip(
                label: '工作',
                selected: _category == Category.work,
                onTap: () => setState(() => _category = Category.work),
              ),
              _CategoryChip(
                label: '生活',
                selected: _category == Category.life,
                onTap: () => setState(() => _category = Category.life),
              ),
              _CategoryChip(
                label: '学习',
                selected: _category == Category.study,
                onTap: () => setState(() => _category = Category.study),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // 截止日期
          _SectionLabel('截止日期'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _pickDate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: ext.chip,
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _dueDate == null ? '选择日期（可选）' : _formatDate(_dueDate!),
                    style: TextStyle(
                      color: _dueDate == null ? ext.meta : scheme.onSurface,
                      fontSize: 16,
                    ),
                  ),
                  Icon(Symbols.calendar_month, size: 20, color: ext.meta),
                ],
              ),
            ),
          ),
          // 重复任务：开启后截止时间固定为截止日期 23:59，不再单独选择。
          if (_repeat == RepeatType.none) ...[
            const SizedBox(height: 18),
            _SectionLabel('截止时间'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _dueDate == null ? null : _pickTime,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _dueDate == null ? '请先选择日期' : _formatTime(_dueDate!),
                      style: TextStyle(
                        color: _dueDate == null ? ext.meta : scheme.onSurface,
                        fontSize: 16,
                      ),
                    ),
                    Icon(Symbols.schedule, size: 20, color: ext.meta),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          // 重复规则
          _SectionLabel('重复'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PriorityChip(
                label: '不重复',
                selected: _repeat == RepeatType.none,
                onTap: () => _onRepeatChanged(RepeatType.none),
              ),
              _PriorityChip(
                label: '每天',
                selected: _repeat == RepeatType.daily,
                onTap: () => _onRepeatChanged(RepeatType.daily),
              ),
              _PriorityChip(
                label: '每周',
                selected: _repeat == RepeatType.weekly,
                onTap: () => _onRepeatChanged(RepeatType.weekly),
              ),
              _PriorityChip(
                label: '每隔N天',
                selected: _repeat == RepeatType.interval,
                onTap: () => _onRepeatChanged(RepeatType.interval),
              ),
              _PriorityChip(
                label: '仅工作日',
                selected: _repeat == RepeatType.weekday,
                onTap: () => _onRepeatChanged(RepeatType.weekday),
              ),
            ],
          ),
          // 每周：选择星期（可多选）
          if (_repeat == RepeatType.weekly) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var d = 1; d <= 7; d++)
                  _PriorityChip(
                    label: ['一', '二', '三', '四', '五', '六', '日'][d - 1],
                    selected: _repeatWeekdays.contains(d),
                    onTap: () => setState(() {
                      if (_repeatWeekdays.contains(d)) {
                        if (_repeatWeekdays.length > 1) _repeatWeekdays.remove(d);
                      } else {
                        _repeatWeekdays.add(d);
                      }
                    }),
                  ),
              ],
            ),
          ],
          // 每隔 N 天：间隔步进
          if (_repeat == RepeatType.interval) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text('每', style: TextStyle(color: ext.meta, fontSize: 15)),
                IconButton(
                  onPressed: () => setState(
                      () => _repeatInterval = (_repeatInterval - 1).clamp(1, 30)),
                  icon: Icon(Symbols.remove, size: 18, color: scheme.onSurface),
                  style: IconButton.styleFrom(
                    backgroundColor: ext.chip,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.all(8),
                  ),
                ),
                Container(
                  width: 36,
                  alignment: Alignment.center,
                  child: Text('$_repeatInterval',
                      style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  onPressed: () => setState(
                      () => _repeatInterval = (_repeatInterval + 1).clamp(1, 30)),
                  icon: Icon(Symbols.add, size: 18, color: scheme.onSurface),
                  style: IconButton.styleFrom(
                    backgroundColor: ext.chip,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.all(8),
                  ),
                ),
                Text('天', style: TextStyle(color: ext.meta, fontSize: 15)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          // 提醒时间（任意重复类型都有）
          if (_repeat != RepeatType.none)
            GestureDetector(
              onTap: _pickRepeatTime,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatTimeOfDay(_repeatTime),
                      style: TextStyle(color: scheme.onSurface, fontSize: 16),
                    ),
                    Icon(Symbols.schedule, size: 20, color: ext.meta),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 18),
          // 保存
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: canSave ? _save : null,
              child: Text(_isEdit ? '保存修改' : '保存'),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Text(label,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ext.meta));
  }
}

class _PriorityChip extends StatelessWidget {
  final String label;
  final Color? dot;
  final bool selected;
  final VoidCallback onTap;
  const _PriorityChip({
    required this.label,
    this.dot,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            const SizedBox(width: 6),
          ],
          Text(label),
        ],
      ),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      selectedColor: scheme.primary,
      labelStyle: TextStyle(
        color: selected ? scheme.onPrimary : scheme.onSurface,
        fontSize: 14,
      ),
      backgroundColor: appColors(context).chip,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppColors.chipRadius)),
      side: BorderSide.none,
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      selectedColor: scheme.primary,
      labelStyle: TextStyle(
        color: selected ? scheme.onPrimary : scheme.onSurface,
        fontSize: 14,
      ),
      backgroundColor: appColors(context).chip,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppColors.chipRadius)),
      side: BorderSide.none,
    );
  }
}
