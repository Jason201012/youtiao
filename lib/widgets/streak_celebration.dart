import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

/// 打破连续天数历史纪录时的全屏庆祝动效。
///
/// 纯 Flutter 实现，不引入 confetti 等第三方包：中心火焰弹性放大 + 「新纪录 N 天」
/// 文案淡入 + 一圈 emoji 粒子向外迸射并淡出，~2 秒后自动消失。通过根 Overlay 插入，
/// 可盖在底部弹层（习惯详情 / 分享面板）之上。
void showStreakCelebration(BuildContext context, int days) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _StreakCelebrationOverlay(
      days: days,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _StreakCelebrationOverlay extends StatefulWidget {
  final int days;
  final VoidCallback onDone;
  const _StreakCelebrationOverlay({
    required this.days,
    required this.onDone,
  });

  @override
  State<_StreakCelebrationOverlay> createState() =>
      _StreakCelebrationOverlayState();
}

class _StreakCelebrationOverlayState extends State<_StreakCelebrationOverlay>
    with SingleTickerProviderStateMixin {
  static const _particles = [
    '🎉', '✨', '🔥', '💪', '⭐', '🏆', '🌟', '🎊'
  ];

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    // 动画到达峰值后短暂停留，再自动收起，避免遮挡过久。
    Timer(const Duration(milliseconds: 2000), widget.onDone);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 火焰弹性放大：前 60% 进度用 elasticOut 回弹，之后稳定在 1.0。
  double _popScale(double p) {
    final t = Curves.elasticOut.transform((p / 0.6).clamp(0.0, 1.0));
    return 0.3 + 0.7 * t;
  }

  Widget _particle(int i, double p) {
    final angle = (i / _particles.length) * 2 * pi;
    final dist = 150.0 * Curves.easeOut.transform(p.clamp(0.0, 1.0));
    final dx = cos(angle) * dist;
    final dy = sin(angle) * dist;
    final op = (1.0 - p).clamp(0.0, 1.0);
    final scale = 0.5 + 0.5 * p;
    return Transform.translate(
      offset: Offset(dx, dy),
      child: Opacity(
        opacity: op,
        child: Transform.scale(
          scale: scale,
          child: Text(_particles[i], style: const TextStyle(fontSize: 26)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.45),
      child: IgnorePointer(
        child: Center(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              final p = _ctrl.value;
              final textOpacity = ((p - 0.25) / 0.75).clamp(0.0, 1.0);
              return Stack(
                alignment: Alignment.center,
                children: [
                  for (int i = 0; i < _particles.length; i++)
                    _particle(i, p),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.scale(
                        scale: _popScale(p),
                        child: const Text('🔥', style: TextStyle(fontSize: 84)),
                      ),
                      const SizedBox(height: 10),
                      Opacity(
                        opacity: textOpacity,
                        child: Column(
                          children: [
                            const Text(
                              '新纪录！',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '连续 ${widget.days} 天',
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
