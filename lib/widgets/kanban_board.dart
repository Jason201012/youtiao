import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/task_parser.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
// ui_durations 的 kUndoWindow 已收进 undo_snack_bar（P3-4），本文件不再直接用时删 import。
import 'package:todolist/widgets/undo_snack_bar.dart';
// T2-3（v2.9.2 功能增强）：列内「+」快速建卡复用 TaskSheet（分类 / 标签自动预填）。
import 'package:todolist/widgets/new_task_sheet.dart';
// U2-4（v2.9.5 审计）：卡片单击进任务详情（此前单击直接改状态，全屏无详情入口）。
import 'package:todolist/screens/task_detail_screen.dart';

/// 看板分组模式（本地 UI 状态，不污染任务数据）。
enum KanbanGroupMode { status, category, tag }

/// P3-4（v2.9.0 审计）：分组模式的偏好键——把「视图偏好」从页面内存态升级为持久偏好。
const String kKanbanGroupModePrefsKey = 'kanban_group_mode';

/// T2-3（v2.9.2 功能增强）：「待办」泳道进行中上限（WIP）的偏好键。0 = 不限。
const String kKanbanWipLimitPrefsKey = 'kanban_wip_limit';

/// T2-3：待办超限判定（纯函数，供单测钉死）。[limit] <= 0 恒不拦。
@visibleForTesting
bool kanbanWipBlocked(int todoCount, int limit) =>
    limit > 0 && todoCount >= limit;

/// T2-3：全局「待办」计数（与状态分组待办泳道同口径：未删 + todo）。
int kanbanTodoCountOf(TaskProvider provider) => provider.tasks
    .where((t) => t.deletedAt == null && t.status == TaskStatus.todo)
    .length;

/// 分类 / 标签（横向滚动）模式下每条泳道的**基准**宽度（逻辑像素）。
///
/// 这两类泳道位于 `SingleChildScrollView(horizontal)` 内、宽度约束无界，而泳道头的
/// `Row + Spacer()` 与卡片内 `Expanded(child: Text)` 都要求**有界宽度**——不给确定宽度
/// 就会在 debug 抛「RenderFlex children have non-zero flex but incoming width constraints
/// are unbounded」，release 下则静默降级（`Spacer` 塌成 0、卡片按内容自适应）。
/// 220 在常见手机宽度（360~430dp）下约同屏可见 1.5~2 列，横向滚动手感正常。
const double _scrollLaneWidth = 220;

/// 泳道宽度的下 / 上限（U4：宽屏时按可用宽自适应，仍夹在此区间内）。
const double _minLaneWidth = 200;
const double _maxLaneWidth = 280;

/// 「宽屏」判定阈值（逻辑像素）：达到即认为平板 / 折叠屏展开态 / 横屏手机，
/// 按可用宽铺满列宽（U4）。
const double _wideBreakpoint = 600;

/// 解析持久化的分组模式名；缺失 / 非法（含旧版本写入的未知值）回退 [KanbanGroupMode.status]。
@visibleForTesting
KanbanGroupMode kanbanModeFromName(String? name) {
  for (final m in KanbanGroupMode.values) {
    if (m.name == name) return m;
  }
  return KanbanGroupMode.status;
}

/// U4（v2.9.0 审计）：分类 / 标签泳道的目标宽度（逻辑像素）。
///
/// 硬约束不变：该模式下泳道处于**无界宽度视口**内，每条泳道必须有确定宽度（原因见
/// [_scrollLaneWidth]）。差别在于宽度不再恒为 220：
/// - 窄屏（`available < [_wideBreakpoint]`）沿用 [_scrollLaneWidth]；
/// - 宽屏按「可用宽 / 列数」（扣掉列间距）铺满，单列夹在 [_minLaneWidth, _maxLaneWidth]。
///
/// 于是平板 / 横屏下不再出现「一列 220 宽、右侧大片空白」的弱存在感；列数过多
/// （夹取下限后总宽仍超屏）时保留横向滚动，行为与原来一致。
@visibleForTesting
double kanbanLaneWidthFor(double available, int laneCount) {
  if (laneCount <= 0) return _minLaneWidth;
  if (available.isNaN || available <= 0) return _scrollLaneWidth;
  if (available < _wideBreakpoint) return _scrollLaneWidth;
  const gap = 8.0; // 与 `_Column` 的 `margin.right` 对齐
  // P3-9（v2.9.1 审计）：每列都带 `margin.right: 8`（**含最后一列**），故间距要按
  // 「列数」扣而不是「列数 − 1」。旧算法在未触发夹取时整行实宽 = available + 8：
  // 1000dp 宽屏 4 列会莫名其妙多出 8px 溢出并出现横向滚动条，与「宽屏铺满」的
  // 设计目标相反（夹取到上限时因 raw 被截断反而不溢出，故只在中间区间暴露）。
  final raw = (available - gap * laneCount) / laneCount;
  return raw.clamp(_minLaneWidth, _maxLaneWidth);
}

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

  /// T2-3：该泳道「+」快速建卡的预填维度；状态泳道与「其他」泳道为 null。
  final Category? category;
  final String? tag;

  const KanbanLaneData(
    this.title,
    this.tasks, {
    this.dropStatus,
    this.paletteIndex,
    this.category,
    this.tag,
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
        // T2-3：泳道带分类预填，列内「+」建卡自动归入该分类。
        lanes.add(KanbanLaneData(_catLabel(c), items,
            paletteIndex: i, category: c));
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
        // P3-11（v2.9.1 审计）：补字典序次级键——Dart 的 `List.sort` **不是稳定排序**，
        // 同频标签的先后完全取决于底层实现的内部顺序，于是「顺序稳定可复现」的注释
        // 并不成立（计数和没错，但泳道顺序可能在不同运行 / 不同 SDK 版本下变化，
        // 让用户以为看板自己重排了）。频次降序 + 标签字典序 = 完全确定的顺序。
        ..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          return byCount != 0 ? byCount : a.key.compareTo(b.key);
        });
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
        // T2-3：泳道带标签预填，列内「+」建卡自动带上该标签。
        lanes.add(KanbanLaneData(tag, items, paletteIndex: i, tag: tag));
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

  /// T2-3：列内「+」建卡的预填维度（分类 / 标签泳道专用）。
  final Category? category;
  final String? tag;
  const _Lane(this.title, this.color, this.tasks,
      {this.dropStatus, this.category, this.tag});
}

/// 看板：支持按「状态 / 分类 / 标签」三种方式分组。
/// - 长按卡片可拖拽到另一列，松手即改状态（仅「状态」模式下可跨列拖拽）；
/// - 单击卡片打开任务详情（U2-4，v2.9.5 审计——改状态走显式勾选圈 /
///   拖拽落列，见 [_KanbanCard] 文档；新U3-6，v2.9.7 审计：本行旧文案
///   「单击切换完成状态」自 v2.9.5 起已不实）。
class KanbanBoard extends StatefulWidget {
  const KanbanBoard({super.key});

  @override
  State<KanbanBoard> createState() => _KanbanBoardState();
}

class _KanbanBoardState extends State<KanbanBoard> {
  KanbanGroupMode _mode = KanbanGroupMode.status;

  /// 标签泳道上限，超出部分折叠到「其他」。
  static const int _maxTagLanes = 8;

  /// T2-3：「待办」泳道的进行中上限（0 = 不限）。仅「状态」分组生效。
  int _wipLimit = 0;

  @override
  void initState() {
    super.initState();
    _restoreMode();
    _restoreWipLimit();
  }

  /// T2-3：读取持久化的 WIP 上限（读取失败静默保持「不限」）。
  Future<void> _restoreWipLimit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(kKanbanWipLimitPrefsKey) ?? 0;
      if (!mounted || v == _wipLimit) return;
      setState(() => _wipLimit = v < 0 ? 0 : v);
    } catch (_) {
      // 偏好不可读：静默保持不限。
    }
  }

  /// T2-3：写入 WIP 上限（落盘失败不影响当次生效）。
  void _setWipLimit(int v) {
    final clamped = v < 0 ? 0 : v;
    setState(() => _wipLimit = clamped);
    SharedPreferences.getInstance().then((prefs) {
      return prefs.setInt(kKanbanWipLimitPrefsKey, clamped);
    }).catchError((_) {
      // 写入失败：仅本次不记忆。
    });
  }

  /// T2-3：WIP 上限编辑弹窗（步进器，0 = 不限）。
  Future<void> _editWipLimit() async {
    var v = _wipLimit;
    final confirmed = await showDialog<int>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text('待办上限'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '「待办」列最多保留多少个任务（0 = 不限）。'
                '超限后拖入 / 勾选转回 / 新建都会被拦截。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: v > 0 ? () => setD(() => v--) : null,
                    icon: const Icon(Symbols.remove_circle_outline),
                    tooltip: '减',
                  ),
                  SizedBox(
                    width: 56,
                    child: Center(
                      child: Text('$v',
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  IconButton(
                    onPressed: v < 99 ? () => setD(() => v++) : null,
                    icon: const Icon(Symbols.add_circle_outline),
                    tooltip: '加',
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, v),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != null) _setWipLimit(confirmed);
  }

  /// P3-4（v2.9.0 审计）：分组模式此前是纯页面内存态（宿主为 `const KanbanBoard()`
  /// 且位于 `SingleChildScrollView` 内，页面销毁重建即复位「状态」、滚动位置也回到顶部），
  /// 习惯「标签」视图的用户每次进看板都要重切。改为写入 SharedPreferences 持久记忆；
  /// 读取失败不影响看板可用性（保持默认「状态」分组）。
  Future<void> _restoreMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved =
          kanbanModeFromName(prefs.getString(kKanbanGroupModePrefsKey));
      if (!mounted || saved == _mode) return;
      setState(() => _mode = saved);
    } catch (_) {
      // 偏好不可读（极端情况下插件缺失）：静默保持默认分组。
    }
  }

  /// 切换分组模式并落盘（落盘失败不影响当次切换）。
  void _setMode(KanbanGroupMode mode) {
    setState(() => _mode = mode);
    SharedPreferences.getInstance().then((prefs) async {
      try {
        await prefs.setString(kKanbanGroupModePrefsKey, mode.name);
      } catch (_) {
        // 写入失败：仅本次不记忆，不影响视图。
      }
    }).catchError((_) {
      // 取实例失败：忽略。
    });
  }

  /// 分类 / 标签泳道的强调色循环调色板。
  ///
  /// U3-4（v2.9.5 审计）：原 8 色硬编码调色板（蓝/青/琥珀/紫/粉/…）脱离主题
  /// 体系，与本项目「纯黑白色系」设计偏好冲突 → 改为前景色 8 档透明度灰阶，
  /// 随明暗主题自适应；泳道本身仍靠标题与位置区分，不依赖色相辨位。
  /// （实例 getter 而非 static const：颜色需从 Theme 取 `onBackground`。）
  List<Color> get _lanePalette {
    final base = Theme.of(context).colorScheme.onBackground;
    const alphas = [1.0, 0.85, 0.70, 0.58, 0.47, 0.37, 0.28, 0.20];
    return [for (final a in alphas) base.withValues(alpha: a)];
  }

  /// 泳道强调色：状态泳道与分类 / 标签泳道统一走主题灰阶，
  /// 「其他」泳道用前景色。
  ///
  /// U3-3（v2.9.6 审计）：「已完成」泳道此前仍硬编码深绿 `Color(0xFF0F6E56)`，
  /// 本轮其余泳道与存储占比条都已回归灰阶，唯独此处漏网——不随主题、且偏离
  /// 本项目纯黑白的设计偏好。泳道语义靠标题与位置区分即可，无需色相辨位。
  Color _laneColor(KanbanLaneData lane) {
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
          category: lane.category,
          tag: lane.tag,
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
          // T2-3：WIP 上限只约束「状态」分组的待办列；列内建卡预填维度透传。
          wipLimit: lane.dropStatus == TaskStatus.todo ? _wipLimit : 0,
          category: lane.category,
          tag: lane.tag,
        ),
    ];

    // 「状态」模式：双列等宽铺满。
    //
    // 必须用 [Expanded] 给每条泳道分配**有界宽度**：泳道头的 `Row + Spacer()` 与卡片内的
    // `Expanded(child: Text)` 都要求父级提供有界宽度，而 Row 给「非 flex 子项」的约束是
    // `BoxConstraints(maxHeight: h)`（maxWidth 无界）。此前两条泳道作为普通子项直接塞进
    // Row，拿到无界宽度 → debug 下必然抛
    // 「RenderFlex children have non-zero flex but incoming width constraints are
    // unbounded」；release 无断言，`RenderFlex._computeSizes` 首轮 `canFlex && flex > 0`
    // 判定使无界时的 flex 子项被当非 flex 处理，于是 `Spacer` 静默塌成 0、卡片宽度按内容
    // 自适应 —— 注释里承诺的「双列等宽铺满」其实从未实现。加 `Expanded` 后两列各占一半
    // 宽度，注释与实现一致。
    //
    // 分类 / 标签模式列数可变，仍走横向滚动：该模式下泳道处于**无界宽度视口**内（`Expanded`
    // 在此同样非法），故给每条泳道**确定宽度** —— 既满足上面同一个「有界宽度」前提，
    // 又保留「列数可变 + 横向滚动」的既有交互。
    // U4（v2.9.0 审计）：宽度改由 [kanbanLaneWidthFor] 按可用宽自适应（宽屏铺满、
    // 单列 200~280 封顶），窄屏仍是 220。
    final lanesView = _mode == KanbanGroupMode.status
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final w in laneWidgets) Expanded(child: w),
            ],
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final laneWidth = kanbanLaneWidthFor(
                constraints.maxWidth,
                laneWidgets.length,
              );
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final w in laneWidgets)
                      SizedBox(width: laneWidth, child: w),
                  ],
                ),
              );
            },
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
        // T2-3：WIP 上限配置入口（仅「状态」分组可配；其余分组禁用该按钮）。
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: SegmentedButton<KanbanGroupMode>(
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
                onSelectionChanged: (s) => _setMode(s.first),
              ),
            ),
            IconButton(
              tooltip: '待办上限',
              onPressed: _mode == KanbanGroupMode.status ? _editWipLimit : null,
              icon: Badge(
                isLabelVisible: _wipLimit > 0,
                label: Text('$_wipLimit'),
                child: const Icon(Symbols.speed, size: 20),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 新U3-4（v2.9.7 审计）：看板全空补空态——「状态」模式此前只剩两条
        // 空泳道，分类 / 标签模式因「空分组自动隐藏」什么都不剩，页面只有
        // 标题与分组按钮，用户无从确认「是真没任务还是没加载出来」。
        if (provider.tasks.any((t) => t.deletedAt == null))
          lanesView
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                '暂无任务 · 回首页新建后在这里排布',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: appColors(context).meta,
                ),
              ),
            ),
          ),
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

  /// T2-3：本列的 WIP 上限（0 = 不限 / 不适用）；仅待办列会拿到 >0 的值。
  final int wipLimit;

  /// T2-3：列内「+」建卡的预填维度。
  final Category? category;
  final String? tag;
  const _Column({
    required this.title,
    required this.color,
    required this.tasks,
    required this.canDrop,
    required this.wipLimit,
    this.dropStatus,
    required this.provider,
    this.category,
    this.tag,
  });

  /// T2-3：本列是否为「状态」分组的待办列（WIP 与「+」的适用对象）。
  bool get _isTodoLane => dropStatus == TaskStatus.todo;

  /// T2-3：列内快速建卡。WIP 满时先拦截（弹了表单也存不进「待办」，
  /// 与拖入 / 勾选转回同一口径），并给出明确提示。
  void _quickAdd(BuildContext context) {
    if (_isTodoLane &&
        kanbanWipBlocked(kanbanTodoCountOf(provider), wipLimit)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(wipLimit > 0
            ? '待办已满（上限 $wipLimit），先完成或移出其它待办再新建'
            : '待办已满'),
        duration: const Duration(seconds: 3),
      ));
      return;
    }
    TaskSheet.show(
      context,
      draft: Task(
        id: '',
        title: '',
        priority: Priority.medium,
        category: category ?? Category.work,
        tags: tag == null ? const <String>[] : <String>[tag!],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    // 仅在「状态」模式下允许跨列拖拽改状态；其余分组模式仅展示。
    final accept = canDrop && dropStatus != null;
    return DragTarget<Task>(
      onWillAcceptWithDetails: accept
          ? (d) => d.data.status != dropStatus
          : (_) => false,
      onAcceptWithDetails: accept
          ? (d) {
              // T2-3（v2.9.2 功能增强）：拖入「待办」超限拦截——先放行悬停
              // 视觉（onWillAccept 不掺 WIP，让用户知道落点是合法目标），
              // 接收时再校验并给出明确原因，比悬停即拒绝更有反馈。
              final snapshot = d.data;
              if (_isTodoLane &&
                  snapshot.status != TaskStatus.todo &&
                  kanbanWipBlocked(kanbanTodoCountOf(provider), wipLimit)) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('待办已满（上限 $wipLimit），先完成或移出其它待办'),
                  duration: const Duration(seconds: 3),
                ));
                return;
              }
              // P3-10（v2.9.4 审计）：拖拽改状态同样给出撤销。d.data 是被拖的
              // 那份 Task 快照（拖拽开始时捕获），可直接用作回滚源。
              provider.setStatus(snapshot.id, dropStatus!);
              if (context.mounted) {
                _KanbanCard._showStatusUndo(context, provider, snapshot);
              }
            }
          : null,
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
              for (final t in tasks)
                _KanbanCard(task: t, provider: provider, wipLimit: wipLimit),
              // T2-3（v2.9.2 功能增强）：列内快速建卡——「已完成」列没有
              // 「往里新建」的语义，不展示；其余列复用 TaskSheet 并预填维度。
              if (dropStatus != TaskStatus.done)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () => _quickAdd(context),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor:
                            Theme.of(context).colorScheme.onBackground,
                      ),
                      icon: const Icon(Symbols.add, size: 18),
                      label: const Text('新建'),
                    ),
                  ),
                ),
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

  /// T2-3：所在列的 WIP 上限（0 = 不限 / 不适用）。勾选圈把已完成任务
  /// 转回「待办」时同样受其约束，与拖拽落列同口径。
  final int wipLimit;
  const _KanbanCard(
      {required this.task, required this.provider, this.wipLimit = 0});

  /// P3-10（v2.9.4 审计）：改状态的两个入口都给出 10 秒撤销。
  ///
  /// U2-4（v2.9.5 审计）：**单击不再改状态**，改为打开任务详情。
  /// P2-7（v2.9.7 审计）：v2.9.5 时本文档曾写「改状态保留拖拽落列 + **长按**
  /// 两个显式入口」——v2.9.6 审计确认外层 `onLongPress` 与
  /// `LongPressDraggable` 手势竞争后**实际不可达**，已删除（见 build 末尾
  /// 注释）。现在改状态的等价入口是**标题行末尾的显式勾选圈**（全分组可用）
  /// 与「拖拽落列」（仅状态模式），本文档随实现更正（新U3-6）。
  ///
  /// 变更理由：单击卡片在所有列表型界面里的通用含义都是「打开」；此前单击 =
  /// 切换完成状态，本意想看详情的人一点就把任务改了，而且**全屏没有任何进入
  /// 详情的入口**（备注 / 子任务 / 附件 / 预计时长在看板完全不可达）。
  static void _openDetail(Task t, BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: t.id)),
    );
  }

  /// T2-3：勾选圈改状态。done → todo 方向受 WIP 上限约束（与拖拽落列同口径）：
  /// 超限时提示并阻止，不静默放行。
  void _cycle(BuildContext context) {
    final next =
        task.status == TaskStatus.todo ? TaskStatus.done : TaskStatus.todo;
    if (next == TaskStatus.todo &&
        kanbanWipBlocked(kanbanTodoCountOf(provider), wipLimit)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('待办已满（上限 $wipLimit），先完成或移出其它待办'),
        duration: const Duration(seconds: 3),
      ));
      return;
    }
    final snapshot = task;
    provider.setStatus(task.id, next);
    _showStatusUndo(context, provider, snapshot);
  }

  /// 改状态后的撤销提示。[snapshot] 是 [TaskProvider.setStatus] 变更前的快照。
  ///
  /// 刻意不调 `hideCurrentSnackBar()`（U2-4 同型缺陷）：那会亲手丢掉队列里
  /// 上一条尚未点掉的撤销机会。直接 showSnackBar 让 ScaffoldMessenger 按队列
  /// 依次展示即可。
  ///
  /// P3-5（v2.9.5 审计）：改走 `widgets/undo_snack_bar.dart` 的唯一实现，
  /// 与首页 / occurrence / 习惯侧统一——除时长外还补上「窗口超时已结束」提示
  /// （此前在 10 秒后点空气毫无反馈）。
  static void _showStatusUndo(
      BuildContext context, TaskProvider provider, Task snapshot) {
    // P3-15（v2.9.5 审计）：原为三档三元（todo→'已完成'、done→'待办'、
    // else→'进行中'）。但 [TaskStatus] 只有 `todo` / `done` 两值（见
    // `task.dart:101`），`'进行中'` 分支不可达——是上一版三态枚举的残留。
    // 直接二元映射，避免给读者「还有 doing 状态」的错觉。
    final to =
        snapshot.status == TaskStatus.todo ? '已完成' : '待办';
    showUndoSnackBar(
      context,
      content: undoContent('已移至「$to」'),
      // P2-2（v2.9.6 审计）：restoreTaskSnapshot 返回是否生效（任务已删除时
      // false），由唯一实现统一提示「撤销已失效」。
      onUndo: () async => provider.restoreTaskSnapshot(snapshot),
    );
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
              // P2-7（v2.9.6 审计）：显式改状态入口（勾选圈）——外层长按入口
              // 与 LongPressDraggable 手势竞争后不可达（见 build 末尾注释），
              // 分类 / 标签分组下曾完全无法从看板改状态。视觉小圆圈、48dp
              // 命中区，与今日页勾选框同一形态。
              IconButton(
                onPressed: () => _cycle(context),
                tooltip: done ? '移到待办' : '标记完成',
                // 新U3-3（v2.9.7 审计）：移除 `VisualDensity.compact`——密度
                // 压缩作用在约束的 min 值上（compact = −2 → min −8px），会把
                // `constraints` 声明的 48dp 命中区实际压到 40dp。Material 48dp
                // 最小可点目标是硬要求，视觉紧凑靠 padding: zero 已足够。
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: Icon(
                  done ? Icons.check_circle : Icons.check_circle_outline,
                  size: 20,
                  color: done
                      ? Theme.of(context).colorScheme.primary
                      : ext.meta,
                ),
              ),
            ],
          ),
          // P3-10（v2.9.4 审计）：预计时长此前只出现在任务详情 / 今日页 / 导出表，
          // 看板卡完全没有——排期时最需要「这件事大概要多久」的场景反而看不到。
          // 条件同时容纳 dueHint / repeat / estimate 三者，任一存在才占这一行高度。
          if (dueHint.isNotEmpty || task.isRepeating || task.hasEstimate) ...[
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
                if (task.hasEstimate) ...[
                  if (dueHint.isNotEmpty || task.isRepeating)
                    const SizedBox(width: 6),
                  Icon(Icons.schedule, size: 12, color: ext.meta),
                  const SizedBox(width: 2),
                  // 完成后淡化，与标题的删除线语义一致：预估此时只是历史值。
                  Text(
                    TaskParser.formatDuration(task.estimateMinutes!),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: done ? ext.meta : onBg.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // U2-4：单击进详情（此前单击直接切换完成状态，且全屏无详情入口）。
      //
      // P2-7（v2.9.6 审计）：**移除外层 `onLongPress` 改状态入口**——它与内层
      // `LongPressDraggable` 的 `DelayedMultiDragGestureRecognizer`（同为
      // kLongPressTimeout）在手势竞技场竞争，内层先入竞技场并胜出，外层
      // `onLongPress` 实际不会被投递；而分类 / 标签分组下 `dropStatus == null`、
      // `DragTarget` 不接受落点，长按起拖后**既改不了状态也没有第二入口**，
      // U2-4 想保留的「长按改状态」名存实亡。现改为卡片标题行末尾的**显式
      // 勾选圈**（P2-7 报告建议），全分组模式下都可用。
      onTap: () => _openDetail(task, context),
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
    // P3-1（v2.9.6 审计）：日差判定统一经 [dueCompareKey] 取比较键——本应用
    // 截止时间有「纯日期（00:00/23:59）」与「带时刻」两种存储形态，全部比较
    // 收口到 schedule_advisor 的同一真源，避免口径逐处漂移（P2-10 已是实证）。
    final key = dueCompareKey(t.dueDate!);
    final d = DateTime(key.year, key.month, key.day);
    final diff = d.difference(today).inDays;
    if (diff > 0) return '$diff天后';
    if (diff == 0) return '今天';
    if (diff == -1) return '昨天';
    return '逾期';
  }
}
