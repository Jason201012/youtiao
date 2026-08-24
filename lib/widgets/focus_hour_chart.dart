import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 专注时段分布图（A2）：自绘 24 小时直方图。
///
/// 复用 [FocusWeekBars] 的极简视觉（圆角柱 + 标签），把全部专注会话按「开始时刻的小时」
/// 聚合到 24 个桶，柱高反映该时段累计专注秒数。深夜(0-5)与白天(6-23)同图展示，不按天拆分，
/// 用于观察个人「专注生物钟」。桶为空时显示最小占位柱，避免图表塌陷。
///
/// 无参构造：内部从 [FocusProvider.hourDistribution] 现算，便于直接挂进专注页/周报页。
class FocusHourChart extends StatelessWidget {
  const FocusHourChart({super.key});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final hours = context.watch<FocusProvider>().hourDistribution();
    final max = hours.fold(0, (a, b) => a > b ? a : b);
    // 为可读性，仅标注整点偶数小时（0/2/4…22），奇数小时留白避免拥挤。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Symbols.schedule, size: 18, color: ext.accent),
            const SizedBox(width: 6),
            Text(
              '专注时段分布',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onBackground,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 96,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var h = 0; h < 24; h++)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (hours[h] > 0 && max > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text('${(hours[h] / 60).round()}', // 分钟数
                              style: TextStyle(fontSize: 9, color: ext.meta)),
                        ),
                      Container(
                        height: max == 0 ? 4 : (4 + 60 * hours[h] / max),
                        width: 8, // 比周柱状图更窄，24 根并排更紧凑
                        decoration: BoxDecoration(
                          color: ext.accent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        h % 2 == 0 ? '$h' : '', // 仅偶数整点标注
                        style: TextStyle(fontSize: 9, color: ext.meta),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
