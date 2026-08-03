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
  Priority _priority = Priority.medium;
  Category _category = Category.work;
  DateTime? _dueDate;

  /// 每日提醒开关与每天提醒时刻。
  bool _dailyReminder = false;
  TimeOfDay _dailyTime = const TimeOfDay(hour: 7, minute: 0);

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
      _dailyReminder = t.dailyReminder;
      _dailyTime = t.dailyReminderMinute != null
          ? TimeOfDay(hour: t.dailyReminderMinute! ~/ 60, minute: t.dailyReminderMinute! % 60)
          : const TimeOfDay(hour: 7, minute: 0);
      _noteController.text = t.note;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
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
      // 开启每日提醒时，截止时间固定为所选日期 23:59；否则保留既有时间或默认 09:00。
      final int h;
      final int m;
      if (_dailyReminder) {
        h = 23;
        m = 59;
      } else {
        h = _dueDate?.hour ?? 9;
        m = _dueDate?.minute ?? 0;
      }
      setState(() => _dueDate = DateTime(picked.year, picked.month, picked.day, h, m));
    }
  }

  /// 每日提醒开关变化：开启时隐藏截止时间选择器，并把截止时间设为当天 23:59。
  /// 若当前没有截止日期，则默认设为今天 23:59。
  void _onDailyReminderChanged(bool v) {
    setState(() {
      _dailyReminder = v;
      if (v) {
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

  Future<void> _pickDailyTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _dailyTime,
      helpText: '选择每日提醒时间',
    );
    if (picked != null) setState(() => _dailyTime = picked);
  }

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    final provider = Provider.of<TaskProvider>(context, listen: false);
    final dailyMinute = _dailyReminder ? _dailyTime.hour * 60 + _dailyTime.minute : null;
    if (_isEdit) {
      provider.updateTask(widget.task!.copyWith(
        title: title,
        priority: _priority,
        category: _category,
        dueDate: _dueDate,
        dailyReminder: _dailyReminder,
        dailyReminderMinute: dailyMinute,
        note: _noteController.text.trim(),
      ));
    } else {
      provider.addTask(Task(
        id: '',
        title: title,
        priority: _priority,
        category: _category,
        dueDate: _dueDate,
        dailyReminder: _dailyReminder,
        dailyReminderMinute: dailyMinute,
        note: _noteController.text.trim(),
      ));
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    final canSave = _titleController.text.trim().isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
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
          // 开启每日提醒后，截止时间固定为截止日期 23:59，不再让用户单独选择。
          if (!_dailyReminder) ...[
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
          // 每日提醒开关
          _SectionLabel('每日提醒'),
          const SizedBox(height: 8),
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: ext.chip,
              borderRadius: BorderRadius.circular(AppColors.chipRadius),
            ),
            child: Row(
              children: [
                Icon(Symbols.repeat, size: 20, color: ext.meta),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '每天固定时间提醒此任务',
                    style: TextStyle(color: scheme.onSurface, fontSize: 15),
                  ),
                ),
                Switch(
                  value: _dailyReminder,
                  onChanged: _onDailyReminderChanged,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 每日提醒时间（开启时显示）
          if (_dailyReminder)
            GestureDetector(
              onTap: _pickDailyTime,
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
                      _formatTimeOfDay(_dailyTime),
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
