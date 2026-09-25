import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/widgets/habit_heatmap.dart';

/// 习惯分享长图的数据快照（与任务分享卡同理：截图时不再依赖 Provider）。
class HabitShareData {
  final String emoji;
  final String title;
  final int current; // 当前连续
  final int longest; // 历史最长
  /// P2-7（v2.9.4 审计）：语义为「累计**达标**天数」（原 `checkInCount`
  /// 已在 v2.9.4 切到达标口径，此处同步更名，避免标签继续写「累计打卡」）。
  final int total;
  final DateTime createdAt;
  final Set<DateTime> checkedDays; // 近 [weeks] 周已打卡集合
  /// P2-7：按达成度分级的强度函数（0..4）；null = 退化为二值着色。
  ///
  /// 此前分享卡不传此回调，量化习惯的 1/8 与 8/8 在长图上完全同色——
  /// App 内四档、导出图二值，属对外产物的口径失真。
  final int Function(DateTime)? levelOf;
  final int weeks;

  const HabitShareData({
    required this.emoji,
    required this.title,
    required this.current,
    required this.longest,
    required this.total,
    required this.createdAt,
    required this.checkedDays,
    required this.weeks,
    this.levelOf,
  });

  factory HabitShareData.from(HabitProvider hp, Habit h) => HabitShareData(
        emoji: h.emoji,
        title: h.title,
        current: hp.currentStreak(h),
        longest: hp.longestStreak(h),
        total: hp.checkInCount(h),
        createdAt: h.createdAt,
        checkedDays: hp.checkedDays(h, 18 * 7),
        // P2-7：与详情页共用 [HabitProvider.progressLevelOn] 单一真源。
        // 布尔习惯传 null 走二值即可（无量化语义，分级无意义）。
        levelOf: h.isQuantified ? (d) => hp.progressLevelOn(h, d) : null,
        weeks: 18,
      );
}

/// 习惯打卡分享长图：品牌头 + 习惯 hero（连续天数）+ 统计 + 单习惯热力图 + 页脚。
/// 内部强制套用 lightTheme / darkTheme，并锁定文字缩放为 1.0，与 App 当前主题解耦。
class HabitShareCard extends StatelessWidget {
  final HabitShareData data;
  final bool dark;
  final double width;

  const HabitShareCard({
    super.key,
    required this.data,
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
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppColors.darkAccent : AppColors.lightPrimary;
    final created = DateFormat('yyyy年M月d日').format(data.createdAt);

    return [
      // 顶部品牌行
      Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accent.withOpacity(isDark ? 0.24 : 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.local_fire_department, size: 21, color: accent),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '有条 · 习惯打卡',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: onBg,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                created,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: ext.meta,
                ),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 18),
      // hero：习惯 + 当前连续
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
        child: Row(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: accent.withOpacity(isDark ? 0.24 : 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Text(data.emoji, style: const TextStyle(fontSize: 34)),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: onBg,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.local_fire_department, size: 18, color: accent),
                      const SizedBox(width: 4),
                      Text(
                        '连续 ${data.current} 天',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: accent,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      // 统计：最长连续 / 累计达标
      // P2-7（v2.9.4 审计）：标签由「累计打卡」改为「累计达标」——
      // v2.9.4 已把 checkInCount 切到达标口径，继续写「打卡」会让量化习惯
      // 的「达标天数」被读成「投入总量」，与 App 内概览卡口径打架。
      Row(
        children: [
          Expanded(child: _Stat(value: '${data.longest}', label: '最长连续')),
          const SizedBox(width: 12),
          Expanded(child: _Stat(value: '${data.total}', label: '累计达标')),
        ],
      ),
      const SizedBox(height: 16),
      // 单习惯热力图
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
              '最近 ${data.weeks} 周打卡',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: onBg,
              ),
            ),
            const SizedBox(height: 12),
            HabitHeatmap(
              checkedDays: data.checkedDays,
              // P2-7：量化习惯按达成度四档着色（与 App 内详情页同源）。
              levelOf: data.levelOf,
              weeks: data.weeks,
              accent: accent,
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      // 页脚
      Container(height: 1, color: ext.track),
      const SizedBox(height: 10),
      Row(
        children: [
          Flexible(
            child: Text(
              '有条 · 极简待办清单',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: ext.meta,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'gitee.com/jason1012/youtiao',
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: ext.meta.withOpacity(0.75),
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    ];
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: onBg,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: ext.meta),
          ),
        ],
      ),
    );
  }
}

/// 打开「分享习惯」面板：实时预览长图 + 浅色/深色切换 + 保存到相册 / 系统分享。
Future<void> showHabitShareSheet(BuildContext context, Habit habit) {
  final hp = context.read<HabitProvider>();
  final data = HabitShareData.from(hp, habit);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _HabitShareSheet(data: data, title: habit.title),
  );
}

class _HabitShareSheet extends StatefulWidget {
  final HabitShareData data;
  final String title;
  const _HabitShareSheet({required this.data, required this.title});

  @override
  State<_HabitShareSheet> createState() => _HabitShareSheetState();
}

class _HabitShareSheetState extends State<_HabitShareSheet> {
  final GlobalKey _cardKey = GlobalKey();
  bool _dark = false;
  bool _busy = false;

  Future<Uint8List> _capture() async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary = _cardKey.currentContext!.findRenderObject()
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData!.buffer.asUint8List();
  }

  String get _fileName =>
      '有条习惯_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.png';

  Future<void> _saveToGallery() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final bytes = await _capture();
      await DataIo.saveImageToGallery(_fileName, bytes);
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('已保存到相册 · Pictures/有条')),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text('保存失败：${e.message ?? e.code}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('生成图片失败：$e')));
    }
  }

  Future<void> _share() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final bytes = await _capture();
      await DataIo.shareImageBytes(bytes, fileName: _fileName);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('分享失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final size = MediaQuery.of(context).size;
    final previewH = (size.height * 0.5).clamp(280.0, 460.0);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * 0.92),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: ext.track,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
              child: Row(
                children: [
                  Text(
                    '分享习惯 · ${widget.title}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: onBg,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Symbols.close),
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        height: previewH,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: _dark
                              ? AppColors.darkBackground
                              : AppColors.lightBackground,
                          borderRadius: BorderRadius.circular(AppColors.cardRadius),
                          border: Border.all(color: ext.track),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: RepaintBoundary(
                            key: _cardKey,
                            child: HabitShareCard(data: widget.data, dark: _dark),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      '卡片外观',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: onBg,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: Text('浅色'),
                          icon: Icon(Symbols.light_mode, size: 18),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text('深色'),
                          icon: Icon(Symbols.dark_mode, size: 18),
                        ),
                      ],
                      selected: {_dark},
                      showSelectedIcon: false,
                      onSelectionChanged: _busy
                          ? null
                          : (s) => setState(() => _dark = s.first),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _saveToGallery,
                      icon: const Icon(Symbols.download, size: 20),
                      label: const Text('保存到相册'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(23),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _share,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Symbols.ios_share, size: 20),
                      label: Text(_busy ? '生成中' : '分享'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(23),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
