import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/services/app_nav.dart';
import 'package:todolist/widgets/command_palette.dart';
import 'package:todolist/widgets/quick_entry_sheet.dart';
import 'package:todolist/widgets/export_sheet.dart';
import 'package:todolist/widgets/backup_sheet.dart';
import 'package:todolist/screens/trash_screen.dart';
import 'package:todolist/screens/tag_manage_screen.dart';
import 'package:todolist/theme/app_theme.dart';

/// U4：命令面板的移动端顶栏入口。
///
/// 此前 CommandPalette 唯一调用点在 `_isDesktopShortcutsEnabled`（Windows/Linux/macOS）
/// 分支内——Android APK 主要用户按不出 Ctrl+P，12 个命令与中文别名全部不可达。
/// 这里给六个主 Tab 的 [TopAppBar] 提供一个统一的动作按钮：点开面板，
/// 目的地点击经 [AppNav.jumpToTab] 切 Tab（MainScaffold 注册），
/// `/new` `/trash` 等动作命令也在本组件内完成——页面上零重复、零反向依赖。
///
/// 注：[currentIndex] 为当前页所在 Tab 下标（0=首页 … 5=设置），用于高亮「当前页」。
class CommandPaletteButton extends StatelessWidget {
  final int currentIndex;
  const CommandPaletteButton({super.key, required this.currentIndex});

  void _open(BuildContext context) {
    CommandPalette.show(
      context,
      currentIndex: currentIndex,
      onPick: AppNav.jumpToTab,
      // 与桌面端一致的常用动作命令。/done 依赖首页选中态，此处不注入
      // （面板会把未注入命令标为「当前不可用」，不产生死链）。
      actions: {
        'new': () => QuickEntrySheet.show(context),
        'trash': () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TrashScreen()),
            ),
        'tags': () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TagManageScreen()),
            ),
        'export': () => ExportSheet.show(context),
        'backup': () => BackupSheet.show(context),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    return IconButton(
      onPressed: () => _open(context),
      icon: Icon(Symbols.keyboard_command_key, size: 22, color: onBg),
      tooltip: '命令面板',
      splashRadius: 20,
    );
  }
}
