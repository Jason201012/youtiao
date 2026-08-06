import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 专注与任务关联统计：把带关联任务的专注会话按任务聚合，
/// 展示每件事的累计时长与次数（按累计时长降序）。与专注 Tab 呼应。
class FocusTaskStats extends StatelessWidget {
  final FocusProvider focus;
  const FocusTaskStats({super.key, required this.focus});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final meta = ext.meta;
    final primary = Theme.of(context).colorScheme.primary;
    final stats = focus.taskStats;
    final maxSec = stats.isEmpty ? 1 : stats.first.totalSec;

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
          Row(
            children: [
              Icon(Symbols.account_tree, size: 18, color: meta),
              const SizedBox(width: 8),
              Text('任务专注统计',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold, color: onBg)),
              const Spacer(),
              Text('按累计时长', style: TextStyle(fontSize: 11, color: meta)),
            ],
          ),
          const SizedBox(height: 12),
          if (stats.isEmpty)
            Text(
              '还没有关联任务的专注记录。开始专注时选择关联任务，'
              '这里会统计每件事累计花了多少时间。',
              style: TextStyle(fontSize: 12, color: meta),
            )
          else
            for (final s in stats)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(s.title,
                              style: TextStyle(fontSize: 13, color: onBg),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 8),
                        Text(formatFocusDuration(s.totalSec),
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: onBg)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    LinearProgressIndicator(
                      value: maxSec == 0 ? 0 : s.totalSec / maxSec,
                      backgroundColor: ext.track,
                      color: primary,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    const SizedBox(height: 3),
                    Text('${s.count} 次',
                        style: TextStyle(fontSize: 11, color: meta)),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
