import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

/// 新建任务 FAB（仅首页）：56×56，圆角 28，primary 填充，白色 + 图标。
class NewTaskFab extends StatelessWidget {
  final VoidCallback? onPressed;
  const NewTaskFab({super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: primary,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: primary.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: const Icon(Symbols.add, size: 24, color: Colors.white),
      ),
    );
  }
}
