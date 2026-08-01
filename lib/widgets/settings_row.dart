import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 设置行：高 56，圆角 12，surface 填充。
/// 图标(24) + 标签(15) + 可选值(14) + 可选箭头(20)
class SettingsRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final bool showArrow;
  final VoidCallback? onTap;
  final bool? switchValue;
  final ValueChanged<bool>? onSwitchChanged;
  const SettingsRow({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.showArrow = true,
    this.onTap,
    this.switchValue,
    this.onSwitchChanged,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Container(
      height: 56,
      padding: const EdgeInsets.only(left: 16, right: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: ext.meta),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: onBg)),
            ),
            if (switchValue != null)
              Switch(
                value: switchValue!,
                onChanged: onSwitchChanged,
                splashRadius: 0,
              )
            else ...[
              if (value != null)
                Text(value!, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: ext.meta)),
              if (showArrow) ...[
                const SizedBox(width: 12),
                Icon(Symbols.arrow_forward_ios, size: 20, color: ext.meta),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
