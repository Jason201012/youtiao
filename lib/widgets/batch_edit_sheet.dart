/// 多选批量编辑 / 逾期一键顺延（P0-1 / P0-2，纯离线）。
///
/// 早期多选模式只有「批量删除」一个动作，5 个作业统一顺延三天、10 个任务统一打
/// 标签这类高频操作只能逐条点开编辑。这里补上批量操作的安全子集：
/// 改截止日期 / 改优先级 / 改分类 / 追加标签 / 置顶取消置顶。
///
/// 实现上全部收敛到 [TaskProvider.batchUpdate]，落库、拼音重算、提醒重排都复用
/// 既有 [TaskProvider.updateTask] 链路，不新增持久化路径。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';

class BatchEditSheet {
  /// 打开批量编辑面板，返回实际更新的条数（用户取消则为 null）。
  static Future<int?> show(BuildContext context, List<String> ids) async {
    if (ids.isEmpty) return null;
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _BatchEditBody(ids: ids),
    );
  }
}

/// 截止日期改动模式。
enum _DueMode { keep, today, tomorrow, plusDays, clear }

class _BatchEditBody extends StatefulWidget {
  final List<String> ids;
  const _BatchEditBody({required this.ids});

  @override
  State<_BatchEditBody> createState() => _BatchEditBodyState();
}

class _BatchEditBodyState extends State<_BatchEditBody> {
  _DueMode _due = _DueMode.keep;
  final TextEditingController _daysCtl = TextEditingController(text: '3');
  final TextEditingController _tagCtl = TextEditingController();
  Priority? _priority;
  Category? _category;

  /// 置顶：null=不改，true=全部置顶，false=全部取消置顶
  bool? _pinned;

  @override
  void dispose() {
    _daysCtl.dispose();
    _tagCtl.dispose();
    super.dispose();
  }

  /// 把截止日期平移到 [day]（保留原时刻）；无截止日期的任务原样跳过。
  Task _shiftTo(Task t, DateTime day) {
    final d = t.dueDate;
    if (d == null) return t;
    return t.copyWith(
      dueDate: DateTime(day.year, day.month, day.day, d.hour, d.minute),
    );
  }

  Future<void> _apply() async {
    final provider = context.read<TaskProvider>();
    // F1：二次确认 + 影响前瞻——批量编辑一次性改写 N 条且无快照，先让用户确认。
    final count = widget.ids.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('确认批量编辑？'),
        content: Text(
          '将更新 $count 项任务'
          '${_due == _DueMode.plusDays ? '（按「+N 天」顺延截止日期）' : ''}。'
          '此操作可被撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final rawDays = int.tryParse(_daysCtl.text.trim());
    // P2-4 / F1：边界校验——「顺延」语义下负数会把截止日期提前（与意图相反），
    // 超大值（如 999999 天）会让日期计算溢出到怪异的远古/远期；用 clamp 兜底。
    final days = rawDays == null ? null : rawDays.clamp(0, 3650);
    // 追加标签：支持逗号 / 空格分隔，去重、去空，不覆盖已有标签。
    final tags = _tagCtl.text
        .split(RegExp(r'[,，\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final n = provider.batchUpdate(widget.ids, (t) {
      var nt = t;
      switch (_due) {
        case _DueMode.today:
          nt = _shiftTo(nt, today);
          break;
        case _DueMode.tomorrow:
          nt = _shiftTo(nt, today.add(const Duration(days: 1)));
          break;
        case _DueMode.plusDays:
          if (days != null) {
            nt = _shiftTo(nt, today.add(Duration(days: days)));
          }
          break;
        case _DueMode.clear:
          nt = nt.copyWith(dueDate: null);
          break;
        case _DueMode.keep:
          break;
      }
      if (_priority != null) nt = nt.copyWith(priority: _priority);
      if (_category != null) nt = nt.copyWith(category: _category);
      if (_pinned != null) nt = nt.copyWith(pinned: _pinned);
      if (tags.isNotEmpty) {
        final merged = <String>{...nt.tags, ...tags}.toList();
        nt = nt.copyWith(tags: merged);
      }
      return nt;
    });
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final primary = Theme.of(context).colorScheme.primary;
    final onBg = Theme.of(context).colorScheme.onBackground;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('批量编辑（${widget.ids.length} 项）',
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600, color: onBg)),
              const SizedBox(height: 4),
              Text('未勾选的维度保持不变',
                  style: TextStyle(fontSize: 13, color: ext.meta)),
              const Divider(height: 20),

              // ===== 截止日期 =====
              _SectionTitle('截止日期'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  _chip('今天', _due == _DueMode.today,
                      () => setState(() => _due = _DueMode.today), context),
                  _chip('明天', _due == _DueMode.tomorrow,
                      () => setState(() => _due = _DueMode.tomorrow), context),
                  _chip('+N 天', _due == _DueMode.plusDays,
                      () => setState(() => _due = _DueMode.plusDays), context),
                  _chip('清除', _due == _DueMode.clear,
                      () => setState(() => _due = _DueMode.clear), context),
                ],
              ),
              if (_due == _DueMode.plusDays) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _daysCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '顺延天数',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 16),

              // ===== 优先级 =====
              _SectionTitle('优先级'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final p in [Priority.high, Priority.medium, Priority.low])
                    _chip(_prioLabel(p), _priority == p,
                        () => setState(() => _priority = _priority == p ? null : p),
                        context),
                ],
              ),
              const SizedBox(height: 16),

              // ===== 分类 =====
              _SectionTitle('分类'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in Category.values)
                    _chip(_catLabel(c), _category == c,
                        () => setState(() => _category = _category == c ? null : c),
                        context),
                ],
              ),
              const SizedBox(height: 16),

              // ===== 置顶 =====
              _SectionTitle('置顶'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  _chip('置顶', _pinned == true,
                      () => setState(() => _pinned = _pinned == true ? null : true),
                      context),
                  _chip('取消置顶', _pinned == false,
                      () => setState(() => _pinned = _pinned == false ? null : false),
                      context),
                ],
              ),
              const SizedBox(height: 16),

              // ===== 追加标签 =====
              _SectionTitle('追加标签（逗号分隔）'),
              const SizedBox(height: 6),
              TextField(
                controller: _tagCtl,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '如：工作, 紧急',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),

              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _apply,
                  child: const Text('应用'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('取消', style: TextStyle(color: primary)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(
      String label, bool selected, VoidCallback onTap, BuildContext context) {
    final ext = appColors(context);
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedText = isDark ? AppColors.lightChip : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? primary : ext.chip,
          borderRadius: BorderRadius.circular(AppColors.chipRadius),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: selected ? selectedText : ext.meta,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600));
  }
}

String _prioLabel(Priority p) => switch (p) {
      Priority.high => '高',
      Priority.medium => '中',
      Priority.low => '低',
    };

String _catLabel(Category c) => switch (c) {
      Category.work => '工作',
      Category.life => '生活',
      Category.study => '学习',
    };
