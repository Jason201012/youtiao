import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/widgets/share_card.dart';

/// 打开「分享看板」面板：实时预览长图 + 勾选包含的板块 + 保存到相册 / 系统分享。
Future<void> showShareSheet(BuildContext context, {bool home = false}) {
  // 进面板时取一次数据快照，避免勾选过程中数字跳动。
  final data = ShareCardData.from(context.read<TaskProvider>());
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ShareSheet(data: data, home: home),
  );
}

class _ShareSheet extends StatefulWidget {
  final ShareCardData data;
  final bool home;
  const _ShareSheet({required this.data, this.home = false});

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final GlobalKey _cardKey = GlobalKey();
  ShareOptions _opt = const ShareOptions();

  @override
  void initState() {
    super.initState();
    // 首页分享只含「日期分区」（逾期/今天/未来/每天/已完成），
    // 不挂载看板页的分析模块（完成率/统计/优先级/分类/趋势/看板）。
    // 看板分享保持默认全套板块。
    _opt = widget.home
        ? const ShareOptions(
            ring: false,
            stats: false,
            priority: false,
            category: false,
            trend: false,
            kanban: false,
            home: true,
          )
        : const ShareOptions();
  }
  bool _busy = false;

  /// 把预览中的卡片渲染成 PNG 字节。
  ///
  /// 预览本身就在屏幕上（RepaintBoundary 已绘制），因此可直接 toImage；
  /// pixelRatio 3 → 360 逻辑像素宽的卡片导出为约 1080px 宽的图片。
  Future<Uint8List> _capture() async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        _cardKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData!.buffer.asUint8List();
  }

  String get _fileName =>
      '${widget.home ? '有条清单' : '有条看板'}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.png';

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
    final previewH = (size.height * 0.36).clamp(220.0, 340.0);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * 0.92),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽条
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: ext.track,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题行
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
              child: Row(
                children: [
                  Text(
                    widget.home ? '分享首页' : '分享看板',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: onBg,
                    ),
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
                    _preview(previewH, ext),
                    const SizedBox(height: 18),
                    _label('包含内容', onBg),
                    const SizedBox(height: 10),
                    _moduleChips(),
                    const SizedBox(height: 18),
                    _label('卡片外观', onBg),
                    const SizedBox(height: 10),
                    _appearance(),
                    if (!widget.home && _opt.kanban) ...[
                      const SizedBox(height: 6),
                      _hideTitlesSwitch(ext, onBg),
                    ],
                  ],
                ),
              ),
            ),
            _actions(),
          ],
        ),
      ),
    );
  }

  /// 长图实时预览：整张卡片等比缩放塞进预览框，勾选变化即时反映。
  /// 截图直接取这个 RepaintBoundary —— 它在屏幕上真实绘制过，最稳妥。
  Widget _preview(double height, AppColorsExt ext) {
    return Center(
      child: Container(
        height: height,
        width: double.infinity,
        decoration: BoxDecoration(
          color: _opt.dark
              ? AppColors.darkBackground
              : AppColors.lightBackground,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
          border: Border.all(color: ext.track),
        ),
        clipBehavior: Clip.antiAlias,
        child: _opt.hasModule
            ? FittedBox(
                fit: BoxFit.contain,
                child: RepaintBoundary(
                  key: _cardKey,
                  child: ShareCard(data: widget.data, options: _opt),
                ),
              )
            : Center(
                child: Text(
                  '至少选择一个板块',
                  style: TextStyle(fontSize: 13, color: ext.meta),
                ),
              ),
      ),
    );
  }

  Widget _label(String text, Color color) => Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      );

  Widget _moduleChips() {
    final items = <(String, bool, ShareOptions Function(bool))>[
      if (widget.home)
        // 首页分享：仅「日期分区」一个板块
        ('日期分区', _opt.home, (v) => _opt.copyWith(home: v))
      else ...[
        // 看板分享：全套分析模块
        ('完成率', _opt.ring, (v) => _opt.copyWith(ring: v)),
        ('数据统计', _opt.stats, (v) => _opt.copyWith(stats: v)),
        ('优先级', _opt.priority, (v) => _opt.copyWith(priority: v)),
        ('分类进度', _opt.category, (v) => _opt.copyWith(category: v)),
        ('近 7 日趋势', _opt.trend, (v) => _opt.copyWith(trend: v)),
        ('看板明细', _opt.kanban, (v) => _opt.copyWith(kanban: v)),
      ],
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, selected, apply) in items)
          FilterChip(
            label: Text(label),
            selected: selected,
            showCheckmark: true,
            onSelected: _busy ? null : (v) => setState(() => _opt = apply(v)),
          ),
      ],
    );
  }

  Widget _appearance() {
    return SegmentedButton<bool>(
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
      selected: {_opt.dark},
      showSelectedIcon: false,
      onSelectionChanged: _busy
          ? null
          : (s) => setState(() => _opt = _opt.copyWith(dark: s.first)),
    );
  }

  Widget _hideTitlesSwitch(AppColorsExt ext, Color onBg) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: _opt.hideTitles,
      onChanged:
          _busy ? null : (v) => setState(() => _opt = _opt.copyWith(hideTitles: v)),
      title: Text(
        '隐藏任务标题',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: onBg),
      ),
      subtitle: Text(
        '看板明细只显示数量，不暴露具体内容',
        style: TextStyle(fontSize: 12, color: ext.meta),
      ),
    );
  }

  Widget _actions() {
    final enabled = _opt.hasModule && !_busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: enabled ? _saveToGallery : null,
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
              onPressed: enabled ? _share : null,
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
    );
  }
}
