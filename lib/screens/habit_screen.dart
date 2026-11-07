import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/achievement.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
// U3-5：撤销窗口时长的单一真源（与任务侧删除横幅共用）。
import 'package:todolist/theme/ui_durations.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/command_palette_button.dart';
import 'package:todolist/widgets/habit_heatmap.dart';
import 'package:todolist/widgets/habit_share_card.dart';
// P3-2（v2.9.6 审计）：删除习惯的撤销横幅迁入唯一实现（showUndoSnackBar / undoContent）。
import 'package:todolist/widgets/undo_snack_bar.dart';
import 'package:todolist/widgets/streak_celebration.dart';

/// 习惯打卡 / 成就页：今日打卡列表 + 新增习惯 + 成就墙。
/// 主题色、开关、强调色等统一跟随全局 ThemeProvider（导航选中/FAB/勾选均绑定
/// colorScheme.primary / ext.accent），无需在此单独处理。
class HabitScreen extends StatelessWidget {
  const HabitScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final habit = context.watch<HabitProvider>();
    final task = context.watch<TaskProvider>();
    final focus = context.watch<FocusProvider>();
    final primary = Theme.of(context).colorScheme.primary;

    final ctx = AchievementContext.fromProviders(task, focus, habit);

    // P2-5（v2.9.6 审计）：分母与分子统一走 [HabitProvider.habitsDueOn]
    // （`shouldCheckInOn` 过滤）——此前 `total = activeHabits.length` 把休息日
    // 也计入，「每周一三五 + 每天」在周二显示「今日 1/2」，与今日卡 / 晚简报
    // 的同族口径打架，持续暗示用户「漏了一个习惯」。
    final dueToday = habit.habitsDueOn(DateTime.now());
    final total = dueToday.length;
    // T1-2：达成口径——量化习惯要求当日累计量 ≥ 每日目标，仅有记录不算完成。
    final todayDone = dueToday.where((h) => habit.isTargetMetToday(h)).length;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            const TopAppBar(
              title: '习惯',
              // U4：命令面板移动端入口。
              actions: [CommandPaletteButton(currentIndex: 4)],
            ),
            Expanded(
              // P3-8（v3.1.2 审计）：页面滚动改为 CustomScrollView——习惯列表
              // 用 SliverReorderableList 融入页面滚动，拖到屏幕边缘时可自动
              // 滚动（旧实现 shrinkWrap + NeverScrollableScrollPhysics 内嵌
              // 在 SingleChildScrollView 里，列表自身不滚，习惯多于一屏时
              // 无法一次把底部条目拖到顶部，只能「滚一屏、拖一段」）。
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                        AppColors.pagePadX, 8, AppColors.pagePadX, 0),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        _OverviewCard(
                          todayDone: todayDone,
                          total: total,
                          currentStreak: habit.overallCurrentStreak,
                          totalCheckIns: habit.totalCheckIns,
                        ),
                        if (habit.habitCount > 0) ...[
                          const SizedBox(height: 24),
                          const _HeatmapCard(),
                          const SizedBox(height: 24),
                          const _StreakSection(),
                        ],
                        const SizedBox(height: 24),
                        _SectionTitle('今日习惯'),
                        const SizedBox(height: AppColors.contentGap),
                        if (habit.activeHabits.isEmpty) const _EmptyHint(),
                      ]),
                    ),
                  ),
                  if (habit.activeHabits.length == 1)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppColors.pagePadX),
                      sliver: SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _HabitTile(habit: habit.activeHabits.first),
                        ),
                      ),
                    )
                  else if (habit.activeHabits.length > 1)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppColors.pagePadX),
                      sliver: SliverReorderableList(
                        // P3-8：迁移 onReorderItem（onReorder 自 v3.41.0 起废弃，
                        // analyzer 已给 info，未来升级会编译失败）。语义差异：
                        // onReorderItem 的 newIndex 已是「移除项后的最终落点」，
                        // 而 [HabitProvider.reorderHabits] 按旧 onReorder 约定
                        // 实现（newIndex 需 -1 校正，测试已钉死）——此处换算回
                        // 旧口径，provider 单一真源语义不变。
                        onReorderItem: (oldIndex, newIndex) async {
                          final legacy =
                              newIndex > oldIndex ? newIndex + 1 : newIndex;
                          final ok =
                              await habit.reorderHabits(oldIndex, legacy);
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('排序未保存，请重试')),
                            );
                          }
                        },
                        itemBuilder: (ctx, i) {
                          final h = habit.activeHabits[i];
                          return Padding(
                            key: ValueKey(h.id),
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _HabitDragRow(index: i, habit: h),
                          );
                        },
                        itemCount: habit.activeHabits.length,
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                        AppColors.pagePadX, 0, AppColors.pagePadX, 20),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        if (habit.activeHabits.length > 1) ...[
                          const SizedBox(height: 8),
                          // P3-8：拖拽入口已收窄为行首手柄，提示随之改如实。
                          Text('拖动行首手柄可调整顺序',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        ],
                        // 新P2-2（v2.9.7 审计）：归档习惯的取消归档入口——见
                        // [_ArchivedSection] 文档。
                        if (habit.archivedHabits.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          _ArchivedSection(habits: habit.archivedHabits),
                        ],
                        const SizedBox(height: 24),
                        _SectionTitle('成就'),
                        const SizedBox(height: AppColors.contentGap),
                        _AchievementGrid(ctx: ctx),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _AddHabitSheet.show(context),
        backgroundColor: primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

String _wdLabel(int wd) => ['一', '二', '三', '四', '五', '六', '日'][wd - 1];

/// U3-1（v2.9.6 审计）：休息日状态的**统一文案**——此前同一状态在习惯列表
/// chip（「今天不打卡」）、计数 pill（「休息」）、今日页 meta（「今日休息」）、
/// 今日页按钮（「今天不打卡」）四处四种写法。今日页经 `show` 子句引用本常量。
const String kHabitRestDayLabel = '今天不打卡';

/// L5（v3.0.8 审计）：习惯图标选项集——新建与编辑弹层共用。此前两份私有副本、
/// 且编辑层没有入口：选错图标只能删除重建并丢失全部打卡历史。
const List<String> kHabitEmojis = [
  '💪', '📚', '🏃', '💧', '🧘', '😴',
  '🥗', '✍️', '🎯', '💡', '🌟', '🚭',
];

/// L5（v3.0.8 审计）：习惯颜色选项集（同上，新建与编辑共用）。
const List<Color> kHabitPalette = [
  Color(0xFF0061A4),
  Color(0xFF6750A4),
  Color(0xFF00696E),
  Color(0xFFB3261E),
  Color(0xFF386A20),
  Color(0xFF965400),
  Color(0xFF8B4A82),
];

/// A3（v3.1.1 功能增强）：量化单位预设（新建 / 编辑弹层共用，单一真源）。
const List<String> kHabitUnitPresets = ['杯', '页', '次', '分钟', '公里', '个'];

/// A3（v3.1.1 功能增强）：量化单位编辑器（新建 / 编辑弹层共用单一真源）：
/// 自由输入（≤[Habit.maxUnitLength] 字符）+ 预设 chips 快捷填充；为空 = 无单位
/// （保持旧文案「6/8」）。输入实时回写 [controller]，保存时由调用方统一提交。
class _HabitUnitEditor extends StatelessWidget {
  final TextEditingController controller;
  final AppColorsExt ext;
  /// P3-8（v3.1.4 审计）：单位变化时通知父级重建目标预览 / 说明文案。
  /// 旧实现只让预设 chip 的 AnimatedBuilder 监听 controller，父级不重建，
  /// 输入「公里」或点「杯」后上方仍显示「8 / 天」，直到改目标 / 切频率
  /// 触发别的 setState 才刷新。
  final ValueChanged<String>? onChanged;
  const _HabitUnitEditor(
      {required this.controller, required this.ext, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('单位', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Expanded(
              child: Text('显示在进度旁，如「6/8 杯」；留空不显示',
                  style: TextStyle(fontSize: 12, color: ext.meta)),
            ),
            SizedBox(
              width: 96,
              child: TextField(
                controller: controller,
                maxLength: Habit.maxUnitLength,
                onChanged: onChanged, // P3-8（v3.1.4 审计）：预览随输入刷新
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  counterText: '',
                  hintText: '如「杯」',
                  filled: true,
                  fillColor: ext.chip,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppColors.cardRadius),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          // AnimatedBuilder 监听 controller：自由输入 / 点 chip 后选中态即时同步。
          children: kHabitUnitPresets
              .map((u) => AnimatedBuilder(
                    animation: controller,
                    builder: (_, __) => ChoiceChip(
                      label: Text(u),
                      selected: controller.text == u,
                      onSelected: (sel) {
                        // 点已选中的 chip = 清空；点未选中的 = 填入。
                        controller.text = sel ? u : '';
                        // P3-8：直接改 controller.text 不会触发 TextField 的
                        // onChanged，必须显式通知父级，否则预设 chip 同样是旧预览。
                        onChanged?.call(controller.text);
                      },
                    ),
                  ))
              .toList(),
        ),
      ],
    );
  }
}

/// U2-2（v2.9.6 审计）：休息日点击写入口的统一反馈——此前习惯列表行的
/// 圆圈 / ✎ / +1 在休息日 `onTap: null`，但 `HitTestBehavior.opaque` 仍吞掉
/// 点击，完全无反应（说明只挂 Tooltip 需长按才弹），用户会误判「点坏了」。
/// 今日页与通知 action 对同场景都会回报，唯独列表行静默。现在三入口都可点、
/// 统一走本提示（与 [toggleHabitWithUndo] 的守卫分支同一文案）。
void showHabitRestDayHint(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('今天不打卡 · 如需补记请在习惯详情里用「补卡」'),
      duration: Duration(seconds: 3),
    ),
  );
}

/// P2-3（v3.0.1 审计）：归档习惯点击写入口的统一反馈——归档语义 = 退场，
/// provider 层（[HabitProvider.setCheckInValue] 的 archived 守卫）会拦截全部
/// 写入；归档行的动作区已替换为「已归档」占位（见 _HabitTile），此提示供
/// 未来入口兜底，避免「点按无反应」。
void showHabitArchivedHint(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('已归档 · 恢复归档后可继续打卡'),
      duration: Duration(seconds: 3),
    ),
  );
}

String _fmtMinute(int minute) {
  final h = minute ~/ 60;
  final m = minute % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// 打卡并在打破历史最长连续时播放庆祝动效。
///
/// 先记录「打卡前最长连续」与「是否已达标」，变更后若本次是**新增达标**且当前连续
/// 已超过此前最长，即触发全屏庆祝。供习惯列表圆圈与详情弹层共用。
///
/// P3-2（v3.0.5 审计）：App 内写入口的落盘失败如实反馈——provider 已回滚内存
/// （UI 显示的即已落盘的），此处仅提示用户写入未保存、可重试（旧实现全部
/// 忽略 provider 返回的 bool，落盘失败时 App 内照样乐观显示成功）。
///
/// P3-1（v3.0.8 审计）：按安全模式分化（与任务侧 showTaskPersistFailedHint
/// 同口径）——HabitProvider.load() 失败会置位 dbLoadFailed，此后 _persist
/// 恒 false（设计行为：保护坏库不被内存态覆盖），顶部横幅已告知「本次修改
/// 不会保存」：此时复读「请重试」既与横幅重复又误导（重试必然再失败）。
/// [provider] 缺省（测试 / 无 provider 上下文）时按非安全模式处理。
void showCheckInPersistFailedHint(BuildContext context, {HabitProvider? provider}) {
  final safeMode = provider?.dbLoadFailed ?? false;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(safeMode
          ? '安全模式下更改不会保存：已阻止写入以保护数据，请先修复或恢复后再试'
          : '写入失败：数据未保存，请重试'),
    ),
  );
}

/// T1-2：判定基准由「是否已打卡」改为「是否已达成当日目标」——量化习惯在喝到第 8
/// 杯那一刻（而不是第 1 杯）才该庆祝；布尔习惯两者等价，行为不变。
Future<void> checkInWithCelebration(
  BuildContext context,
  HabitProvider hp,
  Habit habit,
) async {
  final wasMet = hp.isTargetMetToday(habit);
  final longestBefore = hp.longestStreak(habit);
  final ok = await hp.toggleCheckInToday(habit);
  if (!context.mounted) return;
  if (!ok) {
    showCheckInPersistFailedHint(context, provider: hp);
    return;
  }
  await _maybeCelebrate(context, hp, habit, wasMet, longestBefore);
}

/// T1-2：量化习惯的「+1」打卡（累加 1 个单位），达标那一刻触发庆祝。
Future<void> incrementWithCelebration(
  BuildContext context,
  HabitProvider hp,
  Habit habit,
) async {
  final wasMet = hp.isTargetMetToday(habit);
  final longestBefore = hp.longestStreak(habit);
  final ok = await hp.adjustCheckInValue(habit, DateTime.now(), 1);
  if (!context.mounted) return;
  if (!ok) {
    showCheckInPersistFailedHint(context, provider: hp);
    return;
  }
  await _maybeCelebrate(context, hp, habit, wasMet, longestBefore);
}

/// P3-9（v2.9.4 审计）：「今日达标」入口的庆祝包装。
///
/// 此前「设置数量」「今日达标」两条路径直接调 provider，绕过了 [_maybeCelebrate]，
/// 于是同一屏里「+1」会庆祝、点「今日达标」却毫无反馈——用户以为按钮没生效。
///
/// P3-7（v2.9.5 审计）：**本函数上方原注释**在此声称「所有『新增达标』的写
/// 入口统一走这一层包装（打卡 / +1 / 今日达标 / **通知打卡**）」——但通知打卡
/// 走的是 [main.dart] 的 `_doHabitCheckIn`，只能拿到 `NavigatorState.context`，
/// 从未调用本函数，注释比代码乐观。处置：
/// - 通知侧无法弹全屏庆祝（App 可能在后台，弹窗不可见且会打断），改为**如实回报**
///   进度（`showHabitCheckedConfirm` 的「已记 x/y · 未达标」/「已打卡 ✓」），
///   这是通知场景下唯一有效的反馈形态；
/// - 因此注释改为只声明它真实覆盖的范围，避免下一轮审计再当成「声称已修」。
///   界面上四条写入口（打卡 / +1 / 今日达标 / 设置数量）现已全部收口。
Future<void> completeTodayTargetWithCelebration(
  BuildContext context,
  HabitProvider hp,
  Habit habit,
) async {
  final wasMet = hp.isTargetMetToday(habit);
  final longestBefore = hp.longestStreak(habit);
  final ok = await hp.completeTodayTarget(habit);
  if (!context.mounted) return;
  if (!ok) {
    showCheckInPersistFailedHint(context, provider: hp);
    return;
  }
  await _maybeCelebrate(context, hp, habit, wasMet, longestBefore);
}

/// P3-9（v2.9.4 审计）：设置今日数量的庆祝包装（同上，补齐「设置数量」路径）。
Future<void> setTodayQuantityWithCelebration(
  BuildContext context,
  HabitProvider hp,
  Habit habit,
) async {
  final wasMet = hp.isTargetMetToday(habit);
  final longestBefore = hp.longestStreak(habit);
  await promptHabitTodayQuantity(context, hp, habit);
  await _maybeCelebrate(context, hp, habit, wasMet, longestBefore);
}

/// 把「今天」规整为 date-only（撤销时固化操作日用，见 [showCheckInUndoSnackBar]）。
DateTime _dateOnlyNow() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// P3-1 / P3-2 / U1-1 / U2-4 / U3-4（v2.9.4 审计）：打卡类「撤销」的**唯一**实现。
///
/// 四个历史缺陷在此一次性收口：
/// 1. **P3-1 日期取点击时刻**：撤销闭包里写 `DateTime.now()`，23:59 取消打卡、
///    00:00 后点撤销 → 记录落到「今天」，昨天连续天数仍断着。改为调用方在
///    **操作发生时**就传入 [day]（date-only），撤销只按这一天回写。
/// 2. **P3-2 无条件覆盖**：10 秒内「先 +1 再撤销」会把用户新加的量抹掉。
///    现在撤销前校验「当前值仍等于操作后的状态（0 = 已清空/已取消）」，
///    不等则提示「撤销已失效」，不覆盖用户后续操作。
/// 3. **U1-1 弹层内点不到**：SnackBar 渲染在 ModalBarrier 之下，点击落在遮罩上
///    （关掉弹层而非撤销）。[closeSheet] 为 true 时先 pop 弹层再提示。
/// 4. **U2-4 横幅被顶掉**：不再 `hideCurrentSnackBar()`——`ScaffoldMessenger`
///    自带队列（后一条排在前一条播完之后），主动 hide 等于亲手丢掉上一条撤销机会。
///    另附 **U3-4**：窗口超时自动收起时给一句「撤销窗口已结束」，避免用户
///    在 10 秒后点空气。
///
/// 新P3-2（v2.9.7 审计）：本函数已**整体委托**给 [showUndoSnackBar]（任务侧
/// 唯一实现）——此前自管超时提示，缺「活跃计数 skip 判据」，与 v2.9.6 审计
/// P2-1 的复现①/②完全同型（A 的超时提示排在 B 之后错位；B 撤销成功后仍弹
/// 「窗口已结束」误导）。现在队列计数、120ms 判定、失效反馈、超时追加提示
/// 全部继承单一实现；本函数只保留两个习惯侧语义：
/// - [closeSheet]：先 pop 弹层再展示横幅（U1-1，SnackBar 在 ModalBarrier 之下）；
/// - **覆盖校验**：撤销前校验「当前值仍等于操作后的状态（0）」，不等则失效
///   （提示文案带细节，经 [showUndoSnackBar] 的 `failureHint` 传入）。
Future<void> showCheckInUndoSnackBar(
  BuildContext context, {
  required HabitProvider hp,
  required Habit habit,
  required DateTime day,
  required int previous,
  required String content,
  bool closeSheet = false,
}) async {
  // U1-1：先取 navigator（pop 之后本页 context 随即失效）。
  final navigator = Navigator.of(context, rootNavigator: true);
  if (closeSheet) navigator.pop();
  if (previous <= 0) return;

  showUndoSnackBar(
    context,
    content: content,
    // U3-4：超时追加提示绑定到具体日期（content 无固定后缀，自动剥取会退回
    // 通用文案，故显式传入）。
    expiredHint: '${day.month}月${day.day}日 的撤销窗口已结束',
    failureHint: '撤销已失效：这条记录之后已被再次修改',
    onUndo: () async {
      // P3-2：只有「当前仍是操作后的状态（0）」才回写，不覆盖用户后续操作。
      // L2（v3.0.8 审计）：习惯可能已在 10 秒窗口内被删除——旧闭包不校验，
      // 撤销会写孤儿打卡记录并复活已删习惯的每日提醒（restoreHabit/落盘路径
      // 都按 snapshot 放回）。先按 id 判在，不在即真失效。
      if (hp.byId(habit.id) == null) return false;
      // P3-2（v3.0.5 审计）：回写结果透传——落盘失败按「撤销已失效」如实反馈。
      final cur = hp.checkInValueOn(habit, day);
      if (cur != 0) return false;
      return hp.setCheckInValue(habit, day, previous);
    },
  );
}

/// U2-2（v2.9.3 审计）：列表侧的「打卡 / 取消打卡」入口。
///
/// 未打卡 → 正常打卡（带庆祝）；已打卡再点 = 取消，此前零确认零撤销——
/// 误触即断掉连续天数，与详情页的二次确认口径不对等。现在取消后提供
/// 10 秒撤销 SnackBar（复用删除习惯的撤销机制），把当天记录原值放回。
///
/// 供习惯列表圆圈与今日页「已打卡」按钮共用；详情页主按钮保留其二次确认。
Future<void> toggleHabitWithUndo(
  BuildContext context,
  HabitProvider hp,
  Habit habit,
) async {
  // P3-3 / U2-6（v2.9.4 审计）：休息日统一禁用（今日页 / 列表行 / 详情三处同口径）。
  // 保留这道守卫是因为本函数是**公开**入口，未来新调用点不必再各自记得判断。
  // U2-2（v2.9.6 审计）：提示改走共享 [showHabitRestDayHint]（与列表行
  // ✎ / +1 的休息日反馈同源）。
  if (!habit.shouldCheckInOn(_dateOnlyNow())) {
    showHabitRestDayHint(context);
    return;
  }
  if (!hp.isCheckedToday(habit)) {
    await checkInWithCelebration(context, hp, habit);
    return;
  }
  // P3-1：操作发生时就固化 date-only，撤销不再取「点击撤销那一刻」。
  final day = _dateOnlyNow();
  final previous = hp.todayValue(habit);
  // P3-2（v3.0.5 审计）：按落盘结果反馈，失败不给撤销横幅（取消未生效）。
  final ok = await hp.toggleCheckInToday(habit);
  if (!context.mounted) return;
  if (!ok) {
    showCheckInPersistFailedHint(context, provider: hp);
    return;
  }

  // P3-1 / P3-2 / U2-4 / U3-4：统一走共享撤销实现（日期固化 + 覆盖校验 +
  // 不再 hideCurrentSnackBar 以保留队列 + 超时反馈）。
  await showCheckInUndoSnackBar(
    context,
    hp: hp,
    habit: habit,
    day: day,
    previous: previous,
    content: habit.isQuantified
        ? '已清空今日记录（$previous）'
        : '已取消今日打卡',
  );
}

/// 共用庆祝判定：本次由「未达标」变为「已达标」，且当前连续超过历史最长。
///
/// P3-5（v2.9.6 审计）：加**同日去重**——判据 `currentStreak > longestBefore`
/// 依赖 longestStreak 不降，而「达标 → 清空今日（不撤销）→ +1 补到达标」会让
/// longestStreak 先降后升，二次全屏庆祝。这里用「习惯 id @ 日期」键去重，
/// 同一习惯当天只庆祝一次；跨天自然失效（键含日期）。
Future<void> _maybeCelebrate(
  BuildContext context,
  HabitProvider hp,
  Habit habit,
  bool wasMet,
  int longestBefore,
) async {
  if (!context.mounted || wasMet) return;
  if (!hp.isTargetMetToday(habit)) return;
  final now = hp.currentStreak(habit);
  if (now <= longestBefore) return;
  final n = DateTime.now();
  final key = '${habit.id}@${n.year}-${n.month}-${n.day}';
  if (!_celebratedKeys.add(key)) return; // 今天已庆祝过
  if (_celebratedKeys.length > 4096) _celebratedKeys.clear(); // 防御性上界
  showStreakCelebration(context, now);
}

/// P3-5（v2.9.6 审计）：已触发过庆祝的「习惯 id @ date-only」键。
final Set<String> _celebratedKeys = <String>{};

/// T1-2：通用整数输入对话框（每日目标量 / 补卡数量共用）。
///
/// 返回 null = 取消；否则返回夹到 [min, max] 的整数。
Future<int?> promptHabitInt(
  BuildContext context, {
  required String title,
  required int current,
  int min = 0,
  int max = 9999,
  String? hint,
}) async {
  final ctl = TextEditingController(text: '$current');
  final result = await showDialog<int>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(hintText: hint ?? '请输入 $min–$max 之间的整数'),
        onSubmitted: (v) => Navigator.pop(d, int.tryParse(v.trim()) ?? -1),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(d, int.tryParse(ctl.text.trim()) ?? -1),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  ctl.dispose();
  if (result == null) return null;
  if (result < min || result > max) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请输入 $min–$max 之间的整数')),
      );
    }
    return null;
  }
  return result;
}

/// T1-2：设置「今日数量」对话框（量化习惯的长按 / 详情页「数量」入口）。
/// 填 0 = 清空今日记录（等价于撤卡）。
Future<void> promptHabitTodayQuantity(
  BuildContext context,
  HabitProvider hp,
  Habit habit,
) async {
  final cur = hp.todayValue(habit);
  final v = await promptHabitInt(
    context,
    title: '设置今日数量',
    current: cur,
    min: 0,
    max: 9999,
    hint: '目标 ${habit.effectiveTarget}'
        '${habit.unit.trim().isEmpty ? '' : ' ${habit.unit.trim()}'}'
        '；填 0 = 清空今日记录',
  );
  if (v == null) return;
  // P3-2（v3.0.5 审计）：「设置数量」对话框消费落盘结果，失败如实提示
  //（provider 已回滚内存，不再乐观显示成功）。
  final ok = await hp.setCheckInValue(habit, DateTime.now(), v);
  if (!ok && context.mounted) showCheckInPersistFailedHint(context, provider: hp);
}

/// 打开单习惯详情弹层（含该习惯自己的热力图、连续天数与分享入口）。
void showHabitDetailSheet(BuildContext context, Habit habit) =>
    _HabitDetailSheet.show(context, habit);

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Text(text,
        style:
            TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ext.meta));
  }
}

class _OverviewCard extends StatelessWidget {
  final int todayDone;
  final int total;
  final int currentStreak;
  final int totalCheckIns;
  const _OverviewCard({
    required this.todayDone,
    required this.total,
    required this.currentStreak,
    required this.totalCheckIns,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final items = [
      ('今日', '$todayDone/$total'),
      ('连续', '$currentStreak 天'),
      // P2-3（v2.9.4 审计）：数字改为达标口径（[HabitProvider.totalCheckIns]），
      // 标签必须同步——否则「累计 7 次」与详情页「累计 3 天」在同一 App 里对同一个
      // 习惯给出两个数。这里明确写成「累计达标(天)」，与导出的同名列一致。
      ('累计达标', '$totalCheckIns 天'),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Row(
        children: items
            .map((e) => Expanded(
                  child: Column(
                    children: [
                      Text(e.$2,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(e.$1,
                          style: TextStyle(fontSize: 12, color: ext.meta)),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _HeatmapCard extends StatelessWidget {
  const _HeatmapCard();

  @override
  Widget build(BuildContext context) {
    final habit = context.watch<HabitProvider>();
    final ext = appColors(context);
    const weeks = 18;
    // P3-2（v2.9.3 审计）：聚合热力图改按「达标习惯数」着色，与详情页的
    // 「按达成度」口径对齐——量化习惯某日只完成 1/8 不再与「8/8 达标」同色。
    // 布尔习惯「达标 = 有记录」，与旧口径逐位一致。
    final counts = habit.metCountsByDay(weeks * 7);
    final checkedDays = counts.keys.toSet();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('打卡热力图',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('最近 $weeks 周达标密度（颜色深浅 = 当日达标习惯数）',
              style: TextStyle(fontSize: 12, color: ext.meta)),
          const SizedBox(height: 14),
          HabitHeatmap(
            checkedDays: checkedDays,
            levelOf: (d) => counts[d] ?? 0,
            weeks: weeks,
          ),
        ],
      ),
    );
  }
}

class _StreakSection extends StatelessWidget {
  const _StreakSection();

  @override
  Widget build(BuildContext context) {
    final habit = context.watch<HabitProvider>();
    final ext = appColors(context);
    final primary = Theme.of(context).colorScheme.primary;
    final list = habit.activeHabits.toList()
      ..sort((a, b) => habit.currentStreak(b).compareTo(habit.currentStreak(a)));
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('连续天数'),
        const SizedBox(height: AppColors.contentGap),
        ...list.map((h) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.cardRadius),
                ),
                child: Row(
                  children: [
                    Text(h.emoji, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(h.title,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    StreakBadge(
                      current: habit.currentStreak(h),
                      longest: habit.longestStreak(h),
                      accent: primary,
                      showLongest: true,
                    ),
                  ],
                ),
              ),
            )),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Column(
        children: [
          Icon(Symbols.emoji_events, size: 40, color: ext.meta),
          const SizedBox(height: 12),
          Text('还没有习惯，点右下角 + 添加',
              style: TextStyle(color: ext.meta)),
        ],
      ),
    );
  }
}

/// P3-8（v3.1.2 审计）：习惯行 + 行首专用拖拽手柄——拖拽入口收窄到手柄
/// （与首页任务行的手柄同款交互），行内的「+1」长按（设数量）与提醒 chip
/// 长按（取消提醒）等业务长按不再被拖拽手势抢占（旧实现整行长按进入拖拽，
/// 用户摸不到哪块能拖、哪块是业务动作）。
class _HabitDragRow extends StatelessWidget {
  final int index;
  final Habit habit;
  const _HabitDragRow({required this.index, required this.habit});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ReorderableDragStartListener(
          index: index,
          child: Container(
            width: 24,
            height: 56,
            alignment: Alignment.center,
            child: Icon(Symbols.drag_indicator, size: 20, color: ext.meta),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(child: _HabitTile(habit: habit)),
      ],
    );
  }
}

class _HabitTile extends StatelessWidget {
  final Habit habit;
  const _HabitTile({required this.habit});

  @override
  Widget build(BuildContext context) {
    final hp = context.watch<HabitProvider>();
    final ext = appColors(context);
    final primary = Theme.of(context).colorScheme.primary;
    final quantified = habit.isQuantified;
    final value = hp.todayValue(habit);
    // A3（v3.1.1 功能增强）：x/y 与单位统一走 [Habit.progressLabelOf]，
    // 分母（effectiveTarget）在真源内部取，本方法不再单独持有 target。
    // T1-2：量化习惯用「达成」判定，布尔习惯等价于原「已打卡」。
    final checked = quantified ? hp.isTargetMetToday(habit) : hp.isCheckedToday(habit);
    final streak = hp.currentStreak(habit);
    final freq = habit.weekdays.isEmpty
        ? '每天'
        : '每周 ${habit.weekdays.map(_wdLabel).join(' ')}';
    final goalN = hp.weeklyCheckIns(habit);
    // P3-7（v2.9.6 审计）：读「生效值」（按当前计划天数夹取）——裸字段自本轮起
    // 保留 fromJson 原值（保真），展示层一律经 [Habit.effectiveWeeklyGoal]。
    final goalM = habit.effectiveWeeklyGoal;
    final goalMet = goalN >= goalM;
    // P3-3 / U2-6（v2.9.4 审计）：今天是否计划内打卡。休息日与今日卡（today_card）
    // 的「今天不打卡」必须同口径——此前列表行照旧显示「今日 x/y」且「+1」可点，
    // 写出的计划外记录还会污染连续天数与热力图。
    final restDay = !habit.shouldCheckInOn(DateTime.now());

    // 左侧整块（头像 + 标题 + 连续/频率）点击进入单习惯详情；
    // 提醒 chip 是独立兄弟节点，点它只改提醒、不会误开详情。
    final left = Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showHabitDetailSheet(context, habit),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Color(habit.colorValue),
                child: Text(habit.emoji, style: const TextStyle(fontSize: 20)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(habit.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StreakBadge(current: streak, accent: primary),
                        Text(freq,
                            style: TextStyle(color: ext.meta, fontSize: 12)),
                        // T1-2：量化进度芯片（今日 / 本周累计 → 目标）。
                        // P3-3（v2.9.4 审计）：休息日改显「今天不打卡」，不再显示
                        // 「今日 x/y」并让「+1」可点。
                        if (quantified)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: checked
                                  ? primary.withValues(alpha: 0.14)
                                  : ext.chip,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              // U3-1（v2.9.6 审计）：休息日文案走共享常量。
                              // A3（v3.1.1 功能增强）：x/y 与单位统一走
                              // [Habit.progressLabelOf] 单一真源（含单位后缀）。
                              restDay
                                  ? kHabitRestDayLabel
                                  : '今日 ${habit.progressLabelOf(value)}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: checked ? primary : ext.meta,
                              ),
                            ),
                          )
                        // 新U2-3（v2.9.7 审计）：布尔习惯的休息日此前**行内零可见
                        // 文案**——chip 只在量化分支渲染，布尔分支仅长按 Tooltip
                        // 说明（触屏不可主动发现），周二看「每周一」的布尔行只剩
                        // 一枚淡圈。补一枚与量化行同款的常驻小字。
                        else if (restDay)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ext.chip,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              kHabitRestDayLabel,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: ext.meta,
                              ),
                            ),
                          ),
                        // P3-7（v2.9.6 审计）：生效值（计划天数夹取）。
                        if (habit.effectiveWeeklyGoal > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: goalMet
                                  ? primary.withValues(alpha: 0.14)
                                  : ext.chip,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            // U3-3/U3-7（v2.9.4/v2.9.5 审计）：「本周 2/5」是裸
                            // 术语，此前解释只挂在 Tooltip 上——触屏不可主动发现
                            // （与 U2-2 同一教训）。改为文案自带「达标」语义；
                            // 「达标即本周达成」的完整解释下沉到详情弹层常驻文案。
                            child: Text('本周达标 $goalN/$goalM 次',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: goalMet ? primary : ext.meta,
                                )),
                          ),
                        // T1-4：宽限日提示（仅开启时显示，避免噪音）。
                        // U3-7（v2.9.5 审计）：解释此前只挂 Tooltip（触屏不可主动
                        // 发现）→ 文案自带「漏卡不断签」语义，Tooltip 移除。
                        if (habit.graceDays > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ext.chip,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                                '宽限 ${habit.graceDays} 天/周（漏卡不断签）',
                                style:
                                    TextStyle(fontSize: 11, color: ext.meta)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final chip = habit.reminderMinute != null
        ? Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _ReminderChip(habit: habit),
          )
        : const SizedBox.shrink();

    // 右侧动作区：
    // - 布尔习惯：勾选圆圈（点击打卡 + 打破纪录庆祝）；取消打卡走 U2-2 的撤销保护。
    // - 量化习惯（T1-2）：计数 pill（点开详情）+「✎ 设数量」显式入口 +「+1」按钮
    //   （点击累加 1，达标那一刻触发庆祝）。
    // U2-2（v2.9.3 审计）：「长按设数量」此前完全不可发现——Tooltip 罩在
    // GestureDetector 外层，触屏上内层 onLongPress 赢下手势仲裁，Tooltip 永不弹，
    // 手机用户只能靠猜。现补**常驻可见的 ✎ 按钮**（不依赖悬停/长按），
    // 长按设数量作为等价入口保留。
    // P3-3 / U2-6（v2.9.4 审计）：休息日禁用「✎ / +1」并改提示文案，与今日卡
    // 「今天不打卡」一致（补卡入口仍在详情弹层里，计划外补记不受影响）。
    // P2-3（v3.0.1 审计）：归档行动作区整体替换为「已归档」占位——归档语义
    // = 退场，此前的「✎ / +1 / 打卡圆圈」在归档折叠区里全部可用（provider
    // 守卫落地前可真实写入，落地后则是静默无反应），与详情页「已归档」提示
    // 自相矛盾。左侧整块仍可点开详情（恢复归档的入口在那里）；占位 chip
    // 本身可点，给出与休息日 U2-2 同款的统一反馈。
    final action = habit.archived
        ? Padding(
            padding: const EdgeInsets.only(right: 16),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showHabitArchivedHint(context),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Symbols.archive, size: 14, color: ext.meta),
                const SizedBox(width: 4),
                Text('已归档', style: TextStyle(fontSize: 12, color: ext.meta)),
              ]),
            ),
          )
        : quantified
        ? Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: '点按看详情',
                  waitDuration: const Duration(milliseconds: 400),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => showHabitDetailSheet(context, habit),
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 46),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: checked ? primary : ext.chip,
                        borderRadius: BorderRadius.circular(10),
                      ),
                            child: Text(
                              // P3-6（v2.9.5 审计）：同一行左侧 chip 已按休息日改口
                              // 「今天不打卡」（v2.9.4 的 P3-3），右侧这个点开详情的
                              // 计数 pill 却仍原样渲染 `0/8`——「左说不打卡、右报 0/8」，
                              // 用户无从判断该不该点。两处同属一个语义，统一读 [restDay]。
                              // U3-1（v2.9.6 审计）：文案统一为共享常量（原「休息」）。
                              // A3（v3.1.1 功能增强）：x/y 与单位统一走
                              // [Habit.progressLabelOf] 单一真源。
                              restDay
                                  ? kHabitRestDayLabel
                                  : habit.progressLabelOf(value),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: checked ? Colors.white : ext.meta,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // U2-2：可见的「设数量」入口（48×48 命中区），取代仅靠长按的隐藏手势。
                Tooltip(
                  message: restDay ? '今天不打卡' : '设置今日数量',
                  waitDuration: const Duration(milliseconds: 400),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // U2-2（v2.9.6 审计）：休息日不再 `onTap: null`——opaque 命中
                    // 区仍会吞掉点击却毫无反馈。改走与今日页相同的提示分支。
                    onTap: restDay
                        ? () => showHabitRestDayHint(context)
                        // P3-8（v2.9.5 审计）：此前直调 `promptHabitTodayQuantity`，
                        // 绕过了 `setTodayQuantityWithCelebration` 的庆祝包装——
                        // 同一行「+1」会庆祝、「✎ 设数量」不庆祝，用户以为没生效。
                        : () => setTodayQuantityWithCelebration(context, hp, habit),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: restDay ? ext.meta.withValues(alpha: 0.4) : ext.meta,
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: restDay ? '今天不打卡' : '点按 +1 · 长按设数量',
                  waitDuration: const Duration(milliseconds: 400),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // U2-2（v2.9.6 审计）：同上，休息日可点、给统一反馈。
                    onTap: restDay
                        ? () => showHabitRestDayHint(context)
                        : () => incrementWithCelebration(context, hp, habit),
                    onLongPress: restDay
                        ? () => showHabitRestDayHint(context)
                        // P3-8：同上，长按设数量与 ✎ 是同一动作，走同一包装。
                        : () => setTodayQuantityWithCelebration(context, hp, habit),
                    // U3-1（v2.9.3 审计）：视觉圆钮保持 32×32，外包 48×48 命中区，
                    // 达到 Material 48dp 最小可点目标，小圆钮不再易误触/难点中。
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: restDay
                                ? ext.chip
                                : checked
                                    ? primary.withValues(alpha: 0.16)
                                    : primary,
                          ),
                          child: Icon(Icons.add,
                              size: 18,
                              color: restDay
                                  ? ext.meta.withValues(alpha: 0.4)
                                  : checked
                                      ? primary
                                      : Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              // P3-3 / U2-6（v2.9.4 审计）：休息日禁用打卡并说明原因（与今日卡一致）。
              message: restDay ? '今天不打卡 · 如需补记请在详情里用「补卡」' : '点按打卡',
              waitDuration: const Duration(milliseconds: 400),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // U2-2（v2.9.3 审计）：已打卡状态再点 = 取消打卡，走「撤销 SnackBar」
                // 保护（与详情页二次确认、删除撤销体验对齐）；未打卡直接打卡不变。
                // U2-2（v2.9.6 审计）：休息日不再 `onTap: null`——改走统一提示
                // （toggleHabitWithUndo 的守卫分支会给出「今天不打卡 · 如需补记…」）。
                onTap: () => toggleHabitWithUndo(context, hp, habit),
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: checked ? primary : Colors.transparent,
                      border: Border.all(
                          color: checked
                              ? primary
                              : ext.meta.withValues(alpha: restDay ? 0.35 : 1),
                          width: 2),
                    ),
                    child: checked
                        ? const Icon(Icons.check, color: Colors.white, size: 18)
                        : null,
                  ),
                ),
              ),
            ),
          );

    return Container(
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Row(
        children: [left, chip, action],
      ),
    );
  }
}

/// 提醒时间 chip：点击改时间；长按取消提醒，先确认再撤（U18）。
///
/// 旧实现长按即静默取消提醒且无任何提示/确认——手势不可发现、误触即丢设置。
/// 现改为长按先弹确认；提示语义由 Tooltip 常驻承载（「点按修改时间 · 长按取消
/// 提醒」）。P3-11（v2.9.6 审计）：本注释此前声称「chip 下方给出『长按可取消』
/// 的弱提示文案」，代码中并不存在该文案，属不实注释，已改为与实现一致。
class _ReminderChip extends StatelessWidget {
  final Habit habit;
  const _ReminderChip({required this.habit});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Tooltip(
      message: '点按修改时间 · 长按取消提醒',
      waitDuration: const Duration(milliseconds: 400),
      child: GestureDetector(
        onTap: () async {
          final cur = habit.reminderMinute!;
          final picked = await showTimePicker(
            context: context,
            initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
          );
          if (picked != null) {
            // U2-1（v3.0.6 审计）：消费落盘结果——DB 异常时旧实现改时间仅存
            // 内存、系统闹钟已按新时刻重挂，三处口径分裂。失败回滚内存 +
            // 不动通知，此处如实提示。
            final hp = context.read<HabitProvider>();
            final ok =
                await hp.setReminder(habit, picked.hour * 60 + picked.minute);
            if (!ok && context.mounted) showCheckInPersistFailedHint(context, provider: hp);
          }
        },
        onLongPress: () async {
          // U18：取消提醒是不可逆操作，先弹确认，避免误长按清掉提醒。
          final hp = context.read<HabitProvider>();
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              title: const Text('取消提醒？'),
              content: Text(
                '「${habit.title}」到点将不再提醒。确定取消吗？',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(d, false),
                  child: const Text('保留提醒'),
                ),
                FilledButton(
                  // U3-6（v2.9.6 审计）：`Colors.red` → `colorScheme.error`。
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('取消提醒'),
                ),
              ],
            ),
          );
          if (confirmed == true) {
            // U2-1（v3.0.6 审计）：同 onTap——消费落盘结果，失败如实提示。
            final ok = await hp.setReminder(habit, null);
            if (!ok && context.mounted) showCheckInPersistFailedHint(context, provider: hp);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: ext.chip,
            borderRadius: BorderRadius.circular(AppColors.chipRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.alarm, size: 12, color: ext.meta),
              const SizedBox(width: 3),
              Text(_fmtMinute(habit.reminderMinute!),
                  style: TextStyle(fontSize: 11, color: ext.meta)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AchievementGrid extends StatelessWidget {
  final AchievementContext ctx;
  const _AchievementGrid({required this.ctx});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final primary = Theme.of(context).colorScheme.primary;
    final width =
        (MediaQuery.of(context).size.width - AppColors.pagePadX * 2 - 12) / 2;

    final groups = achievementsByGroup();
    final children = <Widget>[];
    groups.forEach((g, list) {
      children.add(_SectionTitle(g.label));
      children.add(const SizedBox(height: 12));
      children.add(
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: list
              .map((a) => _AchievementCell(
                    a: a,
                    ctx: ctx,
                    primary: primary,
                    ext: ext,
                    width: width,
                  ))
              .toList(),
        ),
      );
      children.add(const SizedBox(height: 24));
    });

    // 即将解锁：取最接近解锁的若干未解锁成就，以紧凑芯片呈现（避免与分组卡片重复）。
    final next = nextAchievements(ctx, limit: 3);
    if (next.isNotEmpty) {
      children.add(const _SectionTitle('即将解锁'));
      children.add(const SizedBox(height: 12));
      children.add(
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: next
              .map(
                (a) => Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: ext.chip,
                    borderRadius: BorderRadius.circular(AppColors.chipRadius),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(a.emoji, style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      Text(
                        a.progressLabel(ctx) ?? a.title,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: ext.meta,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _AchievementCell extends StatelessWidget {
  final Achievement a;
  final AchievementContext ctx;
  final Color primary;
  final AppColorsExt ext;
  final double width;
  const _AchievementCell({
    required this.a,
    required this.ctx,
    required this.primary,
    required this.ext,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    final unlocked = a.unlocked(ctx);
    final progress = a.progress(ctx);
    final showProgress = a.hasProgress;
    return Container(
      width: width,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: unlocked ? ext.chip : Colors.transparent,
        border: Border.all(color: ext.navBorder),
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(a.emoji,
                  style: TextStyle(
                      fontSize: 22, color: unlocked ? null : ext.meta)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(a.title,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: unlocked ? null : ext.meta)),
              ),
              if (unlocked) Icon(Icons.verified, size: 16, color: primary),
            ],
          ),
          const SizedBox(height: 6),
          Text(a.desc, style: TextStyle(fontSize: 12, color: ext.meta)),
          if (showProgress) ...[
            const SizedBox(height: 8),
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: ext.track,
                borderRadius: BorderRadius.circular(AppColors.progressRadius),
              ),
              child: FractionallySizedBox(
                widthFactor: progress.clamp(0, 1),
                alignment: Alignment.centerLeft,
                child: Container(
                  decoration: BoxDecoration(
                    color: primary,
                    borderRadius: BorderRadius.circular(AppColors.progressRadius),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              a.progressLabel(ctx) ?? '',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: ext.meta,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 新增习惯底部弹层：标题 + emoji + 颜色 + 打卡星期（空=每天）。
class _AddHabitSheet extends StatefulWidget {
  const _AddHabitSheet();

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _AddHabitSheet(),
    );
  }

  @override
  State<_AddHabitSheet> createState() => _AddHabitSheetState();
}

class _AddHabitSheetState extends State<_AddHabitSheet> {
  // L5（v3.0.8 审计）：改为引用文件级共享集（与编辑弹层同源）。
  static const List<Color> _palette = kHabitPalette;
  static const List<String> _emojis = kHabitEmojis;

  final _titleCtl = TextEditingController();
  /// A3（v3.1.1 功能增强）：量化单位输入（空 = 无单位）。
  final _unitCtl = TextEditingController();
  /// P3-4（v3.0.7 审计）：提交中守卫——「添加」异步化（await addHabit）后
  /// 出现了以前不存在的异步窗口，双击会并发两次 addHabit（各自分配不同 id）
  /// 生成两条重复习惯；且成功分支还会对已 pop 的 context 再调 Navigator.pop。
  /// 与同文件 `_HabitEditSheet` 的 `_saving`（2743/2751 两处 onPressed 置灰）
  /// 完全对齐。
  bool _saving = false;
  String _emoji = _emojis.first;
  int _colorValue = _palette.first.value;
  final Set<int> _weekdays = {};
  /// 每日提醒时间（分钟数，null = 不提醒）。
  int? _reminderMinute;
  /// 每周目标打卡次数（0 = 不启用，1..计划天数）。
  /// P3-10（v2.9.4 审计）：上界不再是写死的 14，改为随 [_weekdays] 联动——
  /// 「每周一三五」的习惯设「每周 14 次」是永远达不到的目标。
  int _weeklyGoal = 0;
  /// T1-2：每日目标量（null = 按天打卡的布尔习惯）。
  int? _dailyTarget;
  /// T1-4：宽限日（0..3，0 = 关闭）。
  int _graceDays = 0;

  String _formatReminder() {
    if (_reminderMinute == null) return '未设置';
    final h = _reminderMinute! ~/ 60;
    final m = _reminderMinute! % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// P3-10：当前所选星期下的「每周目标」合法上界（不选 = 每天 = 7）。
  int get _maxWeeklyGoal => Habit.plannedDaysOf(_weekdays.toList());

  /// P3-10：计划天数变化时把 [_weeklyGoal] 收敛到 [_maxWeeklyGoal]。
  void _syncWeeklyGoalToPlannedDays() {
    final max = _maxWeeklyGoal;
    if (_weeklyGoal > max) _weeklyGoal = max;
  }

  @override
  void dispose() {
    _titleCtl.dispose();
    _unitCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final primary = Theme.of(context).colorScheme.primary;
    final wdLabels = ['一', '二', '三', '四', '五', '六', '日'];

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: ext.meta,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('新建习惯',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            controller: _titleCtl,
            decoration: InputDecoration(
              hintText: '习惯名称，如「每天阅读」',
              filled: true,
              fillColor: ext.chip,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.cardRadius),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(height: 16),
          const Text('图标', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _emojis
                .map((e) => GestureDetector(
                      onTap: () => setState(() => _emoji = e),
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _emoji == e ? ext.chip : Colors.transparent,
                          border: Border.all(
                              color: _emoji == e ? primary : ext.navBorder),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 20)),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
          const Text('颜色', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _palette
                .map((c) => GestureDetector(
                      onTap: () => setState(() => _colorValue = c.value),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: _colorValue == c.value
                              ? Border.all(color: Colors.white, width: 3)
                              : null,
                        ),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
          const Text('打卡日（不选 = 每天）',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(7, (i) {
              final wd = i + 1;
              final sel = _weekdays.contains(wd);
              return ChoiceChip(
                label: Text(wdLabels[i]),
                selected: sel,
                onSelected: (_) => setState(() {
                  if (sel) {
                    _weekdays.remove(wd);
                  } else {
                    _weekdays.add(wd);
                  }
                  // P3-10：计划天数变化后，把「每周目标」收敛到新的上界。
                  // 典型场景：先设「每周 5 次」再只勾周一三五 → 目标自动降为 3，
                  // 不留一个永远达不到的进度条。
                  _syncWeeklyGoalToPlannedDays();
                }),
                selectedColor: primary,
                labelStyle:
                    TextStyle(color: sel ? Colors.white : ext.meta),
              );
            }),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('每日提醒',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(
                      DateTime(2020, 1, 1,
                          (_reminderMinute ?? 21 * 60) ~/ 60,
                          (_reminderMinute ?? 21 * 60) % 60),
                    ),
                  );
                  if (picked != null) {
                    setState(() =>
                        _reminderMinute = picked.hour * 60 + picked.minute);
                  }
                },
                icon: Icon(Symbols.alarm, size: 18, color: primary),
                label: Text(_formatReminder(),
                    style: TextStyle(color: primary)),
              ),
              if (_reminderMinute != null)
                IconButton(
                  icon: Icon(Symbols.close, size: 18, color: ext.meta),
                  tooltip: '清除提醒',
                  onPressed: () => setState(() => _reminderMinute = null),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('每周目标',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              // P3-10：候选项只到「计划天数」——再往上就是不可达目标。
              DropdownButton<int>(
                value: _weeklyGoal,
                items: List.generate(
                  _maxWeeklyGoal + 1,
                  (i) => DropdownMenuItem(
                    value: i,
                    child: Text(i == 0 ? '关闭' : '每周 $i 次'),
                  ),
                ),
                onChanged: (v) => setState(() => _weeklyGoal = v ?? 0),
                underline: const SizedBox.shrink(),
              ),
            ],
          ),
          // T1-2：每日目标量（量化习惯，如「每天喝 8 杯水」）。
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('每日目标量',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  final v = await promptHabitInt(
                    context,
                    title: '每日目标量',
                    current: _dailyTarget ?? 1,
                    min: 1,
                    max: 9999,
                    hint: '如「每天喝 8 杯水」填 8',
                  );
                  if (v != null) setState(() => _dailyTarget = v);
                },
                child: Text(
                  // P3-4（v3.1.3 审计）：目标显示接单位真源（有单位时「8 杯 / 天」）。
                  _dailyTarget == null
                      ? '关闭（按天打卡）'
                      : '${Habit.quantityLabel(_dailyTarget!, _unitCtl.text)} / 天',
                  style: TextStyle(color: primary),
                ),
              ),
              if (_dailyTarget != null)
                IconButton(
                  icon: Icon(Symbols.close, size: 18, color: ext.meta),
                  tooltip: '关闭量化（改回按天打卡）',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _dailyTarget = null),
                ),
            ],
          ),
          Text(
            _dailyTarget == null
                ? '开启后可「+1」累加数量，达标才算完成（如喝水、阅读页数）'
                // P3-4（v3.1.3 审计）：说明文案与目标显示同口径带单位。
                : '打卡时按数量累加，达到 ${Habit.quantityLabel(_dailyTarget!, _unitCtl.text)} 才算当日达成',
            style: TextStyle(fontSize: 12, color: ext.meta),
          ),
          // A3（v3.1.1 功能增强）：量化单位（仅量化习惯显示）。
          if (_dailyTarget != null) ...[
            const SizedBox(height: 12),
            _HabitUnitEditor(
              controller: _unitCtl,
              ext: ext,
              onChanged: (_) => setState(() {}),
            ),
          ],
          // T1-4：宽限日——每周允许漏卡 N 天而不断签，降低「一次失手前功尽弃」的挫败。
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('宽限日',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('每周允许漏卡不断签',
                  style: TextStyle(fontSize: 12, color: ext.meta)),
              const Spacer(),
              IconButton(
                onPressed: _graceDays > 0
                    ? () => setState(() => _graceDays--)
                    : null,
                icon: const Icon(Symbols.remove_circle_outline),
                visualDensity: VisualDensity.compact,
              ),
              Text('$_graceDays',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                onPressed: _graceDays < 3
                    ? () => setState(() => _graceDays++)
                    : null,
                icon: const Icon(Symbols.add_circle_outline),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              // P3-4（v3.0.7 审计）：提交期间置灰，与 _HabitEditSheet 的 _saving 同口径。
              onPressed: _saving
                  ? null
                  : () async {
                      final title = _titleCtl.text.trim();
                      if (title.isEmpty) return;
                      // P3-4（v3.0.7 审计）：防重入——异步窗口期内按钮已置灰，
                      // 这里是兜底（键盘 / 快捷键等非按钮路径）。
                      if (_saving) return;
                      setState(() => _saving = true);
                      // U2-1（v3.0.6 审计）：消费落盘结果——失败停留编辑层并如实
                      // 提示（provider 已回滚内存，重试不会造出重复习惯）。旧实现
                      // fire-and-forget 后直接 pop：新建的习惯仅存内存，重启即丢，
                      // 用户却已看到它出现在列表里。
                      final hp = context.read<HabitProvider>();
                      final ok = await hp.addHabit(
                        title: title,
                        emoji: _emoji,
                        colorValue: _colorValue,
                        // L4（v3.0.8 审计）：与编辑层同款排序——Set 迭代顺序
                        // 不保证，未排序时频率文案可能显示「每周 三 一」。
                        weekdays: _weekdays.toList()..sort(),
                        reminderMinute: _reminderMinute,
                        weeklyGoal: _weeklyGoal,
                        dailyTarget: _dailyTarget,
                        graceDays: _graceDays,
                        // A3（v3.1.1 功能增强）：随新建一并提交（空串 = 无单位）。
                        unit: _unitCtl.text,
                      );
                      if (!ok) {
                        // P3-4（v3.0.7 审计）：失败分支解除守卫（按钮恢复可点），
                        // 用户留在编辑层可直接重试。
                        if (mounted) setState(() => _saving = false);
                        if (context.mounted) showCheckInPersistFailedHint(context, provider: hp);
                        return;
                      }
                      // P3-4（v3.0.7 审计）：成功分支补 mounted 守卫——旧实现
                      // 直接 Navigator.pop(context)：若 await 期间 sheet 已被
                      // 销毁（系统返回 / 父级路由弹出），对失效 context 调 pop
                      // 会触发断言异常（失败分支早有该检查，成功分支没有）。
                      if (!mounted) return;
                      Navigator.pop(context);
                    },
              child: const Text('添加'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单习惯详情弹层：该习惯自己的热力图 + 连续/累计统计 + 打卡（带破纪录庆祝）+ 分享。
///
/// U2/U3/U15 增强：此前弹层只有「打卡 / 分享」两个按钮——习惯打错字无法改名、
/// 不想要的习惯无法删除、忘了打卡只能眼睁睁看 streak 归零；已打卡按钮还误触即撤。
/// 现补：
/// - 顶栏「编辑」（改名/改星期/改周目标/归档/删除，删除带二次确认）；
/// - 「补卡」按钮（日期选择器选过去日期，调 [HabitProvider.checkInOnDay]）；
/// - 已打卡时主按钮先弹确认再取消，避免误触清掉连续记录。
///
/// H4（v3.0.8 审计）：弹层改持 **habitId** 而非 Habit 对象——updateHabit 是
/// 不可变替换（`_habits[idx] = updated`），旧实现一次性持有对象、永不按 id
/// 回读：保存成功后弹层继续持旧对象，写按钮按旧状态全部可点（归档/休息日
/// 守卫被旁路、已归档习惯的提醒被旧对象重挂回系统闹钟），且「编辑层从旧对象
/// 初始化」会把首次编辑的标题/目标量按旧值整体覆盖回去。现在 build 时经
/// `hp.byId` 取当前对象（provider 变更即随 watch 刷新）；取不到 = 习惯已
/// 被删除，自动关层。
class _HabitDetailSheet extends StatelessWidget {
  final String habitId;
  const _HabitDetailSheet({required this.habitId});

  static void show(BuildContext context, Habit habit) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _HabitDetailSheet(habitId: habit.id),
    );
  }

  /// U3：补卡——选过去某天标记打卡。补的是提醒日/错过日，不限今天。
  ///
  /// T1-4 补齐两处此前的死路：
  /// 1. **撤卡**：已打卡的日期原先只弹一句「已打过卡」就结束，补错的卡无法取消
  ///    （连续天数、热力图、周报全都被这条错误记录污染）；
  /// 2. **改数量**：量化习惯（T1-2）补卡时可以填「那天到底做了多少」，而不是被
  ///    硬编码记成 1 个单位。
  Future<void> _backfillCheckIn(BuildContext context, HabitProvider hp) async {
    // H4（v3.0.8 审计）：按 id 取当前对象（弹层不持有快照，见类注释）。
    final habit = hp.byId(habitId);
    if (habit == null) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final first = DateTime(habit.createdAt.year, habit.createdAt.month,
        habit.createdAt.day);
    // L8（v3.0.8 审计）：补卡日期夹取到 **createdAt**——旧实现在「习惯当天
    // 创建」时回退到 30 天前，补卡日期可早于创建日，longestStreak 扫描起点被
    // 拉到创建前（为一条「出生前」的记录延长连续天数）。创建日在未来（时钟
    // 漂移）时收敛到今天，避免 firstDate > lastDate 触发选择器断言。
    final firstDate = first.isAfter(today) ? today : first;
    final picked = await showDatePicker(
      context: context,
      // initialDate 必须同落在 [firstDate, lastDate] 内，否则断言崩溃。
      initialDate: firstDate.isBefore(today)
          ? today.subtract(const Duration(days: 1))
          : today,
      firstDate: firstDate,
      lastDate: today,
      helpText: '选择要补卡 / 撤卡的日期',
    );
    if (picked == null) return;
    // H4（v3.0.8 审计）：补卡选到今天且今天是休息日时，provider 侧按无操作
    // 处理（返回 true），此处提前给如实反馈，避免「已补 X月X日打卡」的假成功。
    final isToday = picked.year == today.year &&
        picked.month == today.month &&
        picked.day == today.day;
    if (isToday && !habit.shouldCheckInOn(picked)) {
      showHabitRestDayHint(context);
      return;
    }
    final dayLabel = '${picked.month}月${picked.day}日';
    final existing = hp.checkInValueOn(habit, picked);

    // 已有记录 → 提供「撤销 / 改数量」，不再是一句无法操作的提示。
    if (existing > 0) {
      if (!context.mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('$dayLabel 已有打卡'),
          content: Text(habit.isQuantified
              // P3-7（v3.1.2 审计）：接 progressLabelOf——「已记录 5/8 杯」替代
              // 手拼的「已记录 5 个单位（目标 8）」（无单位且两套口径）。
              ? '该日已记录 ${habit.progressLabelOf(existing)}。'
                  '可以撤销这条记录，或修改数量。'
              : '该日已打过卡。可以撤销它，撤销后连续天数与热力图会同步回退。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, 'cancel'),
              child: const Text('取消'),
            ),
            // P3-7（v2.9.3 审计）：布尔习惯没有「数量」语义（value 恒为 1，
            // 填 5 会造出与布尔语义不符的记录并污染导出的「累计量」列），
            // 不再提供「修改数量」；撤销即其唯一操作，升为主按钮。
            if (habit.isQuantified)
              TextButton(
                onPressed: () => Navigator.pop(d, 'undo'),
                child: const Text('撤销打卡'),
              )
            else
              FilledButton(
                onPressed: () => Navigator.pop(d, 'undo'),
                child: const Text('撤销打卡'),
              ),
            if (habit.isQuantified)
              FilledButton(
                onPressed: () => Navigator.pop(d, 'edit'),
                child: const Text('修改数量'),
              ),
          ],
        ),
      );
      if (action == 'undo') {
        // P3-2（v3.0.5 审计）：按落盘结果反馈，失败不再谎报「已撤销」。
        final ok = await hp.setCheckInValue(habit, picked, 0);
        if (context.mounted) {
          if (ok) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已撤销 $dayLabel 的打卡')),
            );
          } else {
            // P3-1（v3.0.8 审计）：改走统一助手（安全模式分化），不再硬编码
            // 「请重试」。
            showCheckInPersistFailedHint(context, provider: hp);
          }
        }
      } else if (action == 'edit') {
        if (!context.mounted) return;
        final v = await promptHabitInt(
          context,
          title: '修改 $dayLabel 的数量',
          current: existing,
          min: 0,
          max: 9999,
          hint: '填 0 = 撤销该日打卡',
        );
        if (v == null) return;
        // 新U2-4（v2.9.7 审计）：命中今天且改后新达标 → 与其余写入口同享庆祝。
        // _maybeCelebrate 内部要求「今天由未达标变达标」，对过去日期的写入
        // 不改变今日达标态，调用为 no-op，无需按日期分支。
        final wasMet = hp.isTargetMetToday(habit);
        final longestBefore = hp.longestStreak(habit);
        // P3-2（v3.0.5 审计）：按落盘结果反馈，失败不再谎报「已更新」。
        final ok = await hp.setCheckInValue(habit, picked, v);
        if (context.mounted) {
          if (!ok) {
            showCheckInPersistFailedHint(context, provider: hp);
            return;
          }
          await _maybeCelebrate(context, hp, habit, wasMet, longestBefore);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(v == 0 ? '已撤销 $dayLabel 的打卡' : '已把 $dayLabel 更新为 $v')),
          );
        }
      }
      return;
    }

    // 无记录 → 补打。量化习惯允许填数量。
    var value = 1;
    if (habit.isQuantified) {
      if (!context.mounted) return;
      final v = await promptHabitInt(
        context,
        title: '补 $dayLabel 的数量',
        current: habit.effectiveTarget,
        min: 1,
        max: 9999,
        // P3-7（v3.1.2 审计）：输入提示补单位（与「设今日数量」同口径）。
        hint: '目标 ${habit.effectiveTarget}'
            '${habit.unit.trim().isEmpty ? '' : ' ${habit.unit.trim()}'}',
      );
      if (v == null) return;
      value = v;
    }
    if (!context.mounted) return;
    // 新U2-4（v2.9.7 审计）：补卡日期选择器 `lastDate: today` 允许选今天，
    // 但该路径此前直调 `checkInOnDay`，绕过了 [_maybeCelebrate]——同一屏里
    // 列表「+1」/详情「+1」/今日页/通知打卡都会庆祝，「补卡选今天补足目标」
    // 却毫无反馈，用户以为没生效。补庆祝包装（对过去日期为 no-op，见上）。
    final wasMet = hp.isTargetMetToday(habit);
    final longestBefore = hp.longestStreak(habit);
    // P3-2（v3.0.5 审计）：按落盘结果反馈，失败不再谎报「已补」。
    final ok = await hp.checkInOnDay(habit, picked, value: value);
    if (context.mounted) {
      if (!ok) {
        showCheckInPersistFailedHint(context, provider: hp);
        return;
      }
      await _maybeCelebrate(context, hp, habit, wasMet, longestBefore);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('已补 $dayLabel 打卡（连续天数已更新）')),
      );
    }
  }

  /// U15：已打卡状态下点主按钮 = 取消今日打卡，先确认再撤（防误触清连续记录）。
  Future<void> _confirmUncheckToday(
      BuildContext context, HabitProvider hp) async {
    // H4（v3.0.8 审计）：按 id 取当前对象（见类注释）。
    final habit = hp.byId(habitId);
    if (habit == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('取消今日打卡？'),
        content: Text(
          '「${habit.title}」今天的打卡会被撤销，连续天数可能回退。确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('保留'),
          ),
          FilledButton(
            // U3-6（v2.9.6 审计）：`Colors.red` → `colorScheme.error`。
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('撤销打卡'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      // P3-2（v3.0.5 审计）：按落盘结果反馈，失败不再静默（provider 已回滚内存，
      // 打卡记录原样保留）。
      final ok = await hp.uncheckInOnDay(habit, DateTime.now());
      if (!ok && context.mounted) showCheckInPersistFailedHint(context, provider: hp);
    }
  }

  /// U1-1（v2.9.3 审计）：清空今日累计量 + 10 秒撤销窗口。
  ///
  /// 与「设置数量（过对话框）」「取消打卡（详情页有二次确认）」的保护对齐；
  /// 撤销把清空前的累计量原值放回（走 [HabitProvider.setCheckInValue]，
  /// 连续天数 / 周目标进度随记录恢复，无需另行补偿）。
  ///
  /// P3-1 / P3-2 / U1-1 / U2-4 / U3-4（v2.9.4 审计）：本函数此前是**独立实现**，
  /// 于是四个缺陷原样存在——撤销闭包取「点击那一刻」的 `DateTime.now()`
  /// （跨零点写错日期）、无条件覆盖用户 10 秒内的后续操作、
  /// `hideCurrentSnackBar()` 顶掉前一条横幅、SnackBar 被详情弹层的
  /// ModalBarrier 挡住点不到。现在统一委托 [showCheckInUndoSnackBar]，
  /// 并传 `closeSheet: true` 先关弹层再提示。
  Future<void> _clearTodayWithUndo(BuildContext context, HabitProvider hp) async {
    // H4（v3.0.8 审计）：按 id 取当前对象（见类注释）。
    final habit = hp.byId(habitId);
    if (habit == null) return;
    // P3-1：操作发生时即固化 date-only。
    final day = _dateOnlyNow();
    final previous = hp.todayValue(habit);
    if (previous <= 0) return;
    // P3-2（v3.0.5 审计）：按落盘结果反馈，失败不给撤销横幅（清空未生效）。
    final ok = await hp.clearToday(habit);
    if (!context.mounted) return;
    if (!ok) {
      showCheckInPersistFailedHint(context, provider: hp);
      return;
    }
    await showCheckInUndoSnackBar(
      context,
      hp: hp,
      habit: habit,
      day: day,
      previous: previous,
      content: '已清空今日记录（$previous）',
      // U1-1：SnackBar 渲染在 ModalBarrier 之下，必须先关详情弹层。
      closeSheet: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hp = context.watch<HabitProvider>();
    // H4（v3.0.8 审计）：按 id 回读**当前**对象（provider 变更随 watch 刷新）；
    // 取不到 = 习惯已被删除（如备份恢复整体替换），安排退场后自动关层，
    // 不再持旧对象继续渲染与放行写按钮。
    final habit = hp.byId(habitId);
    if (habit == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return const SizedBox.shrink();
    }
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final primary = Theme.of(context).colorScheme.primary;
    const weeks = 18;

    final current = hp.currentStreak(habit);
    final longest = hp.longestStreak(habit);
    final total = hp.checkInCount(habit);
    final checked = hp.checkedDays(habit, weeks * 7);
    final freq = habit.weekdays.isEmpty
        ? '每天'
        : '每周 ${habit.weekdays.map(_wdLabel).join(' ')}';
    final created = DateFormat('yyyy年M月d日').format(habit.createdAt);
    final isCheckedToday = hp.isCheckedToday(habit);
    // T1-2：量化习惯的今日进度。
    final quantified = habit.isQuantified;
    final todayValue = hp.todayValue(habit);
    final target = habit.effectiveTarget;
    final metToday = hp.isTargetMetToday(habit);
    final todayRatio = habit.progressRatioOf(todayValue);
    // P3-3 / U2-6（v2.9.4 审计）：今天是否计划内打卡（与列表行、今日卡同口径）。
    // 休息日禁用「设置数量 / 今日达标 / 清空今日 / +1」，避免一键写入计划外记录。
    // P2-3（v3.0.1 审计）：归档习惯同样禁写——归档语义 = 退场，此前同屏
    // 一面显示「该习惯已归档，不再出现在今日打卡与提醒中」，一面全部写按钮
    // 可点且真实写入（统计与成就仍被改动）。归档优先于休息日判定。
    final restDay = !habit.shouldCheckInOn(DateTime.now());
    final writeBlocked = habit.archived || restDay;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Spacer(),
                  // U2：编辑习惯入口（改名 / 星期 / 周目标 / 归档 / 删除）。
                  IconButton(
                    tooltip: '编辑习惯',
                    icon: const Icon(Symbols.edit),
                    onPressed: () => _HabitEditSheet.show(context, habit),
                  ),
                  IconButton(
                    icon: const Icon(Symbols.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Color(habit.colorValue),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Text(habit.emoji,
                          style: const TextStyle(fontSize: 30)),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(habit.title,
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: onBg)),
                        const SizedBox(height: 4),
                        Text('$freq · 创建于 $created',
                            style: TextStyle(fontSize: 12, color: ext.meta)),
                        // U3-7（v2.9.5 审计）：宽限日 / 周目标的完整解释在此
                        // 常驻展示（卡片 chip 只留短文案），触屏用户点进详情即可见。
                        if (quantified)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              // P3-7（v3.1.2 审计）：详情头部的每日目标同样带单位。
                              '每日目标 $target'
                              '${habit.unit.trim().isEmpty ? '' : ' ${habit.unit.trim()}'}'
                              '${habit.graceDays > 0 ? ' · 宽限 ${habit.graceDays} 天/周（漏卡不断签）' : ''}',
                              style: TextStyle(fontSize: 12, color: ext.meta),
                            ),
                          )
                        else if (habit.graceDays > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('宽限 ${habit.graceDays} 天/周（漏卡不断签）',
                                style: TextStyle(fontSize: 12, color: ext.meta)),
                          ),
                        // P3-7（v2.9.6 审计）：生效值（计划天数夹取）。
                        if (habit.effectiveWeeklyGoal > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '本周达标 ${hp.weeklyCheckIns(habit)}/${habit.effectiveWeeklyGoal} 次'
                              '（达标 ${habit.effectiveWeeklyGoal} 次即本周达成）',
                              style: TextStyle(fontSize: 12, color: ext.meta),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // hero：当前连续 + 最长 + 累计
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.cardRadius),
                ),
                child: Row(
                  children: [
                    Icon(Icons.local_fire_department, size: 40, color: primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('$current',
                              style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.bold,
                                  color: primary)),
                          Text('当前连续（天）',
                              style:
                                  TextStyle(fontSize: 12, color: ext.meta)),
                        ],
                      ),
                    ),
                    _MiniStat(value: '$longest', label: '最长'),
                    const SizedBox(width: 16),
                    // P2-3（v2.9.4 审计）：标签与概览卡、导出一致（「累计达标」），
                    // 避免「累计」在概览/详情/成就三处各指一件事。
                    // U3-3（v2.9.4 审计）：「达标」对新用户是裸术语（量化习惯里
                    // 指「当日累计量 ≥ 每日目标」），补 Tooltip 一行解释。
                    Tooltip(
                      // P3-4（v3.1.3 审计）：Tooltip 的「≥ 目标」接单位真源。
                      message: habit.isQuantified
                          ? '累计**达标**天数：当天累计量 ≥ ${habit.quantityLabelOf(habit.effectiveTarget)} 才计一天'
                          : '累计打卡天数',
                      // U3-2（v2.9.6 审计）：解释同时以常驻小字展示（sub）——
                      // Tooltip 触屏不可主动发现，是 U3-1 同族教训。
                      child: _MiniStat(
                        value: '$total',
                        label: '累计达标',
                        // P3-4（v3.1.3 审计）：常驻小字与 Tooltip 同源。
                        sub: habit.isQuantified
                            ? '当日量 ≥ ${habit.quantityLabelOf(habit.effectiveTarget)} 才计一天'
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // T1-2：量化习惯的今日进度（累计量 / 目标 + 进度条 + 快捷操作）。
              if (quantified) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: ext.chip,
                    borderRadius: BorderRadius.circular(AppColors.cardRadius),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('今日进度',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700)),
                          const Spacer(),
                          Text(
                            // P3-4（v2.9.6 审计）：休息日不再渲染「0 / 8」——同一张
                            // 卡片下方就是「今天不打卡（不在计划的打卡日）」，上半
                            // 报数字、下半说不打卡，自相矛盾（v2.9.5 的 P3-6 只改了
                            // 列表侧两处，详情弹层漏网）。现在数字分支同样读 [restDay]。
                            // P3-7（v3.1.2 审计）：接 progressLabelOf 单一真源——
                            // 旧实现手拼 '$todayValue / $target'（分隔空格还与列表
                            // 的 6/8 不一致、无单位），同一习惯列表「今日 6/8 杯」
                            // 详情「6 / 8」会让用户怀疑单位没保存成功。
                            restDay
                                ? kHabitRestDayLabel
                                : '${habit.progressLabelOf(todayValue)}${metToday ? ' · 已达标' : ''}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: restDay
                                  ? ext.meta
                                  : (metToday ? primary : ext.meta),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // P3-6（v2.9.3 审计）：量化习惯补「本周累计 / 周目标量」——
                      // weeklyValue / weeklyValueTarget 此前定义后零消费。
                      // P3-7（v3.1.2 审计）：单位贯穿——周目标量同样带单位
                      //（与 progressLabelOf 同族口径：单位与数值间一个空格）。
                      Text(
                        '本周累计 ${hp.weeklyValue(habit)}/${hp.weeklyValueTarget(habit)}'
                        '${habit.unit.trim().isEmpty ? '' : ' ${habit.unit.trim()}'}'
                        '（计划日 × 每日目标）',
                        style: TextStyle(fontSize: 12, color: ext.meta),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        height: 8,
                        decoration: BoxDecoration(
                          color: ext.track,
                          borderRadius:
                              BorderRadius.circular(AppColors.progressRadius),
                        ),
                        child: FractionallySizedBox(
                          widthFactor: todayRatio,
                          alignment: Alignment.centerLeft,
                          child: Container(
                            decoration: BoxDecoration(
                              color: primary,
                              borderRadius: BorderRadius.circular(
                                  AppColors.progressRadius),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // P3-3 / U2-6（v2.9.4 审计）：休息日说明 + 三个写入口全部禁用
                      // （「设置数量」「今日达标」会一键写入计划外记录）。
                      // P2-3（v3.0.1 审计）：归档时改显下方「已归档」说明行，
                      // 本行（引导去用「补卡」）不再出现——补卡入口同样已禁用。
                      if (restDay && !habit.archived)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            '今天不打卡（不在计划的打卡日）· 如需补记请用下方「补卡」',
                            style: TextStyle(fontSize: 12, color: ext.meta),
                          ),
                        ),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: writeBlocked
                                ? null
                                // P3-8（v2.9.5 审计）：详情弹层这处「设置数量」同样
                                // 直调 provider 层、绕过庆祝包装。列表侧两处已改，
                                // 这里若不改就换个页面又出现「+1 庆祝 / 设数量不庆祝」。
                                : () => setTodayQuantityWithCelebration(
                                    context, hp, habit),
                            icon: const Icon(Symbols.edit, size: 16),
                            label: const Text('设置数量'),
                          ),
                          // U2-5（v2.9.3 审计）：兑现 toggleCheckInToday 注释的
                          // 承诺——「今日达标」轻量入口，喝到 6/8 时不必再点 2 次
                          // 「+1」或长按猜「设置数量」。已达标后无操作，故直接隐藏。
                          if (!metToday)
                            TextButton.icon(
                              // P3-9（v2.9.4 审计）：此前此路径绕过庆祝，与「+1」/打卡
                              // 入口不一致（用户「今日达标」看不到反馈，以为没生效）。
                              // 统一走 completeTodayTargetWithCelebration。
                              onPressed: writeBlocked
                                  ? null
                                  : () => completeTodayTargetWithCelebration(
                                      context, hp, habit),
                              icon: const Icon(Symbols.done_all, size: 16),
                              label: const Text('今日达标'),
                            ),
                          if (todayValue > 0)
                            TextButton.icon(
                              // U1-1（v2.9.3 审计）：清空今日不再裸奔——
                              // 已达标 8/8 一键归零会连带连续天数、周目标回退，
                              // 而同屏的「设置数量」要过对话框。改为撤销式保护：
                              // 立即清空 + 10 秒内可原值放回（与删除习惯对齐）。
                              onPressed: writeBlocked
                                  ? null
                                  : () => _clearTodayWithUndo(context, hp),
                              icon: const Icon(Symbols.undo, size: 16),
                              label: const Text('清空今日'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              // 单习惯热力图
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.cardRadius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('打卡热力图',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(quantified ? '最近 $weeks 周（颜色深浅 = 当日达成度）' : '最近 $weeks 周',
                        style: TextStyle(fontSize: 12, color: ext.meta)),
                    const SizedBox(height: 14),
                    HabitHeatmap(
                      checkedDays: checked,
                      weeks: weeks,
                      accent: primary,
                      goalMet: hp.goalMetThisWeek(habit),
                      // T1-2：量化习惯用「当日达成度」分级着色（4 档），
                      // 一眼能看出「哪些天只是勉强打了卡、哪些天做满了」。
                      // P2-7（v2.9.4 审计）：分级判据上移到
                      // [HabitProvider.progressLevelOn]，与分享卡共用同一真源
                      // （此前这段内联在闭包里，分享长图只能二值着色）。
                      levelOf: quantified
                          ? (d) => hp.progressLevelOn(habit, d)
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      // T1-2：量化习惯主按钮是「+1 累加」；布尔习惯沿用
                      // U15 的「已打卡先确认再撤」口径。
                      // P3-3 / U2-6（v2.9.4 审计）：休息日禁用主按钮（补卡入口不受限），
                      // 避免同屏既说「今天不打卡」又提供一个一键写入的按钮。
                      // P2-3（v3.0.1 审计）：归档同样禁用主按钮与补卡（原实现
                      // 只看 restDay，归档习惯三个写按钮全部可点且真实写入）。
                      onPressed: writeBlocked
                          ? null
                          : quantified
                              ? () =>
                                  incrementWithCelebration(context, hp, habit)
                              : (isCheckedToday
                                  ? () => _confirmUncheckToday(context, hp)
                                  : () =>
                                      checkInWithCelebration(context, hp, habit)),
                      icon: Icon(quantified
                          ? Icons.add
                          : (isCheckedToday ? Icons.check : Icons.add)),
                      // 新U3-7（v2.9.7 审计）：文案同值但此前是裸字面量，改走
                      // 共享常量 kHabitRestDayLabel，与列表 chip / 今日页同真源。
                      label: Text(habit.archived
                          ? '已归档'
                          : restDay
                              ? kHabitRestDayLabel
                              : quantified
                                  ? (metToday ? '+1（已达标）' : '+1')
                                  : (isCheckedToday ? '今日已打卡' : '打卡')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // U3：补卡入口——热力图纯展示，过去漏卡的唯一补救路径此前不存在。
                  Expanded(
                    child: OutlinedButton.icon(
                      // P2-3（v3.0.1 审计）：归档禁用补卡（写入侧 setCheckInValue
                      // 守卫兜底）。
                      onPressed: habit.archived
                          ? null
                          : () => _backfillCheckIn(context, hp),
                      icon: const Icon(Symbols.event_available),
                      label: const Text('补卡'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => showHabitShareSheet(context, habit),
                      icon: const Icon(Symbols.ios_share),
                      label: const Text('分享'),
                    ),
                  ),
                ],
              ),
              if (habit.archived)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Icon(Symbols.archive, size: 16, color: ext.meta),
                      const SizedBox(width: 6),
                      // P2-3（v3.0.1 审计）：补「恢复归档后可继续打卡」——写按钮
                      // 现已随归档禁用，说明行同步交代恢复路径，消除
                      // 「文案说退场、按钮可写入」的同屏矛盾。
                      Expanded(
                        child: Text(
                            '该习惯已归档，不再出现在今日打卡与提醒中 · 恢复归档后可继续打卡',
                            style: TextStyle(fontSize: 12, color: ext.meta)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 新P2-2（v2.9.7 审计）：已归档习惯折叠区。
///
/// 归档此前是**单向不可逆**操作：习惯页只渲染 `activeHabits`、搜索命中归档
/// 习惯只切 Tab——详情/编辑层（取消归档开关在其中）永久不可达，误触归档后
/// App 内无任何恢复途径（只能靠「从备份恢复」整体回滚）。折叠区让归档习惯
/// 重新可达：点行进详情 → 编辑 → 关「归档」开关即恢复。
class _ArchivedSection extends StatefulWidget {
  final List<Habit> habits;
  const _ArchivedSection({required this.habits});

  @override
  State<_ArchivedSection> createState() => _ArchivedSectionState();
}

class _ArchivedSectionState extends State<_ArchivedSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Container(
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Symbols.archive, size: 18, color: ext.meta),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('已归档（${widget.habits.length}）',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, color: onBg)),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: ext.meta,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  for (final h in widget.habits)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _HabitTile(habit: h),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// U2：编辑习惯底部弹层（改名 / 打卡星期 / 周目标 / 归档 / 删除）。
///
/// 详情弹层顶栏的「编辑」打开这里。保存走 [HabitProvider.updateHabit]（星期变更会
/// 重排提醒）；删除需二次确认，且删除后有 [kUndoWindowSeconds] 秒撤销窗口
/// （[HabitProvider.restoreHabit] 按快照原样恢复含原列表位置）。
///
/// P3-10（v2.9.4 审计）：此处原文写「清除全部历史打卡，**不可恢复**」——
/// 与紧随其后的 10 秒撤销自相矛盾（v2.9.3 已改过弹层内文案，漏了这段文档注释）。
class _HabitEditSheet extends StatefulWidget {
  final Habit habit;
  const _HabitEditSheet({required this.habit});

  static void show(BuildContext context, Habit habit) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _HabitEditSheet(habit: habit),
    );
  }

  @override
  State<_HabitEditSheet> createState() => _HabitEditSheetState();
}

class _HabitEditSheetState extends State<_HabitEditSheet> {
  late final TextEditingController _titleCtl =
      TextEditingController(text: widget.habit.title);
  // A3（v3.1.1 功能增强）：量化单位输入（初值取现有单位；空 = 无单位）。
  late final TextEditingController _unitCtl =
      TextEditingController(text: widget.habit.unit);
  late final Set<int> _weekdays = {...widget.habit.weekdays};
  // P3-7（v2.9.6 审计）：初值取「生效值」——编辑层保存时写入侧会按新计划天数
  // 收敛，打开时显示生效值与该行为一致（裸字段可能是保真的超界原值）。
  late int _weeklyGoal = widget.habit.effectiveWeeklyGoal;
  late bool _archived = widget.habit.archived;
  // T1-4：编辑层补齐「提醒时刻 / 每日目标量 / 宽限日」三项。
  late int? _reminderMinute = widget.habit.reminderMinute;
  late int? _dailyTarget = widget.habit.dailyTarget;
  late int _graceDays = widget.habit.graceDays;
  // L5（v3.0.8 审计）：编辑层补齐图标 / 颜色（provider 的 updateHabit 早已
  // 支持这两个入参，UI 侧此前无入口——选错只能删除重建并丢失全部打卡历史）。
  late String _emoji = widget.habit.emoji;
  late int _colorValue = widget.habit.colorValue;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // P3-15（v2.9.5 审计）：本类上方注释称「打开编辑层即自动降为计划天数」，
    // 但此前 `initState` 完全没调 [_syncWeeklyGoalToPlannedDays]——收敛只发生在
    // 勾选星期与保存时。于是「只打开看一眼就关掉」的用户，界面上的周目标
    // 仍显示旧的超界值（`+1` 控件的 `onPressed: _weeklyGoal < _maxWeeklyGoal`
    // 也跟着失效），注释与行为矛盾。
    //
    // 兜底补上后：即便内存中的 `weeklyGoal` 超界（读侧已按 P2-5 收敛过，但
    // 编辑中途的状态不保证），打开弹层即刻呈现合法上界。
    // **不写库**——落库仍只由 [_save] 触发，保持「不静默改写用户数据」。
    _syncWeeklyGoalToPlannedDays();
  }

  @override
  void dispose() {
    _titleCtl.dispose();
    _unitCtl.dispose();
    super.dispose();
  }

  String get _reminderLabel {
    final m = _reminderMinute;
    if (m == null) return '未设置';
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  /// P3-10：每周目标上界联动「当前所选星期」（不选 = 每天 = 7）。
  int get _maxWeeklyGoal => Habit.plannedDaysOf(_weekdays.toList());

  /// P3-10：星期变化时把 [_weeklyGoal] 收敛到新的上界。
  ///
  /// 典型：旧数据里「每周一三五 + 目标 5 次」（不可达）→ 打开编辑层即自动降为 3，
  /// 用户不必手动调；这不写库，只有 [_save] 时才落盘。
  void _syncWeeklyGoalToPlannedDays() {
    final max = _maxWeeklyGoal;
    if (_weeklyGoal > max) _weeklyGoal = max;
  }

  Future<void> _save() async {
    final title = _titleCtl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('习惯名称不能为空')));
      return;
    }
    setState(() => _saving = true);
    final hp = context.read<HabitProvider>();
    // P3-2（v3.0.5 审计）：按落盘结果反馈——失败时编辑层停留、如实提示
    //（provider 已回滚内存），不再 pop 后谎报「已保存」。
    final ok = await hp.updateHabit(
      widget.habit,
      title: title,
      emoji: _emoji,
      colorValue: _colorValue,
      weekdays: _weekdays.toList()..sort(),
      weeklyGoal: _weeklyGoal,
      archived: _archived,
      reminderMinute: _reminderMinute,
      clearReminder: _reminderMinute == null,
      dailyTarget: _dailyTarget,
      clearDailyTarget: _dailyTarget == null,
      graceDays: _graceDays,
      // A3（v3.1.1 功能增强）：随保存一并提交（空串 = 清除单位）。
      unit: _unitCtl.text,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() => _saving = false);
      // P3-1（v3.0.8 审计）：按安全模式分化（与打卡失败提示同口径），不再
      // 无条件「请重试」——安全模式下重试必然再失败。
      showCheckInPersistFailedHint(context, provider: hp);
      return;
    }
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存「$title」')),
    );
  }

  /// U2 + T1-4：删除习惯（含全部打卡记录），删除后提供 10 秒撤销窗口。
  ///
  /// 旧实现删除即永久丢失：一次误触就抹掉连续天数、热力图与全部历史打卡，
  /// 而任务侧早就有 SnackBar 撤销。现在删除返回快照，撤销即原样放回
  /// （含原列表位置与全部打卡记录，见 [HabitProvider.restoreHabit]）。
  Future<void> _delete() async {
    final hp = context.read<HabitProvider>();
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除该习惯？'),
        content: Text(
          // U3-2（v2.9.3 审计）：旧文案「不可恢复」与随后的撤销自相矛盾；
          // U3-5（v2.9.4 审计）：秒数也改为读 [kUndoWindowSeconds]，
          // 不再在本处独立写死「10 秒」（与任务侧删除文案曾长期不一致）。
          '将删除「${widget.habit.title}」及其全部打卡记录，删除后 $kUndoWindowSeconds 秒内可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          FilledButton(
            // U3-6（v2.9.6 审计）：硬编码 `Colors.red` 收口到 `colorScheme.error`，
            // 与任务侧破坏性按钮同口径（focus_screen:755 已改，此处是漏网点）。
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final snapshot = await hp.deleteHabit(widget.habit.id);
    if (!mounted) return;
    // P3-2（v3.0.5 审计）：snapshot == null = 删除未生效（habit 不存在或落盘
    // 失败——provider 已回滚内存，习惯仍在），如实提示并留在编辑层，不谎报
    // 「习惯已删除」（旧实现 null 也照走删除文案 + 无撤销按钮）。
    if (snapshot == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除未生效，请重试')),
      );
      return;
    }
    // 关闭编辑层 + 其下的详情弹层，回到习惯列表（删除后详情已无意义）。
    navigator.pop();
    navigator.pop();
    // U3-1（v3.0.8 审计）：删除后编辑层 context 随即失效，而撤销横幅的
    // onUndo / failureAction 回调都发生在弹层关闭**之后**——继续用本层
    // context 调 ScaffoldMessenger.of 会静默失败（mounted=false），成功 /
    // 失败反馈都看不到。横幅本身渲染在页面级 messenger 上，这里提前捕获
    // messenger 状态供两个闭包使用。
    final messenger = ScaffoldMessenger.of(context);
    // U2-4（v2.9.4 审计）：不再 `hideCurrentSnackBar()`——`ScaffoldMessenger`
    // 自带队列，主动 hide 等于亲手丢掉前一条撤销机会（用户毫不知情）。
    //
    // P3-2（v2.9.6 审计）：迁入 `widgets/undo_snack_bar.dart` 唯一实现——
    // 此前是内联 SnackBar + SnackBarAction（文案 `undoLabel` **不含秒数**、
    // 无「窗口超时已结束」提示），同族「撤销」的第 3 套实现。迁入后与任务侧
    // 统一（秒数插值 + 超时反馈）；P2-2 口径：恢复失败（同 id 已重建）时由
    // 唯一实现统一提示「撤销已失效」。
    showUndoSnackBar(
      context,
      // U3-1（v3.0.6 审计）：原为 `snapshot?.undoLabel ?? '习惯已删除'` +
      // `snapshot == null ? null : (...)`——上方 `if (snapshot == null)` 提前
      // 返回后两者成死分支（invalid_null_aware_operator +
      // unnecessary_null_comparison 两条 warning，打破项目「0 warning」声明）。
      // 控制流已保证非空，直写。
      content: undoContent(snapshot.undoLabel),
      onUndo: () async {
        final restored = await hp.restoreHabit(snapshot);
        if (restored != null) return true;
        // P2-1（v3.0.7 审计）：null 双义拆开——
        // ① 同 id 已重建（restoreHabit 早退分支，快照**未**暂存）= 真失效：
        //    自挂失效提示并返回 true——不走 failureHint（那条文案与「再试一次」
        //    是给落盘失败的，此时重试只会二次骗人）；
        // ② 落盘失败（restoreHabit 失败路径已把快照暂存进 provider）= 返回
        //    false，让唯一实现弹 failureHint + failureAction，「再试一次」
        //    有真实载体（见 _retryHabitRestore）。
        if (hp.byId(snapshot.habit.id) != null) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('撤销已失效：已重新创建了同名习惯，请手动合并或删除'),
            ),
          );
          return true;
        }
        return false;
      },
      // U2-1（v3.0.6 审计）：null 曾同时覆盖「同 id 已重建 / 落盘失败已回滚」，
      // 文案改成对两者都准确的「撤销未生效：请重试」。
      // P2-1（v3.0.7 审计）：该文案随后被证伪——撤销 action 点按后横幅即被
      // 框架关闭，快照原本只活在该闭包里，而习惯已从内存与数据库**同时**移除
      // （deleteHabit 早已成功落盘），「请重试」在物理上不存在入口，用户拿到
      // 的是虚假承诺（对照：v3.0.6 之前的默认文案「撤销已失效：该操作已不可
      // 恢复」对本分支反而准确）。现 restoreHabit 失败路径暂存快照，本提示挂
      // 「再试一次」action 重新恢复——与通知侧 showTaskUndoNotSaved 的「重试」
      // 载体对齐，两侧口径不再自相矛盾。
      failureHint: '撤销未保存：习惯已从列表移除，点「再试一次」重新恢复',
      failureAction: (
        label: '再试一次',
        onPressed: () => _retryHabitRestore(messenger, hp, snapshot),
      ),
    );
  }

  /// P2-1（v3.0.7 审计）：删除撤销失败提示的「再试一次」——从 provider 暂存区
  /// （[HabitProvider.retryRestoreHabit]）重新恢复被删的习惯。快照不会因提示条
  /// 超时消失而丢失（暂存在 provider，不在闭包里），仍失败时如实告知备份路径，
  /// 不再让用户去找一个不存在的按钮。
  ///
  /// U3-1（v3.0.8 审计）：重试显式携带**当次快照**（provider 侧按 id 校验暂存
  /// 区，两次删除撤销连续失败时不会恢复错对象）；反馈走页面级 messenger
  /// （编辑层 context 在两次 pop 后已失效，见 _delete 内注释）。
  Future<void> _retryHabitRestore(ScaffoldMessengerState messenger,
      HabitProvider hp, DeletedHabit snapshot) async {
    final restored = await hp.retryRestoreHabit(snapshot);
    messenger.showSnackBar(
      SnackBar(
        content: Text(restored != null
            ? '已恢复「${snapshot.habit.title}」'
            : '恢复失败：请前往「设置 → 备份与恢复」从备份找回'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final wdLabels = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: ext.meta,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('编辑习惯',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: onBg)),
            const SizedBox(height: 16),
            TextField(
              controller: _titleCtl,
              decoration: InputDecoration(
                labelText: '习惯名称',
                filled: true,
                fillColor: ext.chip,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppColors.cardRadius),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // L5（v3.0.8 审计）：图标 / 颜色编辑入口（与新建弹层同款选器）。
            const Text('图标', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: kHabitEmojis
                  .map((e) => GestureDetector(
                        onTap: () => setState(() => _emoji = e),
                        child: Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _emoji == e ? ext.chip : Colors.transparent,
                            border: Border.all(
                                color: _emoji == e
                                    ? Theme.of(context).colorScheme.primary
                                    : ext.navBorder),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 20)),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            const Text('颜色', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: kHabitPalette
                  .map((c) => GestureDetector(
                        onTap: () => setState(() => _colorValue = c.value),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: _colorValue == c.value
                                ? Border.all(color: Colors.white, width: 3)
                                : null,
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            const Text('打卡日（不选 = 每天）',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: List.generate(7, (i) {
                final wd = i + 1;
                final sel = _weekdays.isEmpty || _weekdays.contains(wd);
                final active = _weekdays.isEmpty ? false : _weekdays.contains(wd);
                final isAll = _weekdays.isEmpty;
                return GestureDetector(
                  onTap: () => setState(() {
                    if (isAll) {
                      // 从「每天」点某个星期 → 进入「仅该天」。
                      _weekdays
                        ..clear()
                        ..add(wd);
                    } else if (active) {
                      _weekdays.remove(wd);
                      if (_weekdays.isEmpty) _weekdays.addAll(List.generate(7, (x) => x + 1));
                    } else {
                      _weekdays.add(wd);
                    }
                    // P3-10：计划天数变化 → 每周目标同步收敛。
                    _syncWeeklyGoalToPlannedDays();
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: sel
                          ? Theme.of(context).colorScheme.primary.withOpacity(0.14)
                          : ext.chip,
                      borderRadius: BorderRadius.circular(AppColors.chipRadius),
                    ),
                    child: Text(
                      '周${wdLabels[wd - 1]}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: sel
                            ? Theme.of(context).colorScheme.primary
                            : ext.meta,
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('每周目标次数', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  onPressed: _weeklyGoal > 0
                      ? () => setState(() => _weeklyGoal--)
                      : null,
                  icon: const Icon(Symbols.remove_circle_outline),
                  visualDensity: VisualDensity.compact,
                ),
                Text('$_weeklyGoal',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(
                  onPressed: _weeklyGoal < _maxWeeklyGoal
                      ? () => setState(() => _weeklyGoal++)
                      : null,
                  icon: const Icon(Symbols.add_circle_outline),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('每日提醒时刻',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    final cur = _reminderMinute ?? 21 * 60;
                    final picked = await showTimePicker(
                      context: context,
                      initialTime:
                          TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
                    );
                    if (picked != null) {
                      setState(() =>
                          _reminderMinute = picked.hour * 60 + picked.minute);
                    }
                  },
                  icon: Icon(Symbols.alarm,
                      size: 18,
                      color: _reminderMinute == null
                          ? ext.meta
                          : Theme.of(context).colorScheme.primary),
                  label: Text(
                    _reminderLabel,
                    style: TextStyle(
                      color: _reminderMinute == null
                          ? ext.meta
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                if (_reminderMinute != null)
                  IconButton(
                    icon: Icon(Symbols.close, size: 18, color: ext.meta),
                    tooltip: '清除提醒',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _reminderMinute = null),
                  ),
              ],
            ),
            // U3-2（v2.9.3 审计）：编辑层补说明文案（与新建层同项对齐）。
            Text(
              _reminderMinute == null
                  ? '未设提醒；开启后每天在该时刻提醒打卡'
                  : '每天 ${_reminderLabel} 到点提醒打卡',
              style: TextStyle(fontSize: 12, color: ext.meta),
            ),
            const SizedBox(height: 16),
            // T1-2：每日目标量（关闭 = 按天打卡的布尔习惯）。
            Row(
              children: [
                const Text('每日目标量',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    final v = await promptHabitInt(
                      context,
                      title: '每日目标量',
                      current: _dailyTarget ?? 1,
                      min: 1,
                      max: 9999,
                      hint: '如「每天喝 8 杯水」填 8',
                    );
                    if (v != null) setState(() => _dailyTarget = v);
                  },
                  child: Text(
                    // P3-4（v3.1.3 审计）：编辑层与新建层同源。
                    _dailyTarget == null
                        ? '关闭（按天打卡）'
                        : '${Habit.quantityLabel(_dailyTarget!, _unitCtl.text)} / 天',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                ),
                if (_dailyTarget != null)
                  IconButton(
                    icon: Icon(Symbols.close, size: 18, color: ext.meta),
                    tooltip: '关闭量化',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _dailyTarget = null),
                  ),
              ],
            ),
            // U3-2（v2.9.3 审计）：编辑层补说明文案（文案与新建层同源同义）。
            Text(
              _dailyTarget == null
                  ? '开启后可「+1」累加数量，达标才算完成（如喝水、阅读页数）'
                  // P3-4（v3.1.3 审计）：说明文案与目标显示同口径带单位。
                : '打卡时按数量累加，达到 ${Habit.quantityLabel(_dailyTarget!, _unitCtl.text)} 才算当日达成',
              style: TextStyle(fontSize: 12, color: ext.meta),
            ),
            // A3（v3.1.1 功能增强）：量化单位（仅量化习惯显示；空 = 无单位）。
            if (_dailyTarget != null) ...[
              const SizedBox(height: 12),
              _HabitUnitEditor(
              controller: _unitCtl,
              ext: ext,
              onChanged: (_) => setState(() {}),
            ),
            ],
            const SizedBox(height: 16),
            // T1-4：宽限日。
            Row(
              children: [
                const Text('宽限日',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Text('每周允许漏卡不断签',
                    style: TextStyle(fontSize: 12, color: ext.meta)),
                const Spacer(),
                IconButton(
                  onPressed: _graceDays > 0
                      ? () => setState(() => _graceDays--)
                      : null,
                  icon: const Icon(Symbols.remove_circle_outline),
                  visualDensity: VisualDensity.compact,
                ),
                Text('$_graceDays',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(
                  onPressed: _graceDays < 3
                      ? () => setState(() => _graceDays++)
                      : null,
                  icon: const Icon(Symbols.add_circle_outline),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Symbols.archive, size: 20, color: ext.meta),
                const SizedBox(width: 8),
                const Expanded(child: Text('归档（不再出现在今日打卡与提醒）')),
                Switch(
                  value: _archived,
                  onChanged: (v) => setState(() => _archived = v),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    // U3-6（v2.9.6 审计）：`Colors.red` → `colorScheme.error`。
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: _saving ? null : _delete,
                    icon: const Icon(Symbols.delete_outline),
                    label: const Text('删除'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String value;
  final String label;

  /// U3-2（v2.9.6 审计）：常驻小字解释（可选）——「累计达标」的口径此前只挂
  /// Tooltip，触屏不可主动发现；sub 会在 label 下再渲染一行 10px 说明。
  final String? sub;
  const _MiniStat({required this.value, required this.label, this.sub});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: onBg)),
        Text(label, style: TextStyle(fontSize: 11, color: ext.meta)),
        if (sub != null)
          Text(sub!,
              style: TextStyle(fontSize: 10, color: ext.meta)),
      ],
    );
  }
}
