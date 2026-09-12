import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/review.dart';
import 'package:todolist/models/today.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/command_palette_button.dart';
import 'package:todolist/widgets/task_row.dart';
import 'package:todolist/widgets/new_task_sheet.dart';
import 'package:todolist/widgets/review_card.dart';
import 'package:todolist/widgets/today_card.dart';
import 'package:todolist/screens/review_screen.dart';
import 'package:todolist/screens/period_review_screen.dart';
import 'package:todolist/screens/today_screen.dart';
import 'package:todolist/screens/task_detail_screen.dart';
import 'package:todolist/widgets/share_sheet.dart';
import 'package:todolist/widgets/batch_edit_sheet.dart';
import 'package:todolist/widgets/past_due_guard.dart';
import 'package:todolist/services/update_checker.dart';
import 'package:todolist/services/search_index.dart';
import 'package:todolist/widgets/update_dialog.dart';

/// 首页所有分区标题共用的字号。
/// 「逾期 / 今天 / 未来 / 每天 / 已完成」必须完全一致，避免视觉层级混乱。
const double _sectionTitleFontSize = 20;

/// 1=周一 … 7=周日 → 中文单字（搜索习惯频率文案用）。
String _wdLabel(int w) =>
    ['一', '二', '三', '四', '五', '六', '日'][(w - 1).clamp(0, 6)];

class HomeScreen extends StatefulWidget {
  /// 搜索态变化回调：用于让宿主 Scaffold 在搜索时隐藏「新增任务」FAB。
  final void Function(bool)? onSearchingChanged;

  /// 搜索结果中点「习惯」时，通知宿主切到「习惯」Tab（index 4）。
  final void Function()? onOpenHabit;

  const HomeScreen({super.key, this.onSearchingChanged, this.onOpenHabit});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

/// 状态类设为公开：P1-9 桌面端 Ctrl/Cmd+F 需由宿主 MainScaffold 经
/// GlobalKey<HomeScreenState> 调用 [focusSearch] / [exitSearch]，故不能私有。
class HomeScreenState extends State<HomeScreen> {
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

  /// 搜索输入框焦点：P1-9 供桌面端 Ctrl/Cmd+F 快捷键从外部聚焦。
  final FocusNode _searchFocus = FocusNode();

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

  /// P1-9：供桌面端 Ctrl/Cmd+F 快捷键从宿主 Scaffold 调用——进入搜索并聚焦输入框。
  /// 已处于搜索态时仅重新聚焦，避免重复重建。
  void focusSearch() {
    if (!_searching) _enterSearch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).requestFocus(_searchFocus);
    });
  }

  /// P1-9：供桌面端 Esc 快捷键从宿主 Scaffold 调用——退出搜索（仅搜索态有效）。
  void exitSearch() {
    if (_searching) _exitSearch();
  }

  // 搜索匹配逻辑已下沉到 GlobalSearch（lib/services/search_index.dart），
  // 纯 Dart、可单测，不在此处重复实现。

  @override
  void dispose() {
    _searchCtl.dispose();
    _searchFocus.dispose();
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

  /// P0-1：批量编辑已选项（改日期 / 优先级 / 分类 / 追加标签 / 置顶）。
  void _editSelected(BuildContext context) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final n = await BatchEditSheet.show(context, ids);
    if (n == null || n == 0 || !context.mounted) return;
    _exitSelect();
    // F1：批量编辑后提供一键撤销（改前快照已由 TaskProvider 保存）。
    final provider = context.read<TaskProvider>();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已更新 $n 条任务'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => provider.undoBatchEdit(),
        ),
      ),
    );
  }

  /// 批量删除已选项，并弹出带撤销的提示
  ///
  /// U8：删除是单向不可逆操作（虽然有撤销 snackbar，但用户容易错过撤销时限），
  /// 故在执行前弹确认框，让用户看清影响条数后再继续。
  Future<void> _deleteSelected(BuildContext context) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final count = ids.length;
    final provider = context.read<TaskProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('批量删除？'),
        content: Text('将删除 $count 项任务（可在 5 秒内撤销）。继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    provider.deleteTasks(ids);
    _exitSelect();
    _showBatchUndoSnackBar(context, provider, count);
  }

  /// P1-6：供桌面端 `Cmd/Ctrl+Enter` 调用，批量完成当前选中项，返回实际完成条数。
  ///
  /// **必须**走 [TaskProvider.toggleDone] 而不是 [TaskProvider.batchUpdate]：
  /// `updateTask` 会强制保留旧的 `status` 与 `completedAt`，经 batchUpdate 提交的
  /// 完成态会被静默丢弃（看似成功实则无效）。toggleDone 同时负责重排重复提醒，
  /// 与点击勾选框的行为完全一致。
  ///
  /// 已完成的项会被跳过——快捷键语义是「完成」而非「反选」，
  /// 否则对混合选区按一次会把已完成的任务又切回未完成。
  int completeSelected() {
    if (_selected.isEmpty) return 0;
    final provider = context.read<TaskProvider>();
    // 先快照成列表再逐条切换：toggleDone 会改动 _tasks，边遍历边改不安全。
    final ids = _selected
        .where((id) {
          final t = provider.byId(id);
          return t != null && !t.done;
        })
        .toList();
    for (final id in ids) {
      provider.toggleDone(id);
    }
    if (ids.isNotEmpty) _exitSelect();
    return ids.length;
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
      // U5：仅拖拽重排场景保留任务行固定窄标题（绕过 shrinkWrap 弹性零宽 bug）；
      // 搜索结果 / 标签筛选等普通列表用全宽 Expanded，长标题可读、整行可点进详情。
      constrainTitleWidth: dragIndex != null,
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
    Widget? headerAction,
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
      action: headerAction,
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
    final query = _searchCtl.text.trim();
    if (query.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('输入关键字搜索任务 / 习惯',
              style: TextStyle(color: ext.meta, fontSize: 14)),
        ),
      );
    }
    final habits = context.read<HabitProvider>().habits;
    final result = GlobalSearch.query(query, tasks: provider.tasks, habits: habits);
    if (result.total == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Text('没有匹配的结果',
              style: TextStyle(color: ext.meta, fontSize: 14)),
        ),
      );
    }
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
            child: Text('找到 ${result.total} 条',
                style: TextStyle(color: ext.meta, fontSize: 13)),
          ),
          if (result.tasks.isNotEmpty) ...[
            _SectionHeader(
              title: '任务',
              count: result.tasks.length,
              chipColor: ext.chip,
              metaColor: ext.meta,
            ),
            ...result.tasks.map((t) => _tile(context, t)),
            const SizedBox(height: 8),
          ],
          if (result.habits.isNotEmpty) ...[
            _SectionHeader(
              title: '习惯',
              count: result.habits.length,
              chipColor: ext.chip,
              metaColor: ext.meta,
            ),
            ...result.habits.map(
              (h) => _SearchHabitRow(habit: h, onTap: widget.onOpenHabit),
            ),
            const SizedBox(height: 8),
          ],
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
        // 1) 未完成 + 非（仍在循环的）重复任务，按截止日期分成「逾期 / 今天 / 未来」三段；
        //    无截止日期的任务归入「今天」（视为当天就要做，且始终跟随当前日期，跨天自动顺延到第二天）。
        // 2) 未完成 + 仍在循环的重复任务单独归入「每天」，不参与日期切分（它每天都要做）。
        // 3) 已完成的任务统一进「已完成」，不按日期切分。
        // 四类互不重叠，任何一个任务在首页只会出现在一个板块里。
        //
        // F-5：口径与 TaskProvider.homeTasks / sectionCounts / _sectionNameOf 严格对齐。
        // 此前这里用「isRepeating」一刀切，导致两处偏差：
        // ① 已「结束重复」或自然到期的任务仍被留在「每天」板块里永远赖着不走
        //    （用户点「结束重复」的本意是让它干净退场，弹窗也承诺「今天起不再出现」）；
        // ② 同一任务在首页与分享卡片 / 拖拽落点被分到不同板块。
        // 现统一按 [Task.isRepeatEnded] 判定是否仍在循环，并把已结束重复任务的
        // 那个过期占位截止日中性化（[endRepeat] 已直接清空；自然到期在判定层处理），
        // 使其回落到「今天」而不是「逾期」。
        // P1-1（v2.8.6 审计）：五个分区直接复用 [TaskProvider.homeTasks] 的同一份
        // 序列（pinned → order → 日期 三级排序）。此前这里本地重排「只看 pinned +
        // 日期」，与 [TaskProvider.reorderTasks] 写回的 order 基准脱节：
        // ① 拖拽改好的顺序在页面重建后立刻被日期排序打回（手动排序承诺失效）；
        // ② 两套排序基准 → UI 序列与 provider 序列错位，拖拽会作用到「视觉相邻、
        //    逻辑不同」的任务上，并反复污染同分区所有任务的 order。
        // 现在 UI 与 reorderTasks 共享同一索引空间，上述问题一并消除；
        // 分享长图等 homeTasks 消费方看到的顺序也与首页完全一致。
        final home = provider.homeTasks;
        final overdue = home['overdue'] ?? const <Task>[];
        final today = home['today'] ?? const <Task>[];
        final future = home['future'] ?? const <Task>[];
        final repeat = home['repeat'] ?? const <Task>[];
        final done = home['done'] ?? const <Task>[];

        final filter = provider.taskFilter;
        final filtered = switch (filter) {
          TaskFilter.todo => tasks.where((t) => t.status == TaskStatus.todo).toList(),
          TaskFilter.done => tasks.where((t) => t.status == TaskStatus.done).toList(),
          // 与「逾期」板块口径保持一致：按「天」判断，今天到点未做不算逾期。
          TaskFilter.overdue =>
            tasks.where((t) => Task.isOverdue(t, DateTime.now())).toList(),
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
                          focusNode: _searchFocus,
                          autofocus: true,
                          onChanged: (_) => setState(() {}),
                          style: TextStyle(fontSize: 16, color: onBg),
                          decoration: InputDecoration(
                            hintText: '搜索任务 / 习惯',
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
                          // P0-1：批量编辑（改日期 / 优先级 / 分类 / 标签 / 置顶）
                          IconButton(
                            onPressed: () => _editSelected(context),
                            icon: Icon(Symbols.edit, size: 24, color: primary),
                            splashRadius: 20,
                            tooltip: '批量编辑所选',
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
                      // U4：命令面板移动端入口（原来只有桌面 Ctrl+P 可达）。
                      const CommandPaletteButton(currentIndex: 0),
                      IconButton(
                        onPressed: _enterSearch,
                        icon: Icon(Symbols.search, size: 24, color: onBg),
                        tooltip: '搜索',
                        splashRadius: 20,
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PeriodReviewScreen(),
                          ),
                        ),
                        icon: Icon(Symbols.calendar_month, size: 24, color: onBg),
                        tooltip: '月报 / 年报',
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
                          // 今日摘要卡：仅默认全量视图、非搜索态显示，点击进入今日聚合页。
                          if (filter == TaskFilter.all && !_searching) ...[
                            Builder(
                              builder: (context) {
                                final t = TodayAggregate.fromProviders(
                                  provider,
                                  context.read<FocusProvider>(),
                                  context.read<HabitProvider>(),
                                );
                                return TodayCard(
                                  today: t,
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => const TodayScreen(),
                                    ),
                                  ),
                                );
                              },
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
                            // P0-2：逾期区头部「顺延」入口——一键把全部逾期任务改到
                            // 今天 / 明天 / +N 天，省去逐条改期。
                            ..._section(context, '逾期', 'overdue', overdue, ext,
                                countColor: error,
                                reorderable: canReorder,
                                headerAction: overdue.isEmpty
                                    ? null
                                    : _PostponeButton(
                                        ids: overdue.map((t) => t.id).toList(),
                                      )),
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

  /// P0-2：标题右侧的分区级操作（目前仅「逾期」区使用，放「一键顺延」入口）。
  final Widget? action;
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.chipColor,
    required this.metaColor,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppColors.contentGap),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 字号统一走 _sectionTitleFontSize，保证各分区标题一样大
              Text(title,
                  style: TextStyle(
                      fontSize: _sectionTitleFontSize,
                      fontWeight: FontWeight.bold,
                      color: onBg)),
              if (action != null) ...[
                const SizedBox(width: 10),
                action!,
              ],
            ],
          ),
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

/// P0-2：逾期区头部的「顺延」入口——把该区全部任务整体改期到今天 / 明天 / +N 天，
/// 省去「逾期堆积后逐条改期」的机械劳动。改期走 [TaskProvider.postponeTo]，
/// 提醒由既有链路统一重排。
class _PostponeButton extends StatelessWidget {
  final List<String> ids;
  const _PostponeButton({required this.ids});

  Future<void> _postpone(BuildContext context, DateTime day) async {
    final provider = context.read<TaskProvider>();
    // U9：先记录各任务原截止日期（仅取有截止的），供 snackbar 展示「原日期」。
    final originalDates = <String>{};
    for (final id in ids) {
      final t = provider.byId(id);
      if (t?.dueDate != null) {
        originalDates.add(
            '${t!.dueDate!.month}月${t.dueDate!.day}日');
      }
    }
    // P3-5：预演改期结果——「顺延到今天」而原时刻已过时，一次性任务的截止提醒
    // 会被排到过去时刻、**永远不会触发**。此前只有新建 / 编辑弹层有这条警告，
    // 这里补齐口径一致（预演用的变换与 postponeTo 内部严格相同，保留原时分）。
    final dead = PastDueGuard.countDeadAfter(
      ids.map(provider.byId).whereType<Task>().toList(),
      (t) {
        final d = t.dueDate;
        if (d == null) return t;
        return t.copyWith(
          dueDate: DateTime(day.year, day.month, day.day, d.hour, d.minute),
        );
      },
      DateTime.now(),
    );
    if (dead > 0) {
      final go = await PastDueGuard.confirm(
        context,
        count: dead,
        detail: '$dead 项任务的截止时刻已早于当前时刻，'
            '顺延后提醒将不会触发（原时刻保留）。\n\n仍要顺延吗？',
      );
      if (!go || !context.mounted) return;
    }
    final n = provider.postponeTo(ids, day);
    if (!context.mounted) return;
    final origText = originalDates.isEmpty
        ? ''
        : '原截止：${originalDates.take(3).join('、')}'
            '${originalDates.length > 3 ? ' 等 ${originalDates.length} 个日期' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已顺延 $n 条任务到 '
            '${day.month}月${day.day}日'
            '${origText.isEmpty ? '' : ' · $origText'}'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          // U9：顺延经 batchUpdate 落库，_lastEditBatch 留有改前快照，
          // undoBatchEdit 可一键还原全部日期与提醒。
          label: '撤销',
          onPressed: () => context.read<TaskProvider>().undoBatchEdit(),
        ),
      ),
    );
  }

  /// 自定义天数：弹窗输入后按「今天 + N 天」改期。
  Future<void> _custom(BuildContext context) async {
    final ctl = TextEditingController(text: '3');
    final days = await showDialog<int>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('顺延天数'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '输入天数，如 3'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(d, int.tryParse(ctl.text.trim())),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctl.dispose();
    // U20：输入非数字 / ≤0 时旧实现静默 return（用户以为执行了）；改为显式提示。
    if (days == null || days <= 0) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入大于 0 的天数')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    final now = DateTime.now();
    await _postpone(
        context, DateTime(now.year, now.month, now.day).add(Duration(days: days)));
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      tooltip: '一键顺延',
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: primary.withOpacity(0.12),
          borderRadius: BorderRadius.circular(AppColors.chipRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.schedule, size: 15, color: primary),
            const SizedBox(width: 4),
            Text('顺延',
                style: TextStyle(
                    fontSize: 12,
                    color: primary,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
      onSelected: (v) async {
        switch (v) {
          case 'today':
            await _postpone(context, today);
            break;
          case 'tomorrow':
            await _postpone(context, today.add(const Duration(days: 1)));
            break;
          case 'custom':
            await _custom(context);
            break;
          default:
            final d = int.tryParse(v);
            if (d != null) {
              await _postpone(context, today.add(Duration(days: d)));
            }
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'today', child: Text('顺延到今天')),
        PopupMenuItem(value: 'tomorrow', child: Text('顺延到明天')),
        PopupMenuItem(value: '3', child: Text('顺延 3 天')),
        PopupMenuItem(value: '7', child: Text('顺延 7 天')),
        PopupMenuItem(value: 'custom', child: Text('自定义天数…')),
      ],
    );
  }
}

/// 搜索结果中的习惯行：复用习惯卡片的视觉（emoji 圆头像 + 标题 + 连续天数/频率），
/// 点击整体跳到「习惯」Tab（由 HomeScreen.onOpenHabit 驱动）。
class _SearchHabitRow extends StatelessWidget {
  final Habit habit;
  final VoidCallback? onTap;
  const _SearchHabitRow({required this.habit, this.onTap});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final hp = context.watch<HabitProvider>();
    final streak = hp.currentStreak(habit);
    final freq = habit.weekdays.isEmpty
        ? '每天'
        : '每周 ${habit.weekdays.map(_wdLabel).join(' ')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppColors.contentGap),
      child: Material(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
          onTap: onTap,
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: CircleAvatar(
              backgroundColor: Color(habit.colorValue),
              child: Text(habit.emoji, style: const TextStyle(fontSize: 20)),
            ),
            title: Text(habit.title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('连续 $streak 天 · $freq',
                style: TextStyle(color: ext.meta, fontSize: 12)),
            trailing: Icon(Symbols.chevron_right, color: ext.meta, size: 20),
          ),
        ),
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
  /// U5：转发给 [TaskRow.constrainTitleWidth]（仅拖拽重排场景为 true）。
  final bool constrainTitleWidth;
  const _DismissibleTask({
    required this.task,
    this.selecting = false,
    this.selected = false,
    this.onToggle,
    this.onLongPress,
    this.onEdit,
    this.onSelect,
    this.constrainTitleWidth = false,
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
      constrainTitleWidth: constrainTitleWidth,
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
        // 向右滑 = 删除。
        // F-09 修复：右滑是**最顺手**的方向（拇指自然起手），此前却无确认直接删除，
        // 与「批量删除有二次确认、清空回收站有二次确认」的其它破坏性操作口径不一致，
        // 只靠 5 秒 SnackBar 兜底（容易错过）。这里补一层轻量确认，
        // 保留滑删的顺手、去掉误触的杀伤力。
        final name = task.title.trim();
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('删除任务？'),
            content: Text(name.isEmpty
                ? '该任务将移入回收站（可在 5 秒内撤销）。'
                : '「$name」将移入回收站（可在 5 秒内撤销）。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: error),
                onPressed: () => Navigator.pop(d, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        return confirmed ?? false;
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
