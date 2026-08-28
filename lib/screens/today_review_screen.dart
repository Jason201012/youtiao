import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/services/daily_briefing.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';

/// P0-1 晚间简报落地页：点击「今日小结」通知进入，展示当日聚合概览卡片。
/// 数据在打开时从三大 Provider 按本地日期口径实时聚合（与首页 / 周报一致）。
class TodayReviewScreen extends StatelessWidget {
  const TodayReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final task = context.watch<TaskProvider>();
    final focus = context.watch<FocusProvider>();
    final habit = context.watch<HabitProvider>();
    final brief = buildEveningBriefFromState(task, focus, habit);
    final ext = appColors(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('今日回顾'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Symbols.nightlight, color: ext.meta),
                const SizedBox(width: 8),
                Text(brief.title,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 16),
            ...brief.lines.map((line) => _LineCard(text: line)),
            const SizedBox(height: 8),
            Text(
              '数据每日本地聚合，不涉及任何网络',
              style: TextStyle(color: ext.meta, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  final String text;
  const _LineCard({required this.text});
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isBullet = text.startsWith('• ');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      width: double.infinity,
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: isBullet ? 14 : 15,
          color: isBullet ? ext.meta : null,
          height: 1.35,
        ),
      ),
    );
  }
}
