import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/widgets/category_progress.dart';
import 'package:todolist/widgets/priority_distribution.dart';
import 'package:todolist/widgets/stat_card.dart';
import 'package:todolist/widgets/week_trend.dart';

/// 分享卡片的模块开关 + 外观选项。
///
/// 每个 bool 对应长图中的一个板块，用户在分享面板里勾选；
/// [dark] 控制卡片自身的明暗（与 App 当前主题解耦，方便发到深色聊天背景）；
/// [hideTitles] 打开后看板明细只显示数量，不泄露任务标题（隐私优先）。
class ShareOptions {
  final bool ring; // 完成率概览
  final bool stats; // 数据统计（总任务/已完成/逾期/进行中）
  final bool priority; // 优先级分布
  final bool category; // 分类进度
  final bool trend; // 近 7 日完成趋势
  final bool kanban; // 看板三列明细
  final bool home; // 首页日期分区（逾期/今天/未来/每天/已完成）
  final bool dark; // 深色卡片
  final bool hideTitles; // 隐藏任务标题

  const ShareOptions({
    this.ring = true,
    this.stats = true,
    this.priority = true,
    this.category = true,
    this.trend = true,
    this.kanban = false,
    this.home = false,
    this.dark = false,
    this.hideTitles = false,
  });

  /// 至少要留一个板块，否则生成的图是空的。
  bool get hasModule =>
      ring || stats || priority || category || trend || kanban || home;

  ShareOptions copyWith({
    bool? ring,
    bool? stats,
    bool? priority,
    bool? category,
    bool? trend,
    bool? kanban,
    bool? home,
    bool? dark,
    bool? hideTitles,
  }) =>
      ShareOptions(
        ring: ring ?? this.ring,
        stats: stats ?? this.stats,
        priority: priority ?? this.priority,
        category: category ?? this.category,
        trend: trend ?? this.trend,
        kanban: kanban ?? this.kanban,
        home: home ?? this.home,
        dark: dark ?? this.dark,
        hideTitles: hideTitles ?? this.hideTitles,
      );
}

/// 分享卡片的数据快照。
///
/// 单独抽一层是为了：截图时不再依赖 Provider（避免离屏渲染时找不到
/// InheritedWidget），并且数据在勾选面板中切换选项时保持稳定不跳动。
class ShareCardData {
  final DateTime date;
  final double rate;
  final int total;
  final int completed;
  final int overdue;
  final int inProgress;
  final Map<Priority, int> priorityCounts;
  final Map<Category, double> categoryProgress;
  final List<int> weekValues;
  final List<DateTime> weekDates;
  final List<int> lastWeekValues;
  final Map<TaskStatus, List<String>> kanbanTitles;
  final Map<TaskStatus, int> kanbanCounts;
  final Map<String, int> homeCounts; // 首页分区计数：overdue/today/future/daily/done
  final Map<String, List<Task>> homeTasks; // 首页分区任务明细：逾期/今天/未来/每天/已完成

  const ShareCardData({
    required this.date,
    required this.rate,
    required this.total,
    required this.completed,
    required this.overdue,
    required this.inProgress,
    required this.priorityCounts,
    required this.categoryProgress,
    required this.weekValues,
    required this.weekDates,
    required this.lastWeekValues,
    required this.kanbanTitles,
    required this.kanbanCounts,
    required this.homeCounts,
    required this.homeTasks,
  });

  /// 从 TaskProvider 取一份即时快照。
  factory ShareCardData.from(TaskProvider p) {
    final groups = p.kanbanGroups;
    return ShareCardData(
      date: DateTime.now(),
      rate: p.completionRate,
      total: p.total,
      completed: p.completed,
      overdue: p.overdue,
      inProgress: p.inProgress,
      priorityCounts: p.priorityCounts,
      categoryProgress: p.categoryProgress(),
      weekValues: p.weekTrend,
      weekDates: p.weekTrendDates,
      lastWeekValues: p.lastWeekTrend,
      kanbanTitles: {
        for (final s in TaskStatus.values)
          s: (groups[s] ?? const <Task>[]).map((t) => t.title).toList(),
      },
      kanbanCounts: {
        for (final s in TaskStatus.values) s: (groups[s] ?? const <Task>[]).length,
      },
      homeCounts: p.sectionCounts,
      homeTasks: p.homeTasks,
    );
  }
}

/// 看板分享长图卡片。
///
/// 固定 [width] 逻辑像素（默认 360），高度由内容撑开；外层用 RepaintBoundary
/// 截图后按 pixelRatio 3 导出，得到约 1080px 宽的 PNG。
/// 内部强制套用 [lightTheme]/[darkTheme]，与 App 当前主题无关；
/// 同时锁定文字缩放为 1.0，避免系统字体放大把版式撑乱。
class ShareCard extends StatelessWidget {
  final ShareCardData data;
  final ShareOptions options;
  final double width;

  const ShareCard({
    super.key,
    required this.data,
    required this.options,
    this.width = 360,
  });

  @override
  Widget build(BuildContext context) {
    final theme = options.dark ? darkTheme : lightTheme;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: Theme(
        data: theme,
        child: Builder(
          builder: (context) => Material(
            color: theme.colorScheme.background,
            child: SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _buildBlocks(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBlocks(BuildContext context) {
    final blocks = <Widget>[_Header(date: data.date, home: options.home)];

    void add(Widget w) {
      blocks.add(const SizedBox(height: 14));
      blocks.add(w);
    }

    if (options.ring) add(_RingBlock(data: data));
    if (options.stats) add(_StatsBlock(data: data));
    if (options.priority) {
      add(_Section(child: PriorityDistribution(counts: data.priorityCounts)));
    }
    if (options.category) {
      add(_Section(child: CategoryProgress(progress: data.categoryProgress)));
    }
    if (options.trend) {
      add(_Section(
        child: WeekTrend(
          values: data.weekValues,
          dates: data.weekDates,
          lastWeekValues: data.lastWeekValues,
        ),
      ));
    }
    if (options.kanban) {
      add(_KanbanBlock(data: data, hideTitles: options.hideTitles));
    }
    if (options.home) {
      add(_HomeBlock(data: data, hideTitles: options.hideTitles));
    }

    blocks.add(const SizedBox(height: 16));
    blocks.add(const _Footer());
    return blocks;
  }
}

/// 顶部品牌行：图标 + 有条 + 日期。
class _Header extends StatelessWidget {
  final DateTime date;
  final bool home;
  const _Header({required this.date, this.home = false});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    // 不用 EEEE：项目未调 initializeDateFormatting，中文星期自行映射，零依赖零风险。
    const wk = ['一', '二', '三', '四', '五', '六', '日'];
    final text =
        '${DateFormat('yyyy年M月d日').format(date)} · 周${wk[date.weekday - 1]}';

    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: accent.withOpacity(isDark ? 0.24 : 0.12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(Symbols.task_alt, size: 21, color: accent),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              home ? '有条 · 我的清单' : '有条 · 任务看板',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: onBg,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              text,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: ext.meta,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 统一的板块外壳：surface 底 + 圆角 14 + 内边距 16。
class _Section extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _Section({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 6),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: child,
    );
  }
}

/// 完成率大环 + 完成数。
class _RingBlock extends StatelessWidget {
  final ShareCardData data;
  const _RingBlock({required this.data});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;

    return _Section(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          _BigRing(value: data.rate, color: accent, track: ext.track),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '已完成',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: ext.meta,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${data.completed} / ${data.total}',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: accent,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '任务完成率',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: ext.meta,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 大号完成率圆环（直径 104，描边 11），比看板页的 68 环更适合长图主视觉。
class _BigRing extends StatelessWidget {
  final double value;
  final Color color;
  final Color track;
  const _BigRing({
    required this.value,
    required this.color,
    required this.track,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 104,
      height: 104,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(104, 104),
            painter: _BigRingPainter(value: value, color: color, track: track),
          ),
          Text(
            '${(value * 100).round()}%',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _BigRingPainter extends CustomPainter {
  final double value;
  final Color color;
  final Color track;
  const _BigRingPainter({
    required this.value,
    required this.color,
    required this.track,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 11.0;
    final center = size.center(Offset.zero);
    final radius = (size.width - stroke) / 2;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      value.clamp(0, 1) * 2 * pi,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _BigRingPainter old) =>
      old.value != value || old.color != color || old.track != track;
}

/// 2×2 统计网格：总任务 / 已完成 / 逾期 / 进行中。
class _StatsBlock extends StatelessWidget {
  final ShareCardData data;
  const _StatsBlock({required this.data});

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final high = isDark ? AppColors.darkHigh : AppColors.lightHigh;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatCard(
                value: '${data.total}',
                label: '总任务',
                valueColor: onBg,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatCard(
                value: '${data.completed}',
                label: '已完成',
                valueColor: accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatCard(
                value: '${data.overdue}',
                label: '逾期',
                valueColor: high,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatCard(
                value: '${data.inProgress}',
                label: '进行中',
                valueColor: accent,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 看板三列明细：待办 / 进行中 / 已完成，每列最多列 4 条标题。
class _KanbanBlock extends StatelessWidget {
  final ShareCardData data;
  final bool hideTitles;
  const _KanbanBlock({required this.data, required this.hideTitles});

  static const _cols = [
    (TaskStatus.todo, '待办'),
    (TaskStatus.doing, '进行中'),
    (TaskStatus.done, '已完成'),
  ];

  Color _colColor(BuildContext context, TaskStatus s) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (s == TaskStatus.doing) {
      return isDark ? const Color(0xFF80C0FF) : const Color(0xFF378ADD);
    }
    if (s == TaskStatus.done) return const Color(0xFF0F6E56);
    return appColors(context).meta;
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;

    return _Section(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '看板',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: onBg,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (status, title) in _cols) ...[
                Expanded(
                  child: _KanbanColumn(
                    title: title,
                    color: _colColor(context, status),
                    count: data.kanbanCounts[status] ?? 0,
                    titles: hideTitles
                        ? const []
                        : (data.kanbanTitles[status] ?? const []),
                    meta: ext.meta,
                    onBg: onBg,
                  ),
                ),
                if (status != TaskStatus.done) const SizedBox(width: 10),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _KanbanColumn extends StatelessWidget {
  final String title;
  final Color color;
  final int count;
  final List<String> titles;
  final Color meta;
  final Color onBg;
  const _KanbanColumn({
    required this.title,
    required this.color,
    required this.count,
    required this.titles,
    required this.meta,
    required this.onBg,
  });

  static const _maxItems = 4;

  @override
  Widget build(BuildContext context) {
    final shown = titles.take(_maxItems).toList();
    final rest = titles.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: onBg,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: meta,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          Text(
            titles.isEmpty && count > 0 ? '· · ·' : '—',
            style: TextStyle(fontSize: 11, color: meta),
          )
        else
          for (final t in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  t,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.25,
                    fontWeight: FontWeight.w500,
                    color: onBg,
                  ),
                ),
              ),
            ),
        if (rest > 0)
          Text(
            '+$rest',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: meta,
            ),
          ),
      ],
    );
  }
}

/// 首页日期分区明细：逾期 / 今天 / 未来 / 每天 / 已完成，每段列出真实事件 / 任务。
class _HomeBlock extends StatelessWidget {
  final ShareCardData data;
  final bool hideTitles;
  const _HomeBlock({required this.data, this.hideTitles = false});

  static const List<(String, String)> _sections = [
    ('overdue', '逾期'),
    ('today', '今天'),
    ('future', '未来'),
    ('daily', '每天'),
    ('done', '已完成'),
  ];

  Color _color(BuildContext context, String key) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ext = appColors(context);
    switch (key) {
      case 'overdue':
        return scheme.error;
      case 'today':
        return isDark ? AppColors.darkAccent : AppColors.lightPrimary;
      case 'future':
        return ext.meta;
      case 'daily':
        return isDark ? const Color(0xFF80C0FF) : const Color(0xFF378ADD);
      case 'done':
      default:
        return const Color(0xFF0F6E56);
    }
  }

  /// 每行次要信息：每日提醒显示「每天 HH:mm」，已完成显示「完成于 M月d日」，
  /// 其余显示相对截止时间（今天 / 明天 / M月d日 …）。
  String _meta(Task t, String key) {
    if (key == 'daily') {
      if (t.dailyReminderMinute != null) {
        final hh = t.dailyReminderMinute! ~/ 60;
        final mm = t.dailyReminderMinute! % 60;
        return '每天 ${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
      }
      return '每天';
    }
    if (key == 'done') {
      if (t.completedAt != null) {
        return '完成于 ${t.completedAt!.month}月${t.completedAt!.day}日';
      }
      return _dueLabel(t.dueDate);
    }
    return _dueLabel(t.dueDate);
  }

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;

    return _Section(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '日期分区',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: onBg,
            ),
          ),
          const SizedBox(height: 12),
          for (final (key, label) in _sections) ...[
            _HomeSection(
              label: label,
              color: _color(context, key),
              tasks: data.homeTasks[key] ?? const [],
              metaOf: (t) => _meta(t, key),
              hideTitles: hideTitles,
            ),
          ],
        ],
      ),
    );
  }
}

/// 单个日期分区：标题（彩色圆点 + 名称 + 数量）+ 该段下的具体任务列表。
class _HomeSection extends StatelessWidget {
  final String label;
  final Color color;
  final List<Task> tasks;
  final String Function(Task) metaOf;
  final bool hideTitles;
  const _HomeSection({
    required this.label,
    required this.color,
    required this.tasks,
    required this.metaOf,
    this.hideTitles = false,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 8, height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${tasks.length}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ext.meta,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 15, bottom: 10),
            child: Text('暂无任务',
                style: TextStyle(fontSize: 12, color: ext.meta)),
          )
        else
          for (final t in tasks)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: ext.track.withOpacity(0.35),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 3,
                    height: 30,
                    decoration: BoxDecoration(
                      color: t.done
                          ? ext.meta
                          : (isDark
                              ? t.priority.darkColor()
                              : t.priority.lightColor()),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hideTitles ? '· · ·' : t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: t.done ? ext.meta : onBg,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${t.category.label} · ${metaOf(t)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: ext.meta,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 10),
      ],
    );
  }
}

/// 相对截止时间文案（与 task_row.dart 的 _dueLabel 口径一致，但本文件内独立定义，
/// 避免依赖首页私有的划线函数）。
String _dueLabel(DateTime? due) {
  if (due == null) return '无截止';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(due.year, due.month, due.day);
  final diff = d.difference(today).inDays;
  final time =
      ' ${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}';
  if (diff == 0) return '今天$time';
  if (diff == 1) return '明天$time';
  if (diff == -1) return '昨天$time';
  if (diff < 0) return '已逾期$time';
  return '${due.month}月${due.day}日$time';
}

/// 底部署名：App 名 + 开源地址。
class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 1, color: ext.track),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              '有条 · 极简待办清单',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: ext.meta,
              ),
            ),
            const Spacer(),
            Text(
              'gitee.com/jason1012/youtiao',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: ext.meta.withOpacity(0.75),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
