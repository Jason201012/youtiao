import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/widgets/focus_share_card.dart';

/// 打开「分享专注记录」面板：实时预览长图 + 浅/深色切换 + 保存到相册 / 系统分享。
Future<void> showFocusShareSheet(BuildContext context) {
  // 进面板时取一次数据快照（今日记录），避免后续变动导致预览跳动。
  final today = DateTime.now();
  final t = DateTime(today.year, today.month, today.day);
  final sessions = context
      .read<FocusProvider>()
      .sessions
      .where((s) =>
          DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day) == t)
      .toList();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _FocusShareSheet(sessions: sessions),
  );
}

class _FocusShareSheet extends StatefulWidget {
  final List<FocusSession> sessions;
  const _FocusShareSheet({required this.sessions});

  @override
  State<_FocusShareSheet> createState() => _FocusShareSheetState();
}

class _FocusShareSheetState extends State<_FocusShareSheet> {
  final GlobalKey _cardKey = GlobalKey();
  bool _dark = false;
  bool _busy = false;

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
      '有条专注_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.png';

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
    final previewH = (size.height * 0.42).clamp(240.0, 360.0);

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
                    '分享专注记录',
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
                            child: FocusShareCard(
                              sessions: widget.sessions,
                              dark: _dark,
                            ),
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
