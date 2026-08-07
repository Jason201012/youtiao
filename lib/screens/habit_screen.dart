import 'package:flutter/material.dart';
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

    final ctx = AchievementContext(
      totalCheckIns: habit.totalCheckIns,
      longestStreak: habit.overallLongestStreak,
      currentStreak: habit.overallCurrentStreak,
      habitCount: habit.habitCount,
      completedTasks: task.completed,
      focusMinutes: focus.totalSec ~/ 60,
    );

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
    return Container(
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: Color(habit.colorValue),
          child: Text(habit.emoji, style: const TextStyle(fontSize: 20)),
        ),
        title: Text(habit.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Row(
          children: [
            Text('连续 $streak 天 · $freq',
                style: TextStyle(color: ext.meta, fontSize: 12)),
            if (habit.reminderMinute != null) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () async {
                  final cur = habit.reminderMinute!;
                  final picked = await showTimePicker(
                    context: context,
                    initialTime:
                        TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
                  );
                  if (picked != null) {
                    context.read<HabitProvider>().setReminder(
                        habit, picked.hour * 60 + picked.minute);
                  }
                },
                onLongPress: () =>
                    context.read<HabitProvider>().setReminder(habit, null),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: ext.chip,
                    borderRadius:
                        BorderRadius.circular(AppColors.chipRadius),
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
            ],
          ],
        ),
        trailing: GestureDetector(
          onTap: () =>
              context.read<HabitProvider>().toggleCheckInToday(habit),
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
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: allAchievements.map((a) {
        final unlocked = a.unlocked(ctx);
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
                          fontSize: 22,
                          color: unlocked ? null : ext.meta)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(a.title,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: unlocked ? null : ext.meta)),
                  ),
                  if (unlocked)
                    Icon(Icons.verified, size: 16, color: primary),
                ],
              ),
              const SizedBox(height: 6),
              Text(a.desc, style: TextStyle(fontSize: 12, color: ext.meta)),
            ],
          ),
        );
      }).toList(),
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
