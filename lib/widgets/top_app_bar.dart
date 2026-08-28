import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/theme/tokens.dart';

/// 顶部应用栏：高 64，左右 padding 20，标题 28 Bold。
/// - [title] 始终显示
/// - [onBack] 非空时显示返回箭头（24px，onBackground 色），与标题间距 8，匹配设计稿「顶部应用栏」
/// - [actions] 标题右侧附加控件（如清空按钮），传入后自动撑开
class TopAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final VoidCallback? onBack;
  final List<Widget>? actions;

  const TopAppBar({
    super.key,
    required this.title,
    this.onBack,
    this.actions,
  });

  @override
  final Size preferredSize = const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final onBg = Theme.of(context).colorScheme.onBackground;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppColors.pagePadX),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (onBack != null) ...[
              IconButton(
                onPressed: onBack,
                icon: Icon(Symbols.arrow_back_ios, size: 24, color: onBg),
                splashRadius: 20,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              title,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: onBg,
              ),
            ),
            if (actions != null) ...[
              const Spacer(),
              ...actions!,
            ],
          ],
        ),
      ),
    );
  }
}
