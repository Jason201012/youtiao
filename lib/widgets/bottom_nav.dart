import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 底部胶囊导航（M3 风格）：圆角 36，3 个等宽标签。
class AppBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  const AppBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  static const List<(IconData, String)> _items = [
    (Symbols.home, '首页'),
    (Symbols.dashboard, '看板'),
    (Symbols.calendar_month, '日历'),
    (Symbols.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final selectedText = isDark ? AppColors.lightChip : Colors.white;

    return Padding(
      padding: const EdgeInsets.fromLTRB(21, 12, 21, 21),
      child: Container(
        height: 62,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: ext.navFill,
          borderRadius: BorderRadius.circular(AppColors.navRadius),
          border: Border.all(color: ext.navBorder),
        ),
        child: Row(
          children: [
            for (var i = 0; i < _items.length; i++)
              Expanded(
                child: _NavItem(
                  icon: _items[i].$1,
                  label: _items[i].$2,
                  selected: i == currentIndex,
                  fill: primary,
                  selectedText: selectedText,
                  unselected: ext.meta,
                  onTap: () => onTap(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color fill;
  final Color selectedText;
  final Color unselected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.fill,
    required this.selectedText,
    required this.unselected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? fill : Colors.transparent,
      borderRadius: BorderRadius.circular(AppColors.navItemRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppColors.navItemRadius),
        onTap: onTap,
        child: SizedBox(
          height: 54,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: selected ? selectedText : unselected),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? selectedText : unselected,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
