import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/app_theme.dart';

/// 把秒数格式化为「分钟」标签：避免不足 30 秒四舍五入显示为 0 的视觉毛刺
/// （有专注却标 0 分钟会让人误以为没数据）。
String _formatMinutes(int secs) {
  final mins = (secs / 60).round();
  return (mins == 0 ? 1 : mins).toString();
}

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
                          child: Text(_formatMinutes(hours[h]), // 分钟数
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

/// 专注时段「日历块状映射」（P1-7）：把某一天的专注 / 休息会话按时段渲染为纵向色条。
///
/// - 左侧纵向时间轴 07:00–24:00；右侧色条按 [FocusSession.startedAt]/[endedAt] 定位；
/// - 专注 = 主题色、休息 = 浅色；点击色块弹出关联任务名与时长；
/// - 跨午夜的会话按日切段并夹取在 [day 07:00, day 24:00] 区间内；
/// - 纯本地渲染，无新依赖、无网络。
class FocusDayTimeline extends StatelessWidget {
  final DateTime day;
  final FocusProvider focus;
  final double height;
  const FocusDayTimeline({
    super.key,
    required this.day,
    required this.focus,
    this.height = 520,
  });

  static const int _startHour = 7;
  static const int _endHour = 24;

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final track = ext.track;
    final dayStart = DateTime(day.year, day.month, day.day, _startHour);
    final dayEnd = DateTime(day.year, day.month, day.day, _endHour);
    final spanMin = (_endHour - _startHour) * 60; // 17h

    double toY(DateTime t) {
      // 夹取到当天时间轴区间，避免跨午夜会话溢出。
      final clamped = t.isBefore(dayStart)
          ? dayStart
          : (t.isAfter(dayEnd) ? dayEnd : t);
      final mins = (clamped.hour - _startHour) * 60 + clamped.minute;
      return mins / spanMin * height;
    }

    final isBreak = (FocusPhase p) => p != FocusPhase.focus;

    final sessions = focus.sessionsOn(day).where((s) {
      // 仅展示与当天时间轴有交集的会话。
      return !s.endedAt.isBefore(dayStart) && !s.startedAt.isAfter(dayEnd);
    }).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧时间轴刻度
          SizedBox(
            width: 42,
            child: Stack(
              children: [
                for (var h = _startHour; h <= _endHour; h++)
                  Positioned(
                    top: toY(DateTime(day.year, day.month, day.day, h)) - 7,
                    left: 0,
                    right: 0,
                    child: Text(
                      h == _endHour ? '24:00' : '$h:00',
                      style: TextStyle(fontSize: 10, color: ext.meta),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // 右侧色条区
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: track, width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: sessions.isEmpty
                  ? Center(
                      child: Text('当天无专注记录',
                          style: TextStyle(fontSize: 12, color: ext.meta)),
                    )
                  : Stack(
                      children: [
                        // 整点网格线
                        for (var h = _startHour; h <= _endHour; h++)
                          Positioned(
                            top: toY(DateTime(day.year, day.month, day.day, h)),
                            left: 0,
                            right: 0,
                            child:
                                Container(height: 1, color: track.withOpacity(0.5)),
                          ),
                        // 会话色块
                        for (final s in sessions)
                          _buildBlock(context, s, toY, isBreak, ext),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlock(
    BuildContext context,
    FocusSession s,
    double Function(DateTime) toY,
    bool Function(FocusPhase) isBreak,
    dynamic ext,
  ) {
    final top = toY(s.startedAt);
    final bottom = toY(s.endedAt);
    final h = (bottom - top).clamp(6.0, double.infinity);
    final breakPhase = isBreak(s.phase);
    final color = breakPhase ? ext.meta.withOpacity(0.35) : ext.accent;
    return Positioned(
      top: top,
      left: 8,
      right: 8,
      height: h,
      child: GestureDetector(
        onTap: () => _showSession(context, s, breakPhase, ext),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_hm(s.startedAt)}–${_hm(s.endedAt)}',
                style: const TextStyle(fontSize: 10, color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
              if (h > 30)
                Text(
                  s.taskTitle ?? '独立专注',
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSession(BuildContext context, FocusSession s, bool breakPhase, dynamic ext) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(breakPhase ? '休息时段' : '专注时段'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('任务：${s.taskTitle ?? '独立专注'}'),
            const SizedBox(height: 6),
            Text('时间：${_hm(s.startedAt)} – ${_hm(s.endedAt)}'),
            const SizedBox(height: 6),
            Text('时长：${formatFocusDuration(s.durationSec)}'),
            if (!s.completed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('（提前结束）', style: TextStyle(color: ext.meta)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
