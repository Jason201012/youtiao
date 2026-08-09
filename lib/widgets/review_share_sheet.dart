import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/review.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/widgets/review_card.dart';

/// 打开「分享周报」面板：实时预览长图 + 浅/深外观切换 + 保存到相册 / 系统分享。
///
/// [review] 由调用方（ReviewScreen）提前聚合好，截图时不再依赖 Provider，
/// 避免离屏渲染找不到 InheritedWidget，也保证预览数字稳定不跳动。
Future<void> showReviewShareSheet(
  BuildContext context, {
  required WeeklyReview review,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ReviewShareSheet(review: review),
  );
}

class _ReviewShareSheet extends StatefulWidget {
  final WeeklyReview review;
  const _ReviewShareSheet({required this.review});

  @override
  State<_ReviewShareSheet> createState() => _ReviewShareSheetState();
}

class _ReviewShareSheetState extends State<_ReviewShareSheet> {
  final GlobalKey _cardKey = GlobalKey();
  bool _dark = false;
  bool _busy = false;

  /// 把预览中的卡片渲染成 PNG 字节（pixelRatio 3 → 约 1080px 宽）。
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
      '有条周报_${DateFormat('yyyyMMdd').format(widget.review.weekStart)}.png';

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
    final previewH = (size.height * 0.5).clamp(300.0, 460.0);

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
                    '分享周报',
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
                    _preview(previewH),
                    const SizedBox(height: 18),
                    Text('卡片外观',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: onBg,
                        )),
                    const SizedBox(height: 10),
                    _appearance(),
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

  Widget _preview(double height) {
    final ext = appColors(context);
    return Center(
      child: Container(
        height: height,
        width: double.infinity,
        decoration: BoxDecoration(
          color: _dark ? AppColors.darkBackground : AppColors.lightBackground,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
          border: Border.all(color: ext.track),
        ),
        clipBehavior: Clip.antiAlias,
        child: FittedBox(
          fit: BoxFit.contain,
          child: RepaintBoundary(
            key: _cardKey,
            child: ReviewShareCard(review: widget.review, dark: _dark),
          ),
        ),
      ),
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
      selected: {_dark},
      showSelectedIcon: false,
      onSelectionChanged:
          _busy ? null : (s) => setState(() => _dark = s.first),
    );
  }

  Widget _actions() {
    return Padding(
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
    );
  }
}
