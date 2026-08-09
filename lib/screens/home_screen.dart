import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/review.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/task_row.dart';
import 'package:todolist/widgets/new_task_sheet.dart';
import 'package:todolist/widgets/review_card.dart';
import 'package:todolist/screens/review_screen.dart';
import 'package:todolist/screens/task_detail_screen.dart';
import 'package:todolist/widgets/share_sheet.dart';
import 'package:todolist/services/update_checker.dart';
import 'package:todolist/widgets/update_dialog.dart';

/// 首页所有分区标题共用的字号。
/// 「逾期 / 今天 / 未来 / 每天 / 已完成」必须完全一致，避免视觉层级混乱。
const double _sectionTitleFontSize = 20;

/// 计算截止日期相对「今天」的天数差（只比较年月日，忽略时分秒）。
///
/// 返回值：负数 = 逾期，0 = 今天，正数 = 未来，null = 没有截止日期。
/// 与任务行右侧的日期标签（task_row.dart 的 _dueLabel）采用同一套按天比较口径。
int? _dueDayDiff(DateTime? due) {
  if (due == null) return null;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return DateTime(due.year, due.month, due.day).difference(today).inDays;
}

class HomeScreen extends StatefulWidget {
  /// 搜索态变化回调：用于让宿主 Scaffold 在搜索时隐藏「新增任务」FAB。
  final void Function(bool)? onSearchingChanged;

  const HomeScreen({super.key, this.onSearchingChanged});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// 同一进程内只自动检测一次（防止 Tab 切换导致 State 重建重复触发）。
  static bool _autoUpdateChecked = false;

  @override
  void initState() {
    super.initState();
    _autoCheckUpdate();
  }

  /// 启动后自动检测一次新版本：每日最多弹一次 + 跳过的版本不再提示。
  void _autoCheckUpdate() {
    if (_autoUpdateChecked) return;
    _autoUpdateChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!await UpdateChecker.shouldAutoPrompt()) return;
      final skip = await UpdateChecker.getSkipVersion();
      final res = await UpdateChecker.check();
      await UpdateChecker.markAutoChecked();
      if (!mounted) return;
      if (res.hasUpdate && res.info != null) {
        if (skip == res.info!.version) return; // 该版本已选择跳过
        await UpdateDialog.show(context, res.info!);
      }
    });
  }

  /// 是否处于多选模式
  bool _selecting = false;

  /// 已选中的任务 id（多选模式）
  final Set<String> _selected = {};

  /// 是否进入搜索模式
  bool _searching = false;

  /// 当前标签筛选（null 表示不过滤）。点击标签芯片切换；再次点击同一标签取消。
  String? _tagFilter;

  /// 搜索关键字输入框
  final TextEditingController _searchCtl = TextEditingController();

  /// 长按进入多选模式，并把当前任务预选上。
  void _enterSelect(Task task) {
    setState(() {
      _selecting = true;
      _selected.add(task.id);
    });
  }

  /// 点选 / 取消点选某项
  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
      if (_selected.isEmpty) _selecting = false;
    });
  }

  /// 退出多选模式
  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  /// 进入搜索模式
  void _enterSearch() {
    setState(() => _searching = true);
    widget.onSearchingChanged?.call(true);
  }

  /// 退出搜索模式并清空关键字
  void _exitSearch() {
    _searchCtl.clear();
    setState(() => _searching = false);
    widget.onSearchingChanged?.call(false);
  }

  /// 任务是否命中搜索关键字：标题 / 分类 / 优先级 / 备注 / 重复规则 / 标签（忽略大小写）。
  bool _matchesQuery(Task t) {
    final q = _searchCtl.text.trim().toLowerCase();
    if (q.isEmpty) return false;
    return t.title.toLowerCase().contains(q) ||
        t.category.label.toLowerCase().contains(q) ||
        t.category.name.toLowerCase().contains(q) ||
        _prioLabel(t.priority).contains(q) ||
        t.priority.name.toLowerCase().contains(q) ||
        t.note.toLowerCase().contains(q) ||
        t.repeat.label.toLowerCase().contains(q) ||
        t.repeatSummary.toLowerCase().contains(q) ||
        t.tags.any((tag) => tag.toLowerCase().contains(q));
  }

  static String _prioLabel(Priority p) =>
      p == Priority.high ? '高' : p == Priority.medium ? '中' : '低';

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  /// 全选 / 反选当前可见任务
  void _toggleSelectAll(List<Task> visible) {
    final allSelected = visible.isNotEmpty &&
        visible.every((t) => _selected.contains(t.id));
    setState(() {
      if (allSelected) {
        _selected.clear();
        _selecting = false;
      } else {
        _selected.addAll(visible.map((t) => t.id));
      }
    });
  }

  /// 批量删除已选项，并弹出带撤销的提示
  void _deleteSelected(BuildContext context) {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final count = ids.length;
    final provider = context.read<TaskProvider>();
    provider.deleteTasks(ids);
    _exitSelect();
    _showBatchUndoSnackBar(context, provider, count);
  }

  /// 单个任务行（含滑动/多选/编辑），两个分区与筛选列表共用。
  /// [dragIndex] 非 null 时在左侧显示一个拖拽手柄（仅首页默认视图、无标签筛选时启用），
  /// 用于手动重排；其余场景走普通 Padding。
  Widget _tile(BuildContext context, Task t, {Key? key, int? dragIndex}) {
    final provider = context.read<TaskProvider>();
    final dismissible = _DismissibleTask(
      task: t,
      selecting: _selecting,
      selected: _selected.contains(t.id),
      onToggle: () => provider.toggleDone(t.id),
      onLongPress: () => _enterSelect(t),
      onEdit: () => TaskSheet.show(context, task: t),
      onSelect: () => _toggleSelect(t.id),
      onDeleted: (removed) => _showUndoSnackBar(context, provider, removed),
    );
    if (dragIndex == null) {
      return Padding(
        key: key,
        padding: const EdgeInsets.only(bottom: AppColors.contentGap),
        child: dismissible,
      );
    }
    final ext = appColors(context);
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: AppColors.contentGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ReorderableDragStartListener(
            index: dragIndex,
            child: Container(
              width: 26,
              height: 56,
              alignment: Alignment.center,
              child: Icon(Symbols.drag_indicator, size: 20, color: ext.meta),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(child: dismissible),
        ],
      ),
    );
  }

  /// 生成一个首页分区：标题行 + 任务行 + 段间距。
  ///
  /// - 任务为空时整段隐藏，避免首页出现一排「0」的空标题；
  /// - [alwaysShow] 为 true 的分区（「今天」）即使为空也保留标题，让页面不至于全空；
  /// - [countColor] 用于给「逾期」的计数一点醒目色，标题字号/字重/颜色所有分区完全一致；
  /// - [reorderable] 为 true 时（仅默认全量视图、无标签筛选）把任务行包进
  ///   [ReorderableListView]，左侧拖拽手柄即可手动重排，顺序写入任务的 [Task.order]。
  List<Widget> _section(
    BuildContext context,
    String title,
    String sectionKey,
    List<Task> items,
    AppColorsExt ext, {
    Color? countColor,
    bool alwaysShow = false,
    bool reorderable = false,
  }) {
    // 标签筛选：仅保留含该标签的任务（reorderable 时 _tagFilter 必为 null）。
    final shown = _tagFilter == null
        ? items
        : items.where((t) => t.tags.contains(_tagFilter)).toList();
    if (shown.isEmpty && !alwaysShow) return const [];
    final provider = context.read<TaskProvider>();
    final header = _SectionHeader(
      title: title,
      count: shown.length,
      chipColor: ext.chip,
      metaColor: countColor ?? ext.meta,
    );
    final tiles = shown
        .map((t) => _tile(
              context,
              t,
              key: Key(t.id),
              dragIndex: reorderable ? items.indexOf(t) : null,
            ))
        .toList();
    if (reorderable) {
      return [
        header,
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (oldIndex, newIndex) =>
              provider.reorderTasks(sectionKey, oldIndex, newIndex),
          children: tiles,
        ),
        const SizedBox(height: 8),
      ];
    }
    return [
      header,
      ...tiles,
      const SizedBox(height: 8),
    ];
  }

  /// 搜索结果视图：空关键字显示提示，有结果则扁平列出命中任务（复用现有任务行）。
  Widget _buildSearchResults(BuildContext context, TaskProvider provider) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final query = _searchCtl.text.trim();
    if (query.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('输入关键字搜索任务',
              style: TextStyle(color: ext.meta, fontSize: 14)),
        ),
      );
    }
    final results = provider.tasks.where(_matchesQuery).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppColors.pagePadX,
        8,
        AppColors.pagePadX,
        20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('找到 ${results.length} 条',
                style: TextStyle(color: ext.meta, fontSize: 13)),
          ),
          if (results.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Center(
                child: Text('没有匹配的任务',
                    style: TextStyle(color: ext.meta, fontSize: 14)),
              ),
            )
          else
            ...results.map((t) => _tile(context, t)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    final onBg = scheme.onBackground;
    final error = scheme.error;

    return Consumer<TaskProvider>(
      builder: (context, provider, _) {
        final tasks = provider.tasks;

        // —— 首页分区口径（按日期切分）——
        // 1) 未完成 + 非每日提醒的任务，按截止日期分成「逾期 / 今天 / 未来」三段；
        //    无截止日期的任务归入「今天」（视为当天就要做，且始终跟随当前日期，跨天自动顺延到第二天）。
        // 2) 未完成 + 开启每日提醒的任务单独归入「每天」，不参与日期切分（它每天都要做）。
        // 3) 已完成的任务统一进「已完成」，不按日期切分。
        // 四类互不重叠，任何一个任务在首页只会出现在一个板块里。
        final active = tasks.where((t) => !t.done && !t.isRepeating).toList();

        // 逾期：截止日期早于今天，按截止时间升序（拖得最久的排最前，优先处理）
        final overdue = active
            .where((t) => (_dueDayDiff(t.dueDate) ?? 0) < 0)
            .toList()
          ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));

        // 今天：截止日期就是今天，或没有截止日期（无截止视为当天，始终跟随当前日期，跨天自动顺延）。
        final today = active
            .where((t) => _dueDayDiff(t.dueDate) == 0 || t.dueDate == null)
            .toList()
          ..sort((a, b) {
            // 无截止日期的排到今天列表末尾，不破坏有日期任务的按时排序
            if (a.dueDate == null && b.dueDate == null) return 0;
            if (a.dueDate == null) return 1;
            if (b.dueDate == null) return -1;
            return a.dueDate!.compareTo(b.dueDate!);
          });

        // 未来：仅含截止日期在今天之后的任务（无截止已归入「今天」）。
        final future = active.where((t) {
          final d = _dueDayDiff(t.dueDate);
          return d != null && d > 0;
        }).toList()
          ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));

        // 重复：重复任务（所有规则），按提醒时刻升序（未设时刻的排最后）
        final repeat = tasks.where((t) => t.isRepeating && !t.done).toList()
          ..sort((a, b) => (a.repeatMinute ?? 24 * 60)
              .compareTo(b.repeatMinute ?? 24 * 60));

        final done = tasks.where((t) => t.done).toList();

        final filter = provider.taskFilter;
        final filtered = switch (filter) {
          TaskFilter.todo => tasks.where((t) => t.status == TaskStatus.todo).toList(),
          TaskFilter.done => tasks.where((t) => t.status == TaskStatus.done).toList(),
          // 与「逾期」板块口径保持一致：按「天」判断，今天到点未做不算逾期。
          TaskFilter.overdue =>
            tasks.where((t) => !t.done && (_dueDayDiff(t.dueDate) ?? 0) < 0).toList(),
          TaskFilter.all => const <Task>[],
        };
        final visible = filter == TaskFilter.all
            ? [...overdue, ...today, ...future, ...repeat, ...done]
            : filtered;

        // 拖拽重排仅在默认全量视图、无标签筛选时启用（与 _section 的 reorderable 对齐）。
        final canReorder = filter == TaskFilter.all && _tagFilter == null;

        final appBar = _searching
            ? SizedBox(
                height: 64,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppColors.pagePadX),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      IconButton(
                        onPressed: _exitSearch,
                        icon: Icon(Symbols.arrow_back, size: 24, color: onBg),
                        splashRadius: 20,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: TextField(
                          controller: _searchCtl,
                          autofocus: true,
                          onChanged: (_) => setState(() {}),
                          style: TextStyle(fontSize: 16, color: onBg),
                          decoration: InputDecoration(
                            hintText: '搜索任务 / 分类 / 优先级',
                            hintStyle: TextStyle(fontSize: 16, color: ext.meta),
                            border: InputBorder.none,
                            isCollapsed: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : _selecting
                ? SizedBox(
                    height: 64,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppColors.pagePadX),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          IconButton(
                            onPressed: _exitSelect,
                            icon: Icon(Symbols.close, size: 24, color: onBg),
                            splashRadius: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '已选 ${_selected.length}',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: onBg,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => _toggleSelectAll(visible),
                            child: Text(
                              '全选',
                              style: TextStyle(fontSize: 15, color: primary),
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            onPressed: () => _deleteSelected(context),
                            icon: Icon(Symbols.delete, size: 24, color: error),
                            splashRadius: 20,
                            tooltip: '删除所选',
                          ),
                        ],
                      ),
                    ),
                  )
                : TopAppBar(
                    title: '首页',
                    actions: [
                      IconButton(
                        onPressed: _enterSearch,
                        icon: Icon(Symbols.search, size: 24, color: onBg),
                        tooltip: '搜索',
                        splashRadius: 20,
                      ),
                      IconButton(
                        onPressed: () => showShareSheet(context, home: true),
                        icon: Icon(Symbols.ios_share, size: 24, color: onBg),
                        tooltip: '分享首页',
                        splashRadius: 20,
                      ),
                    ],
                  );

        return PopScope(
          // 搜索 / 多选模式下，系统侧滑返回应先退出子模式，而不是直接退出 App 回到桌面
          canPop: !_searching && !_selecting,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (didPop) return;
            if (_searching) {
              _exitSearch();
            } else if (_selecting) {
              _exitSelect();
            }
          },
          child: Column(
            children: [
              appBar,
            Expanded(
              child: _searching
                  ? _buildSearchResults(context, provider)
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                        AppColors.pagePadX,
                        8,
                        AppColors.pagePadX,
                        20,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 筛选芯片：默认「全部」；看板统计卡点击会套用对应筛选
                          _FilterChips(provider: provider),
                          const SizedBox(height: 12),
                          // 标签筛选芯片：存在标签且非搜索态时才显示
                          if (filter == TaskFilter.all &&
                              !_searching &&
                              provider.allTags.isNotEmpty) ...[
                            _TagFilterChips(
                              allTags: provider.allTags,
                              active: _tagFilter,
                              onTap: (tag) => setState(() {
                                _tagFilter = _tagFilter == tag ? null : tag;
                              }),
                            ),
                            const SizedBox(height: 12),
                          ],
                          // 本周回顾摘要卡：仅默认全量视图、非搜索态显示，点击进入完整周报页。
                          if (filter == TaskFilter.all && !_searching) ...[
                            Builder(
                              builder: (context) {
                                final r = WeeklyReview.fromProviders(
                                  provider,
                                  context.read<FocusProvider>(),
                                  context.read<HabitProvider>(),
                                );
                                return WeeklyReviewCard(
                                  review: r,
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => const ReviewScreen(),
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (filter == TaskFilter.all) ...[
                            // 拖拽重排仅在默认全量视图、无标签筛选时启用
                            // 逾期：已过截止日期（计数用醒目色，字号与其他分区一致）
                            ..._section(context, '逾期', 'overdue', overdue, ext,
                                countColor: error, reorderable: canReorder),
                            // 今天：今天到期（唯一常驻分区，为空也保留标题）
                            ..._section(context, '今天', 'today', today, ext,
                                alwaysShow: canReorder, reorderable: canReorder),
                            // 未来：今天之后到期 + 无截止日期
                            ..._section(context, '未来', 'future', future, ext,
                                reorderable: canReorder),
                            // 重复：重复任务（所有规则）
                            ..._section(context, '重复', 'repeat', repeat, ext,
                                reorderable: canReorder),
                            // 已完成
                            ..._section(context, '已完成', 'done', done, ext,
                                reorderable: canReorder),
                          ] else ...[
                            ...filtered.map((t) => _tile(context, t, key: Key(t.id))),
                          ],
                        ],
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

/// 首页标签筛选芯片行：列出所有已用标签，点击切换筛选（再次点击同一标签取消）。
class _TagFilterChips extends StatelessWidget {
  final List<String> allTags;
  final String? active;
  final void Function(String tag) onTap;
  const _TagFilterChips({
    required this.allTags,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedText = isDark ? AppColors.lightChip : Colors.white;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tag in allTags)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => onTap(tag),
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: active == tag ? primary : ext.chip,
                    borderRadius: BorderRadius.circular(AppColors.chipRadius),
                  ),
                  child: Center(
                    child: Text(
                      '#$tag',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: active == tag ? selectedText : ext.meta,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 首页筛选芯片行：全部 / 待办 / 已完成 / 逾期。
class _FilterChips extends StatelessWidget {
  final TaskProvider provider;
  const _FilterChips({required this.provider});

  static const List<(TaskFilter, String)> _items = [
    (TaskFilter.all, '全部'),
    (TaskFilter.todo, '待办'),
    (TaskFilter.done, '已完成'),
    (TaskFilter.overdue, '逾期'),
  ];

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedText = isDark ? AppColors.lightChip : Colors.white;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (f, label) in _items)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => provider.setTaskFilter(f),
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: provider.taskFilter == f ? primary : ext.chip,
                    borderRadius: BorderRadius.circular(AppColors.chipRadius),
                  ),
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: provider.taskFilter == f ? selectedText : ext.meta,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color chipColor;
  final Color metaColor;
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.chipColor,
    required this.metaColor,
  });

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppColors.contentGap),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 字号统一走 _sectionTitleFontSize，保证各分区标题一样大
          Text(title,
              style: TextStyle(
                  fontSize: _sectionTitleFontSize,
                  fontWeight: FontWeight.bold,
                  color: onBg)),
          Container(
            height: 19,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: chipColor,
              borderRadius: BorderRadius.circular(AppColors.chipRadius),
            ),
            child: Text('$count',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500, color: metaColor)),
          ),
        ],
      ),
    );
  }
}

/// 可滑动的任务行：
/// - 向右滑（startToEnd）删除任务，删除后回调 onDeleted(removed) 并支持撤销；
/// - 向左滑（endToStart）进入编辑，回调 onEdit（通常是打开编辑面板，不删除）；
/// - 长按主体进入多选模式（onLongPress），由父级控制 [selecting]；
/// - [selecting] 为 true 时：禁用滑动手势，整行点击切换选中（onSelect）。
class _DismissibleTask extends StatelessWidget {
  final Task task;
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;
  final VoidCallback? onEdit;
  final VoidCallback? onSelect;
  final void Function(Task removed) onDeleted;
  const _DismissibleTask({
    required this.task,
    this.selecting = false,
    this.selected = false,
    this.onToggle,
    this.onLongPress,
    this.onEdit,
    this.onSelect,
    required this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final row = TaskRow(
      task: task,
      onToggle: selecting ? null : onToggle,
      onLongPress: selecting ? null : onLongPress,
      onTap: selecting
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TaskDetailScreen(taskId: task.id),
                ),
              ),
      selecting: selecting,
      selected: selected,
      onSelect: selecting ? onSelect : null,
    );

    // 多选模式下不响应滑动手势
    if (selecting) return row;

    final error = Theme.of(context).colorScheme.error;
    final ext = appColors(context);
    return Dismissible(
      key: Key(task.id),
      direction: DismissDirection.horizontal,
      // 向右滑：左侧露出「删除」红色背景
      background: _deleteBg(error, Alignment.centerLeft),
      // 向左滑：右侧露出「编辑」蓝色背景
      secondaryBackground: _editBg(ext.accent, Alignment.centerRight),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          // 向左滑 = 编辑：不让 Dismissible 真正消失，先回弹再打开编辑面板。
          onEdit?.call();
          return false;
        }
        // 向右滑 = 删除：允许 dismiss。
        return true;
      },
      onDismissed: (_) {
        // 只有右滑（startToEnd）会走到这里。
        final removed = context.read<TaskProvider>().deleteTask(task.id);
        if (removed != null) onDeleted(removed);
      },
      child: row,
    );
  }

  Widget _deleteBg(Color error, Alignment align) => Container(
        decoration: BoxDecoration(
          color: error,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
        alignment: align,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Symbols.delete, color: Colors.white, size: 24),
      );

  Widget _editBg(Color accent, Alignment align) => Container(
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
        alignment: align,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Symbols.edit, color: Colors.white, size: 24),
      );
}

/// 单个删除后底部提示，支持撤销。
void _showUndoSnackBar(BuildContext context, TaskProvider provider, Task removed) {
  ScaffoldMessenger.of(context).clearSnackBars();
  final controller = ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已删除「${removed.title}」'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => provider.undoDelete(),
      ),
      duration: const Duration(seconds: 4),
    ),
  );
  // 兜底：无论是否点击撤销，4 秒后强制收起。
  Future.delayed(const Duration(seconds: 4), () {
    controller.close();
  });
}

/// 批量删除后底部提示，支持整体撤销。
void _showBatchUndoSnackBar(
    BuildContext context, TaskProvider provider, int count) {
  ScaffoldMessenger.of(context).clearSnackBars();
  final controller = ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已删除 $count 个任务'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => provider.undoDelete(),
      ),
      duration: const Duration(seconds: 4),
    ),
  );
  Future.delayed(const Duration(seconds: 4), () {
    controller.close();
  });
}
