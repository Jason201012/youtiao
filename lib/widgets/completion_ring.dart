import 'dart:math';
import 'package:flutter/material.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// 完成率圆环：直径 68，描边 8，居中百分比文字。
class CompletionRing extends StatelessWidget {
  final double value; // 0..1
  final String centerText;
  const CompletionRing({
    super.key,
    required this.value,
    required this.centerText,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final progress = isDark ? AppColors.darkAccent : AppColors.lightPrimary;

    return SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 68,
            height: 68,
            child: CustomPaint(
              painter: _RingPainter(
                value: value,
                track: ext.track,
                progress: progress,
                stroke: AppColors.ringStroke,
              ),
            ),
          ),
          Text(
            centerText,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: progress,
              fontFamily: 'Sarasa Gothic SC',
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  final Color track;
  final Color progress;
  final double stroke;

  _RingPainter({
    required this.value,
    required this.track,
    required this.progress,
    required this.stroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = Rect.fromCircle(center: rect.center, radius: size.width / 2);
    // 底环
    canvas.drawCircle(
      rect.center,
      size.width / 2,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    // 进度弧（从顶部 -90° 顺时针）
    canvas.drawArc(
      r,
      -pi / 2,
      (value.clamp(0, 1)) * 2 * pi,
      false,
      Paint()
        ..color = progress
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.value != value || old.track != track || old.progress != progress;
}
