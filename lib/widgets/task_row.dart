import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/occurrence_sheet.dart';

/// 任务行：高 64，圆角 14，surface 填充。
/// 左：优先级色条(3×36) → 勾选框(22) → 标题(15) → 截止信息(12)
///
/// [selecting] 为 true 时进入多选模式：左侧显示选择框（已选为高亮实心圆），
/// 整行点击切换选中（[onSelect]），不再响应长按编辑与勾选完成。
class TaskRow extends StatelessWidget {
  final Task task;
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;

  /// U5：是否允许在「可用宽不可用」时把标题区锁成固定窄宽（默认否 = 始终放开）。
  ///
  /// 旧实现为绕过 ReorderableListView + shrinkWrap 嵌套滚动下弹性插槽拿到零宽度的
  /// 布局 bug，把标题统一塞进 80px 固定 [SizedBox]——但该组件同样被搜索结果、
  /// 标签筛选列表复用，导致长标题只能显示 3~5 字、且进详情的点击热区只剩 80px
  /// （点行内其它位置毫无反应），故 v2.9.0 起默认 [Expanded] 全宽。
  ///
  /// U2-1（v2.9.1 审计）：本开关不再无条件生效——真正决定宽度的是 LayoutBuilder
  /// 探到的**可用宽**（见 build 内说明）：有界且够宽时一律放开 Expanded，仅当宽度
  /// 无界 / 过窄（历史 bug 场景）时才用 80px 兜底。首页重排列表传 true 也只是
  /// 「允许兜底」，不再等于「永远 80px」。
  final bool constrainTitleWidth;

  const TaskRow({
    super.key,
    required this.task,
    this.onToggle,
    this.onLongPress,
    this.onTap,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
    this.constrainTitleWidth = false,
  });

  Color _priorityColor(BuildContext context) {
    final ext = appColors(context);
    if (task.done) return ext.meta; // 已完成：灰
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? task.priority.darkColor() : task.priority.lightColor();
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final primary = Theme.of(context).colorScheme.primary;
    final titleColor = task.done ? ext.meta : onBg;

    // 左侧指示：多选模式显示选择框；否则显示优先级色条 + 完成勾选框
    late final Widget leading;
    if (selecting) {
      leading = Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: selected ? primary : Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? primary : ext.meta),
        ),
        child: selected
            ? const Icon(Symbols.check, size: 14, color: Colors.white)
            : null,
      );
    } else {
      leading = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 优先级色条
          Container(
            width: 3,
            height: 36,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: _priorityColor(context),
              borderRadius: BorderRadius.circular(AppColors.ringBarRadius),
            ),
          ),
          // 勾选框
          GestureDetector(
            onTap: onToggle,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: task.done ? primary : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: ext.meta),
              ),
              child: task.done
                  ? const Icon(Symbols.check, size: 14, color: Colors.white)
                  : null,
            ),
          ),
          // 置顶星标：pinned 任务在勾选框后显示一个星标角标，提示其常驻顶部。
          if (task.pinned)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                Symbols.star,
                size: 16,
                color: primary,
                weight: 700,
              ),
            ),
        ],
      );
    }

    final hasNote = task.note.isNotEmpty;
    final hasSub = task.subtasks.isNotEmpty;
    final hasTag = task.tags.isNotEmpty;
    final content = Container(
      // U2（v2.9.0 审计）：由「固定高度」改为「最小高度」——标题放开到 2 行后，
      // 单行标题时的外观与原先完全一致（78/64 的最小高度 + Row 垂直居中），
      // 长标题换行时整行自动增高，不再截断成 3~5 个字。
      constraints: BoxConstraints(
        minHeight: (hasNote || hasSub || hasTag) ? 78 : 64,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        // 多选模式：已选项加一层淡色高亮边框，便于辨识
        border: selecting && selected
            ? Border.all(color: primary.withOpacity(0.6), width: 1.5)
            : null,
      ),
      // U2-1（v2.9.1 审计）：标题宽度不再无条件锁 80px。
      //
      // 80px 的由来是 v2.4.1 的「ReorderableListView + shrinkWrap 嵌套滚动下弹性插槽
      // 收到**零宽**约束」——那是**无界**场景的兜底。但首页拖拽重排默认常开，于是每一行
      // 都被锁成 80px：长标题只剩 ~8 字、备注 / 标签 chips 竖排堆叠把行高撑畸变，同一任务
      // 在搜索视图（放开为 Expanded）与首页（80px）信息量不一致。
      //
      // 这里用 LayoutBuilder 看**真实可用宽**（它是 Row 的父级，拿到的是 Container 内缩后
      // 的有界约束；若把它放进 Row 里则会被 Row 以「非 flex 子项」规则解成无界宽度，那正是
      // 历史上踩过的坑）：
      // - 宽度有界且够宽 → 放开 Expanded（标题 2 行可读、整块是进详情的热区）；
      // - 无界 / 过窄 → 保留 80px 固定宽兜底（历史 bug 的防回归路径）。
      child: LayoutBuilder(
        builder: (context, constraints) {
          final boundedTitle =
              constraints.hasBoundedWidth && constraints.maxWidth >= 240;
          final titleBlock = _TitleBlock(
            task: task,
            ext: ext,
            titleColor: titleColor,
            hasNote: hasNote,
            hasSub: hasSub,
            hasTag: hasTag,
            onTap: onTap,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              leading,
              if (!selecting) const SizedBox(width: 12),
              // 标题（+ 备注预览 + 标签 + 子任务进度）。
              // U5：默认用 Expanded，标题吃满剩余宽度、长标题可见、整块都是进详情的
              // 点击热区；仅「重排 + 宽度不可用」时才回退固定窄宽兜底。
              if (constrainTitleWidth && !boundedTitle)
                SizedBox(width: 80, child: titleBlock)
              else
                Expanded(flex: 3, child: titleBlock),
              // 截止信息 + 每日提醒标识 + 累计专注。
              // 未完成任务：用 Expanded 包裹，MetaInfo 填满标题+按钮之间的剩余空间，
              //   超长内容走 Text ellipsis 省略。
              // 已完成任务：隐藏时间信息（已完成无需展示截止/提醒/专注时长），
              //   整块不渲染，避免布局空白/溢出两难。
              if (!task.done) ...[
                const SizedBox(width: 12),
                Expanded(child: _MetaInfo(task: task, ext: ext)),
              ],
              if (!task.done) ...[
                const SizedBox(width: 6),
                // 「专注」按钮：直接进入专注页并预选本任务
                IconButton(
                  onPressed: () {
                    final focus = context.read<FocusProvider>();
                    focus.requestTask(task.id, task.title);
                  },
                  icon: Icon(Symbols.timer, size: 20, color: primary),
                  tooltip: '开始专注',
                  // U3-6（v2.9.5 审计）：此前 constraints 压到 36dp，低于
                  // Material 最小命中区 48dp；命中区回归 48dp（视觉仍由
                  // 20px 图标承担，不额外添噪）。
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                ),
              ],
            ],
          );
        },
      ),
    );
    // 多选模式：整行点击切换选中
    if (selecting) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onSelect,
        child: content,
      );
    }
    // 普通模式：长按整行打开编辑（勾选框仅切换完成态）
    if (onLongPress == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: content,
    );
  }

}

String _dueLabel(DateTime? due) {
  if (due == null) return '无截止';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(due.year, due.month, due.day);
  final diff = d.difference(today).inDays;
  final time = ' ${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}';
  if (diff == 0) return '今天$time';
  if (diff == 1) return '明天$time';
  if (diff == -1) return '昨天$time';
  if (diff < 0) return '已逾期$time';
  return '${due.month}月${due.day}日$time';
}

/// 累计专注时长格式化：<60 分钟显示「N分钟」，否则「N小时M分」。
String _focusLabel(int sec) {
  final m = (sec / 60).round();
  if (m < 60) return '$m分钟';
  final h = m ~/ 60;
  final mm = m % 60;
  return mm == 0 ? '${h}小时' : '${h}小时$mm分';
}

/// 任务行标题区：标题 + 备注预览 + 子任务进度 + 标签。
/// 普通模式下整块可点击打开详情（[onTap]）；多选 / 无 onTap 时仅展示。
class _TitleBlock extends StatelessWidget {
  final Task task;
  final AppColorsExt ext;
  final Color titleColor;
  final bool hasNote;
  final bool hasSub;
  final bool hasTag;
  final VoidCallback? onTap;
  const _TitleBlock({
    required this.task,
    required this.ext,
    required this.titleColor,
    required this.hasNote,
    required this.hasSub,
    required this.hasTag,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final displayTitle = task.title.isNotEmpty ? task.title : '(无标题)';
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          displayTitle,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: titleColor,
          ),
          // U2（v2.9.0 审计）：与看板卡片对齐，统一 2 行 + 尾省略（原先列表 1 行、
          // 看板 2 行，同一任务在两处可读信息量不一致）。
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (hasNote) ...[
          const SizedBox(height: 3),
          Text(
            task.note,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: ext.meta,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (hasSub) ...[
          const SizedBox(height: 5),
          _SubProgress(task: task, ext: ext),
        ],
        if (hasTag) ...[
          const SizedBox(height: 5),
          _TagChips(task: task, ext: ext),
        ],
      ],
    );
    if (onTap == null) return column;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: column,
    );
  }
}

/// 任务行右侧信息：每日提醒标识 + 截止时间 + 累计专注。
/// 用单行 Text 拼接所有信息（图标用 Unicode 字符内联），避免嵌套 Row 导致的
/// 图标文字重叠 / 溢出卡边问题。外层 Expanded 约束下 ellipsis 必定生效。
class _MetaInfo extends StatelessWidget {
  final Task task;
  final AppColorsExt ext;
  const _MetaInfo({required this.task, required this.ext});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final spans = <InlineSpan>[];
    if (task.repeatEnded) {
      // U3（v2.9.0 审计）：`endRepeat(markDone:false)` 会保留 repeat 字段、只把
      // repeatUntil 设为昨天，于是卡片仍按重复样式渲染（「每天 07:00 至 09/17」），
      // 而任务其实已退场并静默落进「今天」分区——用户会误以为「结束重复」是删除。
      // 这里给出一次性角标（不可点开预览：已无未来循环日可操作）。
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Icon(Symbols.event_busy, size: 13, color: ext.meta),
      ));
      spans.add(TextSpan(
        text: ' 已结束重复',
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
      ));
      spans.add(const TextSpan(text: '  '));
    } else if (task.isRepeating && task.repeatFull.isNotEmpty) {
      // P0-5：重复芯片可点开「未来30天预览」，便于逐次补打 / 跳过。
      void open() => OccurrenceSheet.show(
            context,
            task,
            Provider.of<TaskProvider>(context, listen: false),
          );
      // U3-6（v2.9.5 审计）：此前命中区只有 13px 图标 + 12px 文字
      // （TapGestureRecognizer 的命中范围 = 字形盒），触屏几乎无法准确命中。
      // 改为整个 chip 一个命中区：容器高度补到 48dp、`HitTestBehavior.opaque`
      // 让空白也参与命中；文字用 `Flexible + ellipsis`，超宽时与原 TextSpan
      // 同样截断，不会横向溢出。
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: open,
          // 注意不要给 Container 设 `alignment`：Align 默认会横向撑满可用
          // 宽度，把行内后续文案（截止时间等）挤出单行。这里靠 Row 的
          // min 尺寸收缩，高度由 minHeight 48 兜底、子项交叉轴居中。
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Symbols.repeat, size: 13, color: primary),
                Flexible(
                  child: Text(
                    ' ${task.repeatFull}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: primary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
      spans.add(const TextSpan(text: '  '));
    }
    final parts = <String>[];
    // 开始时间（时间段起点）优先展示，体现「14:00-15:00」这类时段语义。
    if (task.startDate != null) {
      final s = task.startDate!;
      final st =
          '${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}';
      parts.add('起 $st');
    }
    parts.add(_dueLabel(task.dueDate));
    if (task.focusSecTotal > 0) {
      parts.add('⏱ ${_focusLabel(task.focusSecTotal)}');
    }
    spans.add(TextSpan(
      text: parts.join('  '),
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
    ));
    return RichText(
      text: TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 任务行内的子任务进度：『✓ done/total』文案 + 一条细进度条。
class _SubProgress extends StatelessWidget {
  final Task task;
  final AppColorsExt ext;
  const _SubProgress({required this.task, required this.ext});

  @override
  Widget build(BuildContext context) {
    final total = task.subtaskTotal;
    final done = task.subtaskDone;
    final ratio = total == 0 ? 0.0 : done / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.checklist, size: 13, color: ext.meta),
            const SizedBox(width: 4),
            Text(
              '$done/$total',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 120,
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 3,
            backgroundColor: ext.track,
            valueColor: AlwaysStoppedAnimation<Color>(ext.accent),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}

/// 任务行内的标签 chips：每个标签显示为「#标签」小圆角块。
class _TagChips extends StatelessWidget {
  final Task task;
  final AppColorsExt ext;
  const _TagChips({required this.task, required this.ext});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: task.tags
          .where((t) => t.isNotEmpty)
          .map((tag) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Text(
                  '#$tag',
                  style: TextStyle(fontSize: 12, color: ext.meta),
                ),
              ))
          .toList(),
    );
  }
}
