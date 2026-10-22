/// Aurum · 封面下方的直线频谱。
///
/// 就是 360° 频谱环「拉直」的版本：同一份 120 点取值，从左到右
/// 对应低频 → 高频，画成**一条连续的平滑曲线**（不是一排柱子）。
/// 视觉语言与环形完全一致 —— 相邻点用中点二次贝塞尔过渡、
/// 白色描边、高潮时先铺一层模糊辉光再叠清晰本体。
///
/// 与环形的两点区别：
///  - **灵敏度更高**：取值先开方（抬起中低），再乘 [gain]；
///    环形是 1:1 用平滑值，平缓段落几乎不动，这里会明显跟手。
///  - 开口而不是闭合：从左端画到右端，不做首尾相连。
///
/// 安静时它就是一整条贴底的横线，随音乐起伏成波形。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class LinearSpectrumPainter extends CustomPainter {
  LinearSpectrumPainter({
    required this.vals,
    required this.climax,
    required this.oc,
    this.gain = 1.0,
  });

  /// 平滑后的频谱值（0..1），长度 kSpecN，由 VizController 逐帧写入
  final List<double> vals;
  final double climax;
  final bool oc;

  /// 幅度倍率。**保持 1.0**：specVals 在 VizController 里已经做过
  /// `pow(norm, 0.55) * 1.15` 的提亮，这里再放大就会一播放直接贴顶。
  final double gain;

  /// 1.0 = 线性。曾经用 0.70 开方，与上游提亮叠加后整条线常驻满格 ——
  /// 用户要的「灵敏」是跟手快，不是把值抬满。
  static const double _kGamma = 1.0;

  /// 左右各留 4% 空白（头尾留白）
  static const double _kEdgePad = 0.04;

  @override
  void paint(Canvas canvas, Size size) {
    if (vals.isEmpty || size.isEmpty) return;
    final n = vals.length;
    if (n < 2) return;
    final w = size.width;
    final h = size.height;
    // 头尾各留一段空白：曲线两端不贴画布边缘，看着才像"从 10Hz 到 21kHz"
    // 的一条标尺，而不是被裁断的一条线。
    final pad = w * _kEdgePad;
    final step = (w - pad * 2) / (n - 1);

    // 采样点：x 均分（内含头尾留白），y 从底部往上。上下各留 1px 防裁。
    final pts = List<Offset>.generate(n, (i) {
      final v = (math.pow(vals[i].clamp(0.0, 1.0), _kGamma) * gain)
          .clamp(0.0, 1.0)
          .toDouble();
      return Offset(pad + i * step, h - 1 - v * (h - 2));
    });

    // 与环形同一套平滑：经相邻点中点的二次贝塞尔（只是不闭合）
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 1; i < n - 1; i++) {
      final mid = Offset(
        (pts[i].dx + pts[i + 1].dx) / 2,
        (pts[i].dy + pts[i + 1].dy) / 2,
      );
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(pts[n - 1].dx, pts[n - 1].dy);

    final double strokeW = 2 + (oc ? climax * 1.6 : 0.0);
    final double alpha = (0.6 + (oc ? climax * 0.4 : 0.0)).clamp(0.0, 1.0);
    final double glowAlpha = (0.62 * climax).clamp(0.0, 1.0);

    // 高潮辉光：先铺模糊层，再叠清晰主线（与环形同一处理，
    // 直接给唯一的 paint 加 MaskFilter 会把线本身糊掉）
    if (oc && climax > 0.02) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..strokeWidth = strokeW + climax * 3.0
          ..color = Color.fromRGBO(255, 255, 255, glowAlpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, climax * 10),
      );
    }

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
  bool shouldRepaint(LinearSpectrumPainter old) => true;
}
