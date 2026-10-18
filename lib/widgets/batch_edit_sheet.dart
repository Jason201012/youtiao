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
import 'package:todolist/widgets/past_due_guard.dart';

class BatchEditSheet {
  /// 打开批量编辑面板，返回本次编辑的凭据（`batchId` + 实际更新条数）；
  /// 用户取消则为 null。
  ///
  /// U1-2（v2.9.5 审计）：改返回 [BatchEditResult] 而非裸 `int`——调用方需要
  /// `batchId` 才能做**定向**撤销（点哪条横幅的「撤销」就撤销那次编辑，
  /// 而非「最近一次」；SnackBar 是队列展示的，两条横幅可同时在列）。
  static Future<BatchEditResult?> show(
      BuildContext context, List<String> ids) async {
    if (ids.isEmpty) return null;
    return showModalBottomSheet<BatchEditResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _BatchEditBody(ids: ids),
    );
  }
}

/// 批量编辑的返回值（[TaskProvider.batchUpdateAs] 的 `(batchId, count, saved)`
/// 具名化）。
///
/// [batchId] 供 [TaskProvider.undoBatchEdit] 定向撤销；[count] 为实际更新条数；
/// [saved] 为本次批量落盘是否成功（P2-2，v3.0.7 审计——旧实现丢弃 `_persist()`
/// 结果，DB 异常时横幅照弹、重启回退且零反馈；无实际变更时恒 true）。
class BatchEditResult {
  final int batchId;
  final int count;
  final bool saved;
  const BatchEditResult(this.batchId, this.count, {this.saved = true});
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
    // P2-24：「+N 天」模式下输入非法（空 / 非数字）时不应让 batchUpdate 静默通过。
    // 旧逻辑：rawDays == null → days == null → 内部 `days != null` 判空，update 整体
    // 跳过、用户却看到「应用成功」——> 无任何变化、也无任何提示。
    // 现显式拒绝：弹错提示并 return，不调用 batchUpdate。
    if (_due == _DueMode.plusDays && (rawDays == null || days == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入 0 - 3650 之间的天数')),
      );
      return;
    }
    // 追加标签：支持逗号 / 空格分隔，去重、去空，不覆盖已有标签。
    final tags = _tagCtl.text
        .split(RegExp(r'[,，\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    // 把「改期 + 字段覆盖」收敛成单一 transform：预演与实际落库共用同一份口径，
    // 不会出现「提示了但其实没事 / 没事但提示了」。
    Task transform(Task t) {
      var nt = t;
      switch (_due) {
        case _DueMode.today:
          nt = _shiftTo(nt, today);
          break;
        case _DueMode.tomorrow:
          nt = _shiftTo(nt, today.add(const Duration(days: 1)));
          break;
        case _DueMode.plusDays:
          // P2-1：改为「各自 dueDate + N 天」——旧实现把每条任务统一平移到
          // 「今天 + N」，对未来截止的任务实际是**提前**（截止被拉近），与弹窗
          // 「按 +N 天顺延」的直觉语义不符。现保留原时分，各自在原截止日上加 N 天；
          // 无截止日期的任务原样跳过（与 today/tomorrow 模式口径一致）。
          final d = nt.dueDate;
          if (days != null && d != null) {
            nt = nt.copyWith(dueDate: d.add(Duration(days: days)));
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
    }

    // P3-5：预演「改期后截止提醒即永久失效」的条数并提示。典型场景是「顺延到今天」
    // 而原时刻已过——此前只有新建 / 编辑弹层有这条警告，这里补齐口径一致。
    final targets = widget.ids.map(provider.byId).whereType<Task>().toList();
    final dead = PastDueGuard.countDeadAfter(targets, transform, now);
    if (dead > 0) {
      final go = await PastDueGuard.confirm(
        context,
        count: dead,
        detail: '$dead 项任务改期后的截止时刻已早于当前时刻，'
            '保存后这些任务的提醒将不会触发。\n\n仍要改期吗？',
      );
      if (!go || !mounted) return;
    }

    // U1-2：用定向版本拿到 batchId（撤销横幅按 id 定位本次编辑）。
    // P2-2（v3.0.7 审计）：batchUpdateAs 异步化并透传落盘结果（saved 随
    // BatchEditResult 回传给调用方消费）。
    final r = await provider.batchUpdateAs(widget.ids, transform);
    if (!mounted) return;
    Navigator.pop(context, BatchEditResult(r.$1, r.$2, saved: r.$3));
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
