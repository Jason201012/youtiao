import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 看板分组模式（本地 UI 状态，不污染任务数据）。
enum _BoardGroupMode { status, category, tag }

/// 单条泳道描述（标题 + 强调色 + 任务列表 + 是否可拖入改状态）。
class _Lane {
  final String title;
  final Color color;
  final List<Task> tasks;
  final TaskStatus? dropStatus;
  const _Lane(this.title, this.color, this.tasks, {this.dropStatus});
}

/// 看板：支持按「状态 / 分类 / 标签」三种方式分组。
/// - 长按卡片可拖拽到另一列，松手即改状态（仅「状态」模式下可跨列拖拽）；
/// - 单击卡片在 待办↔已完成 间切换（ColorOS 上更稳妥的兜底交互）。
class KanbanBoard extends StatefulWidget {
  const KanbanBoard({super.key});

  @override
  State<KanbanBoard> createState() => _KanbanBoardState();
}

class _KanbanBoardState extends State<KanbanBoard> {
  _BoardGroupMode _mode = _BoardGroupMode.status;

  /// 标签泳道上限，超出部分折叠到「其他」。
  static const int _maxTagLanes = 8;

  /// 分类 / 标签泳道的强调色循环调色板。
  static const List<Color> _lanePalette = [
    Color(0xFF3B82F6), // blue
    Color(0xFF14B8A6), // teal
    Color(0xFFF59E0B), // amber
    Color(0xFF8B5CF6), // violet
    Color(0xFFEC4899), // pink
    Color(0xFF06B6D4), // cyan
    Color(0xFFF97316), // orange
    Color(0xFF22C55E), // green
  ];

  static Color _colColor(BuildContext context, TaskStatus s) {
    if (s == TaskStatus.done) return const Color(0xFF0F6E56);
    return appColors(context).meta;
  }

  static String _catLabel(Category c) =>
      c == Category.work ? '工作' : c == Category.life ? '生活' : '学习';

  /// 根据当前分组模式，从「未删除」任务中派生各泳道（自动隐藏空分组）。
  List<_Lane> _buildLanes(TaskProvider provider) {
    final active = provider.tasks.where((t) => t.deletedAt == null).toList();
    switch (_mode) {
      case _BoardGroupMode.status:
        return [
          _Lane(
            '待办',
            _colColor(context, TaskStatus.todo),
            active.where((t) => t.status == TaskStatus.todo).toList(),
            dropStatus: TaskStatus.todo,
          ),
          _Lane(
            '已完成',
            _colColor(context, TaskStatus.done),
            active.where((t) => t.status == TaskStatus.done).toList(),
            dropStatus: TaskStatus.done,
          ),
        ];
      case _BoardGroupMode.category:
        final lanes = <_Lane>[];
        var i = 0;
        for (final c in Category.values) {
          final items = active.where((t) => t.category == c).toList();
          if (items.isEmpty) continue; // 空分组自动隐藏
          lanes.add(_Lane(_catLabel(c), _lanePalette[i % _lanePalette.length], items));
          i++;
        }
        return lanes;
      case _BoardGroupMode.tag:
        // 统计标签频次，取前 N 个作为独立泳道，其余归入「其他」。
        final freq = <String, int>{};
        for (final t in active) {
          for (final tag in t.tags) {
            freq[tag] = (freq[tag] ?? 0) + 1;
          }
        }
        final top = freq.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final topTags = top.take(_maxTagLanes).map((e) => e.key).toSet();
        final lanes = <_Lane>[];
        var i = 0;
        for (final tag in topTags) {
          final items = active.where((t) => t.tags.contains(tag)).toList();
          lanes.add(_Lane(tag, _lanePalette[i % _lanePalette.length], items));
          i++;
        }
        // 「其他」= 没有任何命中 top 标签的任务（含无标签任务）。
        final others = active
            .where((t) => t.tags.isEmpty || !t.tags.any(topTags.contains))
            .toList();
        if (others.isNotEmpty) {
          lanes.add(_Lane(
            '其他',
            Theme.of(context).colorScheme.onBackground,
            others,
          ));
        }
        return lanes;
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TaskProvider>();
    final lanes = _buildLanes(provider);

    final laneWidgets = <Widget>[
      for (final lane in lanes)
        _Column(
          title: lane.title,
          color: lane.color,
          tasks: lane.tasks,
          canDrop: lane.dropStatus != null,
          dropStatus: lane.dropStatus,
          provider: provider,
        ),
    ];

    // 「状态」模式沿用双列等宽铺满；分类 / 标签模式列数可变，横向滚动。
    final lanesView = _mode == _BoardGroupMode.status
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: laneWidgets,
          )
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: laneWidgets,
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('看板',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onBackground,
            )),
        const SizedBox(height: 12),
        SegmentedButton<_BoardGroupMode>(
          segments: const [
            ButtonSegment(
              value: _BoardGroupMode.status,
              label: Text('状态'),
              icon: Icon(Symbols.dashboard, size: 18),
            ),
            ButtonSegment(
              value: _BoardGroupMode.category,
              label: Text('分类'),
              icon: Icon(Symbols.grid_on, size: 18),
            ),
            ButtonSegment(
              value: _BoardGroupMode.tag,
              label: Text('标签'),
              icon: Icon(Symbols.sell, size: 18),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: 12),
        lanesView,
      ],
    );
  }
}

class _Column extends StatelessWidget {
  final String title;
  final Color color;
  final List<Task> tasks;
  final bool canDrop;
  final TaskStatus? dropStatus;
  final TaskProvider provider;
  const _Column({
    required this.title,
    required this.color,
    required this.tasks,
    required this.canDrop,
    this.dropStatus,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    // 仅在「状态」模式下允许跨列拖拽改状态；其余分组模式仅展示。
    final accept = canDrop && dropStatus != null;
    return DragTarget<Task>(
      onWillAcceptWithDetails: accept
          ? (d) => d.data.status != dropStatus
          : (_) => false,
      onAcceptWithDetails:
          accept ? (d) => provider.setStatus(d.data.id, dropStatus!) : null,
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.08) : ext.track.withOpacity(0.35),
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
            border: active
                ? Border.all(color: color.withOpacity(0.5), width: 1)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onBackground,
                      )),
                  const Spacer(),
                  Text('${tasks.length}',
                      style: TextStyle(fontSize: 12, color: ext.meta)),
                ],
              ),
              const SizedBox(height: 8),
              for (final t in tasks) _KanbanCard(task: t, provider: provider),
            ],
          ),
        );
      },
    );
  }
}

class _KanbanCard extends StatelessWidget {
  final Task task;
  final TaskProvider provider;
  const _KanbanCard({required this.task, required this.provider});

  static void _cycle(TaskProvider p, Task t) {
    final next =
        t.status == TaskStatus.todo ? TaskStatus.done : TaskStatus.todo;
    p.setStatus(t.id, next);
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prio = isDark ? task.priority.darkColor() : task.priority.lightColor();
    final done = task.status == TaskStatus.done;
    final dueHint = _dueHint(task);
    final overdue = dueHint == '逾期' && !done;

    final content = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        border: done ? null : Border.all(color: ext.track, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 14,
                margin: const EdgeInsets.only(top: 2, right: 6),
                decoration: BoxDecoration(
                  color: prio,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Text(
                  task.title.isNotEmpty ? task.title : '(无标题)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: done ? ext.meta : onBg,
                    decoration: done ? TextDecoration.lineThrough : null,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (dueHint.isNotEmpty || task.isRepeating) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (task.isRepeating) Icon(Symbols.repeat, size: 13, color: ext.meta),
                if (task.isRepeating && dueHint.isNotEmpty) const SizedBox(width: 4),
                if (dueHint.isNotEmpty)
                  Text(
                    dueHint,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: overdue ? AppColors.lightHigh : ext.meta,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _cycle(provider, task),
      child: LongPressDraggable<Task>(
        data: task,
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: 96,
            child: content,
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: content),
        child: content,
      ),
    );
  }

  static String _dueHint(Task t) {
    if (t.dueDate == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(t.dueDate!.year, t.dueDate!.month, t.dueDate!.day);
    final diff = d.difference(today).inDays;
    if (diff > 0) return '$diff天后';
    if (diff == 0) return '今天';
    if (diff == -1) return '昨天';
    return '逾期';
  }
}
