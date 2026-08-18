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
    final todayDone =
        habit.activeHabits.where((h) => habit.isCheckedToday(h)).length;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            const TopAppBar(title: '习惯'),
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
/// 先记录「打卡前最长连续」与「是否已打卡」，toggle 后若本次是新增打卡且当前连续
/// 已超过此前最长，即触发全屏庆祝。供习惯列表圆圈与详情弹层共用。
Future<void> checkInWithCelebration(
  BuildContext context,
  HabitProvider hp,
  Habit habit,
) async {
  final wasChecked = hp.isCheckedToday(habit);
  final longestBefore = hp.longestStreak(habit);
  await hp.toggleCheckInToday(habit);
  if (context.mounted && !wasChecked) {
    final now = hp.currentStreak(habit);
    if (now > longestBefore) showStreakCelebration(context, now);
  }
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
    final checked = hp.isCheckedToday(habit);
    final streak = hp.currentStreak(habit);
    final freq = habit.weekdays.isEmpty
        ? '每天'
        : '每周 ${habit.weekdays.map(_wdLabel).join(' ')}';

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
                    Row(
                      children: [
                        StreakBadge(current: streak, accent: primary),
                        const SizedBox(width: 8),
                        Text(freq,
                            style: TextStyle(color: ext.meta, fontSize: 12)),
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

    // 右侧打卡圆圈：快速打卡 + 打破纪录庆祝。
    final check = Padding(
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
        children: [left, chip, check],
      ),
    );
  }
}

/// 提醒时间 chip：点击改时间，长按取消提醒（沿用原习惯页交互）。
class _ReminderChip extends StatelessWidget {
  final Habit habit;
  const _ReminderChip({required this.habit});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return GestureDetector(
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
      onLongPress: () =>
          context.read<HabitProvider>().setReminder(habit, null),
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
/// 与首页聚合热力图区分，这里只展示当前这一个习惯的打卡密度与连续天数。
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
                  Spacer(),
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
                    Text('最近 $weeks 周',
                        style: TextStyle(fontSize: 12, color: ext.meta)),
                    const SizedBox(height: 14),
                    HabitHeatmap(
                      checkedDays: checked,
                      weeks: weeks,
                      accent: primary,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () =>
                          checkInWithCelebration(context, hp, habit),
                      icon: Icon(
                        isCheckedToday ? Icons.check : Icons.add,
                      ),
                      label:
                          Text(isCheckedToday ? '今日已打卡' : '打卡'),
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
            ],
          ),
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
