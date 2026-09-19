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
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/command_palette_button.dart';
import 'package:todolist/widgets/habit_heatmap.dart';
import 'package:todolist/widgets/habit_share_card.dart';
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

    final total = habit.activeHabits.length;
    // T1-2：达成口径——量化习惯要求当日累计量 ≥ 每日目标，仅有记录不算完成。
    final todayDone =
        habit.activeHabits.where((h) => habit.isTargetMetToday(h)).length;

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
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                    AppColors.pagePadX, 8, AppColors.pagePadX, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                    if (habit.activeHabits.isEmpty)
                      const _EmptyHint()
                    else
                      ...habit.activeHabits.map(
                        (h) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _HabitTile(habit: h),
                        ),
                      ),
                    const SizedBox(height: 24),
                    _SectionTitle('成就'),
                    const SizedBox(height: AppColors.contentGap),
                    _AchievementGrid(ctx: ctx),
                  ],
                ),
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
/// T1-2：判定基准由「是否已打卡」改为「是否已达成当日目标」——量化习惯在喝到第 8
/// 杯那一刻（而不是第 1 杯）才该庆祝；布尔习惯两者等价，行为不变。
Future<void> checkInWithCelebration(
  BuildContext context,
  HabitProvider hp,
  Habit habit,
) async {
  final wasMet = hp.isTargetMetToday(habit);
  final longestBefore = hp.longestStreak(habit);
  await hp.toggleCheckInToday(habit);
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
  await hp.adjustCheckInValue(habit, DateTime.now(), 1);
  await _maybeCelebrate(context, hp, habit, wasMet, longestBefore);
}

/// 共用庆祝判定：本次由「未达标」变为「已达标」，且当前连续超过历史最长。
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
  if (now > longestBefore) showStreakCelebration(context, now);
}

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
    hint: '目标 ${habit.effectiveTarget}；填 0 = 清空今日记录',
  );
  if (v == null) return;
  await hp.setCheckInValue(habit, DateTime.now(), v);
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
      ('累计', '$totalCheckIns 次'),
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
    final counts = habit.checkInCountsByDay(weeks * 7);
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
          Text('最近 $weeks 周打卡密度',
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
    final target = habit.effectiveTarget;
    // T1-2：量化习惯用「达成」判定，布尔习惯等价于原「已打卡」。
    final checked = quantified ? hp.isTargetMetToday(habit) : hp.isCheckedToday(habit);
    final streak = hp.currentStreak(habit);
    final freq = habit.weekdays.isEmpty
        ? '每天'
        : '每周 ${habit.weekdays.map(_wdLabel).join(' ')}';
    final goalN = hp.weeklyCheckIns(habit);
    final goalM = habit.weeklyGoal;
    final goalMet = goalN >= goalM;

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
                              '今日 $value/$target',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: checked ? primary : ext.meta,
                              ),
                            ),
                          ),
                        if (habit.weeklyGoal > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: goalMet
                                  ? primary.withValues(alpha: 0.14)
                                  : ext.chip,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text('本周 $goalN/$goalM',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: goalMet ? primary : ext.meta,
                                )),
                          ),
                        // T1-4：宽限日提示（仅开启时显示，避免噪音）。
                        if (habit.graceDays > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ext.chip,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text('宽限 ${habit.graceDays} 天/周',
                                style: TextStyle(fontSize: 11, color: ext.meta)),
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
    // - 布尔习惯：勾选圆圈（点击打卡 + 打破纪录庆祝）；
    // - 量化习惯（T1-2）：计数 pill（点开详情 / 长按设数量）+「+1」按钮
    //   （点击累加 1，达标那一刻触发庆祝）。
    final action = quantified
        ? Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showHabitDetailSheet(context, habit),
                  onLongPress: () =>
                      promptHabitTodayQuantity(context, hp, habit),
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 46),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: checked ? primary : ext.chip,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$value/$target',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: checked ? Colors.white : ext.meta,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => incrementWithCelebration(context, hp, habit),
                  onLongPress: () =>
                      promptHabitTodayQuantity(context, hp, habit),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: checked ? primary.withValues(alpha: 0.16) : primary,
                    ),
                    child: Icon(Icons.add,
                        size: 18,
                        color: checked ? primary : Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: () => checkInWithCelebration(context, hp, habit),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: checked ? primary : Colors.transparent,
                  border: Border.all(
                      color: checked ? primary : ext.meta, width: 2),
                ),
                child: checked
                    ? const Icon(Icons.check, color: Colors.white, size: 18)
                    : null,
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
/// 现改为：长按先弹确认；同时在 chip 下方给出「长按可取消」的弱提示文案，
/// 让用户知道该手势存在，不再靠猜。
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
            context
                .read<HabitProvider>()
                .setReminder(habit, picked.hour * 60 + picked.minute);
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
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('取消提醒'),
                ),
              ],
            ),
          );
          if (confirmed == true) {
            await hp.setReminder(habit, null);
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
  static const List<Color> _palette = [
    Color(0xFF0061A4),
    Color(0xFF6750A4),
    Color(0xFF00696E),
    Color(0xFFB3261E),
    Color(0xFF386A20),
    Color(0xFF965400),
    Color(0xFF8B4A82),
  ];
  static const List<String> _emojis = [
    '💪', '📚', '🏃', '💧', '🧘', '😴',
    '🥗', '✍️', '🎯', '💡', '🌟', '🚭',
  ];

  final _titleCtl = TextEditingController();
  String _emoji = _emojis.first;
  int _colorValue = _palette.first.value;
  final Set<int> _weekdays = {};
  /// 每日提醒时间（分钟数，null = 不提醒）。
  int? _reminderMinute;
  /// 每周目标打卡次数（0 = 不启用，1..14）。
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

  @override
  void dispose() {
    _titleCtl.dispose();
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
              DropdownButton<int>(
                value: _weeklyGoal,
                items: List.generate(
                  15,
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
                  _dailyTarget == null ? '关闭（按天打卡）' : '$_dailyTarget / 天',
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
                : '打卡时按数量累加，达到 $_dailyTarget 才算当日达成',
            style: TextStyle(fontSize: 12, color: ext.meta),
          ),
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
              onPressed: () {
                final title = _titleCtl.text.trim();
                if (title.isEmpty) return;
                context.read<HabitProvider>().addHabit(
                      title: title,
                      emoji: _emoji,
                      colorValue: _colorValue,
                      weekdays: _weekdays.toList(),
                      reminderMinute: _reminderMinute,
                      weeklyGoal: _weeklyGoal,
                      dailyTarget: _dailyTarget,
                      graceDays: _graceDays,
                    );
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
class _HabitDetailSheet extends StatelessWidget {
  final Habit habit;
  const _HabitDetailSheet({required this.habit});

  static void show(BuildContext context, Habit habit) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _HabitDetailSheet(habit: habit),
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
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final first = DateTime(habit.createdAt.year, habit.createdAt.month,
        habit.createdAt.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: today.subtract(const Duration(days: 1)),
      firstDate: first.isBefore(today) ? first : today.subtract(const Duration(days: 30)),
      lastDate: today,
      helpText: '选择要补卡 / 撤卡的日期',
    );
    if (picked == null) return;
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
              ? '该日已记录 $existing 个单位（目标 ${habit.effectiveTarget}）。'
                  '可以撤销这条记录，或修改数量。'
              : '该日已打过卡。可以撤销它，撤销后连续天数与热力图会同步回退。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, 'cancel'),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, 'undo'),
              child: const Text('撤销打卡'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, 'edit'),
              child: const Text('修改数量'),
            ),
          ],
        ),
      );
      if (action == 'undo') {
        await hp.setCheckInValue(habit, picked, 0);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已撤销 $dayLabel 的打卡')),
          );
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
        await hp.setCheckInValue(habit, picked, v);
        if (context.mounted) {
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
        hint: '目标 ${habit.effectiveTarget}',
      );
      if (v == null) return;
      value = v;
    }
    if (!context.mounted) return;
    await hp.checkInOnDay(habit, picked, value: value);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('已补 $dayLabel 打卡（连续天数已更新）')),
      );
    }
  }

  /// U15：已打卡状态下点主按钮 = 取消今日打卡，先确认再撤（防误触清连续记录）。
  Future<void> _confirmUncheckToday(
      BuildContext context, HabitProvider hp) async {
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
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('撤销打卡'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await hp.uncheckInOnDay(habit, DateTime.now());
    }
  }

  @override
  Widget build(BuildContext context) {
    final hp = context.watch<HabitProvider>();
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
                        if (quantified)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '每日目标 $target'
                              '${habit.graceDays > 0 ? ' · 宽限 ${habit.graceDays} 天/周' : ''}',
                              style: TextStyle(fontSize: 12, color: ext.meta),
                            ),
                          )
                        else if (habit.graceDays > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('宽限 ${habit.graceDays} 天/周',
                                style: TextStyle(fontSize: 12, color: ext.meta)),
                          ),
                        if (habit.weeklyGoal > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '本周 ${hp.weeklyCheckIns(habit)}/${habit.weeklyGoal} 次'
                              '（目标 每周 ${habit.weeklyGoal} 次）',
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
                    _MiniStat(value: '$total', label: '累计'),
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
                            '$todayValue / $target${metToday ? ' · 已达标' : ''}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: metToday ? primary : ext.meta,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
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
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: () =>
                                promptHabitTodayQuantity(context, hp, habit),
                            icon: const Icon(Symbols.edit, size: 16),
                            label: const Text('设置数量'),
                          ),
                          if (todayValue > 0)
                            TextButton.icon(
                              onPressed: () => hp.clearToday(habit),
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
                      levelOf: quantified
                          ? (d) {
                              final r = habit
                                  .progressRatioOf(hp.checkInValueOn(habit, d));
                              if (r <= 0) return 0;
                              if (r < 0.5) return 1;
                              if (r < 0.75) return 2;
                              if (r < 1.0) return 3;
                              return 4; // 达标档（HabitHeatmap 的 steps 长度为 4）
                            }
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
                      onPressed: quantified
                          ? () => incrementWithCelebration(context, hp, habit)
                          : (isCheckedToday
                              ? () => _confirmUncheckToday(context, hp)
                              : () => checkInWithCelebration(context, hp, habit)),
                      icon: Icon(quantified
                          ? Icons.add
                          : (isCheckedToday ? Icons.check : Icons.add)),
                      label: Text(quantified
                          ? (metToday ? '+1（已达标）' : '+1')
                          : (isCheckedToday ? '今日已打卡' : '打卡')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // U3：补卡入口——热力图纯展示，过去漏卡的唯一补救路径此前不存在。
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _backfillCheckIn(context, hp),
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
                      Text('该习惯已归档，不再出现在今日打卡与提醒中',
                          style: TextStyle(fontSize: 12, color: ext.meta)),
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

/// U2：编辑习惯底部弹层（改名 / 打卡星期 / 周目标 / 归档 / 删除）。
///
/// 详情弹层顶栏的「编辑」打开这里。保存走 [HabitProvider.updateHabit]（星期变更会
/// 重排提醒）；删除需二次确认（清除全部历史打卡，不可恢复）。
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
  late final Set<int> _weekdays = {...widget.habit.weekdays};
  late int _weeklyGoal = widget.habit.weeklyGoal;
  late bool _archived = widget.habit.archived;
  // T1-4：编辑层补齐「提醒时刻 / 每日目标量 / 宽限日」三项。
  late int? _reminderMinute = widget.habit.reminderMinute;
  late int? _dailyTarget = widget.habit.dailyTarget;
  late int _graceDays = widget.habit.graceDays;
  bool _saving = false;

  @override
  void dispose() {
    _titleCtl.dispose();
    super.dispose();
  }

  String get _reminderLabel {
    final m = _reminderMinute;
    if (m == null) return '未设置';
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
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
    await hp.updateHabit(
      widget.habit,
      title: title,
      weekdays: _weekdays.toList()..sort(),
      weeklyGoal: _weeklyGoal,
      archived: _archived,
      reminderMinute: _reminderMinute,
      clearReminder: _reminderMinute == null,
      dailyTarget: _dailyTarget,
      clearDailyTarget: _dailyTarget == null,
      graceDays: _graceDays,
    );
    if (!mounted) return;
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
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除该习惯？'),
        content: Text(
          '将删除「${widget.habit.title}」及其全部打卡记录，不可恢复。',
        ),
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
    if (confirmed != true) return;
    final snapshot = await hp.deleteHabit(widget.habit.id);
    if (!mounted) return;
    // 关闭编辑层 + 其下的详情弹层，回到习惯列表（删除后详情已无意义）。
    navigator.pop();
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(snapshot?.undoLabel ?? '习惯已删除'),
          duration: const Duration(seconds: 10),
          action: snapshot == null
              ? null
              : SnackBarAction(
                  label: '撤销',
                  onPressed: () => hp.restoreHabit(snapshot),
                ),
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
                  onPressed: _weeklyGoal < 14
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
                    _dailyTarget == null ? '关闭（按天打卡）' : '$_dailyTarget / 天',
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
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
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
  const _MiniStat({required this.value, required this.label});

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
      ],
    );
  }
}
