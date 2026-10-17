/// Aurum · 360° 环绕封面的实时频谱（单条白色闭合曲线）。
/// 对应原版 #specRing：120 个角度均分点，半径随频谱起伏，
/// 经相邻点中点的二次贝塞尔平滑成闭合环；高潮(climax)时整条曲线发散白色辉光。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

const int kSpecN = 120;

/// 频谱环振幅上限（= 曲线可向外凸起的最大像素）。
///
/// 原版 `ampMax = Math.min(cx, cy) * 0.92 - baseR`，其前提是画布真的拿到了
/// 封面的 160%（CSS `inset:-30%`）。若画布被压回封面大小，baseR 会超过画布
/// 半径使结果为负 —— 旧实现直接 `return`，整条环一个像素都不画，
/// 表现为「频谱根本不存在」。这里兜底保留一个最小幅度，保证环始终可见。
double ringAmpMax(double canvasHalf, double coverWidth) =>
    math.max(canvasHalf * 0.12, canvasHalf * 0.92 - coverWidth / 2 * 1.02);

class SpectrumRingPainter extends CustomPainter {
  SpectrumRingPainter({
    required this.vals,
    required this.climax,
    required this.oc,
    required this.coverWidth,
  });

  /// 平滑后的频谱值（0..1），长度 kSpecN，由 VizController 逐帧写入
  final List<double> vals;
  final double climax;
  final bool oc;
  /// 封面 CSS 边长（曲线基准半径紧贴封面边缘）
  final double coverWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final baseR = coverWidth / 2 * 1.02;
    final ampMax = ringAmpMax(math.min(cx, cy), coverWidth);

    final pts = List<Offset>.generate(kSpecN, (i) {
      final step = math.pi * 2 / kSpecN;
      final ang = i * step - math.pi / 2; // 从正上方开始顺时针
      final r = baseR + vals[i] * ampMax * (1 + climax * 0.35);
      return Offset(cx + math.cos(ang) * r, cy + math.sin(ang) * r);
    });

    final path = Path();
    // 经相邻点中点的二次贝塞尔 → 平滑闭合环
    var mx = (pts[kSpecN - 1].dx + pts[0].dx) / 2;
    var my = (pts[kSpecN - 1].dy + pts[0].dy) / 2;
    path.moveTo(mx, my);
    for (var i = 0; i < kSpecN; i++) {
      final cur = pts[i];
      final nxt = pts[(i + 1) % kSpecN];
      final mx2 = (cur.dx + nxt.dx) / 2;
      final my2 = (cur.dy + nxt.dy) / 2;
      path.quadraticBezierTo(cur.dx, cur.dy, mx2, my2);
    }
    path.close();

    final double strokeW = 2 + (oc ? climax * 1.6 : 0.0);
    final double alpha = (0.6 + (oc ? climax * 0.4 : 0.0)).clamp(0.0, 1.0);
    final double glowAlpha = (0.62 * climax).clamp(0.0, 1.0);

    /* 高潮时整条曲线发散白色辉光（对应 web 的 shadowBlur）。
       注意：Canvas 的 shadowBlur 是「先画清晰图形，再在其下层铺一层模糊阴影」，
       线条本体依然清晰。若直接给唯一的 paint 加 MaskFilter.blur，
       会把线条**本身**模糊掉 → 只剩虚影，看起来是「虚化」而不是「发亮」。
       因此这里分两遍：先铺模糊的辉光层，再叠一遍清晰主线。 */
    if (oc && climax > 0.02) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..strokeWidth = strokeW + climax * 3.5
          ..color = Color.fromRGBO(255, 255, 255, glowAlpha)
          ..maskFilter = MaskFilter.blur(
              BlurStyle.normal, climax * 13), // web shadowBlur/2 ≈ sigma
      );
    }

    // 清晰主线（覆盖在辉光之上，保证任何 climax 下线条都锐利可见）
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..strokeWidth = strokeW
        ..color = Color.fromRGBO(255, 255, 255, alpha),
    );
  }

  @override
  bool shouldRepaint(SpectrumRingPainter old) => true;
}
