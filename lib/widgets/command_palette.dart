import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/services/palette_command.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/theme/tokens.dart';

/// P1-9 命令面板：本地路由跳转（不涉及任何网络）。
/// Ctrl/Cmd+P 唤起，输入关键字过滤「首页/看板/日历/专注/习惯/设置」并回车跳转。
/// P1-6 扩充：以 `/` 开头时切换为命令模式（见 [PaletteCommand]）。
class CommandPalette extends StatefulWidget {
  /// 当前所在 Tab，用于高亮「当前页」。
  final int currentIndex;

  /// 选中某目的地后的回调（宿主 Scaffold 据此切 Tab）。
  final void Function(int) onPick;

  /// P1-6：`/done` 的落地回调。选中态在 HomeScreen 内部、面板拿不到，
  /// 故由宿主注入；返回实际完成条数，提示文案也由宿主负责弹出。
  final int Function()? onCompleteSelected;

  const CommandPalette({
    super.key,
    required this.currentIndex,
    required this.onPick,
    this.onCompleteSelected,
  });

  /// 弹出命令面板（模态底部抽屉）。
  static Future<void> show(
    BuildContext context, {
    required int currentIndex,
    required void Function(int) onPick,
    int Function()? onCompleteSelected,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommandPalette(
        currentIndex: currentIndex,
        onPick: onPick,
        onCompleteSelected: onCompleteSelected,
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

  /// P1-6：当前输入解析出的命令；null 表示处于普通搜索模式。
  PaletteCommand? _cmd;

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
    final raw = _ctl.text;
    final q = raw.trim().toLowerCase();
    setState(() {
      // P1-6：以 `/` 开头进入命令模式。仅一个斜杠时仍算搜索，避免列表瞬间清空。
      _cmd = PaletteCommand.parse(raw);
      _filtered = q.isEmpty
          ? List.of(_all)
          : _all
              .where((d) =>
                  d.title.toLowerCase().contains(q) ||
                  d.hint.toLowerCase().contains(q))
              .toList();
    });
  }

  /// P1-6：执行当前命令。返回 true 表示已消费这次提交（面板随即关闭），
  /// false 表示不是可执行命令，调用方应回落到「选中第一个搜索结果」。
  bool _runCommand() {
    final c = _cmd;
    if (c == null || !c.isKnown) return false;
    if (c.isDone) {
      // 兜底：宿主没注入回调时安静地什么都不做，不留死链。
      widget.onCompleteSelected?.call();
      Navigator.pop(context);
      return true;
    }
    final i = c.gotoIndex;
    if (i != null) {
      widget.onPick(i);
      Navigator.pop(context);
      return true;
    }
    return false;
  }

  /// P1-6：命令模式下的结果行。未知命令也占一行并给出可用命令清单，
  /// 避免用户敲完回车「毫无反应」而困惑。
  Widget _commandTile(PaletteCommand c, ColorScheme scheme, AppColorsExt ext,
      Color onSurface) {
    final known = c.isKnown;
    final IconData icon;
    if (c.isDone) {
      icon = Symbols.check_circle;
    } else if (c.gotoIndex != null) {
      icon = Symbols.arrow_forward;
    } else {
      icon = Symbols.help;
    }
    final title = known ? c.label : '未知命令 /${c.name}';
    final hint = c.isDone
        ? (widget.onCompleteSelected == null
            ? '当前不可用'
            : '把首页已勾选的任务标记为完成')
        : (c.gotoIndex != null
            ? '跳转到「${c.label}」'
            : '可用：/done /today /board /calendar /focus /habit /settings');
    return ListTile(
      leading: Icon(icon,
          color: known ? scheme.primary : ext.meta, size: 22),
      title: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w600, color: onSurface),
      ),
      subtitle: Text(hint, style: TextStyle(color: ext.meta, fontSize: 12)),
      onTap: known ? _runCommand : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
    );
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
                    // P1-6：命令模式优先；不是命令才回落到搜索结果。
                    if (_runCommand()) return;
                    if (_filtered.isNotEmpty) _pick(_filtered.first);
                  },
                ),
              ),
              const SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                    AppColors.pagePadX, 4, AppColors.pagePadX, 16),
                // P1-6：命令模式下只显示一行命令结果。
                itemCount: _cmd != null ? 1 : _filtered.length,
                itemBuilder: (context, i) {
                  final c = _cmd;
                  if (c != null) return _commandTile(c, scheme, ext, onSurface);
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
