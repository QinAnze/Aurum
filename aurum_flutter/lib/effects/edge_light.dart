/// 窗口四周打光：kick 响起时整窗边缘亮一圈（舞台灯 / 夜店打光）。
///
/// 组成（从外到内）：
///  - 四条边向内的线性渐变光带（主色 c1）
///  - 四角径向聚光（辅色 c2），让角落更像灯头
///  - 两道细描边：外侧柔光 + 内侧亮线（灯管本体）
///
/// 强度完全由 [level]（KickDetector.env）驱动：0 时一帧都不画。
/// 外层 IgnorePointer —— 这是纯装饰层，绝不能拦鼠标。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class EdgeLight extends StatelessWidget {
  const EdgeLight({
    super.key,
    required this.level,
    required this.c1,
    required this.c2,
  });

  /// 0..1：kick 包络
  final double level;
  final Color c1;
  final Color c2;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: EdgeLightPainter(level: level, c1: c1, c2: c2),
      ),
    );
  }
}

class EdgeLightPainter extends CustomPainter {
  const EdgeLightPainter({
    required this.level,
    required this.c1,
    required this.c2,
  });

  final double level;
  final Color c1;
  final Color c2;

  @override
  void paint(Canvas canvas, Size size) {
    final lv = level.clamp(0.0, 1.0);
    if (lv <= 0.004 || size.width <= 0 || size.height <= 0) return;

    final w = size.width;
    final h = size.height;
    final band = math.min(w, h) * 0.20; // 光向内渗透的宽度
    final full = Offset.zero & size;

    void edge(Rect rect, Alignment from, Alignment to) {
      final paint = Paint()
        ..shader = LinearGradient(
          begin: from,
          end: to,
          colors: [
            c1.withValues(alpha: 0.52 * lv),
            c1.withValues(alpha: 0.16 * lv),
            Colors.transparent,
          ],
          stops: const [0, 0.42, 1],
        ).createShader(rect);
      canvas.drawRect(rect, paint);
    }

    edge(Rect.fromLTWH(0, 0, w, band * 1.25), Alignment.topCenter,
        Alignment.bottomCenter);
    edge(Rect.fromLTWH(0, h - band * 1.25, w, band * 1.25),
        Alignment.bottomCenter, Alignment.topCenter);
    edge(Rect.fromLTWH(0, 0, band, h), Alignment.centerLeft,
        Alignment.centerRight);
    edge(Rect.fromLTWH(w - band, 0, band, h), Alignment.centerRight,
        Alignment.centerLeft);

    // 四角聚光：半径压在 0.38，避免四团光在画面中心糊成一片
    final r = math.min(w, h) * 0.38;
    for (final center in [
      const Offset(0, 0),
      Offset(w, 0),
      Offset(0, h),
      Offset(w, h),
    ]) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [c2.withValues(alpha: 0.34 * lv), Colors.transparent],
        ).createShader(Rect.fromCircle(center: center, radius: r));
      canvas.drawCircle(center, r, paint);
    }

    // 灯管本体：宽柔光 + 细亮线（不用 MaskFilter，省一次离屏合成）
    final soft = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..color = c1.withValues(alpha: 0.10 * lv);
    canvas.drawRect(full.deflate(6), soft);

    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = c1.withValues(alpha: 0.55 * lv);
    canvas.drawRect(full.deflate(1.2), rim);

    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.18 * lv);
    canvas.drawRect(full.deflate(2.8), inner);
  }

  @override
  bool shouldRepaint(EdgeLightPainter old) =>
      old.level != level || old.c1 != c1 || old.c2 != c2;
}
