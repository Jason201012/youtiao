import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';

/// 专注记录分享卡片（长图，360 逻辑像素宽）。
///
/// 固定 [width]，高度由内容撑开；外层用 RepaintBoundary 截图后按 pixelRatio 3 导出，
/// 得到约 1080px 宽的 PNG。内部强制套用 [lightTheme]/[darkTheme]，与 App 当前主题无关；
/// 同时锁定文字缩放为 1.0，避免系统字体放大把版式撑乱。
class FocusShareCard extends StatelessWidget {
  final List<FocusSession> sessions; // 今日（已按结束时间倒序）
  final bool dark;
  final double width;

  const FocusShareCard({
    super.key,
    required this.sessions,
    this.dark = false,
    this.width = 360,
  });

  @override
  Widget build(BuildContext context) {
    final theme = dark ? darkTheme : lightTheme;
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
                  children: _blocks(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _blocks(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final ext = appColors(context);

    final totalSec = sessions.fold(0, (s, e) => s + e.durationSec);
    final completed = sessions.where((e) => e.completed).length;

    final blocks = <Widget>[
      _Header(date: DateTime.now(), accent: accent),
      const SizedBox(height: 14),
      // 统计：今日专注总时长 + 完成番茄数
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: _Stat(
                value: formatFocusDuration(totalSec),
                label: '今日专注',
                valueColor: onBg,
              ),
            ),
            Container(width: 1, height: 36, color: ext.track),
            Expanded(
              child: _Stat(
                value: '$completed',
                label: '完成番茄',
                valueColor: accent,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      // 记录明细
      if (sessions.isEmpty)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 22),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
          ),
          child: Center(
            child: Text(
              '今天还没有专注记录',
              style: TextStyle(fontSize: 13, color: ext.meta),
            ),
          ),
        )
      else
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '专注明细',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: onBg,
                ),
              ),
              const SizedBox(height: 12),
              for (final s in sessions)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      _sharePhaseIcon(s, accent, ext),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _sharePhaseLabel(s),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: onBg,
                          ),
                        ),
                      ),
                      Text(
                        formatFocusDuration(s.durationSec),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: onBg,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        TimeOfDay.fromDateTime(s.endedAt)
                            .format(context),
                        style: TextStyle(fontSize: 12, color: ext.meta),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      const _Footer(),
    ];
    return blocks;
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final Color valueColor;
  const _Stat({
    required this.value,
    required this.label,
    required this.valueColor,
  });
  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: valueColor,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: appColors(context).meta,
            ),
          ),
        ],
      );
}

/// 顶部品牌行：图标 + 有条 · 专注记录 + 日期。
class _Header extends StatelessWidget {
  final DateTime date;
  final Color accent;
  const _Header({required this.date, required this.accent});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    const wk = ['一', '二', '三', '四', '五', '六', '日'];
    final text =
        '${DateFormat('yyyy年M月d日').format(date)} · 周${wk[date.weekday - 1]}';
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: accent.withOpacity(0.12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(Symbols.timer, size: 21, color: accent),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '有条 · 专注记录',
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

/// 分享卡明细行图标：专注完成🔥 / 专注片段⏱ / 休息☕。
Widget _sharePhaseIcon(
    FocusSession s, Color accent, AppColorsExt ext) {
  switch (s.phase) {
    case FocusPhase.focus:
      return Icon(
        s.completed ? Symbols.local_fire_department : Symbols.timer,
        size: 18,
        color: s.completed ? accent : ext.meta,
      );
    case FocusPhase.shortBreak:
    case FocusPhase.longBreak:
      return Icon(Symbols.local_cafe, size: 18, color: ext.meta);
  }
}

/// 分享卡明细行文案：按阶段区分。
String _sharePhaseLabel(FocusSession s) {
  switch (s.phase) {
    case FocusPhase.focus:
      return s.completed ? '完成一个番茄' : '专注片段';
    case FocusPhase.shortBreak:
    case FocusPhase.longBreak:
      return '休息一段';
  }
}
