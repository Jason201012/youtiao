import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 看板分组模式（本地 UI 状态，不污染任务数据）。
enum KanbanGroupMode { status, category, tag }

/// 分类泳道的中文名。
String _catLabel(Category c) =>
    c == Category.work ? '工作' : c == Category.life ? '生活' : '学习';

/// 泳道分组结果（纯数据，不含颜色 / BuildContext 依赖）。
///
/// P3-3（v2.8.8 审计）：把分组口径从 `State` 私有方法抽成纯函数，使分组结果可被单测
/// 直接钉死。看板泳道位于横向滚动视口中（宽度约束无界），其内部 `Row + Spacer /
/// Expanded` 在 debug 断言下无法完成布局，widget 级测试无法稳定断言分组结果——
/// 故把「分组口径」与「渲染」解耦。
@visibleForTesting
class KanbanLaneData {
  final String title;
  final List<Task> tasks;

  /// 「状态」泳道的投放目标状态；其余分组模式为 null（仅展示、不可拖入）。
  final TaskStatus? dropStatus;

  /// 分类 / 标签泳道在调色板中的索引；null 表示使用语义色（状态 / 其他）。
  final int? paletteIndex;

  const KanbanLaneData(
    this.title,
    this.tasks, {
    this.dropStatus,
    this.paletteIndex,
  });
}

/// 按 [mode] 从 [active]（调用方已滤掉回收站条目）派生泳道，列表顺序即展示顺序。
///
/// - `status`：待办 / 已完成，恒为两列（空列保留，作为拖拽投放目标）；
/// - `category`：每任务只归入自身分类，空分类自动隐藏；
/// - `tag`：P3-3（v2.8.8 审计）改为「每个任务仅归入其第一个命中的 top 标签」
///   （按频次降序优先，顺序稳定可复现），使任意任务在整个看板中恰好出现一次、
///   各泳道计数之和 = 实际任务数；不含任何 top 标签（含无标签）的任务归入「其他」。
@visibleForTesting
List<KanbanLaneData> buildKanbanLanes(
  KanbanGroupMode mode,
  List<Task> active, {
  int maxTagLanes = 8,
}) {
  switch (mode) {
    case KanbanGroupMode.status:
      return [
        KanbanLaneData(
          '待办',
          active.where((t) => t.status == TaskStatus.todo).toList(),
          dropStatus: TaskStatus.todo,
        ),
        KanbanLaneData(
          '已完成',
          active.where((t) => t.status == TaskStatus.done).toList(),
          dropStatus: TaskStatus.done,
        ),
      ];
    case KanbanGroupMode.category:
      final lanes = <KanbanLaneData>[];
      var i = 0;
      for (final c in Category.values) {
        final items = active.where((t) => t.category == c).toList();
        if (items.isEmpty) continue; // 空分组自动隐藏
        lanes.add(KanbanLaneData(_catLabel(c), items, paletteIndex: i));
        i++;
      }
      return lanes;
    case KanbanGroupMode.tag:
      // 统计标签频次，取前 N 个作为独立泳道，其余归入「其他」。
      final freq = <String, int>{};
      for (final t in active) {
        for (final tag in t.tags) {
          freq[tag] = (freq[tag] ?? 0) + 1;
        }
      }
      final top = freq.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final topTags =
          top.take(maxTagLanes).map((e) => e.key).toList(growable: false);
      // 先按频次降序建桶，保证泳道顺序稳定。
      final buckets = <String, List<Task>>{
        for (final tag in topTags) tag: <Task>[],
      };
      final others = <Task>[];
      for (final t in active) {
        String? assigned;
        for (final tag in topTags) {
          if (t.tags.contains(tag)) {
            assigned = tag;
            break;
          }
        }
        if (assigned == null) {
          others.add(t);
        } else {
          buckets[assigned]!.add(t);
        }
      }
      final lanes = <KanbanLaneData>[];
      var i = 0;
      for (final tag in topTags) {
        final items = buckets[tag]!;
        // 高频标签可能已被更高频标签「吸走」全部任务，空泳道不再展示
        // （与「分类」模式的空分组自动隐藏一致），调色板索引只对可见泳道递增。
        if (items.isEmpty) continue;
        lanes.add(KanbanLaneData(tag, items, paletteIndex: i));
        i++;
      }
      if (others.isNotEmpty) {
        lanes.add(KanbanLaneData('其他', others));
      }
      return lanes;
  }
}

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
  KanbanGroupMode _mode = KanbanGroupMode.status;

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

  /// 泳道强调色：状态泳道用语义色（已完成 = 深绿、待办 = 次要色），
  /// 分类 / 标签泳道走循环调色板，「其他」泳道用前景色。
  Color _laneColor(KanbanLaneData lane) {
    if (lane.dropStatus == TaskStatus.done) return const Color(0xFF0F6E56);
    if (lane.dropStatus != null) return appColors(context).meta;
    if (lane.paletteIndex != null) {
      return _lanePalette[lane.paletteIndex! % _lanePalette.length];
    }
    return Theme.of(context).colorScheme.onBackground;
  }

  /// 派生泳道（分组口径见 [buildKanbanLanes]，空分组自动隐藏）。
  ///
  /// P3-3（v2.8.8 审计）：分组口径已抽到纯函数 [buildKanbanLanes]，此处只负责
  /// 「滤掉回收站条目 + 绑定颜色」，使分组结果可被单测直接覆盖。
  List<_Lane> _buildLanes(TaskProvider provider) {
    final active = provider.tasks.where((t) => t.deletedAt == null).toList();
    return [
      for (final lane
          in buildKanbanLanes(_mode, active, maxTagLanes: _maxTagLanes))
        _Lane(
          lane.title,
          _laneColor(lane),
          lane.tasks,
          dropStatus: lane.dropStatus,
        ),
    ];
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
    final lanesView = _mode == KanbanGroupMode.status
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
        SegmentedButton<KanbanGroupMode>(
          segments: const [
            ButtonSegment(
              value: KanbanGroupMode.status,
              label: Text('状态'),
              icon: Icon(Symbols.dashboard, size: 18),
            ),
            ButtonSegment(
              value: KanbanGroupMode.category,
              label: Text('分类'),
              icon: Icon(Symbols.grid_on, size: 18),
            ),
            ButtonSegment(
              value: KanbanGroupMode.tag,
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
