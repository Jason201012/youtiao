import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 后台提醒守护状态卡：展示前台服务保活是否开启，
/// 开启后划掉后台 / 重启后定时与每日提醒仍能准点送达（ColorOS 等国产 ROM 关键）。
class GuardStatusCard extends StatelessWidget {
  final bool enabled;
  const GuardStatusCard({super.key, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final scheme = Theme.of(context).colorScheme;
    // U16：硬编码 0xFF0F6E56 / 0xFFE1F5EE（浅绿系）在深色模式下文字/背景近同、
    // 无法辨识。改为语义色：开启态用主色 + 主色淡底（暗色下自动适配）。
    final active = enabled ? scheme.primary : ext.meta;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Row(
        children: [
          Icon(enabled ? Symbols.verified : Symbols.shield, color: active, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('后台提醒守护',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: onBg)),
                const SizedBox(height: 2),
                Text(
                  enabled ? '守护中，定时提醒准时送达' : '已关闭，划掉后台后提醒可能延误',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ext.meta),
                ),
              ],
            ),
          ),
          Container(
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: enabled ? scheme.primary.withOpacity(0.14) : ext.track,
              borderRadius: BorderRadius.circular(AppColors.chipRadius),
            ),
            child: Center(
              child: Text(
                enabled ? '守护中' : '已关闭',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
