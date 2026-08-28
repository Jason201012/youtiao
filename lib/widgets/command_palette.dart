import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';

/// P1-9 命令面板：本地路由跳转（不涉及任何网络）。
/// Ctrl/Cmd+P 唤起，输入关键字过滤「首页/看板/日历/专注/习惯/设置」并回车跳转。
class CommandPalette extends StatefulWidget {
  /// 当前所在 Tab，用于高亮「当前页」。
  final int currentIndex;

  /// 选中某目的地后的回调（宿主 Scaffold 据此切 Tab）。
  final void Function(int) onPick;

  const CommandPalette({
    super.key,
    required this.currentIndex,
    required this.onPick,
  });

  /// 弹出命令面板（模态底部抽屉）。
  static Future<void> show(
    BuildContext context, {
    required int currentIndex,
    required void Function(int) onPick,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommandPalette(
        currentIndex: currentIndex,
        onPick: onPick,
      ),
    );
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final TextEditingController _ctl = TextEditingController();
  final FocusNode _focus = FocusNode();
  late List<_Dest> _filtered;

  static const List<_Dest> _all = [
    _Dest(0, '首页', Symbols.home, '查看今日与待办'),
    _Dest(1, '看板', Symbols.view_kanban, '按状态看板视图'),
    _Dest(2, '日历', Symbols.calendar_month, '按日期浏览'),
    _Dest(3, '专注', Symbols.timer, '番茄钟专注'),
    _Dest(4, '习惯', Symbols.loop, '习惯打卡'),
    _Dest(5, '设置', Symbols.settings, '偏好与备份'),
  ];

  @override
  void initState() {
    super.initState();
    _filtered = List.of(_all);
    _ctl.addListener(_onQuery);
    // 抽屉弹出即聚焦过滤输入框，键入即筛。
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _onQuery() {
    final q = _ctl.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? List.of(_all)
          : _all
              .where((d) =>
                  d.title.toLowerCase().contains(q) ||
                  d.hint.toLowerCase().contains(q))
              .toList();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _pick(_Dest d) {
    widget.onPick(d.index);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    final onSurface = scheme.onSurface;
    return Padding(
      // 贴住键盘上沿，保证输入区始终可见。
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: ext.track,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppColors.pagePadX),
                child: TextField(
                  controller: _ctl,
                  focusNode: _focus,
                  autofocus: true,
                  style: TextStyle(fontSize: 16, color: onSurface),
                  decoration: InputDecoration(
                    hintText: '跳转到…',
                    hintStyle: TextStyle(fontSize: 16, color: ext.meta),
                    prefixIcon: Icon(Symbols.search, color: ext.meta, size: 20),
                    filled: true,
                    fillColor: ext.chip,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppColors.cardRadius),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    isCollapsed: true,
                  ),
                  onSubmitted: (_) {
                    if (_filtered.isNotEmpty) _pick(_filtered.first);
                  },
                ),
              ),
              const SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                    AppColors.pagePadX, 4, AppColors.pagePadX, 16),
                itemCount: _filtered.length,
                itemBuilder: (context, i) {
                  final d = _filtered[i];
                  final active = d.index == widget.currentIndex;
                  return ListTile(
                    leading: Icon(d.icon,
                        color: active ? scheme.primary : ext.meta, size: 22),
                    title: Text(
                      d.title,
                      style: TextStyle(
                        fontWeight: active ? FontWeight.bold : FontWeight.w500,
                        color: onSurface,
                      ),
                    ),
                    subtitle:
                        Text(d.hint, style: TextStyle(color: ext.meta, fontSize: 12)),
                    trailing: active
                        ? Icon(Symbols.check, color: scheme.primary, size: 18)
                        : null,
                    onTap: () => _pick(d),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppColors.cardRadius),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 命令面板的单个目的地（Tab）。
class _Dest {
  final int index;
  final String title;
  final IconData icon;
  final String hint;
  const _Dest(this.index, this.title, this.icon, this.hint);
}
